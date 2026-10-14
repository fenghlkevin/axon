import Foundation
import AppKit
import SwiftUI
import Security
import Yams

struct Host: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var address = ""
    var port = 22
    var username = NSUserName()
    var group = ""
    var tags = ""
    var auth = "password"
    var keyPath = ""
    var keySource: String?
    var agentSocketPath: String?
    var agentFingerprint: String?
    var certificatePath: String?
    var certificateAuthorityPath: String?
    var hostCertificateAuthorityPath: String?
    var forwardAgent: Bool?
    var credentialID: UUID?
    var jumpHostID: UUID?
    /// Missing on legacy profiles: every setting remains a host override.
    var groupInheritance: HostGroupInheritance?
    var persistentSession: Bool?
    var persistentSessionName: String?
    var favorite = false
    var aiCommandWhitelist: String?
    var aiCommandBlacklist: String?
}

struct VaultCredential: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var username = "root"
    var auth = "password"
    var keyPath = ""
    var keySource: String?
}

struct Preferences: Codable, Equatable {
    var language = "auto"
    /// Legacy workspaces retain the original dark application icon.
    var applicationIcon = "black"
    var fontName = "Menlo"
    var fontSize: Double = 19
    var scrollback = 250000
    var copyOnSelect = true
    var rightClickPaste = true
    var trimPaste = true
    var analytics = false
    var globalHotkey = false
    var restoreTabs = false
    var autoOpen = false
    var foreground = "#00CC74"
    var background = "#1e1f29"
    var cursorColor = "#bbbbbb"
    var terminalTheme = "draculaGreen"
    /// Nil on older versions: use the selected preset's original ANSI palette.
    var ansiColors: [String]?
    var customTerminalThemes: [TerminalTheme] = []
    var cursorShape = "block"
    var cursorBlink = false
    var optionAsMeta = false
    var backspaceControlH = false
    var mouseReporting = true
    var bellStyle = "none"
    var confirmMultilinePaste = false
    var middleClickPaste = true
    /// Empty paths preserve the system login shell and home directory.
    var localShell = ""
    var localDirectory = ""
    var localLoginShell = true
    var sshConnectTimeout = 30
    var keywordRules: [KeywordRule] = []
    var shortcuts: [String: ShortcutBinding] = [:]
    var commandHistoryLimit = 1000
    var commandHistoryExclusions = ""
    var commandCompletionNotifications = false

