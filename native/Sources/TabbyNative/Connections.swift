import Foundation
import AppKit
import SwiftUI
import SwiftTerm
import Citadel
import NIO
import NIOSSH
import Crypto

final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let endpoint: String
    let store: AppStore
    let certificateAuthorityConfigured: Bool
    init(endpoint: String, store: AppStore, certificateAuthorityConfigured: Bool = false) { self.endpoint = endpoint; self.store = store; self.certificateAuthorityConfigured = certificateAuthorityConfigured }
    func validateHostCertificate(hostKey: NIOSSHPublicKey, certifiedKey: NIOSSHCertifiedPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // NIOSSH has already checked configured CA, host principal, expiry and signature.
        guard certificateAuthorityConfigured else { validationCompletePromise.fail(AgentWire.failure); return }
        validationCompletePromise.succeed(())
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let encoded = String(openSSHPublicKey: hostKey)
        let bytes = encoded.split(separator: " ").dropFirst().first.flatMap { Data(base64Encoded: String($0)) } ?? Data()
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        Task { @MainActor in
            if let known = store.workspace.trustedKeys[endpoint] {
                guard known == encoded else { validationCompletePromise.fail(AppFailure.message("Host key changed for \(endpoint). Connection rejected.")); return }
            } else {
                let alert = AppModalAlert()
                alert.messageText = store.text("Trust this server?", "信任此服务器？")
                alert.informativeText = "\(endpoint)\n\(fingerprint)\n" + store.text("Verify this fingerprint before connecting.", "请确认服务器指纹后连接。")
                alert.addButton(withTitle: store.text("Trust and connect", "信任并连接")); alert.addButton(withTitle: store.text("Cancel", "取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { validationCompletePromise.fail(CancellationError()); return }
                store.workspace.trustedKeys[endpoint] = encoded; store.save()
            }
            validationCompletePromise.succeed(())
        }
    }
}

@MainActor final class TerminalSession: ObservableObject, Identifiable, TerminalViewDelegate {
    private static var nextCreationOrder: UInt64 = 0
    let id = UUID()
    let creationOrder: UInt64
    let host: Host?
    weak var sceneFiles: FileManagerModel?
    private(set) var authenticatedUsername: String?
    private(set) var authenticatedAddress: String?
    private(set) var authenticatedPort: Int?
    private(set) var authenticatedRoute: [MonitoringRouteHop] = []
    private(set) var connectionInProgress = false
    unowned let store: AppStore
    @Published private(set) var title: String {
        didSet { if title != oldValue { store.objectWillChange.send() } }
    }
    @Published var status = ""
    @Published private(set) var currentDirectory: String? {
        didSet { if currentDirectory != oldValue { store.objectWillChange.send() } }
    }
    @Published var followDirectoryInFiles = false {
        didSet { store.objectWillChange.send() }
    }
    var commandOriginTracker = CommandOriginTracker()
    var lastTranscriptOrigin: CommandOrigin?
    @Published var transcriptID: UUID?
    var commandHistoryStore: CommandHistoryStore?
    var commandHistoryToken = ""
    var aiCommandCapture = AICommandCapture()
    let aiControl = AITerminalControl()
    var aiApplicationCursor = false
    var aiShellInput = AIShellInput()
    var aiTerminalInputRevision: UInt64 = 0
    var aiTerminalOutputRevision: UInt64 = 0
    var aiShellCompletionRevision: UInt64 = 0
    var aiShellExitCode: Int?
    var activeCommandHistoryID: UUID?
    var activeCommandSequence: UInt64?
    var persistentOverride: Bool?
    var persistentNameOverride: String?
    var persistentSessionWasCreated = false
    @Published var commandHistoryReady = false
    @Published var commandHistoryRecording = true
    var pendingDirectoryInsertion: (command: String, host: Host?)?
    @Published var connected = false {
        didSet {
            if !connected { aiControl.disconnected(); aiCommandCapture = AICommandCapture(); aiApplicationCursor = false; aiShellExitCode = nil }
            if connected != oldValue {
                store.objectWillChange.send()
                store.monitoring.connectionsChanged()
                if connected { deliverPendingDirectoryInsertion() }
            }
        }
    }
    var client: SSHClient?
    private var jumpClients: [SSHClient] = []
    var writer: TTYStdinWriter?
    @Published private(set) var fontSizeOverride: Double? {
        didSet { store.objectWillChange.send() }
    }
    var effectiveFontSize: Double { fontSizeOverride ?? store.workspace.preferences.fontSize }
    func setFontSize(_ size: Double?) {
        if let size, !size.isFinite { return }
        fontSizeOverride = size.map { min(40, max(10, $0)) }
        applyFontSize()
    }
    func adjustFontSize(_ delta: Double) { setFontSize(effectiveFontSize + delta) }
    func applyFontSize() {
        guard let terminal else { return }
        let size = effectiveFontSize
        terminal.font = NSFont(name: store.workspace.preferences.fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .light)
    }
    var terminal: TerminalView?
    var task: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    var commandHistoryStartupTask: Task<Void, Never>?
    var commandHistoryBootstrapScreen = false
    var commandHistoryBootstrapCover: NSView?
    private(set) var generation = 0
    private var localProcessGeneration: Int?
    private var columns = 100
    private var rows = 30
    private var temporaryAuthentications: [UUID: ConnectionAuthenticationCacheEntry] = [:]
    private var resolvedSettingsHosts: [UUID: Host] = [:]
    private var authenticationWindow: ConnectionAuthenticationWindowController?
    init(host: Host?, store: AppStore) {
        creationOrder = Self.nextCreationOrder; Self.nextCreationOrder += 1
        self.host = host; self.store = store
        authenticatedUsername = host.map { RecentTargets.effectiveUsername($0, workspace: store.workspace) }
        authenticatedAddress = host?.address; authenticatedPort = host.map { store.resolvedHost($0).port }
        self.title = host.map { Self.remoteTitle(for: $0, store: store) } ?? store.text("Local terminal", "本地终端")
    }
    private static func remoteTitle(for host: Host, store: AppStore) -> String {
        let name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? host.address : name
        let username = RecentTargets.effectiveUsername(host, workspace: store.workspace)
        return username.isEmpty ? label : "\(username)@\(label)"
    }
    func matchesEndpoint(_ target: Host) -> Bool {
        guard let host, RecentTargets.canReuseProfile(host, target, workspace: store.workspace) else { return false }
        let requested = store.resolvedHost(target)
        if connected {
            var route: [MonitoringRouteHop] = []
            var current = requested
            var seen: Set<UUID> = [current.id]
            while let id = current.jumpHostID {
                guard seen.insert(id).inserted, let raw = store.workspace.hosts.first(where: { $0.id == id }) else { return false }
                current = store.resolvedHost(raw)
                route.insert(MonitoringRouteHop(address: current.address, port: current.port, username: current.username), at: 0)
            }
            guard route == authenticatedRoute else { return false }
        }
        return authenticatedAddress?.caseInsensitiveCompare(requested.address) == .orderedSame
            && authenticatedPort == requested.port
            && authenticatedUsername == requested.username
    }
    func makeView() -> TerminalView {
        if let terminal { return terminal }
        let pref = store.workspace.preferences
        let options = TerminalOptions(termName: "xterm-256color", cursorStyle: TerminalAppearance.cursorStyle(pref), scrollback: max(0, min(1000000, pref.scrollback)), enableSixelReported: false)
        let font = NSFont(name: pref.fontName, size: pref.fontSize) ?? .monospacedSystemFont(ofSize: pref.fontSize, weight: .light)
        let view: TerminalView
        if host == nil {
            let local = LocalTerminal(frame: .zero, font: font, options: options)
            local.terminalDelegate = self
            local.store = store; local.sessionID = id; local.ownerSession = self
            view = local
        } else {
            let remote = RemoteTerminal(frame: .zero, font: font, options: options)
            remote.store = store; remote.sessionID = id; remote.ownerSession = self
            remote.terminalDelegate = self
            view = remote
        }
        TerminalAppearance.apply(pref, to: view)
        terminal = view
        applyFontSize()
        KeywordOverlay.attach(to: view, store: store, sessionID: id)
        if let local = view as? LocalTerminal {
            localProcessGeneration = generation
            let launch = LocalTerminalLaunch(preferences: pref)
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            local.startProcess(executable: launch.executable, args: launch.arguments, environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: launch.directory)
            connected = true; status = store.text("Connected", "已连接")
            startAutomaticCommandHistory()
            if local.process.running { store.recordRecentSuccess(kind: .localTerminal) }
        } else { reconnect() }
        return view
    }
    func settings(for original: Host,
                  authenticationPrompt: ((ConnectionAuthenticationDraft) throws -> ConnectionAuthenticationResult)? = nil) throws -> SSHClientSettings {
        // Metadata validation still precedes Keychain reads and presentation.
        // Reload saved auth metadata so remembered choices apply on reconnect.
        let saved = GroupDefaults.connectionSource(original, workspace: store.workspace)
        let source = try ConnectionValidation.host(saved, workspace: store.workspace, chinese: store.chinese)
        SSHCertificates.registerRSA()
        let authority = try source.hostCertificateAuthorityPath.flatMap { $0.isEmpty ? nil : try SSHCertificates.publicKey($0) }
        if source.auth == "agent" {
            let path = try AgentWire.socketPath(source)
            resolvedSettingsHosts[original.id] = source
            var settings = SSHClientSettings(host: source.address, port: source.port,
                authenticationMethod: { .custom(AgentAuthentication(username: source.username, path: path, fingerprint: source.agentFingerprint, certificatePath: source.certificatePath, authorityPath: source.certificateAuthorityPath)) },
                hostKeyValidator: .custom(HostKeyCheck(endpoint: "\(source.address):\(source.port)", store: store, certificateAuthorityConfigured: authority != nil)))
            settings.trustedHostCAKeys = authority.map { [$0] } ?? []
            settings.connectTimeout = .seconds(Int64(max(1, min(120, store.workspace.preferences.sshConnectTimeout))))
            settings.algorithms.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self), (Insecure.RSA.PublicKey.self, Insecure.RSA.SHA256Signature.self)])
            return settings
        }
        let secretID = store.groupSecretID(for: saved)
        let material = Secrets.Value(secret: try Secrets.readChecked(secretID),
                                     privateKey: source.auth == "key" && source.keySource == "text" ? try Secrets.readPrivateKey(secretID) : "")
        var draft = ConnectionAuthenticationDraft(host: source, material: material)
        var reusable: ConnectionAuthenticationResult?
        var validationError = ""
        var refreshTemporarySelection = false
        if let cached = temporaryAuthentications[source.id], cached.matches(host: source, material: material) {
            if let shared = cached.result.sharedSnapshot {
                if store.workspace.credentials.contains(where: { $0.id == cached.result.host.credentialID }) {
                    let chosen = try ConnectionValidation.host(cached.result.host, workspace: store.workspace, chinese: store.chinese)
                    let chosenMaterial = try Secrets.readCredential(chosen.credentialID!)
                    if shared.matches(host: chosen, material: chosenMaterial) { reusable = cached.result }
                    else {
                        // Keep the temporary identity selection while honoring
                        // edits to its shared metadata and saved secrets.
                        draft = ConnectionAuthenticationDraft(host: chosen, material: chosenMaterial)
                        refreshTemporarySelection = true
                    }
                } else {
                    validationError = store.text("The shared credential is unavailable. Choose another credential.", "共享凭据已不存在，请选择其他凭据。")
                }
            } else { reusable = cached.result }
        }
        let result: ConnectionAuthenticationResult
        if let reusable { result = reusable }
        else {
            temporaryAuthentications[source.id] = nil
            var existing: ConnectionAuthenticationResult?
            do { existing = try draft.validatedResult(workspace: store.workspace, chinese: store.chinese) }
            catch {
                // A missing password is the normal prompt. Key errors explain
                // why the saved file, text or passphrase needs attention.
                if draft.host.auth == "key" { validationError = error.localizedDescription }
            }
            if let existing {
                result = existing
                if refreshTemporarySelection {
                    temporaryAuthentications[source.id] = .init(sourceHost: source, sourceMaterial: material, result: result)
                }
            }
            else {
                if let authenticationPrompt {
                    result = try authenticationPrompt(draft)
                    _ = try result.authentication(chinese: store.chinese)
                    try store.rememberConnectionAuthentication(result)
                } else {
                    let controller = ConnectionAuthenticationWindowController(draft: draft, store: store, initialError: validationError)
                    authenticationWindow = controller
                    defer { if authenticationWindow === controller { authenticationWindow = nil } }
                    result = try controller.present()
                }
                if !result.remember {
                    temporaryAuthentications[source.id] = .init(sourceHost: source, sourceMaterial: material, result: result)
                }
            }
        }
        try Task.checkCancellation()
        let host = result.host
        let auth = try result.authentication(chinese: store.chinese)
        resolvedSettingsHosts[original.id] = host
        var settings = SSHClientSettings(host: host.address, port: host.port, authenticationMethod: { auth }, hostKeyValidator: .custom(HostKeyCheck(endpoint: "\(host.address):\(host.port)", store: store, certificateAuthorityConfigured: authority != nil)))
        settings.trustedHostCAKeys = authority.map { [$0] } ?? []
        settings.connectTimeout = .seconds(Int64(max(1, min(120, store.workspace.preferences.sshConnectTimeout))))
        settings.algorithms.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self), (Insecure.RSA.PublicKey.self, Insecure.RSA.SHA256Signature.self)])
        return settings
    }
    func settingsUsername(for host: Host) -> String {
        resolvedSettingsHosts[host.id]?.username ?? RecentTargets.effectiveUsername(host, workspace: store.workspace)
    }
    func settingsHost(for host: Host) -> Host { resolvedSettingsHosts[host.id] ?? store.resolvedHost(host) }
    func reconnect() {
        guard let host else { return }
        disconnect()
        authenticatedRoute = []
        title = Self.remoteTitle(for: host, store: store)
        let request = generation
        task = Task {
            guard request == generation, !Task.isCancelled else { return }
            var outputFinished = false
            var outputError: Error?
            do {
                connectionInProgress = true
                defer { if request == generation { connectionInProgress = false } }
                status = store.text("Connecting…", "正在连接…")
                store.record("ssh", "connecting", host: host.name)
                var chain: [Host] = []; var current: Host? = host; var seen = Set<UUID>()
                while let h = current {
                    guard seen.insert(h.id).inserted else { throw AppFailure.message("Jump host cycle") }
                    let source = GroupDefaults.connectionSource(h, workspace: store.workspace)
                    chain.insert(source, at: 0)
                    if let jump = store.resolvedHost(source).jumpHostID {
                        guard let next = store.workspace.hosts.first(where: { $0.id == jump }) else { throw AppFailure.message("Jump host not found") }
                        current = next
                    } else { current = nil }
                }
                var connection: SSHClient?
                for h in chain {
                    try Task.checkCancellation()
                    let next: SSHClient
                    let connectionSettings = try settings(for: h)
                    let usernameSnapshot = settingsUsername(for: h)
                    let endpoint = settingsHost(for: h)
                    let addressSnapshot = endpoint.address, portSnapshot = endpoint.port
                    if let connection { next = try await connection.jump(to: connectionSettings) }
                    else { next = try await SSHClient.connect(to: connectionSettings) }
                    guard request == generation else { try? await next.close(); throw CancellationError() }
                    if h.id != host.id {
                        // Own each authenticated hop before a later hop can
                        // prompt or fail, so cancellation also closes the chain.
                        jumpClients.append(next)
                        authenticatedRoute.append(MonitoringRouteHop(address: addressSnapshot, port: portSnapshot, username: usernameSnapshot))
                    }
                    if h.id == host.id {
                        authenticatedUsername = usernameSnapshot
                        authenticatedAddress = addressSnapshot; authenticatedPort = portSnapshot
                        let label = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        title = "\(usernameSnapshot)@\(label.isEmpty ? host.address : label)"
                    }
                    connection = next
                }
                guard let connection else { return }
                client = connection
                if usesPersistentSession { try await preparePersistentSession(connection) }
                if settingsHost(for: host).forwardAgent == true {
                    let socket = try AgentWire.socketPath(settingsHost(for: host))
                    guard let fingerprint = settingsHost(for: host).agentFingerprint else { throw AppFailure.message("Select an Agent identity before forwarding / 请先选择转发的 Agent 身份") }
                    let identities = try await Task.detached { try AgentWire.identities(path: socket).filter { $0.fingerprint == fingerprint } }.value
                    guard identities.count == 1 else { throw AgentWire.failure }
                    connection.enableAgentForwarding { channel in channel.pipeline.addHandler(AgentForwardingHandler(path: socket, identities: identities)) }
                }
                client = connection; status = store.text("Opening terminal…", "正在打开终端…")
                try await connection.withPTY(.init(wantReply: true, term: "xterm-256color", terminalCharacterWidth: 100, terminalRowHeight: 30, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { output, input in
                    guard request == generation, !Task.isCancelled else { throw CancellationError() }
                    writer = input;
                    let bootstrap = usesPersistentSession ? "" : automaticCommandHistoryScript()
                    if self.usesPersistentSession { try await input.write(ByteBuffer(string: PersistentSession.attach(name: self.persistentName))) }
                    else {
                        commandHistoryStartupTask = Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(150))
                            guard let self, self.generation == request, !Task.isCancelled else { return }
                            self.beginCommandHistoryBootstrapScreen()
                            do {
                                for line in bootstrap.components(separatedBy: "\n") {
                                    try Task.checkCancellation()
                                    try await input.write(ByteBuffer(string: line + "\r"))
                                    try await Task.sleep(for: .milliseconds(2))
                                }
                                for _ in 0..<20 {
                                    if self.commandHistoryReady { break }
                                    try await Task.sleep(for: .milliseconds(100))
                                }
                                if self.generation == request { self.endCommandHistoryBootstrapScreen() }
                            } catch { self.endCommandHistoryBootstrapScreen() }
                        }
                    }
                    connected = true; connectionInProgress = false; status = store.text("Connected", "已连接")
                    store.record("ssh", "connected", host: host.name)
                    store.recordRecentSuccess(host, kind: .ssh)
                    do {
                        try await input.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
                        for try await event in output {
                            try Task.checkCancellation()
                            guard request == generation else { throw CancellationError() }
                            switch event {
                            case .stdout(let bytes), .stderr(let bytes):
                                let output = Array(bytes.readableBytesView); captureOutput(output); terminal?.feed(byteArray: output[...])
                            }
                        }
                        outputFinished = true
                    } catch {
                        // Citadel may replace an output error with alreadyClosed
                        // while closing its PTY. Keep the original failure visible.
                        outputError = error
                        throw error
                    }
                }
                guard request == generation else { return }
                connectionEnded(request: request, error: connection.isConnected ? nil : unexpectedDisconnect())
            } catch {
                guard request == generation else { return }
                if outputError == nil, outputFinished, client?.isConnected == true,
                   let channelError = error as? ChannelError, channelError == .alreadyClosed {
                    connectionEnded(request: request)
                } else {
                    connectionEnded(request: request, error: outputError ?? error)
                }
            }
        }
    }
    private func unexpectedDisconnect() -> Error {
        AppFailure.message(store.text("Connection ended unexpectedly. Reconnect to try again.", "连接意外中断，请重新连接。"))
    }
    /// A completion belongs to exactly one connection attempt. Closing or
    /// reconnecting invalidates it before any asynchronous cleanup can return.
    func connectionEnded(request: Int, error: Error? = nil) {
        guard request == generation else { return }
        pendingDirectoryInsertion = nil
        if error == nil || error is CancellationError {
            if error is CancellationError, let host { store.record("ssh", "cancelled", host: host.name) }
            if store.sessions.contains(where: { $0 === self }) { store.close(id) }
            else { disconnect() }
            return
        }
        guard let failure = error else { return }
        disconnect()
        if let exit = failure as? SSHClient.CommandFailed {
            status = store.text("Remote process exited with status \(exit.exitCode)", "远程进程退出，状态码 \(exit.exitCode)")
        } else { status = failure.localizedDescription }
        if let host { store.record("ssh", "connection failed", host: host.name, failed: true) }
        terminal?.feed(text: "\r\n\(status)\r\n")
    }
    func disconnect() {
        stopTranscript(); store.synchronizationEnabled = false
        generation += 1; localProcessGeneration = nil
        currentDirectory = nil
        authenticationWindow?.cancel()
        if connected, let host { store.record("ssh", "disconnected", host: host.name) }
        commandHistoryToken = ""; commandHistoryReady = false; activeCommandHistoryID = nil; commandOriginTracker = CommandOriginTracker(); aiShellInput.invalidate(); lastTranscriptOrigin = nil
        inputTask?.cancel(); inputTask = nil
        commandHistoryStartupTask?.cancel(); commandHistoryStartupTask = nil
        endCommandHistoryBootstrapScreen()
        task?.cancel(); task = nil; writer = nil; connected = false; connectionInProgress = false
        if let local = terminal as? LocalTerminal { local.terminate() }
        let clients = jumpClients + (client.map { [$0] } ?? [])
        client = nil; jumpClients = []
        Task { for c in clients.reversed() { try? await c.close() } }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        columns = newCols; rows = newRows
        (source as? LocalTerminal)?.resizeProcess(columns: newCols, rows: newRows)
        Task { try? await writer?.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0) }
    }
    func setTerminalTitle(source: TerminalView, title: String) { if host == nil && !title.isEmpty { self.title = title } }
    /// Authenticated shell-hook metadata also supports shells without OSC 7 directory reports.
    func updateShellDirectory(_ path: String) {
        guard connected, let normalized = try? TerminalDirectoryBridge.normalizedPath(path) else { return }
        currentDirectory = normalized
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard source === terminal, connected else { return }
        if receiveCommandHistory(directory) { return }
        let previous = currentDirectory
        currentDirectory = TerminalDirectoryBridge.currentDirectory(directory, trustedHosts: directoryTrustedHosts)
        guard followDirectoryInFiles, currentDirectory != previous, let currentDirectory else { return }
        do { try store.openTerminalDirectoryInFiles(sessionID: id, path: currentDirectory, activate: false) }
        catch { store.error = error.localizedDescription }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal, let request = localProcessGeneration, request == generation else { return }
        if exitCode == 0 { connectionEnded(request: request) }
        else {
            let message = exitCode.map { store.text("Process exited with status \($0)", "进程退出，状态码 \($0)") }
                ?? store.text("Process ended unexpectedly", "进程意外结束")
            connectionEnded(request: request, error: AppFailure.message(message))
        }
    }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard source === terminal, let request = localProcessGeneration, request == generation else { return }
        connectionEnded(request: request, error: AppFailure.message(store.text("Process launch failed: \(error)", "进程启动失败：\(error)")))
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard source === terminal else { return }
        if store.sessions.contains(where: { $0 === self }) { store.dispatchUserInput(from: id, bytes: Array(data)) }
        else { writeInput(Array(data)) }
    }
    func writeInput(_ data: [UInt8]) {
        guard connected else { return }
        aiControl.takeover(); store.takeOverAI(sessionID: id)
        aiTerminalInputRevision &+= 1
        let local = terminal as? LocalTerminal
        let bytes = ByteBuffer(bytes: data)
        let previous = inputTask; let startup = commandHistoryStartupTask; let input = writer; let request = generation
        inputTask = Task {
            await previous?.value
            await startup?.value
            guard !Task.isCancelled, request == generation else { return }
            do { self.aiShellInput.input(data); self.recordInputOrigin(.human, bytes: data); if let local { local.process.send(data: data[...]) } else { try await input?.write(bytes) } }
            catch { if request == generation { status = error.localizedDescription } }
        }
    }
    /// Preserve input ordering and report transport failures to the task agent.
    func waitForQueuedInput() async throws {
        let request = generation, previous = inputTask
        await previous?.value
        try Task.checkCancellation()
        guard connected, request == generation else { throw AppFailure.message("Terminal changed / 终端已变化") }
    }
    func writeAgentInput(_ data: [UInt8], expectedRevision: UInt64? = nil, expectedCommand: String? = nil, controlLease: UUID? = nil, expectedExecutionID: UUID? = nil) async throws {
        let previous = inputTask, startup = commandHistoryStartupTask, request = generation
        let local = terminal as? LocalTerminal, input = writer
        var failure: Error?
        let work = Task { @MainActor in
            do {
                await previous?.value; await startup?.value
                try Task.checkCancellation()
                guard connected, request == generation else { throw AppFailure.message("Terminal changed / 终端已变化") }
                if let controlLease { try aiControl.validate(controlLease) }
                if let expectedExecutionID, aiCommandCapture.current?.id != expectedExecutionID { throw AppFailure.message("Foreground program changed / 前台程序已变化") }
                guard expectedRevision == nil || expectedRevision == aiTerminalInputRevision,
                      expectedCommand == nil || expectedCommand == aiShellInput.line else { throw AppFailure.message("Terminal input changed before execution / 执行前终端输入已变化，请重新检查命令。") }
                aiShellInput.input(data)
                aiTerminalInputRevision &+= 1
                recordInputOrigin(.ai, bytes: data)
                if let local { local.process.send(data: data[...]) }
                else if let input { try await input.write(ByteBuffer(bytes: data)) }
                else { throw AppFailure.message("Terminal input unavailable / 终端输入不可用") }
            } catch { failure = error }
        }
        inputTask = work
        await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        if let failure { throw failure }
    }
    func writeBootstrapInput(_ bytes: [UInt8]) {
        if let local = terminal as? LocalTerminal { local.process.send(data: bytes[...]) }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) { NSSound.beep() }
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

}

extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        if let value = self { return try await transform(value) }; return nil
    }
}

@MainActor class RemoteTerminal: TerminalView {
    weak var store: AppStore?
    weak var ownerSession: TerminalSession?
    var sessionID: UUID?
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ownerSession?.writeInput(bytes)
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusAttachedTerminal(self, store: store, sessionID: sessionID) }
    override func mouseDown(with event: NSEvent) { if let sessionID { store?.activeSession = sessionID }; super.mouseDown(with: event) }
    override func paste(_ sender: Any) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        TerminalPaste.perform(text, preferences: store?.workspace.preferences ?? Preferences(), confirm: { TerminalPaste.confirm($0, chinese: store?.chinese == true, window: window) }, send: pasteText)
    }
    override func rightMouseDown(with event: NSEvent) {
        if store?.workspace.preferences.rightClickPaste == true && getSelection()?.isEmpty != false { paste(self) } else { super.rightMouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)?.copy() as? NSMenu ?? NSMenu()
        if getSelection()?.isEmpty == false {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: store?.text("Locate selected path in SFTP", "在 SFTP 定位所选路径") ?? "Locate selected path in SFTP", action: #selector(openSelectedPathInFiles), keyEquivalent: "")
            item.target = self; menu.addItem(item)
            let aiItem = NSMenuItem(title: store?.text("Analyze with AI", "使用 AI 分析") ?? "Analyze with AI", action: #selector(analyzeSelectionWithAI), keyEquivalent: "")
            aiItem.target = self; menu.addItem(aiItem)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func analyzeSelectionWithAI() {
        guard let store, let sessionID else { return }
        store.activeSession = sessionID; store.prepareTerminalAI(selectionOnly: true); store.aiTerminalRequest = UUID()
    }
    @objc private func openSelectedPathInFiles() {
        guard let store, let sessionID else { return }
        do { try store.openTerminalDirectoryInFiles(sessionID: sessionID, isSelection: true) }
        catch { store.error = error.localizedDescription }
    }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); if store?.workspace.preferences.copyOnSelect == true, getSelection()?.isEmpty == false { copy(self) } }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 && store?.workspace.preferences.middleClickPaste != false { paste(self) } else { super.otherMouseDown(with: event) } }
}
/// The app owns the local PTY transport so local and SSH terminals share the
/// same input router and transcript capture, without patching SwiftTerm.
@MainActor final class LocalTerminal: RemoteTerminal {
    private let bridge = LocalTerminalProcessBridge()
    lazy var process = LocalProcess(delegate: bridge, dispatchQueue: .main)
    func startProcess(executable: String, args: [String], environment: [String], currentDirectory: String?) {
        bridge.terminal = self
        let dimensions = terminalStateSnapshot().dimensions
        resizeProcess(columns: dimensions.cols, rows: dimensions.rows)
        process.startProcess(executable: executable, args: args, environment: environment, currentDirectory: currentDirectory)
    }
    func terminate() { process.terminate() }
    func resizeProcess(columns: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        bridge.setSize(size); _ = process.updateWindowSize(&size)
    }
    func receive(_ bytes: [UInt8]) {
        ownerSession?.captureOutput(bytes)
        feed(byteArray: bytes[...])
    }
}
private final class LocalTerminalProcessBridge: LocalProcessDelegate {
    weak var terminal: LocalTerminal?
    private let lock = NSLock()
    private var size = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
    func setSize(_ value: winsize) { lock.lock(); size = value; lock.unlock() }
    func getWindowSize() -> winsize { lock.lock(); defer { lock.unlock() }; return size }
    func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { terminal?.receive(Array(slice)) }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            guard let terminal else { return }
            terminal.ownerSession?.processTerminated(source: terminal, exitCode: exitCode)
        }
    }
    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        MainActor.assumeIsolated {
            guard let terminal else { return }
            terminal.ownerSession?.processFailedToStart(source: terminal, error: error)
        }
    }
}

@MainActor private func focusAttachedTerminal(_ view: TerminalView, store: AppStore?, sessionID: UUID?) {
    guard view.window != nil, let store, let sessionID else { return }
    DispatchQueue.main.async { [weak view, weak store] in
        guard let view, let store, !view.isHidden, store.section == "terminal", store.activeSession == sessionID else { return }
        view.window?.makeFirstResponder(view)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var active: Bool
    var focused: Bool
    final class Coordinator { var focused = false; var wantsFocus = false; var revision = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TerminalView { session.makeView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    func updateNSView(_ view: TerminalView, context: Context) {
        view.isHidden = !active
        let coordinator = context.coordinator
        coordinator.wantsFocus = active && focused
        guard coordinator.wantsFocus else { coordinator.focused = false; coordinator.revision += 1; return }
        if view.window?.firstResponder === view { coordinator.focused = true; return }
        guard !coordinator.focused else { return }
        coordinator.revision += 1
        let revision = coordinator.revision
        DispatchQueue.main.async { [weak view] in
            guard let view, coordinator.wantsFocus, coordinator.revision == revision, !view.isHidden, let window = view.window else { return }
            coordinator.focused = window.makeFirstResponder(view)
        }
    }
}
