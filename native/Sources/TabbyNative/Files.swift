import Foundation
import SwiftUI
import Combine
import AppKit
import Citadel
import NIO
import UniformTypeIdentifiers

protocol FileEndpoint: Sendable {
    func list(_ path: String) async throws -> [FileEntry]
    func stat(_ path: String) async throws -> FileEntry
    func mkdir(_ path: String) async throws
    func rename(_ from: String, _ to: String) async throws
    func delete(_ entry: FileEntry) async throws
    func chmod(_ path: String, _ mode: UInt32) async throws
    func read(_ path: String, offset: UInt64, count: Int) async throws -> Data
    func write(_ path: String, offset: UInt64, bytes: Data) async throws
    func isAvailable() async -> Bool
    func removeStagingFile(_ entry: FileEntry) async throws
}

extension FileEndpoint {
    func isAvailable() async -> Bool { true }
    func removeStagingFile(_ entry: FileEntry) async throws {
        try FileStaging.validate(entry)
        try await delete(entry)
    }
}

enum FileStaging {
    static func validate(_ entry: FileEntry) throws {
        guard !entry.directory, [".tabby-", ".backup-"].contains(where: { marker in
            guard let range = entry.name.range(of: marker, options: .backwards) else { return false }
            return UUID(uuidString: String(entry.name[range.upperBound...])) != nil
        }) else { throw AppFailure.message("Only application staging files may be removed directly") }
    }
}