    enum CodingKeys: String, CodingKey {
        case language, applicationIcon, fontName, fontSize, scrollback, copyOnSelect, rightClickPaste, trimPaste
        case analytics, globalHotkey, restoreTabs, autoOpen, foreground, background
        case ansiColors, customTerminalThemes
        case cursorColor, terminalTheme, cursorShape, cursorBlink, optionAsMeta, backspaceControlH
        case mouseReporting, bellStyle, confirmMultilinePaste, middleClickPaste
        case shortcuts, keywordRules, commandHistoryLimit, commandHistoryExclusions, commandCompletionNotifications
        case localShell, localDirectory, localLoginShell, sshConnectTimeout
    }
    init() {}
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        language = try v.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        applicationIcon = try v.decodeIfPresent(String.self, forKey: .applicationIcon) ?? "black"
        fontName = try v.decodeIfPresent(String.self, forKey: .fontName) ?? "Menlo"
        fontSize = try v.decodeIfPresent(Double.self, forKey: .fontSize) ?? 19
        scrollback = try v.decodeIfPresent(Int.self, forKey: .scrollback) ?? 250000
        copyOnSelect = try v.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? true
        rightClickPaste = try v.decodeIfPresent(Bool.self, forKey: .rightClickPaste) ?? true
        trimPaste = try v.decodeIfPresent(Bool.self, forKey: .trimPaste) ?? true
        analytics = try v.decodeIfPresent(Bool.self, forKey: .analytics) ?? false
        globalHotkey = try v.decodeIfPresent(Bool.self, forKey: .globalHotkey) ?? false
        restoreTabs = try v.decodeIfPresent(Bool.self, forKey: .restoreTabs) ?? false
        autoOpen = try v.decodeIfPresent(Bool.self, forKey: .autoOpen) ?? false
        foreground = try v.decodeIfPresent(String.self, forKey: .foreground) ?? "#00CC74"
        background = try v.decodeIfPresent(String.self, forKey: .background) ?? "#1e1f29"
        cursorColor = try v.decodeIfPresent(String.self, forKey: .cursorColor) ?? "#bbbbbb"
        terminalTheme = try v.decodeIfPresent(String.self, forKey: .terminalTheme) ?? "draculaGreen"
        ansiColors = try v.decodeIfPresent([String].self, forKey: .ansiColors)
        customTerminalThemes = try v.decodeIfPresent([TerminalTheme].self, forKey: .customTerminalThemes) ?? []
        cursorShape = try v.decodeIfPresent(String.self, forKey: .cursorShape) ?? "block"
        cursorBlink = try v.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? false
        optionAsMeta = try v.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? false
        backspaceControlH = try v.decodeIfPresent(Bool.self, forKey: .backspaceControlH) ?? false
        mouseReporting = try v.decodeIfPresent(Bool.self, forKey: .mouseReporting) ?? true
        bellStyle = try v.decodeIfPresent(String.self, forKey: .bellStyle) ?? "none"
        confirmMultilinePaste = try v.decodeIfPresent(Bool.self, forKey: .confirmMultilinePaste) ?? false
        middleClickPaste = try v.decodeIfPresent(Bool.self, forKey: .middleClickPaste) ?? true
        localShell = try v.decodeIfPresent(String.self, forKey: .localShell) ?? ""
        localDirectory = try v.decodeIfPresent(String.self, forKey: .localDirectory) ?? ""
        localLoginShell = try v.decodeIfPresent(Bool.self, forKey: .localLoginShell) ?? true
        keywordRules = try v.decodeIfPresent([KeywordRule].self, forKey: .keywordRules) ?? []
        shortcuts = try v.decodeIfPresent([String: ShortcutBinding].self, forKey: .shortcuts) ?? [:]
        commandHistoryLimit = try v.decodeIfPresent(Int.self, forKey: .commandHistoryLimit) ?? 1000
        commandHistoryExclusions = try v.decodeIfPresent(String.self, forKey: .commandHistoryExclusions) ?? ""
        commandCompletionNotifications = try v.decodeIfPresent(Bool.self, forKey: .commandCompletionNotifications) ?? false
        sshConnectTimeout = try v.decodeIfPresent(Int.self, forKey: .sshConnectTimeout) ?? 30
    }
}

struct Workspace: Codable {
    var hosts: [Host] = []
    var groups: [String] = []
    var groupDefaults: [HostGroup] = []
    var tags: [String] = []
    var credentials: [VaultCredential] = []
    var forwards: [PortForwardRule] = []
    var logs: [ActivityLog] = []
    var snippets: [CommandSnippet] = []
    var workScenes: [WorkScene] = []
    var recentTargets: [RecentTarget] = []
    var batchTemplates: [BatchTemplate] = []
    var preferences = Preferences()
    var bookmarks: [String: [String]] = [:]
    var trustedKeys: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case hosts, groups, groupDefaults, tags, credentials, forwards, logs, snippets, workScenes, recentTargets, batchTemplates, preferences, bookmarks, trustedKeys }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try values.decodeIfPresent([Host].self, forKey: .hosts) ?? []
        groups = try values.decodeIfPresent([String].self, forKey: .groups) ?? []
        groupDefaults = try values.decodeIfPresent([HostGroup].self, forKey: .groupDefaults) ?? []
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        credentials = try values.decodeIfPresent([VaultCredential].self, forKey: .credentials) ?? []
        forwards = try values.decodeIfPresent([PortForwardRule].self, forKey: .forwards) ?? []
        logs = try values.decodeIfPresent([ActivityLog].self, forKey: .logs) ?? []
        snippets = try values.decodeIfPresent([CommandSnippet].self, forKey: .snippets) ?? []
        workScenes = try values.decodeIfPresent([WorkScene].self, forKey: .workScenes) ?? []
        recentTargets = try values.decodeIfPresent([RecentTarget].self, forKey: .recentTargets) ?? []
        batchTemplates = try values.decodeIfPresent([BatchTemplate].self, forKey: .batchTemplates) ?? []
        preferences = try values.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
        bookmarks = try values.decodeIfPresent([String: [String]].self, forKey: .bookmarks) ?? [:]
        trustedKeys = try values.decodeIfPresent([String: String].self, forKey: .trustedKeys) ?? [:]
    }
}

