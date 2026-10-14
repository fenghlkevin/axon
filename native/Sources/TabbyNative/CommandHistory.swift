import Foundation
import SwiftUI
import AppKit

enum CommandOrigin: String, Codable, CaseIterable { case ai, human, mixed, unknown
    func title(chinese: Bool) -> String {
        switch self { case .ai: return "AI"; case .human: return chinese ? "人工" : "Human"; case .mixed: return chinese ? "AI + 人工" : "AI + Human"; case .unknown: return chinese ? "来源未知" : "Unknown source" }
    }
    var symbol: String { self == .ai ? "sparkles" : self == .human ? "person" : self == .mixed ? "person.badge.plus" : "questionmark.circle" }
}
struct CommandOriginTracker {
    private var pending: CommandOrigin?
    mutating func input(_ source: CommandOrigin) { pending = pending == nil || pending == source ? source : .mixed }
    mutating func consume() -> CommandOrigin { defer { pending = nil }; return pending ?? .unknown }
}

struct ExecutedCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    let hostID: UUID?
    let hostName: String
    let sessionID: UUID
    let command: String
    var directory: String?
    var exitCode: Int?
    var duration: Double?
    var origin: CommandOrigin?
}

enum CommandHistoryProtocol {
    static func decode(_ report: String, token: String) -> String? {
        let prefix = "axon-command;" + token + ";"
        guard report.hasPrefix(prefix), report.utf8.count <= 16000 else { return nil }
        var payload = String(report.dropFirst(prefix.count))
        if payload.hasPrefix("begin;") {
            let fields = payload.split(separator: ";", maxSplits: 2)
            guard fields.count == 3, UInt64(fields[1]) != nil else { return nil }
            payload = String(fields[2])
        }
        guard let data = Data(base64Encoded: payload), data.count <= 8192,
              let command = String(data: data, encoding: .utf8) else { return nil }
        return command
    }
    static func sequence(_ payload: String) -> UInt64? {
        let fields = payload.split(separator: ";")
        return fields.first == "begin" && fields.count == 3 ? UInt64(fields[1]) : nil
    }
    static func completion(_ payload: String) -> (sequence: UInt64?, code: Int, seconds: Double)? {
        let fields = payload.split(separator: ";")
        guard fields.first == "end", fields.count == 3 || fields.count == 4 else { return nil }
        let offset = fields.count == 4 ? 1 : 0
        guard offset == 0 || UInt64(fields[1]) != nil,
              let code = Int(fields[1 + offset]), let seconds = Double(fields[2 + offset]),
              seconds.isFinite, seconds >= 0, seconds <= 31536000 else { return nil }
        return (offset == 1 ? UInt64(fields[1]) : nil, code, seconds)
    }
    /// Only identify Axon's reserved hook setup, not user commands that mention
    /// the hook (for example grep, cat or printf while troubleshooting).
    static func isInternalIntegration(_ command: String) -> Bool {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("_axon_history_") { return true }
        if value.hasPrefix("add-zsh-hook ") && value.contains(" _axon_history_") { return true }
        if value.hasPrefix("if [ -n \"${ZSH_VERSION-}\" ]") && value.contains("add-zsh-hook preexec _axon_history_emit") && value.contains("_axon_history_report ready") { return true }
        if value.hasPrefix("if ! [[ \"${PROMPT_COMMAND[*]-}\"") && value.contains("_axon_history_finish") { return true }
        if value.hasPrefix("if declare -p PROMPT_COMMAND") && value.contains("PROMPT_COMMAND=(_axon_history_finish") { return true }
        return value.hasPrefix("if [ -z \"$(trap -p DEBUG)\" ]") && value.contains("trap '_axon_history_begin")
    }
    static func allowed(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, command.utf8.count <= 8192, !command.contains("axon-command;"), !trimmed.hasPrefix("_axon_"), !isInternalIntegration(command),
              !command.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else { return false }
        let pattern = #"(?i)(password|passwd|passphrase|secret|token|authorization|api[_-]?key)\s*[:=]|--?(password|passwd|passphrase|token|secret|api-key)\b|\bsshpass\b|\b(mysql|redis-cli)\b.*\s-p\S|\b(export\s+)?[A-Z_]*(PASSWORD|TOKEN|SECRET|API_KEY)[A-Z_]*="#
        return trimmed.range(of: pattern, options: .regularExpression) == nil
    }
    static func script(token: String) -> String { ShellCommandIntegration.script(token: token) }
}

