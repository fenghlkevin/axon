import SwiftUI
import UserNotifications
import AppKit

@MainActor extension AppStore {
    func registerAI(_ assistant: AIAssistant) {
        guard !aiSessions.contains(where: { $0 === assistant }) else { return }
        aiSessions.append(assistant)
        assistant.mayExecute = { [weak self, weak assistant] target in
            guard let self, let assistant else { return false }
            return !self.aiSessions.contains { $0 !== assistant && $0.busy && $0.currentTurnExecuted && $0.context.sessionID == target }
        }
        aiNotifications.onOpen = { [weak self] id in
            guard let self, self.openAIConversation(id) else { return false }
            self.aiAnalysisPresented = true
            SceneWindowController.activateAIWindow(for: self)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        assistant.eventHandler = { [weak self] assistant, state in
            guard let self else { return }
            if state == "settings" { self.aiSessions.filter { $0 !== assistant }.forEach { $0.settings = assistant.settings } }
            else { self.aiNotifications.receive(assistant, state: state) }
        }
    }
    @discardableResult func createAIConversation() -> Bool {
        let current = ai
        guard aiSessions.count < 20 else { current.error = text("Up to 20 conversations can be open.", "最多可打开 20 个会话。"); return false }
        let journal = aiConversationDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let next = AIAssistant(fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("ai-settings.json"), sessionJournalURL: journal)
        next.mcp = current.mcp
        next.settings = current.settings
        next.prepare(source: current.context.source, text: current.context.text, sessionID: current.context.sessionID, question: "")
        ai = next
        return true
    }
    @discardableResult func openAIConversation(_ id: UUID) -> Bool {
        _ = ai
        if let existing = aiSessions.first(where: { $0.id == id }) { selectAI(existing); return true }
        guard aiSessions.count < 20 else { aiNotifications.report("Close an idle conversation before opening saved history / 请先关闭一个空闲会话，再打开历史"); return false }
        let journal = aiConversationDirectory.appendingPathComponent(id.uuidString + ".json")
        let settingsFile = fileURL.deletingLastPathComponent().appendingPathComponent("ai-settings.json")
        let primary = AIAssistant(fileURL: settingsFile, sessionJournalURL: aiPrimaryJournalURL)
        let restored = primary.id == id ? primary : AIAssistant(fileURL: settingsFile, sessionJournalURL: journal)
        guard let entry = restored.taskRecords.last else { aiNotifications.report("Conversation history is unavailable / 会话历史不可用"); return false }
        restored.settings = ai.settings; restored.mcp = ai.mcp
        restored.prepare(source: entry.target, text: "", sessionID: entry.executed == false ? nil : entry.sessionID, question: "")
        restored.restoreTask(entry)
        ai = restored
        return true
    }
    func selectAI(_ assistant: AIAssistant) {
        guard aiSessions.contains(where: { $0 === assistant }) else { return }
        ai = assistant
        if let target = assistant.context.sessionID, sessions.contains(where: { $0.id == target }) { activeSession = target }
    }
    func selectAIForTerminal(_ target: UUID) {
        if ai.context.sessionID == target { return }
        if let existing = aiSessions.first(where: { $0.context.sessionID == target }) { selectAI(existing); return }
        if !ai.busy && ai.context.sessionID == nil && ai.submittedQuestion.isEmpty { return }
        let previous = ai
        if createAIConversation() { ai.prepare(source: "", text: "", sessionID: target, question: "") }
        else { ai = previous }
    }
    func prepareAI(source: String, text: String, sessionID: UUID?, question: String) {
        if ai.busy || ai.context.sessionID != sessionID || ai.context.source != source {
            guard createAIConversation() else { return }
        }
        ai.prepare(source: source, text: text, sessionID: sessionID, question: question)
    }
    func takeOverAI(sessionID: UUID) { aiSessions.forEach { $0.terminalTakenOver(sessionID: sessionID) } }
    func closeAI(_ assistant: AIAssistant) {
        guard !assistant.busy, aiSessions.count > 1 else { return }
        aiSessions.removeAll { $0 === assistant }
        if ai === assistant, let next = aiSessions.first { selectAI(next) }
    }
}

@MainActor final class AINotifications: NSObject, ObservableObject {
    var onOpen: ((UUID) -> Bool)?
    struct Event: Identifiable, Codable {
        var id = UUID()
        var conversation: UUID
        var state: String
        var date = Date()
        var read = false
        // Generic text keeps command output, credentials and prompts off the lock screen.
    }
    @Published private(set) var events: [Event] = []
    @Published private(set) var status = ""
    @Published private(set) var enabled: Bool
    private let file: URL
    private let preference: URL
    init(root: URL) {
        file = root.appendingPathComponent("ai-inbox.json")
        preference = root.appendingPathComponent("ai-notifications.json")
        enabled = (try? JSONDecoder().decode(Bool.self, from: Data(contentsOf: preference))) ?? false
        super.init()
        if Bundle.main.bundleIdentifier == "org.tabby.native" {
            AINotificationRouter.shared.handlers[file.path] = { [weak self] id, event in
                if self?.onOpen?(id) == true, let event { self?.markRead(event) }
            }
            UNUserNotificationCenter.current().delegate = AINotificationRouter.shared
        }
        if let data = try? Data(contentsOf: file), data.count < 256000 { events = (try? JSONDecoder().decode([Event].self, from: data)) ?? [] }
    }
    func enable() {
        guard Bundle.main.bundleIdentifier == "org.tabby.native" else { status = "Enable notifications in the packaged app / 请在打包后的应用中启用通知"; return }
        Task {
            do {
                enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                status = enabled ? "Notifications enabled / 通知已启用" : "Notifications denied; change macOS Settings / 通知未获允许，可在系统设置中修改"
                try FileManager.default.createDirectory(at: preference.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(enabled).write(to: preference, options: .atomic)
            } catch { status = error.localizedDescription }
        }
    }
    func disable() { enabled = false; try? JSONEncoder().encode(false).write(to: preference, options: .atomic) }
    func receive(_ assistant: AIAssistant, state: String) {
        guard ["approval", "question", "finished", "failed", "blocked", "declined", "limited"].contains(state) else { return }
        let event = Event(conversation: assistant.id, state: state)
        events.append(event); events = Array(events.suffix(100)); persist()
        guard enabled, Bundle.main.bundleIdentifier == "org.tabby.native" else { return }
        let content = UNMutableNotificationContent()
        content.userInfo = ["conversation": assistant.id.uuidString, "inbox": file.path]
        content.title = "Axon"
        content.body = Self.title(state)
        content.sound = .default
        Task { do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)) } catch { status = error.localizedDescription } }
    }
    static func title(_ state: String) -> String {
        switch state {
        case "approval": return "Approval required / 等待批准"
        case "question": return "Your answer is needed / 等待回答"
        case "finished": return "Task completed / 任务已完成"
        case "failed": return "Task failed / 任务失败"
        case "blocked": return "Task blocked / 任务受阻"
        case "limited": return "Task limit reached / 任务达到限额"
        default: return "Task cancelled / 任务已取消"
        }
    }
    func report(_ message: String) { status = message }
    func markAllRead() { for index in events.indices { events[index].read = true }; persist() }
    var unreadCount: Int { events.filter { !$0.read }.count }
    func markRead(_ id: UUID) { if let i = events.firstIndex(where: { $0.id == id }) { events[i].read = true; persist() } }
    func clearRead() { events.removeAll { $0.read }; persist() }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { status = error.localizedDescription }
    }
}

