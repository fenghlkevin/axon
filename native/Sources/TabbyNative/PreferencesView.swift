import SwiftUI
import AppKit

enum PreferencesPage: String, CaseIterable, Identifiable {
    case general, terminal, appearance, keywords, keyboard, connection, ai, importHosts, storage, shortcuts, about
    var id: String { rawValue }
    var icon: String {
        switch self { case .ai: return "sparkles"; case .keywords: return "textformat.abc"; case .general: return "gearshape"; case .terminal: return "terminal"; case .appearance: return "paintpalette"; case .keyboard: return "keyboard"; case .connection: return "network"; case .importHosts: return "arrow.up.arrow.down"; case .storage: return "externaldrive.badge.icloud"; case .shortcuts: return "command"; case .about: return "info.circle" }
    }
    func title(chinese: Bool) -> String {
        switch self {
        case .ai: return chinese ? "AI 助手" : "AI assistant"
        case .keywords: return chinese ? "关键词规则" : "Keyword rules"
        case .general: return chinese ? "通用" : "General"
        case .terminal: return chinese ? "终端" : "Terminal"
        case .appearance: return chinese ? "终端配色" : "Terminal colors"
        case .keyboard: return chinese ? "键盘与剪贴板" : "Keyboard & Clipboard"
        case .connection: return chinese ? "连接" : "Connection"
        case .importHosts: return chinese ? "导入与导出" : "Import & Export"
        case .storage: return chinese ? "云备份" : "Cloud backup"
        case .shortcuts: return chinese ? "快捷键" : "Shortcuts"
        case .about: return chinese ? "关于" : "About"
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject var store: AppStore
    @State private var localPage: PreferencesPage
    private let selection: Binding<PreferencesPage>?
    private let showsSidebar: Bool
    private var page: PreferencesPage {
        get { selection?.wrappedValue ?? localPage }
        nonmutating set { if let selection { selection.wrappedValue = newValue } else { localPage = newValue } }
    }
    @State private var draft = Preferences()
    @State private var scrollbackValid = true
    @State private var fontSizeValid = true
    @State private var fontSizeInput = "19"
    @State private var timeoutValid = true
    @State private var historyValid = true
    @State private var error = ""
    @State private var loaded = false
    @State private var draftRevision = 0
    @State private var colorCommitSnapshot: Preferences?
    init(page: PreferencesPage = .general, selection: Binding<PreferencesPage>? = nil, showsSidebar: Bool = true) {
        _localPage = State(initialValue: page); self.selection = selection; self.showsSidebar = showsSidebar
    }
    private var dirty: Bool { draft != store.workspace.preferences || !scrollbackValid || !fontSizeValid || !timeoutValid || !historyValid }
    private var validNumbers: Bool { scrollbackValid && fontSizeValid && timeoutValid && historyValid }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar
                    Rectangle().fill(Palette.border).frame(width: 1)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            PaneHeading(title: page.title(chinese: store.chinese), subtitle: subtitle).id("axon-preferences-heading")
                            pageContent(scrollToSection: { proxy.scrollTo($0, anchor: .top) }).id(draftRevision)
                        }.padding(24).frame(maxWidth: page == .appearance ? .infinity : 840, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.background(Palette.background)
                        .onChange(of: page) { _, _ in proxy.scrollTo("axon-preferences-heading", anchor: .top) }
                }
            }
            if page != .ai {
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 12) {
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                else { Text(!validNumbers ? store.text("Enter a valid value to apply changes", "请输入有效值后自动应用") : store.text("Changes apply automatically", "修改后自动保存并生效")).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer(minLength: 8)
                if !error.isEmpty {
                    Button(store.text("Retry", "重试"), action: save).buttonStyle(ChromeButtonStyle())
                }
            }.padding(.horizontal, 20).padding(.vertical, 14).background(Palette.sidebar)
            }
        }.foregroundStyle(Palette.text).font(.system(size: 13)).frame(minWidth: 650, minHeight: 520)
            .onAppear { if !loaded { reload(); loaded = true } }
            .onReceive(NotificationCenter.default.publisher(for: .axonSaveSettingsShortcut)) { notification in
                if notification.object as? AppStore === store, dirty, validNumbers, ShortcutBinding.validationIssue(draft, chinese: store.chinese) == nil { save() }
            }
            .onChange(of: draft) { _, _ in applyAutomatically() }
            .onChange(of: validNumbers) { _, valid in if valid { applyAutomatically() } }
            .onChange(of: store.workspace.preferences) { _, value in
                if colorCommitSnapshot == value || (try? PreferencesValidation.validated(draft, chinese: store.chinese)) == value { colorCommitSnapshot = nil }
                else if error.isEmpty { reload() }
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Axon").font(.system(size: 20, weight: .semibold)).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 16)
            ForEach(PreferencesPage.allCases) { item in
                PreferencesNavigationButton(title: item.title(chinese: store.chinese), symbol: item.icon, selected: page == item, identifier: "axon-preferences-page-" + item.rawValue) { page = item }
                    .frame(height: 42)
            }
            Spacer()
        }.padding(.horizontal, 10).frame(width: 168).frame(maxHeight: .infinity).background(Palette.sidebar)
    }
    private var subtitle: String {
        switch page {
        case .ai: return store.text("Configure Claude, ChatGPT API or local Codex CLI.", "配置 Claude、ChatGPT 接口或本机 Codex CLI。")
        case .keywords: return store.text("Configurable terminal text highlighting.", "可配置的终端关键词高亮。")
        case .general: return store.text("Application icon, language and local terminal startup.", "程序图标、语言与本地终端启动方式。")
        case .terminal: return store.text("Font, history and cursor behavior.", "字体、历史回滚与光标行为。")
        case .appearance: return store.text("Choose a scheme or create your own complete terminal palette.", "选择主题方案，或创建自己的完整终端配色。")
        case .keyboard: return store.text("Tune shortcuts, mouse input and pasted commands.", "调整按键、鼠标与命令粘贴方式。")
        case .connection: return store.text("Timeout for new SSH and SFTP connections.", "新 SSH 与 SFTP 连接的超时设置。")
        case .importHosts: return store.text("Import SSH profiles, export hosts or back up your workspace.", "导入 SSH 配置、导出主机或备份工作区。")
        case .storage: return store.text("Encrypted backups in iCloud Drive or S3-compatible storage.", "将加密备份保存到 iCloud Drive 或 S3 兼容存储。")
        case .shortcuts: return store.text("Keyboard shortcuts for windows, sessions and terminals.", "窗口、会话与终端的快捷操作。")
        case .about: return store.text("Application version and component information.", "应用版本与组件信息。")
        }
    }
    @ViewBuilder private func pageContent(scrollToSection: @escaping (String) -> Void) -> some View {
        switch page {
        case .ai: AISettingsPane(ai: store.ai)
        case .keywords: KeywordRulesPane(draft: $draft)
        case .general: general
        case .terminal: terminal
        case .appearance: TerminalColorPreferencesView(draft: $draft, chinese: store.chinese, scrollToSection: scrollToSection, commit: saveTerminalColors)
        case .keyboard: keyboard
        case .connection: connection
        case .importHosts: ImportPreferencesPane()
        case .storage: CloudBackupPreferencesPane()
        case .shortcuts: shortcuts
        case .about: about
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(store.text("Application", "应用")) {
                row(store.text("Language", "语言")) { AxonChoiceField(selection: $draft.language, choices: [("auto", store.text("Automatic", "自动")), ("zh-CN", "简体中文"), ("en-US", "English")], placeholder: store.text("Language", "语言"), symbol: "globe", identifier: "axon-language") }
                Text(store.text("Application icon", "程序图标")).foregroundStyle(Palette.muted)
                ApplicationIconPicker(selection: $draft.applicationIcon, chinese: store.chinese)
                note(store.text("Both icons keep the yellow node. The selected application icon and logo apply automatically.", "两款均保留黄色节点；选择后自动应用于程序图标与应用 Logo。"))
            }
            section(store.text("Local terminal", "本地终端")) {
                pathField(store.text("Shell executable", "Shell 程序"), text: $draft.localShell, placeholder: store.text("System default", "使用系统默认"), directory: false)
                pathField(store.text("Starting directory", "启动目录"), text: $draft.localDirectory, placeholder: "~", directory: true)
                Toggle(store.text("Run as a login shell", "作为登录 Shell 启动"), isOn: $draft.localLoginShell).toggleStyle(AxonCheckboxStyle())
                note(store.text("Empty paths use your system shell and home directory. Applies to newly opened local terminals.", "路径留空时使用系统 Shell 与用户主目录；应用于新建本地终端。"))
            }
        }
    }
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 16) {
        TerminalPreferencesPane(draft: $draft, scrollbackValid: $scrollbackValid, fontSizeValid: $fontSizeValid, chinese: store.chinese, fontSizeInput: $fontSizeInput)
        section(store.text("Command history", "命令历史")) {
            row(store.text("Entries to keep", "历史保留数")) {
                IntegerInput(value: $draft.commandHistoryLimit, valid: $historyValid, range: 100...50000, placeholder: "1000", label: store.text("Command history entries", "命令历史保留数")).frame(width: 160)
            }
            note(store.text("Keep 100–50,000 recent commands. Older entries are removed when the limit is reached.", "保留 100–50,000 条最近命令，超出数量时移除最早的记录。"))
            Toggle(store.text("Notify when commands finish after 10 seconds", "命令运行超过 10 秒，完成后通知"), isOn: $draft.commandCompletionNotifications).toggleStyle(AxonCheckboxStyle())
            VStack(alignment: .leading, spacing: 8) {
                Text(store.text("Exclude commands containing", "不记录包含以下内容的命令")).foregroundStyle(Palette.muted)
                TextField(store.text("One term per line", "每行填写一项"), text: $draft.commandHistoryExclusions, axis: .vertical).appInput()
            }
        }
        }
    }
    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(store.text("Keyboard & mouse", "键盘与鼠标")) {
                Toggle(store.text("Use Option as Meta", "将 Option 用作 Meta"), isOn: $draft.optionAsMeta).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Backspace sends Control-H", "退格键发送 Control-H"), isOn: $draft.backspaceControlH).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Allow mouse reporting to terminal apps", "允许终端程序处理鼠标事件"), isOn: $draft.mouseReporting).toggleStyle(AxonCheckboxStyle())
                row(store.text("Terminal bell", "终端铃声")) { AxonChoiceField(selection: $draft.bellStyle, choices: [("none", store.text("Off", "关闭")), ("sound", store.text("Sound", "声音")), ("visual", store.text("Flash", "闪烁")), ("soundAndVisual", store.text("Sound & flash", "声音与闪烁"))], placeholder: store.text("Terminal bell", "终端铃声"), symbol: "bell", identifier: "axon-bell") }
            }
            section(store.text("Clipboard", "剪贴板")) {
                Toggle(store.text("Copy on selection", "选中即复制"), isOn: $draft.copyOnSelect).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Right click to paste", "右键粘贴"), isOn: $draft.rightClickPaste).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Middle click to paste", "中键粘贴"), isOn: $draft.middleClickPaste).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Trim pasted whitespace", "去除粘贴首尾空白"), isOn: $draft.trimPaste).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Confirm multiline paste", "粘贴多行内容前确认"), isOn: $draft.confirmMultilinePaste).toggleStyle(AxonCheckboxStyle())
                note(store.text("Applies to open terminals immediately. Multiline confirmation shows a preview before sending text.", "修改后立即应用到已打开终端；多行粘贴会在发送前展示内容预览。"))
            }
        }
    }
    private var connection: some View {
        section(store.text("SSH & SFTP", "SSH 与 SFTP")) {
            row(store.text("TCP timeout (s)", "TCP 超时（秒）")) { IntegerInput(value: $draft.sshConnectTimeout, valid: $timeoutValid, range: 1...120, placeholder: "30", label: store.text("SSH connection timeout", "SSH 连接超时")) }
            note(store.text("Sets how long a direct TCP connection can take. Saved credentials and jump routes stay in host or group details. Applies on the next connection; existing sessions remain open.", "设置直连 TCP 建立连接的等待时间。登录凭据与跳板机在主机或分组详情中设置；新连接时生效，现有会话保持连接。"))
            note(store.text("SSH authentication has a separate 10-second limit provided by the connection library.", "SSH 认证由连接库单独限制为 10 秒。"))
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Axon") {
                HStack(spacing: 14) { Image(nsImage: ApplicationIconAppearance.image(for: store.workspace.preferences.applicationIcon) ?? NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).accessibilityLabel(store.text("Axon application icon", "Axon 程序图标")); VStack(alignment: .leading, spacing: 5) { Text("Axon " + (Bundle.main.bundleIdentifier == "org.tabby.native" ? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" : "Development")).font(.system(size: 16, weight: .semibold)); Text(store.text("SSH terminal and SFTP workspace for macOS", "macOS SSH 终端与 SFTP 工作区")).font(.system(size: 11)).foregroundStyle(Palette.muted) } }
                Divider()
                row(store.text("Author", "作者")) { Text("fenghlkevin").frame(maxWidth: .infinity, alignment: .leading) }
                note(store.text("Built with SwiftUI for the interface, SwiftTerm for terminal rendering and Citadel for SSH connections.", "界面使用 SwiftUI，终端显示由 SwiftTerm 提供，SSH 连接由 Citadel 提供。"))
            }
        }
    }
    private var shortcuts: some View {
        section(store.text("Keyboard shortcuts", "快捷键")) {
            note(store.text("Click a shortcut, then press a combination containing Command. Escape cancels recording. Valid combinations apply automatically.", "点击快捷键按钮后，按下包含 Command 的组合键；Escape 取消录入，有效组合键自动生效。"))
            ForEach(ShortcutAction.allCases.filter { $0 != .saveSettings }) { action in
                HStack(spacing: 16) {
                    Text(action.title(chinese: store.chinese))
                    Spacer(minLength: 8)
                    ShortcutRecorder(value: Binding(get: { draft.shortcut(action) }, set: { draft.shortcuts[action.rawValue] = $0 }), chinese: store.chinese, identifier: "axon-shortcut-" + action.rawValue).frame(width: 156, height: 38)
                }
            }
            if let issue = ShortcutBinding.validationIssue(draft, chinese: store.chinese) { Text(issue).font(.system(size: 11)).foregroundStyle(Palette.danger) }
            Button(store.text("Restore default shortcuts", "恢复默认快捷键")) { draft.shortcuts = [:] }.buttonStyle(ChromeButtonStyle()).disabled(draft.shortcuts.isEmpty)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 16) { Text(title).font(.system(size: 14, weight: .semibold)); content() }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12)) }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { HStack(alignment: .center, spacing: 14) { Text(title).foregroundStyle(Palette.muted).frame(width: 112, alignment: .leading); content().frame(maxWidth: .infinity, alignment: .trailing) } }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
    private func shortcut(_ title: String, _ keys: String) -> some View { HStack { Text(title).foregroundStyle(Palette.muted); Spacer(); Text(keys).font(.system(size: 12, weight: .medium, design: .monospaced)) } }
    private func pathField(_ title: String, text: Binding<String>, placeholder: String, directory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(Palette.muted)
            HStack { TextField(placeholder, text: text).appInput(); Button(store.text("Browse…", "选择…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path } }.buttonStyle(ChromeButtonStyle()) }
        }
    }
    private func colorRow(_ title: String, value: Binding<String>) -> some View {
        row(title) {
            HStack(spacing: 10) {
                TextField("#RRGGBB", text: value).appInput().font(.system(size: 12, design: .monospaced))
                ColorPicker(title, selection: Binding(get: { Color(hex: value.wrappedValue) }, set: { color in
                    if let rgb = NSColor(color).usingColorSpace(.deviceRGB) { value.wrappedValue = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())) }
                }), supportsOpacity: false).labelsHidden()
            }
        }
    }
    private func reload() { draft = store.workspace.preferences; fontSizeInput = TerminalFontSizeNativeEditor.display(draft.fontSize); scrollbackValid = true; fontSizeValid = true; timeoutValid = true; historyValid = true; error = ""; draftRevision += 1 }
    private func saveTerminalColors(_ value: Preferences) throws {
        try store.commitTerminalColors(value)
        colorCommitSnapshot = store.workspace.preferences
        draft = draft.replacingTerminalColors(from: store.workspace.preferences)
        error = ""
    }
    private func applyAutomatically() {
        guard loaded else { return }
        guard dirty else { error = ""; return }
        save()
    }
    private func save() {
        guard validNumbers else { return }
        do {
            let value = try PreferencesValidation.validated(draft, chinese: store.chinese)
            guard value != store.workspace.preferences else { error = ""; return }
            colorCommitSnapshot = value
            try store.commitPreferences(value)
            error = ""
        }
        catch { self.error = error.localizedDescription }
    }
}

/// A native action keeps keyboard and accessibility activation consistent in
/// this settings window, including when the color well has keyboard focus.
struct PreferencesRestoreThemeButton: NSViewRepresentable {
    let title: String
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesThemeResetNativeButton {
        let button = PreferencesThemeResetNativeButton()
        button.setButtonType(.momentaryPushIn); button.isBordered = false
        button.font = .systemFont(ofSize: 12); button.identifier = NSUserInterfaceItemIdentifier("axon-preferences-restore-theme")
        return button
    }
    func updateNSView(_ button: PreferencesThemeResetNativeButton, context: Context) { button.title = title; button.actionBlock = action; button.setAccessibilityLabel(title) }
}
final class PreferencesThemeResetNativeButton: PreferencesRectNativeButton {}