@MainActor final class CommandHistoryStore: ObservableObject {
    static let shared = CommandHistoryStore()
    @Published private(set) var entries: [ExecutedCommand] = []
    @Published var error: String?
    let fileURL: URL
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TabbyNative/command-history.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let saved = try JSONDecoder().decode([ExecutedCommand].self, from: Data(contentsOf: self.fileURL))
                let visible = saved.filter { !CommandHistoryProtocol.isInternalIntegration($0.command) }
                entries = Array(visible.prefix(50000))
                if visible.count != saved.count { persist() }
            }
            catch { self.error = "Could not read command history: \(error.localizedDescription)" }
        }
    }
    func append(_ entry: ExecutedCommand, limit: Int = 1000) {
        guard error == nil, CommandHistoryProtocol.allowed(entry.command) else { return }
        entries.insert(entry, at: 0); entries = Array(entries.prefix(max(100, min(50000, limit)))); persist()
    }
    func update(_ id: UUID, directory: String? = nil, exitCode: Int? = nil, duration: Double? = nil) -> ExecutedCommand? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        if let directory { entries[index].directory = directory }
        if let exitCode { entries[index].exitCode = exitCode }
        if let duration { entries[index].duration = duration }
        persist(); return entries[index]
    }
    func trim(to limit: Int) { entries = Array(entries.prefix(max(100, min(50000, limit)))); persist() }
    func clear() { entries = []; error = nil; persist() }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class CommandHistoryFrozenSurface: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor extension TerminalSession {
    func beginCommandHistoryBootstrapScreen() {
        guard !commandHistoryBootstrapScreen else { return }
        commandHistoryBootstrapScreen = true
        if let terminal {
            let cover = CommandHistoryFrozenSurface(frame: terminal.bounds)
            cover.autoresizingMask = [.width, .height]
            cover.wantsLayer = true
            cover.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
            if terminal.bounds.width > 0, terminal.bounds.height > 0,
               let bitmap = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) {
                terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
                let image = NSImage(size: terminal.bounds.size)
                image.addRepresentation(bitmap)
                cover.image = image
            }
            cover.imageScaling = .scaleAxesIndependently
            terminal.addSubview(cover, positioned: .above, relativeTo: nil)
            commandHistoryBootstrapCover = cover
        }
        terminal?.feed(text: "\u{1b}[?1049h")
    }
    func endCommandHistoryBootstrapScreen() {
        guard commandHistoryBootstrapScreen else { return }
        commandHistoryBootstrapScreen = false
        // The shell redraws PS1 after the bootstrap command. Replace the old
        // prompt on the restored line rather than appending a second copy.
        terminal?.feed(text: "\u{1b}[?1049l\r\u{1b}[2K")
        let cover = commandHistoryBootstrapCover
        commandHistoryBootstrapCover = nil
        // Keep the frozen normal screen until the restored buffer has rendered.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            cover?.removeFromSuperview()
        }
    }
    func automaticCommandHistoryScript() -> String {
        commandHistoryToken = UUID().uuidString; commandHistoryReady = false
        // macOS PTY canonical input has a small per-line limit. Keep bootstrap
        // statements short so startup input cannot truncate the hook definition.
        return " " + CommandHistoryProtocol.script(token: commandHistoryToken)
    }
    func startAutomaticCommandHistory() {
        guard connected, let terminal else { return }
        let script = automaticCommandHistoryScript()
        let request = generation
        commandHistoryStartupTask = Task { [weak self, weak terminal] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.connected, self.generation == request, !Task.isCancelled else { return }
            self.beginCommandHistoryBootstrapScreen()
            for line in script.components(separatedBy: "\n") {
                guard let terminal, self.connected, self.generation == request, !Task.isCancelled else { return }
                self.writeBootstrapInput(Array((line + "\r").utf8))
                try? await Task.sleep(for: .milliseconds(2))
            }
            for _ in 0..<20 {
                if self.commandHistoryReady { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if self.generation == request { self.endCommandHistoryBootstrapScreen() }
        }
    }
    func receiveCommandHistory(_ report: String?) -> Bool {
        guard let report, report.hasPrefix("axon-command;") else { return false }
        if report == "axon-command;" + commandHistoryToken + ";ready", !commandHistoryToken.isEmpty { commandHistoryReady = true; endCommandHistoryBootstrapScreen(); return true }
        if report == "axon-command;" + commandHistoryToken + ";unsupported", !commandHistoryToken.isEmpty { endCommandHistoryBootstrapScreen(); return true }
        let prefix = "axon-command;" + commandHistoryToken + ";"
        guard commandHistoryReady, report.hasPrefix(prefix) else { return true }
        let payload = String(report.dropFirst(prefix.count))
        if payload == "prompt" { aiShellInput.prompt(); return true }
        let history = commandHistoryStore ?? CommandHistoryStore.shared
        if payload.hasPrefix("meta;") {
            if let bytes = Data(base64Encoded: String(payload.dropFirst(5))), bytes.count <= 8192, let path = String(data: bytes, encoding: .utf8), path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 }) {
                updateShellDirectory(path)
                if let id = activeCommandHistoryID { _ = history.update(id, directory: path) }
            }
            return true
        }
        if payload.hasPrefix("end;") {
            guard let end = CommandHistoryProtocol.completion(payload), end.sequence == activeCommandSequence else { return true }
            if let id = activeCommandHistoryID {
                if let entry = history.update(id, exitCode: end.code, duration: end.seconds), store.workspace.preferences.commandCompletionNotifications, end.seconds >= 10 { CommandCompletionNotification.send(entry) }
            }
            aiShellExitCode = end.code; aiShellCompletionRevision &+= 1
            activeCommandHistoryID = nil; activeCommandSequence = nil; return true
        }
        activeCommandSequence = CommandHistoryProtocol.sequence(payload)
        aiShellInput.invalidate()
        let origin = commandOriginTracker.consume()
        guard commandHistoryRecording, let command = CommandHistoryProtocol.decode(report, token: commandHistoryToken), CommandHistoryProtocol.allowed(command) else { activeCommandHistoryID = nil; return true }
        let excluded = store.workspace.preferences.commandHistoryExclusions.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !excluded.contains(where: { command.localizedCaseInsensitiveContains($0) }) else { activeCommandHistoryID = nil; return true }
        let entry = ExecutedCommand(hostID: host?.id, hostName: host?.name ?? store.text("Local terminal", "本地终端"), sessionID: id, command: command, origin: origin)
        history.append(entry, limit: store.workspace.preferences.commandHistoryLimit); activeCommandHistoryID = entry.id
        if let id = transcriptID { store.sessionLogs.marker(entry, report: report, id: id) }
        return true
    }
}