struct AISessionInbox: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var notifications: AINotifications
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sessions: [AIAssistant] { store.aiSessions.filter { query.isEmpty || ($0.submittedQuestion + " " + $0.context.source).localizedCaseInsensitiveContains(query) } }
    private var events: [AINotifications.Event] { notifications.events.reversed().filter { event in
        query.isEmpty || AINotifications.title(event.state).localizedCaseInsensitiveContains(query) || sessions.contains { $0.id == event.conversation }
    } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Conversations & inbox", "会话与收件箱")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }
            HStack {
                Button(store.text("New conversation", "新会话")) { if store.createAIConversation() { dismiss() } }.buttonStyle(ChromeButtonStyle(prominent: true)).accessibilityIdentifier("axon-ai-session-create")
                Spacer()
                Button(notifications.enabled ? store.text("Disable notifications", "关闭通知") : store.text("Enable notifications", "启用通知")) { if notifications.enabled { notifications.disable() } else { notifications.enable() } }.buttonStyle(ChromeButtonStyle())
            }
            if !notifications.status.isEmpty { Text(localized(notifications.status)).font(.caption).foregroundStyle(Palette.muted) }
            TextField(store.text("Search conversations and task states", "搜索会话、目标和任务状态"), text: $search).appInput().accessibilityIdentifier("axon-ai-inbox-search")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !query.isEmpty && sessions.isEmpty && events.isEmpty {
                        Label(store.text("No matching conversations or notifications", "没有匹配的会话或通知"), systemImage: "magnifyingglass").font(.caption).foregroundStyle(Palette.muted).padding(.vertical, 8).accessibilityIdentifier("axon-ai-inbox-empty")
                    }
                    ForEach(sessions) { assistant in AISessionRow(assistant: assistant, open: { store.selectAI(assistant); dismiss() }, close: { store.closeAI(assistant) }).environmentObject(store) }
                    Divider()
                    HStack {
                        Text(store.text("Inbox · \(notifications.unreadCount) unread", "收件箱 · \(notifications.unreadCount) 条未读")).font(.subheadline)
                        Spacer()
                        Button(store.text("Read all", "全部已读")) { notifications.markAllRead() }.buttonStyle(ChromeButtonStyle()).disabled(notifications.unreadCount == 0).accessibilityIdentifier("axon-ai-inbox-read-all")
                        Button(store.text("Clear read", "清除已读")) { notifications.clearRead() }.buttonStyle(ChromeButtonStyle()).disabled(!notifications.events.contains { $0.read })
                    }
                    if notifications.events.isEmpty { Text(store.text("Task updates appear here.", "任务完成、失败及等待处理的消息将显示在这里。")).font(.caption).foregroundStyle(Palette.muted) }
                    ForEach(events) { event in
                        Button {
                            if store.openAIConversation(event.conversation) { notifications.markRead(event.id); dismiss() }
                        } label: {
                            HStack { Image(systemName: event.read ? "envelope.open" : "envelope.badge"); Text(localized(AINotifications.title(event.state))); Spacer(); Text(event.date, style: .time).foregroundStyle(Palette.muted) }.font(.system(size: 12)).padding(10).background(event.read ? Palette.field : Palette.selected).clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(AxonSurfaceButtonStyle())
                    }
                }
            }
            Text(store.text("Each conversation keeps its own queue and approvals. One execution task per terminal. Queues and running agents do not survive quitting.", "各会话独立保存队列和审批；每个终端同时执行一个任务。退出应用后不保留队列与运行中的代理。")).font(.caption).foregroundStyle(Palette.muted)
        }.padding(20).frame(width: 540, height: 580).foregroundStyle(Palette.text).background(Palette.background)
    }
    private func localized(_ value: String) -> String { let parts = value.components(separatedBy: " / "); return parts.count == 2 ? store.text(parts[0], parts[1]) : value }
}
private struct AISessionRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var assistant: AIAssistant
    let open: () -> Void
    let close: () -> Void
    var body: some View {
        HStack {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(assistant.submittedQuestion.isEmpty ? store.text("New conversation", "新会话") : assistant.submittedQuestion).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(assistant.context.source).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(assistant.pendingApproval != nil ? store.text("Approval required", "等待批准") : assistant.pendingQuestion != nil ? store.text("Answer required", "等待回答") : assistant.busy ? store.text("Running", "运行中") : assistant.error.isEmpty ? store.text("Ready", "就绪") : store.text("Failed", "失败")).font(.caption).foregroundStyle(Palette.accent)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityIdentifier("axon-ai-session-open")
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).disabled(assistant.busy || store.aiSessions.count == 1).help(store.text("Close; history stays on disk", "关闭；历史保留在磁盘"))
        }.background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor private final class AINotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AINotificationRouter()
    var handlers: [String: (UUID, UUID?) -> Void] = [:]
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["conversation"] as? String).flatMap(UUID.init(uuidString:))
        let inbox = info["inbox"] as? String
        let event = UUID(uuidString: response.notification.request.identifier)
        Task { @MainActor in
            if let id, let inbox { Self.shared.handlers[inbox]?(id, event) }
            completionHandler()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}