actor LocalFiles: FileEndpoint {
    func stat(_ path: String) throws -> FileEntry { try LocalFileMetadata.stat(path) }
    func list(_ path: String) throws -> [FileEntry] { try LocalFileMetadata.list(path) }
    func mkdir(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
    func rename(_ from: String, _ to: String) throws { try FileManager.default.moveItem(atPath: from, toPath: to) }
    func delete(_ entry: FileEntry) throws { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
    func removeStagingFile(_ entry: FileEntry) throws {
        try FileStaging.validate(entry)
        try FileManager.default.removeItem(atPath: entry.path)
    }
    func chmod(_ path: String, _ mode: UInt32) throws { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
    func read(_ path: String, offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seek(toOffset: offset); return try handle.read(upToCount: count) ?? Data()
    }
    func write(_ path: String, offset: UInt64, bytes: Data) throws {
        if offset == 0 {
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppFailure.message("Cannot create \(path)") }
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seek(toOffset: offset); try handle.write(contentsOf: bytes)
    }
}

actor RemoteFiles: FileEndpoint {
    let sftp: SFTPClient
    init(_ sftp: SFTPClient) { self.sftp = sftp }
    func isAvailable() -> Bool { sftp.isActive }
    func close() async throws { try await sftp.close() }
    func entry(_ path: String, _ attr: SFTPFileAttributes) -> FileEntry {
        let mode = attr.permissions ?? 0
        return FileEntry(name: (path as NSString).lastPathComponent, path: path, directory: mode & 0o170000 == 0o040000, symlink: mode & 0o170000 == 0o120000, size: attr.size ?? 0, permissions: mode & 0o7777, modified: attr.accessModificationTime?.modificationTime ?? .distantPast)
    }
    func list(_ path: String) async throws -> [FileEntry] {
        let batches = try await sftp.listDirectory(atPath: path)
        return try batches.flatMap(\.components).filter { $0.filename != "." && $0.filename != ".." }.map { entry(try remoteJoin(path, $0.filename), $0.attributes) }
    }
    func stat(_ path: String) async throws -> FileEntry {
        do {
            if path == "/" { return entry(path, try await sftp.getAttributes(at: path)) }
            let parent = (path as NSString).deletingLastPathComponent
            guard let found = try await list(parent.isEmpty ? "/" : parent).first(where: { $0.path == path }) else { throw FileMissing(path) }
            return found
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile { throw FileMissing(path) }
        catch SFTPError.errorStatus(let status) where status.errorCode == .noSuchFile { throw FileMissing(path) }
    }
    func mkdir(_ path: String) async throws { try await sftp.createDirectory(atPath: path) }
    func rename(_ from: String, _ to: String) async throws { try await sftp.rename(at: from, to: to) }
    func delete(_ entry: FileEntry) async throws {
        try Task.checkCancellation()
        if entry.directory && !entry.symlink {
            for child in try await list(entry.path) { try await delete(child) }
            try await sftp.rmdir(at: entry.path)
        } else { try await sftp.remove(at: entry.path) }
    }
    func chmod(_ path: String, _ mode: UInt32) async throws {
        var attrs = SFTPFileAttributes(); attrs.permissions = mode
        try await sftp.setAttributes(at: path, to: attrs)
    }
    func read(_ path: String, offset: UInt64, count: Int) async throws -> Data {
        try await sftp.withFile(filePath: path, flags: .read) { file in Data((try await file.read(from: offset, length: UInt32(count))).readableBytesView) }
    }
    func write(_ path: String, offset: UInt64, bytes: Data) async throws {
        try await sftp.withFile(filePath: path, flags: offset == 0 ? [.write, .create, .truncate] : [.write]) { file in try await file.write(ByteBuffer(bytes: bytes), at: offset) }
    }
}

@MainActor final class FilePane: ObservableObject {
    @Published var path: String
    @Published var entries: [FileEntry] = [] { didSet { pruneSelection() } }
    @Published var selected = Set<String>()
    @Published var filter = "" { didSet { pruneSelection() } }
    @Published var showHidden = false { didSet { pruneSelection() } }
    @Published var loading = false
    @Published var busy = false
    /// Read-only tools retain the endpoint while the browser switches hosts.
    var readerCount = 0
    @Published var error: String? { didSet { errorID = UUID() } }
    @Published private(set) var errorID = UUID()
    @Published var sort = "name"
    let backend: any FileEndpoint
    var history: [String] = []
    var historyIndex = -1
    private var generation = 0
    init(path: String, backend: any FileEndpoint) { self.path = path; self.backend = backend }
    var visible: [FileEntry] {
        entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            switch sort { case "size": return $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size
            case "modified": return $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified
            default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    var chosen: [FileEntry] { visible.filter { selected.contains($0.path) } }
    private func pruneSelection() {
        let visiblePaths = Set(entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }.map(\.path))
        let retained = selected.intersection(visiblePaths)
        if retained != selected { selected = retained }
    }
    @discardableResult func navigate(_ requestedPath: String, record: Bool = true) async -> Bool {
        let expanded = backend is LocalFiles ? (requestedPath as NSString).expandingTildeInPath : requestedPath
        guard expanded.hasPrefix("/") else { error = "Enter an absolute path"; return false }
        let newPath = (expanded as NSString).standardizingPath
        generation += 1; let request = generation; loading = true
        defer { if request == generation { loading = false } }
        do {
            let files = try await backend.list(newPath)
            guard request == generation else { return false }
            let sameDirectory = newPath == path
            path = newPath; entries = files
            selected = sameDirectory ? selected.intersection(Set(files.map(\.path))) : []
            error = nil
            if record && (historyIndex < 0 || history[historyIndex] != newPath) {
                history = Array(history.prefix(historyIndex + 1)); history.append(newPath); historyIndex = history.count - 1
            }
            return true
        } catch { if request == generation { self.error = error.localizedDescription }; return false }
    }
    func back(_ delta: Int) async {
        let index = historyIndex + delta
        guard history.indices.contains(index) else { return }
        if await navigate(history[index], record: false) { historyIndex = index }
    }
    func up() async { await navigate((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) }
}

@MainActor final class TransferJob: ObservableObject, Identifiable {
    let id = UUID()
    var entry: FileEntry
    let destination: String
    var source: any FileEndpoint
    var target: any FileEndpoint
    let direction: String
    @Published var state = "queued"
    @Published var completed: UInt64 = 0
    @Published var total: UInt64 = 0
    @Published var speed: Double = 0
    @Published var error = ""
    @Published var retryAvailable = true
    var retryReason = ""
    var cancelled = false
    var partials: [String: TransferPartial] = [:]
    let expectation: DirectoryTransferExpectation?
    init(entry: FileEntry, destination: String, source: any FileEndpoint, target: any FileEndpoint, direction: String, expectation: DirectoryTransferExpectation? = nil) {
        self.entry = entry; self.destination = destination; self.source = source; self.target = target; self.direction = direction
        self.expectation = expectation
    }
}

@MainActor final class TransferQueue: ObservableObject {
    @Published var jobs: [TransferJob] = []
    @Published private(set) var panelExpanded = true
    var runner: Task<Void, Never>?
    var refresh: (() async -> Void)?
    func collapsePanel() { panelExpanded = false }
    func expandPanel() { if !jobs.isEmpty { panelExpanded = true } }
    func clearFinished() {
        for job in jobs where job.state != "queued" && job.state != "running" { discardPartials(job) }
        jobs.removeAll { $0.state != "queued" && $0.state != "running" }
    }
    func rebindFailedEndpoint(_ old: any FileEndpoint, to replacement: any FileEndpoint) {
        for job in jobs where job.state == "failed" {
            var rebound = false
            if (job.source as AnyObject) === (old as AnyObject) { job.source = replacement; rebound = true }
            if (job.target as AnyObject) === (old as AnyObject) { job.target = replacement; rebound = true }
            if rebound { job.retryAvailable = true; job.retryReason = "" }
        }
    }
    func discardPartials(_ job: TransferJob) {
        let partials = Array(job.partials.values); job.partials.removeAll()
        Task { for partial in partials { if let entry = try? await job.target.stat(partial.path) { try? await job.target.removeStagingFile(entry) } } }
    }
    func restart(_ job: TransferJob) {
        guard job.state != "running", job.state != "queued" else { return }
        let old = Array(job.partials.values); job.partials.removeAll()
        Task { for partial in old { if let entry = try? await job.target.stat(partial.path) { try? await job.target.removeStagingFile(entry) } }; do { job.entry = try await job.source.stat(job.entry.path); self.retry(job) } catch { job.error = error.localizedDescription } }
    }
    func enqueue(_ entry: FileEntry, destination: String, source: any FileEndpoint, target: any FileEndpoint, direction: String, expectation: DirectoryTransferExpectation? = nil) throws {
        try validateLocalTransfer(entry, to: destination, source: source, target: target)
        jobs.append(TransferJob(entry: entry, destination: destination, source: source, target: target, direction: direction, expectation: expectation)); panelExpanded = true; run()
    }
    func retry(_ job: TransferJob) { guard job.retryAvailable else { job.error = job.retryReason; return }; job.cancelled = false; job.completed = 0; job.total = 0; job.error = ""; job.state = "queued"; panelExpanded = true; run() }
    func cancel(_ job: TransferJob) { job.cancelled = true; if job.state == "queued" || job.state == "failed" { job.state = "cancelled"; discardPartials(job) } }
    func run() {
        guard runner == nil else { return }
        runner = Task {
            while let job = jobs.first(where: { $0.state == "queued" }) {
                job.state = "running"
                do { try await transfer(job.entry, to: job.destination, job: job); job.state = "completed" }
                catch { job.state = job.cancelled ? "cancelled" : "failed"; job.error = error.localizedDescription }
                await refresh?()
            }
            runner = nil
        }
    }
    func check(_ job: TransferJob) throws { if job.cancelled { throw CancellationError() }; try Task.checkCancellation() }
    func transfer(_ entry: FileEntry, to destination: String, job: TransferJob) async throws {
        try check(job)
        try validateLocalTransfer(entry, to: destination, source: job.source, target: job.target)
        guard !entry.symlink else { throw AppFailure.message("Symbolic links are not followed during transfers: \(entry.name)") }
        if let expectation = job.expectation {
            try await expectation.prepare(source: job.source, target: job.target, destination: destination, check: { try self.check(job) })
            try check(job)
        }
        let existing = try await fileIfExists(destination, backend: job.target)
        if entry.directory {
            if let existing { guard existing.directory && !existing.symlink else { throw AppFailure.message("Destination is a file: \(destination)") } }
            else { try await job.target.mkdir(destination) }
            // A comparison approves a fixed list, never a new recursive enumeration.
            if job.expectation == nil {
                for child in try await job.source.list(entry.path) { try await transfer(child, to: remoteJoin(destination, child.name), job: job) }
            }
            return
        }
        if let existing {
            guard !existing.directory && !existing.symlink else { throw AppFailure.message("Cannot overwrite directory or symbolic link: \(destination)") }
            if job.expectation == nil {
                let alert = AppModalAlert(); alert.destructive = true; alert.cancelButtonIndex = 2; alert.defaultButtonIndex = 1; alert.messageText = "Replace \(entry.name)?"; alert.informativeText = destination
                alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Skip"); alert.addButton(withTitle: "Cancel transfer")
                switch alert.runModal() { case .alertSecondButtonReturn: return; case .alertThirdButtonReturn: job.cancelled = true; throw CancellationError(); default: break }
            }
        }
        job.total += entry.size
        let previous = job.partials[destination]
        let temp = previous?.path ?? destination + ".tabby-" + UUID().uuidString
        let backup = destination + ".backup-" + UUID().uuidString
        var backedUp = false
        do {
            var offset: UInt64 = 0
            if let previous {
                guard FileContentDigest.sameMetadata(previous.source, entry), sameTransferTarget(previous.target, existing) else { throw AppFailure.message("Source or destination changed; discard partial transfer and start again / 源文件或目标已改变，请丢弃部分传输后重新开始") }
                if let partial = try await fileIfExists(temp, backend: job.target) {
                    offset = try await TransferResume.validatedOffset(entry: entry, partial: partial, source: job.source, target: job.target, check: { try self.check(job) })
                }
            }
            job.partials[destination] = TransferPartial(path: temp, source: entry, target: existing)
            job.completed += offset
            if entry.size == 0 { try await job.target.write(temp, offset: 0, bytes: Data()) }
            while offset < entry.size {
                try check(job)
                let start = Date()
                let bytes = try await job.source.read(entry.path, offset: offset, count: 256 * 1024)
                guard !bytes.isEmpty else { throw AppFailure.message("Source ended before expected size: \(entry.name)") }
                try await job.target.write(temp, offset: offset, bytes: bytes)
                offset += UInt64(bytes.count); job.completed += UInt64(bytes.count)
                job.speed = Double(bytes.count) / max(0.001, Date().timeIntervalSince(start))
            }
            try check(job)
            try await job.target.chmod(temp, entry.permissions & 0o777)
            if let expectation = job.expectation {
                try await expectation.validateCopiedFile(temp, source: job.source, target: job.target, check: { try self.check(job) })
                try await expectation.validateTarget(destination, backend: job.target, check: { try self.check(job) })
                try check(job)
            }
            let sourceAfter = try await job.source.stat(entry.path)
            guard FileContentDigest.sameMetadata(entry, sourceAfter), sameTransferTarget(existing, try await fileIfExists(destination, backend: job.target)) else { throw AppFailure.message("Source or destination changed during transfer / 传输期间源文件或目标已改变") }
            if existing != nil { try await job.target.rename(destination, backup); backedUp = true }
            do { try await job.target.rename(temp, destination) }
            catch { if backedUp { try? await job.target.rename(backup, destination) }; throw error }
            job.partials.removeValue(forKey: destination)
            if backedUp, let old = try? await job.target.stat(backup) {
                do { try await job.target.removeStagingFile(old) }
                catch { job.error = "File committed; recovery backup retained at \(backup): \(error.localizedDescription)" }
            }
        } catch {
            // Retain a verified prefix only until explicit retry or queue cleanup.
            // A committed backup is never treated as resumable payload.
            if backedUp || job.cancelled || error is CancellationError {
                if let partial = try? await job.target.stat(temp) { try? await job.target.removeStagingFile(partial) }
                job.partials.removeValue(forKey: destination)
            }
            throw error
        }
    }
}

/// Local copies cannot overwrite themselves or recursively copy into a child.
func validateLocalTransfer(_ entry: FileEntry, to destination: String, source: any FileEndpoint, target: any FileEndpoint) throws {
    guard source is LocalFiles, target is LocalFiles else { return }
    let sourceURL = URL(fileURLWithPath: entry.path).standardizedFileURL.resolvingSymlinksInPath()
    let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
    let resolvedParent = destinationURL.deletingLastPathComponent().resolvingSymlinksInPath()
    let targetURL = resolvedParent.appendingPathComponent(destinationURL.lastPathComponent).resolvingSymlinksInPath()
    guard sourceURL.path != targetURL.path else { throw AppFailure.message("Cannot copy an item onto itself") }
    if entry.directory && targetURL.path.hasPrefix(sourceURL.path == "/" ? "/" : sourceURL.path + "/") {
        throw AppFailure.message("Cannot copy a folder into its own subfolder")
    }
}

@MainActor struct FileEndpointLease {
    let pane: FilePane
    var isActive: @MainActor () -> Bool = { true }
    var authenticatedUsername: String? = nil
    var release: @MainActor () async -> Void = {}
}

@MainActor final class FileManagerModel: ObservableObject {
    typealias RemoteOpener = @MainActor (Host) async throws -> FileEndpointLease
    @Published var local: FilePane { didSet { observeLocal() } }
    /// The right pane may hold either an SFTP endpoint or a second local endpoint.
    @Published var remote: FilePane? { didSet { observeRight(); if remote != nil { showingHostPicker = false } } }
    @Published private(set) var rightIsLocal = false
    @Published private(set) var rightHost: Host?
    @Published private(set) var showingHostPicker: Bool
    @Published var status = ""
    @Published var showExternalEdits = false
    let queue = TransferQueue()
    let session: TerminalSession
    private var lease: FileEndpointLease?
    private(set) var rightAuthenticatedUsername: String?
    private var rightConnectionSnapshot: Host?
    private var rightSecretSourceID: UUID?
    private var rightRouteSnapshot: [MonitoringRouteHop] = []
    private let remoteOpener: RemoteOpener?
    private var localObservation: AnyCancellable?
    private var remoteObservation: AnyCancellable?
    private var generation = 0
    @Published private(set) var opening = false
    private var handledRecentFileRequest: UUID?
    private var handlingTerminalFileRequest = false
    private var initializedSceneLocations = false
    private var initialSceneLocalDirectory: String?
    private var initialSceneRemoteDirectory: WorkSceneLocation?
    var endpointGeneration: Int { generation }
    var canTransfer: Bool { remote != nil && !showingHostPicker }
    var canSwitchRight: Bool { remote?.busy != true }

    init(session: TerminalSession, remoteOpener: RemoteOpener? = nil) {
        self.session = session
        self.remoteOpener = remoteOpener
        rightHost = session.host
        showingHostPicker = session.host == nil
        local = FilePane(path: NSHomeDirectory(), backend: LocalFiles())
        observeLocal()
        queue.refresh = { [weak self] in
            guard let self else { return }
            await local.navigate(local.path, record: false)
            if let remote { await remote.navigate(remote.path, record: false) }
        }
    }
    deinit {
        let queue = queue, lease = lease
        Task { @MainActor in
            queue.jobs.filter { $0.state == "running" || $0.state == "queued" }.forEach { queue.cancel($0) }
            await queue.runner?.value
            if let lease {
                while lease.pane.busy || lease.pane.readerCount > 0 { try? await Task.sleep(for: .milliseconds(20)) }
                await lease.release()
            }
        }
    }
    private func observeLocal() {
        localObservation = local.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    private func observeRight() {
        remoteObservation = remote?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    func showHostPicker() { guard canSwitchRight else { return }; generation += 1; opening = false; showingHostPicker = true; status = "" }
    func dismissHostPicker() { if remote != nil { showingHostPicker = false; status = "" } }

    func open() async {
        guard !handlingTerminalFileRequest else { return }
        prepareInitialSceneLocations()
        if session.store.terminalFileRequest?.sessionID == session.id {
            initialSceneLocalDirectory = nil; initialSceneRemoteDirectory = nil
        }
        if let initial = initialSceneLocalDirectory, local.path != NSHomeDirectory(), local.path != initial {
            initialSceneLocalDirectory = nil
        }
        let localDirectory = initialSceneLocalDirectory ?? local.path
        if await local.navigate(localDirectory, record: false), local.path == initialSceneLocalDirectory {
            initialSceneLocalDirectory = nil
        }
        if await openTerminalRequestIfNeeded() { return }
        if await openRecentRequestIfNeeded() { return }
        // Refreshing, or a terminal reconnect, preserves the chosen right endpoint.
        if let remote {
            initialSceneRemoteDirectory = nil
            if !rightIsLocal, let lease, !lease.isActive() {
                guard !showingHostPicker, !opening, let host = rightHost else { return }
                await selectHost(host, directory: remote.path)
            } else { await remote.navigate(remote.path, record: false) }
            return
        }
        guard !showingHostPicker, !rightIsLocal, let host = rightHost, !opening else { return }
        if remoteOpener == nil, host.id == session.host?.id, session.client?.isConnected != true {
            status = session.status
            return // The existing terminal is still connecting.
        }
        let initialDirectory = initialSceneRemoteDirectory.flatMap { $0.hostID == host.id ? $0.path : nil }
        await selectHost(host, directory: initialDirectory)
        if remote != nil { initialSceneRemoteDirectory = nil }
    }
    private func prepareInitialSceneLocations() {
        guard !initializedSceneLocations else { return }; initializedSceneLocations = true
        let store = session.store
        guard store.terminalFileRequest?.sessionID != session.id,
              let scene = store.openScenes.first(where: { $0.sessionIDs.contains(session.id) }) else { return }
        if local.path == NSHomeDirectory(), local.entries.isEmpty, local.history.isEmpty {
            initialSceneLocalDirectory = scene.definition.directories.first { $0.hostID == nil }?.path
        }
        if let hostID = session.host?.id {
            initialSceneRemoteDirectory = scene.definition.directories.first { $0.hostID == hostID }
        }
    }
    @discardableResult func openTerminalRequestIfNeeded() async -> Bool {
        let store = session.store
        guard store.section == "sftp" || (store.section == "scene" && store.currentScene?.mode == "files"),
              let request = store.terminalFileRequest,
              request.sessionID == session.id, request.id != store.handledTerminalFileRequestID else { return false }
        handlingTerminalFileRequest = true
        defer { handlingTerminalFileRequest = false }
        store.handledTerminalFileRequestID = request.id
        guard canSwitchRight else {
            remote?.error = store.text("Finish the current file operation first.", "请先完成当前文件操作。"); return true
        }
        guard let sourceSession = store.sessions.first(where: { $0.id == request.sessionID }), sourceSession.connected,
              sourceSession.generation == request.generation else {
            local.error = store.text("The terminal has disconnected.", "终端已断开。"); return true
        }
        let pane: FilePane
        var expectedGeneration = generation
        if let host = request.host {
            guard sourceSession.matchesEndpoint(host) else { local.error = store.text("The terminal connection changed.", "终端连接已改变。"); return true }
            if rightIsLocal || remote == nil || lease?.isActive() != true || !matchesRightConnection(host) {
                expectedGeneration += 1
                await selectHost(host)
            }
            guard generation == expectedGeneration, !rightIsLocal, !showingHostPicker, lease?.isActive() == true,
                  matchesRightConnection(host), rightAuthenticatedUsername == (sourceSession.authenticatedUsername ?? RecentTargets.effectiveUsername(host, workspace: store.workspace)),
                  let remote else {
                status = store.text("The file connection changed. Open the directory again.", "文件连接已改变，请重新打开目录。"); return true
            }
            pane = remote
        } else {
            guard sourceSession.host == nil else { local.error = store.text("The terminal connection changed.", "终端连接已改变。"); return true }
            pane = local
        }
        guard sourceSession.generation == request.generation, sourceSession.connected else { pane.error = store.text("The terminal connection changed.", "终端连接已改变。"); return true }
        do {
            if request.isSelection {
                let entry = try await pane.backend.stat(request.path)
                guard generation == expectedGeneration, sourceSession.generation == request.generation else { throw AppFailure.message(store.text("The connection changed.", "连接已改变。")) }
                if entry.directory && !entry.symlink { _ = await pane.navigate(entry.path) }
                else {
                    let parent = (entry.path as NSString).deletingLastPathComponent
                    if await pane.navigate(parent.isEmpty ? "/" : parent) { pane.selected = [entry.path] }
                }
            } else { _ = await pane.navigate(request.path) }
        } catch { pane.error = error.localizedDescription }
        return true
    }
    func selectLocal(path: String = NSHomeDirectory()) async {
        guard canSwitchRight else { return }
        generation += 1; opening = false
        retireCurrentLease()
        rightIsLocal = true; rightHost = nil; rightAuthenticatedUsername = nil; status = ""
        let pane = FilePane(path: path, backend: LocalFiles())
        remote = pane
        showingHostPicker = false
        if await pane.navigate(path), remote === pane {
            session.store.recordRecentSuccess(kind: .localFiles)
        }
    }
    func selectHost(_ host: Host, directory: String? = nil) async {
        guard canSwitchRight else { return }
        let host = GroupDefaults.connectionSource(host, workspace: session.store.workspace)
        let profileSnapshot = session.store.resolvedHost(host)
        let secretSourceID = session.store.groupSecretID(for: host)
        let routeSnapshot = MonitoringCenter.savedRoute(for: host, workspace: session.store.workspace)
        if rightHost?.id == host.id, !rightIsLocal, remote != nil, directory == nil, lease?.isActive() == true,
           rightConnectionSnapshot == profileSnapshot, rightSecretSourceID == secretSourceID, rightRouteSnapshot == routeSnapshot {
            showingHostPicker = false; status = ""; return
        }
        let oldBackend = rightHost?.id == host.id && rightConnectionSnapshot == profileSnapshot && rightSecretSourceID == secretSourceID && rightRouteSnapshot == routeSnapshot ? remote?.backend : nil
        let previousTransfers = queue.runner
        generation += 1; let request = generation
        let username = RecentTargets.effectiveUsername(host, workspace: session.store.workspace)
        retireCurrentLease()
        remote = nil; rightIsLocal = false; rightHost = host
        showingHostPicker = true
        status = session.store.text("Connecting…", "正在连接…")
        opening = true
        defer { if request == generation { opening = false } }
        do {
            let opened: FileEndpointLease
            if let remoteOpener { opened = try await remoteOpener(host) }
            else { opened = try await openRemote(host, request: request) }
            guard request == generation else { await opened.release(); return }
            if let oldBackend {
                Task { [weak self] in
                    await previousTransfers?.value
                    guard let self, self.remote === opened.pane, opened.isActive() else { return }
                    self.queue.rebindFailedEndpoint(oldBackend, to: opened.pane.backend)
                    self.session.store.externalEdits.rebind(oldBackend, to: opened.pane)
                }
            }
            lease = opened; remote = opened.pane; rightAuthenticatedUsername = opened.authenticatedUsername ?? username; status = ""
            rightConnectionSnapshot = profileSnapshot; rightSecretSourceID = secretSourceID; rightRouteSnapshot = routeSnapshot
            showingHostPicker = false
            if await opened.pane.navigate(directory ?? opened.pane.path), request == generation {
                session.store.recordRecentSuccess(host, kind: .sftp)
            }
        } catch {
            guard request == generation else { return }
            status = error.localizedDescription
        }
    }
    /// Requests are issued only by an explicit recent-target click. Existing panes
    /// retain their current directory when the same endpoint is already open.
    @discardableResult func openRecentRequestIfNeeded() async -> Bool {
        let store = session.store
        guard store.section == "sftp", let request = store.recentFileRequest,
              request.id != handledRecentFileRequest, request.id != store.handledRecentFileRequestID,
              request.sessionID == session.id || (request.sessionID == nil && store.sessions.isEmpty) else { return false }
        handledRecentFileRequest = request.id; store.handledRecentFileRequestID = request.id
        guard canSwitchRight else { status = store.text("Finish the current file operation first.", "请先完成当前文件操作。"); return true }
        let target = request.target
        guard store.recentTargets.contains(where: { $0.id == target.id }) else { return true }
        if target.kind == .localFiles {
            if rightIsLocal, remote != nil { store.recordRecentSuccess(kind: .localFiles) }
            else { await selectLocal() }
        } else if target.kind == .sftp, let host = RecentTargets.resolvedHost(target, workspace: store.workspace) {
            if !rightIsLocal, remote != nil, lease?.isActive() == true, let current = rightHost,
               RecentTargets.canReuseProfile(current, host, workspace: store.workspace),
               current.address.caseInsensitiveCompare(host.address) == .orderedSame,
               matchesRightConnection(host),
               rightAuthenticatedUsername == RecentTargets.effectiveUsername(host, workspace: store.workspace) {
                store.recordRecentSuccess(host, kind: .sftp)
            } else { await selectHost(host) }
        }
        return true
    }
    private func matchesRightConnection(_ host: Host) -> Bool {
        guard let snapshot = rightConnectionSnapshot else { return false }
        let requested = session.store.resolvedHost(host)
        return snapshot.address.caseInsensitiveCompare(requested.address) == .orderedSame
            && snapshot.port == requested.port && snapshot.auth == requested.auth
            && snapshot.keyPath == requested.keyPath && snapshot.keySource == requested.keySource
            && rightSecretSourceID == session.store.groupSecretID(for: host)
            && rightRouteSnapshot == MonitoringCenter.savedRoute(for: host, workspace: session.store.workspace)
    }
    private func openRemote(_ host: Host, request: Int) async throws -> FileEndpointLease {
        var ownedClients: [SSHClient] = []
        let borrowedSession = ([session] + session.store.sessions).first { $0.matchesEndpoint(host) && $0.client?.isConnected == true }
        let borrowed = borrowedSession?.client
        var authenticatedUsername = borrowedSession?.authenticatedUsername
        do {
            let client: SSHClient
            if let borrowed { client = borrowed }
            else {
                var chain: [Host] = []; var current: Host? = host; var seen = Set<UUID>()
                while let h = current {
                    guard seen.insert(h.id).inserted else { throw AppFailure.message("Jump host cycle") }
                    let source = GroupDefaults.connectionSource(h, workspace: session.store.workspace)
                    chain.insert(source, at: 0)
                    if let jump = session.store.resolvedHost(source).jumpHostID {
                        guard let next = session.store.workspace.hosts.first(where: { $0.id == jump }) else { throw AppFailure.message("Jump host not found") }
                        current = next
                    } else { current = nil }
                }
                var previous: SSHClient?
                for h in chain {
                    let settings = try session.settings(for: h)
                    let usernameSnapshot = session.settingsUsername(for: h)
                    let next: SSHClient
                    if let previous { next = try await previous.jump(to: settings) }
                    else { next = try await SSHClient.connect(to: settings) }
                    ownedClients.append(next)
                    guard request == generation else { throw CancellationError() }
                    if h.id == host.id { authenticatedUsername = usernameSnapshot }
                    previous = next
                }
                guard let connected = previous else { throw AppFailure.message("No host to connect") }
                client = connected
            }
            let sftp = try await client.openSFTP()
            do {
                guard request == generation else { throw CancellationError() }
                let home = try await sftp.getRealPath(atPath: ".")
                guard request == generation else { throw CancellationError() }
                let pane = FilePane(path: home, backend: RemoteFiles(sftp))
                return FileEndpointLease(pane: pane, isActive: { sftp.isActive }, authenticatedUsername: authenticatedUsername, release: {
                    try? await sftp.close()
                    for client in ownedClients.reversed() { try? await client.close() }
                })
            } catch { try? await sftp.close(); throw error }
        } catch {
            for client in ownedClients.reversed() { try? await client.close() }
            throw error
        }
    }
    private func retireCurrentLease() {
        guard let lease else { return }
        self.lease = nil
        let backend = lease.pane.backend as AnyObject
        for job in queue.jobs where (job.source as AnyObject) === backend || (job.target as AnyObject) === backend {
            job.retryAvailable = false
            job.retryReason = session.store.text("This connection was switched. Select the files again to start a new transfer.", "连接已切换，请重新选择文件开始新的传输。")
        }
        let pending = queue.runner
        // Existing jobs retain their exact source/target endpoints across a switch.
        Task { await pending?.value; while lease.pane.busy || lease.pane.readerCount > 0 { try? await Task.sleep(for: .milliseconds(20)) }; await lease.release() }
    }
    func close() {
        generation += 1
        queue.jobs.filter { $0.state == "running" || $0.state == "queued" }.forEach { queue.cancel($0) }
        retireCurrentLease()
        remote = nil; opening = false
    }
    func enqueue(_ entries: [FileEntry], from source: any FileEndpoint, to target: FilePane, destinationPath: String? = nil, direction: String) throws {
        let directory = destinationPath ?? target.path
        let prepared = try entries.map { entry -> (FileEntry, String) in
            let destination = try remoteJoin(directory, entry.name)
            try validateLocalTransfer(entry, to: destination, source: source, target: target.backend)
            return (entry, destination)
        }
        for (entry, destination) in prepared {
            try queue.enqueue(entry, destination: destination, source: source, target: target.backend, direction: direction)
        }
    }
    func transfer(_ upload: Bool, entries: [FileEntry]? = nil) {
        guard canTransfer, let remote else { return }
        let source = upload ? local : remote; let target = upload ? remote : local
        do { try enqueue(entries ?? source.chosen, from: source.backend, to: target, direction: rightIsLocal ? "copy" : upload ? "upload" : "download") }
        catch { target.error = error.localizedDescription }
    }
}

struct TransferPartial {
    let path: String
    let source: FileEntry
    let target: FileEntry?
}
func sameTransferTarget(_ left: FileEntry?, _ right: FileEntry?) -> Bool {
    switch (left, right) { case (nil, nil): return true; case let (a?, b?): return FileContentDigest.sameMetadata(a, b); default: return false }
}
enum TransferResume {
    static func validatedOffset(entry: FileEntry, partial: FileEntry, source: any FileEndpoint, target: any FileEndpoint, check: () throws -> Void = {}) async throws -> UInt64 {
        guard !partial.symlink, !partial.directory, partial.size <= entry.size else { throw AppFailure.message("Invalid partial transfer / 部分传输文件无效") }
        guard FileContentDigest.sameMetadata(entry, try await source.stat(entry.path)) else { throw AppFailure.message("Source changed / 源文件已改变") }
        var offset: UInt64 = 0
        while offset < partial.size {
            try check(); try Task.checkCancellation()
            let size = Int(min(256 * 1024, partial.size - offset))
            let expected = try await source.read(entry.path, offset: offset, count: size)
            let actual = try await target.read(partial.path, offset: offset, count: size)
            guard expected.count == size, expected == actual else { throw AppFailure.message("Partial contents changed; restart the transfer / 部分文件内容已改变，请重新传输") }
            offset += UInt64(size)
        }
        guard FileContentDigest.sameMetadata(partial, try await target.stat(partial.path)) else { throw AppFailure.message("Partial file changed during verification") }
        return offset
    }
}