struct CommandHistoryPanel: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var history: CommandHistoryStore
    init(history: CommandHistoryStore = .shared) { self.history = history }
    @State private var query = ""
    @State private var allHosts = false
    @State private var clearing = false
    @State private var limit = 100
    @State private var failedOnly = false
    private var session: TerminalSession? { store.sessions.first { $0.id == store.activeSession } }
    private var entries: [ExecutedCommand] { history.entries.filter { (!failedOnly || ($0.exitCode != nil && $0.exitCode != 0)) && (allHosts || $0.hostID == session?.host?.id) && (query.isEmpty || $0.command.localizedCaseInsensitiveContains(query) || $0.hostName.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.text("Command history", "命令历史")).font(.system(size: 14, weight: .semibold))
            if let session { CommandHistoryControls(session: session); PersistentSessionControls(session: session) }
            Text(store.text("Recording starts automatically for Bash/Zsh. View by server in Logs → Operation history. Interactive password input is not captured.", "Bash/Zsh 打开后自动记录。在「日志 → 操作历史」按服务器查看，不采集交互密码输入。"))
                .font(.system(size: 11)).foregroundStyle(TerminalChrome.muted)
            TextField(store.text("Search command or host", "搜索命令或主机"), text: $query).textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 34).foregroundStyle(TerminalChrome.text).background(TerminalChrome.field).clipShape(RoundedRectangle(cornerRadius: 8))
            Toggle(store.text("All hosts", "所有主机"), isOn: $allHosts).toggleStyle(AxonCheckboxStyle(terminal: true))
            Toggle(store.text("Failed commands only", "仅失败命令"), isOn: $failedOnly).toggleStyle(AxonCheckboxStyle(terminal: true))
            HStack { Text("\(entries.count)").foregroundStyle(TerminalChrome.muted); Spacer(); Button(store.text("Clear history", "清空历史"), role: .destructive) { clearing = true } }
            if let error = history.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            if entries.isEmpty { Text(store.text("No recorded commands", "暂无已记录命令")).foregroundStyle(TerminalChrome.muted) }
            ForEach(entries.prefix(limit)) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text(entry.hostName + " · " + entry.date.formatted(date: .numeric, time: .standard))
                    CommandHistoryMetadata(entry: entry).font(.system(size: 10)).foregroundStyle(TerminalChrome.muted)
                    HStack {
                        Button(store.text("Copy", "复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.command, forType: .string) }
                        Button(store.text("Locate output", "定位输出")) { if store.sessionLogs.locate(entry) { store.section = "logs" } }.buttonStyle(ChromeButtonStyle()).disabled(!store.sessionLogs.records.contains { $0.markers.contains { $0.id == entry.id } })
                        Button(store.text("Insert", "填入")) {
                            guard let session, let terminal = session.terminal else { return }
                            do { let bytes = try SnippetInput.bytes(entry.command, action: .insert, bracketedPaste: terminal.terminalStateSnapshot().bracketedPasteMode, chinese: store.chinese); terminal.send(data: bytes[...]) } catch { store.error = error.localizedDescription }
                        }.disabled(session?.connected != true)
                    }.buttonStyle(ChromeButtonStyle())
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(TerminalChrome.card).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if entries.count > limit { Button(store.text("Load more", "加载更多")) { limit += 100 }.buttonStyle(ChromeButtonStyle()) }
        }.appAlert(store.text("Clear all command history?", "清空所有命令历史？"), isPresented: $clearing) {
            AppAlertButton(store.text("Clear", "清空"), role: .destructive) { history.clear() }
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}
        } message: { Text(store.text("This removes the locally recorded commands for all hosts.", "这会删除本机记录的所有主机命令。")) }
    }
}
private struct CommandHistoryControls: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        if session.commandHistoryReady {
            Toggle(session.store.text("Record commands", "记录命令"), isOn: $session.commandHistoryRecording).toggleStyle(AxonCheckboxStyle(terminal: true))
        } else {
            Text(session.store.text("Initializing automatic recording…", "正在初始化自动记录…")).font(.caption).foregroundStyle(TerminalChrome.muted)
        }
    }
}