struct FileEntry: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var directory: Bool
    var symlink: Bool = false
    var size: UInt64 = 0
    var permissions: UInt32 = 0
    var modified = Date(timeIntervalSince1970: 0)
}

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func remoteJoin(_ parent: String, _ child: String) throws -> String {
    guard !child.isEmpty, child != ".", child != "..", !child.contains("/"), !child.contains("\0") else {
        throw AppFailure.message("Invalid file name")
    }
    let base = (parent as NSString).standardizingPath
    return (base == "/" ? "" : base) + "/" + child
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}

enum Palette {
    static let background = Color(hex: "#EDF2F3")
    static let sidebar = Color(hex: "#F7F9FC")
    static let card = Color(hex: "#FFFFFF")
    static let field = Color(hex: "#E5EBEF")
    static let selected = Color(hex: "#DDE8EE")
    static let border = Color(hex: "#D5DCE1")
    static let text = Color(hex: "#171A2A")
    static let muted = Color(hex: "#7B8A92")
    static let accent = Color(hex: "#2E91EC")
    static let localTerminal = accent
    static let sftp = Color(hex: "#C56A18")
    static let danger = Color(hex: "#C42B38")
    static let blue = Color(hex: "#075479")
    static let orange = Color(hex: "#075479")
    static let chrome = Color(hex: "#303249")
    static let chromeText = Color(hex: "#E7E9F0")
    static let surfaceHex = "#EDF2F3"
    static let terminalForeground = "#00CC74"
    static let terminalBackground = "#1e1f29"
    static let ansi = ["#000000", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#bbbbbb", "#555555", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#ffffff"]
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

enum Secrets {
    static let service = "org.tabby.native.credentials"
    struct Value {
        var secret = ""
        var privateKey = ""
    }
    static func read(_ id: UUID) -> String { (try? readChecked(id)) ?? "" }
    static func readChecked(_ id: UUID) throws -> String { try readChecked(id, allowInteraction: true) }
    static func readChecked(_ id: UUID, allowInteraction: Bool) throws -> String { try readAccount(id.uuidString, allowInteraction: allowInteraction) }
    static func readPrivateKey(_ id: UUID) throws -> String { try readPrivateKey(id, allowInteraction: true) }
    static func readPrivateKey(_ id: UUID, allowInteraction: Bool) throws -> String { try readAccount(id.uuidString + ".privateKey", allowInteraction: allowInteraction) }
    static func readCredential(_ id: UUID) throws -> Value { try readCredential(id, allowInteraction: true) }
    static func readCredential(_ id: UUID, allowInteraction: Bool) throws -> Value {
        try Value(secret: readChecked(id, allowInteraction: allowInteraction), privateKey: readPrivateKey(id, allowInteraction: allowInteraction))
    }
    private static func readAccount(_ account: String, allowInteraction: Bool) throws -> String {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        if status == errSecInteractionNotAllowed {
            throw AppFailure.message("Keychain is unavailable without interaction. Unlock it and retry from Cloud Backup. / 钥匙串暂不可读取，请解锁后在云备份中重试。")
        }
        guard status == errSecSuccess, let data = result as? Data else { throw AppFailure.message("Keychain read failed: \(status)") }
        guard let value = String(data: data, encoding: .utf8) else { throw AppFailure.message("Invalid credential encoding") }
        return value
    }
    static func save(_ value: String, id: UUID) throws { try saveAccount(value, account: id.uuidString) }
    static func saveCredential(_ value: Value, id: UUID) throws {
        let previous = try readCredential(id)
        try save(value.secret, id: id)
        do { try saveAccount(value.privateKey, account: id.uuidString + ".privateKey") }
        catch { try? save(previous.secret, id: id); throw error }
    }
    private static func saveAccount(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status: OSStatus
        if value.isEmpty { status = SecItemDelete(query as CFDictionary) }
        else {
            let data = Data(value.utf8)
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = updated }
        }
        guard status == errSecSuccess || (value.isEmpty && status == errSecItemNotFound) else {
            throw AppFailure.message("Keychain: \(status)")
        }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var aiSessions: [AIAssistant] = []
    @Published private var selectedAssistant: AIAssistant?
    private var aiStorageRoot: URL { aiNamespace.map { fileURL.deletingLastPathComponent().appendingPathComponent("AISceneSessions/" + $0.uuidString) } ?? fileURL.deletingLastPathComponent() }
    var aiPrimaryJournalURL: URL? { aiNamespace == nil ? nil : aiStorageRoot.appendingPathComponent("primary.json") }
    var aiConversationDirectory: URL { aiStorageRoot.appendingPathComponent("AISessions") }
    lazy var aiNotifications = AINotifications(root: aiStorageRoot)
    var ai: AIAssistant {
        get {
            if let selectedAssistant { return selectedAssistant }
            let initial = AIAssistant(fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("ai-settings.json"), sessionJournalURL: aiPrimaryJournalURL)
            registerAI(initial); selectedAssistant = initial
            let directory = aiConversationDirectory
            for path in ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter({ $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }).sorted(by: {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left > right
            }).prefix(19) {
                let restored = AIAssistant(fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("ai-settings.json"), sessionJournalURL: path)
                if let entry = restored.taskRecords.last {
                    restored.prepare(source: entry.target, text: "", sessionID: entry.executed == false ? nil : entry.sessionID, question: "")
                    restored.restoreTask(entry)
                }
                if !restored.taskRecords.isEmpty { registerAI(restored) }
            }
            return initial
        }
        set { registerAI(newValue); selectedAssistant = newValue }
    }
    @Published var aiAnalysisPresented = false
    @Published var aiTerminalRequest = UUID()
    let monitoring = MonitoringCenter()
    let externalEdits = ExternalEditCenter()
    lazy var batchTasks = BatchTaskCenter(store: self)
    lazy var sessionLogs = SessionLogStore(root: fileURL.deletingLastPathComponent().appendingPathComponent("SessionLogs"))
    lazy var automaticBackup = AutomaticBackupCoordinator(store: self)
    @Published var workspace = Workspace()
    @Published var section = "hosts"
    @Published var settingsPage = PreferencesPage.general
    @Published var group = ""
    @Published var search = ""
    @Published var launcherRequest = 0
    @Published var newTabOpen = false
    @Published var recentFileRequest: RecentFileRequest?
    var handledRecentFileRequestID: UUID?
    var deletedHostIDs = Set<UUID>()
    @Published var error: String?
    @Published var sessions: [TerminalSession] = []
    @Published var activeSession: UUID?
    @Published var terminalFileRequest: TerminalFileRequest?
    var handledTerminalFileRequestID: UUID?
    @Published var openScenes: [OpenWorkScene] = []
    @Published var activeSceneID: UUID?
    @Published var logViewers: [LogViewerModel] = []
    @Published var activeLogViewer: UUID?
    var sceneTasks: [UUID: Task<Void, Never>] = [:]
    var sceneManagedForwardIDs = Set<UUID>()
    var sceneTaskTokens: [UUID: UUID] = [:]
    var forwardSessionIDs: [UUID: UUID] = [:]
    @Published var splitPartners: [UUID: UUID] = [:]
    @Published var terminalPaneGroups: [UUID: [UUID]] = [:]
    @Published var synchronizedTargets = Set<UUID>()
    @Published var synchronizationEnabled = false
    var sharedWorkspaceCommit: ((Workspace) -> Bool)?
    weak var sceneWindowOwner: AppStore?
    var sceneWindowID: UUID?
    private let aiNamespace: UUID?
    let fileURL: URL
    var applicationIconController = ApplicationIconController.production()
    @Published var forwardStatus: [UUID: String] = [:]
    var forwardTasks: [UUID: Task<Void, Never>] = [:]
    var forwardEngines: [UUID: LocalForwardEngine] = [:]
    private var loadFailed = false
    var canAutomaticallyBackup: Bool { !loadFailed }
    init(fileURL: URL? = nil, aiNamespace: UUID? = nil) {
        self.aiNamespace = aiNamespace
        self.fileURL = fileURL ?? ProcessInfo.processInfo.environment["TABBY_NATIVE_WORKSPACE"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TabbyNative/workspace.json")
        _ = ai
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                workspace = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: self.fileURL))
                pruneRecentTargets()
            }
            catch { loadFailed = true; self.error = "Could not read workspace: \(error.localizedDescription). Original file preserved." }
        }
    }
    var chinese: Bool { workspace.preferences.language == "zh-CN" || (workspace.preferences.language == "auto" && Locale.preferredLanguages.first?.hasPrefix("zh") == true) }
    func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    @discardableResult func save() -> Bool {
        guard !loadFailed else { error = text("Workspace could not be read. Repair or restore its backup before saving.", "配置读取失败，请修复文件或恢复备份后再保存。"); return false }
        workspace.preferences.scrollback = max(0, min(1000000, workspace.preferences.scrollback))
        workspace.recentTargets = RecentTargets.pruned(workspace.recentTargets, workspace: workspace)
        if let sharedWorkspaceCommit { return sharedWorkspaceCommit(workspace) }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = fileURL.appendingPathExtension("backup")
                if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
                try FileManager.default.copyItem(at: fileURL, to: backup)
            }
            try JSONEncoder().encode(workspace).write(to: fileURL, options: .atomic)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// Recent-history failures cannot leave an in-memory change that disappears
    /// on restart, or mutate a workspace whose original file failed to decode.
    @discardableResult func commitRecentTargets(_ targets: [RecentTarget]) -> Bool {
        guard !loadFailed else { return false }
        let previous = workspace
        workspace.recentTargets = targets
        if save() { return true }
        workspace = previous
        return false
    }
    // Keep credential metadata and both Keychain items together on failed saves.
    func commitCredentials(_ updated: Workspace, changes: [UUID: Secrets.Value]) throws {
        guard !loadFailed else { throw AppFailure.message(text("Workspace could not be read", "配置读取失败，无法保存凭据")) }
        let previousWorkspace = workspace
        var previous: [UUID: Secrets.Value] = [:]
        for id in changes.keys { previous[id] = try Secrets.readCredential(id) }
        var written: [UUID] = []
        do {
            for (id, value) in changes { try Secrets.saveCredential(value, id: id); written.append(id) }
            workspace = updated
            guard save() else { throw AppFailure.message(error ?? text("Could not save workspace", "无法保存配置")) }
        } catch {
            workspace = previousWorkspace
            for id in written.reversed() { if let value = previous[id] { try? Secrets.saveCredential(value, id: id) } }
            throw error
        }
    }
    /// Only a validated full archive can recover an unreadable workspace.
    /// Regular edits and host imports retain the load-failure write protection.
    func commitArchive(_ archive: WorkspaceArchive, changes: [UUID: Secrets.Value]) throws {
        try WorkspaceArchiveCodec.validate(archive)
        let previousLoadFailure = loadFailed
        loadFailed = false
        do { try commitCredentials(archive.workspace, changes: changes); error = nil }
        catch { loadFailed = previousLoadFailure; throw error }
    }
    func keyValue(auth: String, source: String?, path: String, id: UUID, secret: String, privateKey: String?) throws -> Secrets.Value {
        guard auth == "key" else { return Secrets.Value(secret: secret) }
        if source == "text" {
            let content = PrivateKeys.normalize(try privateKey ?? Secrets.readPrivateKey(id))
            _ = try PrivateKeys.authentication(content, passphrase: secret, username: "validation", chinese: chinese)
            return Secrets.Value(secret: secret, privateKey: content)
        }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure.message(text("Choose a private key file or paste its text", "请选择私钥文件或粘贴私钥文本")) }
        return Secrets.Value(secret: secret)
    }
    var groups: [String] { CatalogNames.unique(workspace.groups + workspace.groupDefaults.map(\.name) + workspace.hosts.map(\.group)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func addGroup(_ name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CatalogNames.valid(name), !CatalogNames.contains(groups, name) else { throw AppFailure.message(text("Enter a unique group name", "请输入未使用的分组名称")) }
        var updated = workspace
        updated.groups = CatalogNames.unique(updated.groups + [name])
        try commitCatalog(updated)
    }
    func upsert(_ host: Host, secret: String, privateKey: String? = nil) throws {
        try AIExecutionPolicy().mergingCommandLists(host).validate()
        var host = try GroupDefaults.validatedForStorage(host, workspace: workspace, chinese: chinese)
        host.tags = TagTokens.serialized(TagTokens.parse(host.tags))
        var changes: [UUID: Secrets.Value] = [:]
        if host.groupInheritance?.authentication == true, groupDefaults(named: host.group) != nil {
            // The group owns its secret. Saving host metadata must not erase a
            // saved host override or duplicate the base secret into the profile.
        } else if let id = host.credentialID {
            guard workspace.credentials.contains(where: { $0.id == id }) else { throw AppFailure.message("Credential not found") }
        } else { changes[host.id] = try keyValue(auth: host.auth, source: host.keySource, path: host.keyPath, id: host.id, secret: secret, privateKey: privateKey) }
        var updated = workspace
        if let i = updated.hosts.firstIndex(where: { $0.id == host.id }) { updated.hosts[i] = host }
        else { updated.hosts.append(host) }
        updated.tags = TagTokens.unique(updated.tags + TagTokens.parse(host.tags))
        try commitCredentials(updated, changes: changes)
        deletedHostIDs.remove(host.id)
    }
    func renameGroup(_ old: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CatalogNames.valid(name), !groups.contains(where: { CatalogNames.matches($0, name) && !CatalogNames.matches($0, old) }) else { throw AppFailure.message(text("Enter a unique group name", "请输入未使用的分组名称")) }
        var updated = workspace
        updated.groups = CatalogNames.unique(updated.groups.filter { !CatalogNames.matches($0, old) } + [name])
        for i in updated.groupDefaults.indices where CatalogNames.matches(updated.groupDefaults[i].name, old) { updated.groupDefaults[i].name = name }
        for i in updated.hosts.indices where CatalogNames.matches(updated.hosts[i].group, old) { updated.hosts[i].group = name }
        try commitCatalog(updated)
        if CatalogNames.matches(group, old) { group = name }
    }
    func dissolveGroup(_ name: String) {
        do { try removeGroup(name) } catch { self.error = error.localizedDescription }
    }
    func moveHost(_ id: UUID, to group: String) {
        guard let i = workspace.hosts.firstIndex(where: { $0.id == id }) else { return }
        do {
            var updated = workspace
            var changes: [UUID: Secrets.Value] = [:]
            var host = updated.hosts[i]
            if host.groupInheritance?.hasAny == true, groupDefaults(named: host.group) != nil,
               groupDefaults(named: group) == nil {
                if host.groupInheritance?.authentication == true { changes[host.id] = try Secrets.readCredential(groupSecretID(for: host)) }
                host = resolvedHost(host)
            }
            host.group = group
            updated.hosts[i] = try GroupDefaults.validatedForStorage(host, workspace: updated, chinese: chinese)
            try commitCredentials(updated, changes: changes)
        } catch { self.error = error.localizedDescription }
    }
    func duplicateHost(_ host: Host) throws {
        var copy = host; copy.id = UUID(); copy.name += text(" copy", " 副本")
        copy = try GroupDefaults.validatedForStorage(copy, workspace: workspace, chinese: chinese)
        var updated = workspace; updated.hosts.append(copy)
        let inheritsAuth = host.groupInheritance?.authentication == true && groupDefaults(named: host.group) != nil
        try commitCredentials(updated, changes: !inheritsAuth && host.credentialID == nil ? [copy.id: try Secrets.readCredential(host.id)] : [:])
    }
    func saveCredential(_ value: VaultCredential, secret: String, privateKey: String? = nil) throws {
        let value = try ConnectionValidation.credential(value, chinese: chinese)
        let credentials = try keyValue(auth: value.auth, source: value.keySource, path: value.keyPath, id: value.id, secret: secret, privateKey: privateKey)
        var updated = workspace
        if let i = updated.credentials.firstIndex(where: { $0.id == value.id }) { updated.credentials[i] = value } else { updated.credentials.append(value) }
        try commitCredentials(updated, changes: [value.id: credentials])
    }
    func removeCredential(_ id: UUID) throws {
        guard let credential = workspace.credentials.first(where: { $0.id == id }) else { return }
        let secrets = try Secrets.readCredential(id)
        var updated = workspace
        var changes: [UUID: Secrets.Value] = [id: Secrets.Value()]
        // Preserve access when removing a reusable identity: each host becomes independent.
        for host in updated.hosts where host.credentialID == id { changes[host.id] = secrets }
        for i in updated.hosts.indices where updated.hosts[i].credentialID == id {
            updated.hosts[i].username = credential.username; updated.hosts[i].auth = credential.auth; updated.hosts[i].keyPath = credential.keyPath; updated.hosts[i].keySource = credential.keySource; updated.hosts[i].credentialID = nil
        }
        for i in updated.groupDefaults.indices where updated.groupDefaults[i].credentialID == id {
            changes[updated.groupDefaults[i].id] = secrets
            updated.groupDefaults[i].username = credential.username; updated.groupDefaults[i].auth = credential.auth
            updated.groupDefaults[i].keyPath = credential.keyPath; updated.groupDefaults[i].keySource = credential.keySource
            updated.groupDefaults[i].credentialID = nil
        }
        updated.credentials.removeAll { $0.id == id }
        try commitCredentials(updated, changes: changes)
    }
    func deleteHost(_ id: UUID) throws {
        var updated = workspace; updated.hosts.removeAll { $0.id == id }
        let removedRules = Set(updated.forwards.filter { $0.hostID == id }.map(\.id))
        updated.forwards.removeAll { $0.hostID == id }
        for index in updated.workScenes.indices { updated.workScenes[index].removeHost(id); updated.workScenes[index].forwardIDs.removeAll { removedRules.contains($0) } }
        try commitCredentials(updated, changes: [id: Secrets.Value()])
        for rule in removedRules { stopForward(rule) }
        deletedHostIDs.insert(id)
    }
    func connect(_ host: Host? = nil) {
        if section == "launcher" { newTabOpen = false }
        let session = TerminalSession(host: host, store: self)
        sessions.append(session); activeSession = session.id; section = "terminal"
        if let sceneWindowID, let scene = openScenes.first(where: { $0.id == sceneWindowID }) {
            scene.sessionIDs.append(session.id); scene.selectedSessionID = session.id; scene.mode = "terminal"; showScene(scene)
        }
    }
    func openLauncher() { newTabOpen = true; launcherRequest += 1; section = "launcher" }
    func showMonitoring(_ host: Host? = nil) {
        section = "monitoring"
        if let host { monitoring.select(monitoring.targetID(for: host, workspace: workspace)) }
        else { monitoring.select(nil) }
    }
    func quickConnectionHost(_ target: Host) -> Host {
        // Reuse an explicitly selected identity, or a saved host's credentials for the same login.
        guard target.credentialID == nil else { return target }
        return workspace.hosts.first { saved in
            let effective = resolvedHost(saved)
            return effective.address.caseInsensitiveCompare(target.address) == .orderedSame && effective.port == target.port && effective.username == target.username
        } ?? target
    }
    @discardableResult func connectQuick(_ target: Host) -> Bool {
        do {
            let normalized = try ConnectionValidation.host(target, workspace: workspace, chinese: chinese)
            let selected = quickConnectionHost(normalized)
            _ = try ConnectionValidation.host(selected, workspace: workspace, chinese: chinese)
            connect(selected)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func openFiles(_ host: Host) {
        if let session = sessions.first(where: { $0.host?.id == host.id && $0.connected }) { activeSession = session.id }
        else { connect(host) }
        section = "sftp"
    }
    var terminalTabs: [TerminalSession] {
        standaloneSessions.filter { session in paneIDs(containing: session.id).first == session.id }
    }
    func closeTerminalTab(_ id: UUID) { for key in paneIDs(containing: id) { close(key) } }
    func separateSession(_ id: UUID) { dissolvePane(id) }
    func pairSessions(_ source: UUID, with target: UUID) {
        guard source != target, sessions.contains(where: { $0.id == source }), sessions.contains(where: { $0.id == target }),
              (sceneWindowID != nil || !openScenes.contains(where: { $0.sessionIDs.contains(source) || $0.sessionIDs.contains(target) })) else { return }
        var ids = paneIDs(containing: target)
        guard !ids.contains(source), ids.count < 4 else { return }
        dissolvePane(source)
        if ids.count == 1 { ids = [target] }
        for key in terminalPaneGroups.keys.filter({ terminalPaneGroups[$0]?.contains(target) == true }) { terminalPaneGroups.removeValue(forKey: key) }
        splitPartners = splitPartners.filter { !ids.contains($0.key) && !ids.contains($0.value) }
        ids.append(source); terminalPaneGroups[ids[0]] = ids
        if ids.count == 2 { splitPartners[ids[0]] = ids[1]; splitPartners[ids[1]] = ids[0] }
        activeSession = target; section = "terminal"; synchronizationEnabled = false
    }
    func split() {
        guard let id = activeSession, let current = sessions.first(where: { $0.id == id }) else { connect(); return }
        let ids = paneIDs(containing: id)
        guard ids.count < 4 else { error = text("A group supports up to four panes", "一个分屏组最多支持四个终端"); return }
        let session = TerminalSession(host: current.host, store: self)
        sessions.append(session)
        for key in terminalPaneGroups.keys.filter({ terminalPaneGroups[$0]?.contains(id) == true }) { terminalPaneGroups.removeValue(forKey: key) }
        splitPartners = splitPartners.filter { !ids.contains($0.key) && !ids.contains($0.value) }
        terminalPaneGroups[ids.first ?? id] = ids + [session.id]
        if ids.count == 1 { splitPartners[id] = session.id; splitPartners[session.id] = id }
        if let owner = openScenes.first(where: { $0.sessionIDs.contains(id) }) { owner.sessionIDs.append(session.id) }
        synchronizationEnabled = false; activeSession = session.id; showTerminalSection()
    }
    func moveSession(_ id: UUID, before target: UUID) {
        guard id != target, let from = sessions.firstIndex(where: { $0.id == id }), let targetIndex = sessions.firstIndex(where: { $0.id == target }) else { return }
        positionSession(from: from, at: targetIndex > from ? targetIndex - 1 : targetIndex)
    }
    func moveSession(_ id: UUID, after target: UUID) {
        guard id != target, let from = sessions.firstIndex(where: { $0.id == id }), let targetIndex = sessions.firstIndex(where: { $0.id == target }) else { return }
        positionSession(from: from, at: targetIndex < from ? targetIndex + 1 : targetIndex)
    }
    func moveSession(_ id: UUID, by offset: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        let destination = offset < 0 ? max(0, from + max(offset, -from)) : min(sessions.count - 1, from + min(offset, sessions.count - 1 - from))
        positionSession(from: from, at: destination)
    }
    func moveSessionToBeginning(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), index != 0 else { return }
        positionSession(from: index, at: 0)
    }
    func moveSessionToEnd(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), index != sessions.count - 1 else { return }
        positionSession(from: index, at: sessions.count - 1)
    }
    private func positionSession(from index: Int, at destination: Int) {
        guard index != destination else { return }
        // Publish a complete ordering so a live tab never briefly disappears during a move.
        var reordered = sessions
        let session = reordered.remove(at: index); reordered.insert(session, at: destination)
        sessions = reordered
    }
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        let partner = paneIDs(containing: id).first { $0 != id }
        dissolvePane(id)
        sessions.remove(at: index)
        for scene in openScenes { scene.sessionIDs.removeAll { $0 == id } }
        if activeSession == id || !sessions.contains(where: { $0.id == activeSession }) {
            if section == "scene", let scene = currentScene {
                activeSession = scene.sessionIDs.first { candidate in sessions.contains { $0.id == candidate } }
                scene.selectedSessionID = activeSession
            } else if let partner, sessions.contains(where: { $0.id == partner }) { activeSession = partner }
            else { activeSession = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id }
        }
        if sessions.isEmpty, section == "terminal" { section = "hosts" }
        session.disconnect()
        monitoring.connectionsChanged()
    }
    func importTabby(_ url: URL) throws {
        _ = try importHosts(HostTransfer.parse(WorkspaceTransfer.read(url), format: .tabby))
    }
}