struct OperationHistoryView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var history: CommandHistoryStore
    @State private var server: String?
    @State private var failedOnly = false
    @State private var search = ""
    @State private var clearing = false
    @State private var originFilter = "all"
    init(history: CommandHistoryStore = .shared, server: String? = nil) {
        _history = ObservedObject(wrappedValue: history); _server = State(initialValue: server)
    }
    private func key(_ entry: ExecutedCommand) -> String { entry.hostID?.uuidString ?? "local" }
    private var filtered: [ExecutedCommand] { history.entries.filter { (originFilter == "all" || ($0.origin ?? .unknown).rawValue == originFilter) && (!failedOnly || ($0.exitCode != nil && $0.exitCode != 0)) && (server == nil || key($0) == server) && (search.isEmpty || $0.command.localizedCaseInsensitiveContains(search) || $0.hostName.localizedCaseInsensitiveContains(search)) } }
    private var servers: [String] { Array(Set(filtered.map(key))).sorted { lhs, rhs in
        (history.entries.first { key($0) == lhs }?.hostName ?? "") < (history.entries.first { key($0) == rhs }?.hostName ?? "")
    } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if server != nil { Button { server = nil } label: { Label(store.text("All servers", "全部服务器"), systemImage: "chevron.left") }.buttonStyle(ChromeButtonStyle()) }
                Text(server.flatMap { value in history.entries.first { key($0) == value }?.hostName } ?? store.text("Operation history", "操作历史")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Toggle(store.text("Failed only", "仅失败"), isOn: $failedOnly).toggleStyle(AxonCheckboxStyle()).fixedSize(horizontal: true, vertical: false)
                Button(store.text("Clear all history", "清空全部历史"), role: .destructive) { clearing = true }.buttonStyle(ChromeButtonStyle()).disabled(history.entries.isEmpty)
            }
            Text(store.text("Records Bash/Zsh commands by server. Axon initialization scripts and password input are excluded.", "自动记录 Bash/Zsh 命令，按服务器查看；不记录 Axon 初始化脚本和密码提示中的输入。" )).font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack(spacing: 12) {
                VaultSearchField(placeholder: store.text("Search server or command", "搜索服务器或命令"), text: $search)
                AxonChoiceField(selection: $originFilter, choices: [("all", store.text("All sources", "全部来源"))] + [CommandOrigin.ai, .human].map { ($0.rawValue, $0.title(chinese: store.chinese)) }, placeholder: store.text("Command source", "命令来源"), symbol: "line.3.horizontal.decrease.circle", identifier: "axon-history-origin-filter").frame(width: 180)
            }
            if let error = history.error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if server == nil {
                        ForEach(servers, id: \.self) { value in
                            let entries = filtered.filter { key($0) == value }
                            Button { server = value } label: {
                                HStack(spacing: 14) {
                                    IconTile(symbol: value == "local" ? "terminal" : "server.rack", size: 36)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entries.first?.hostName ?? "").font(.system(size: 14, weight: .semibold))
                                        Text(store.text("\(entries.count) recorded commands", "\(entries.count) 条操作记录")).font(.caption).foregroundStyle(Palette.muted)
                                    }
                                    Spacer()
                                    if let date = entries.first?.date { Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(Palette.muted) }
                                    Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
                                }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                            }.buttonStyle(AxonSurfaceButtonStyle())
                        }
                    } else {
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: 14) {
                                Text(entry.date, format: .dateTime.year().month().day().hour().minute().second()).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 160, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) { Text(entry.command).font(.system(size: 13, design: .monospaced)).textSelection(.enabled); CommandHistoryMetadata(entry: entry) }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.command, forType: .string) } label: { Label(store.text("Copy", "复制"), systemImage: "doc.on.doc") }.buttonStyle(ChromeButtonStyle())
                                Button(store.text("Locate output", "定位输出")) { if store.sessionLogs.locate(entry) { store.section = "logs" } }.buttonStyle(ChromeButtonStyle()).disabled(!store.sessionLogs.records.contains { $0.markers.contains { $0.id == entry.id } })
                                Button(store.text("Insert", "填入")) { insert(entry) }.buttonStyle(ChromeButtonStyle()).disabled(target(entry) == nil)
                            }.padding(14).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    if filtered.isEmpty { ContentUnavailableView(store.text("No matching operations", "没有匹配的操作记录"), systemImage: "clock.arrow.circlepath", description: Text(store.text("Change the source, search or failure filter to see other records.", "调整来源、搜索或失败筛选，可查看其他记录。"))) }
                }
            }
        }.padding(22).appAlert(store.text("Clear all command history?", "清空所有操作历史？"), isPresented: $clearing) {
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}
            AppAlertButton(store.text("Clear", "清空"), role: .destructive) { history.clear() }
        } message: { Text(store.text("Removes all saved command history on this Mac.", "删除本机保存的全部命令历史。")) }
    }
    private func target(_ entry: ExecutedCommand) -> TerminalSession? { store.sessions.first { $0.connected && $0.host?.id == entry.hostID } }
    private func insert(_ entry: ExecutedCommand) {
        guard let session = target(entry), let terminal = session.terminal else { return }
        do {
            let bytes = try SnippetInput.bytes(entry.command, action: .insert, bracketedPaste: terminal.terminalStateSnapshot().bracketedPasteMode, chinese: store.chinese)
            terminal.send(data: bytes[...]); store.activeSession = session.id; store.showTerminalSection()
        } catch { store.error = error.localizedDescription }
    }
}

struct CommandHistoryMetadata: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var store: AppStore
    let entry: ExecutedCommand
    private func sourceBadge(_ origin: CommandOrigin) -> some View {
        let color: Color = origin == .ai ? Palette.accent : origin == .human ? (colorScheme == .dark ? TerminalChrome.text : Palette.blue) : Palette.muted
        return Label(origin.title(chinese: store.chinese), systemImage: origin.symbol)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 5))
    }
    var body: some View {
        HStack(spacing: 8) {
            if entry.origin == .mixed {
                HStack(spacing: 4) {
                    sourceBadge(.ai)
                    Text("+").foregroundStyle(Palette.muted)
                    sourceBadge(.human)
                }
            } else { sourceBadge(entry.origin ?? .unknown) }
            if let directory = entry.directory { Text(directory).lineLimit(1).help(directory) }
            if let code = entry.exitCode { Text("exit \(code)").foregroundStyle(code == 0 ? .green : .red) }
            if let duration = entry.duration { Text(String(format: "%.1f s", duration)) }
        }.font(.system(size: 10)).foregroundStyle(Palette.muted)
    }
}
