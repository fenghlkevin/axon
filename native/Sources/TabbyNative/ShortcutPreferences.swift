import SwiftUI
import AppKit

enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTab, search, localTerminal, split, find, closeSession, settings, saveSettings, fontIncrease, fontDecrease, fontReset
    var id: String { rawValue }
    func title(chinese: Bool) -> String {
        let labels: [Self: (String, String)] = [.fontIncrease: ("Increase terminal font", "放大终端字号"), .fontDecrease: ("Decrease terminal font", "缩小终端字号"), .fontReset: ("Reset terminal font", "恢复终端字号"), .newTab: ("New tab", "新标签"), .search: ("Search hosts or tabs", "搜索主机或标签"), .localTerminal: ("Local terminal", "本地终端"), .split: ("Split terminal", "终端分屏"), .find: ("Find in terminal", "搜索终端"), .closeSession: ("Close session", "关闭会话"), .settings: ("Settings", "设置"), .saveSettings: ("Save settings", "保存设置")]
        return chinese ? labels[self]!.1 : labels[self]!.0
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .fontIncrease: return .init(key: "=")
        case .fontDecrease: return .init(key: "-")
        case .fontReset: return .init(key: "0")
        case .newTab: return .init(key: "t")
        case .search: return .init(key: "k")
        case .localTerminal: return .init(key: "t", shift: true)
        case .split: return .init(key: "d")
        case .find: return .init(key: "f")
        case .closeSession: return .init(key: "w", shift: true)
        case .settings: return .init(key: ",")
        case .saveSettings: return .init(key: "\r")
        }
    }
}
struct ShortcutBinding: Codable, Equatable, Hashable {
    var key: String
    var shift = false
    var option = false
    var control = false
    var modifiers: EventModifiers {
        var result: EventModifiers = .command
        if shift { result.insert(.shift) }; if option { result.insert(.option) }; if control { result.insert(.control) }
        return result
    }
    var keyEquivalent: KeyEquivalent { key == "\r" ? .return : KeyEquivalent(key.first ?? "t") }
    var display: String { (control ? "⌃ " : "") + (option ? "⌥ " : "") + (shift ? "⇧ " : "") + "⌘ " + (key == "\r" ? "↩" : key.uppercased()) }
    var valid: Bool {
        guard key == key.lowercased(), key == "\r" || key.count == 1 && key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return false }
        // Keep standard editing, window and application commands available.
        if !option && !control && !shift && ["q", "w", "h", "m", "a", "c", "v", "x", "z"].contains(key) { return false }
        return !(key == "q" && shift && !option && !control)
    }
    static func from(_ event: NSEvent) -> Self? {
        guard event.modifierFlags.contains(.command), let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)?.lowercased(), chars.count == 1 else { return nil }
        let value = Self(key: chars, shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option), control: event.modifierFlags.contains(.control))
        return value.valid ? value : nil
    }
    static func validationIssue(_ preferences: Preferences, chinese: Bool) -> String? {
        var seen = Set<Self>()
        for action in ShortcutAction.allCases where action != .saveSettings {
            let value = preferences.shortcut(action)
            if !value.valid { return chinese ? "请使用有效组合键，并避开系统常用快捷键。" : "Use a valid combination that leaves standard system shortcuts available." }
            if !seen.insert(value).inserted { return chinese ? "快捷键重复，请为每个操作设置不同的组合键。" : "Shortcuts conflict. Choose a different combination for each action." }
        }
        return nil
    }
}
extension Preferences {
    func shortcut(_ action: ShortcutAction) -> ShortcutBinding { shortcuts[action.rawValue] ?? action.defaultBinding }
}
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: ShortcutBinding
    let chinese: Bool
    let identifier: String
    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton() }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.value = value; button.chinese = chinese; button.didRecord = { value = $0 }
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        if !button.recording { button.title = value.display }
        button.setAccessibilityLabel(chinese ? "修改快捷键 " + value.display : "Edit shortcut " + value.display)
        button.needsDisplay = true
    }
    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.finish() }
}
final class ShortcutRecorderButton: PreferencesRectNativeButton {
    var value = ShortcutBinding(key: "t")
    var chinese = false
    var didRecord: ((ShortcutBinding) -> Void)?
    private(set) var recording = false
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override init() { super.init(); actionBlock = { [weak self] in self?.begin() } }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin() {
        finish(); guard let window else { return }
        guard window.makeFirstResponder(self) else { return }; recording = true; selected = true
        title = chinese ? "按下组合键…" : "Press shortcut…"; needsDisplay = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.window === self.window || event.window == nil && NSApp.keyWindow === self.window else { return event }
            self.receive(event); return nil
        }
    }
    func receive(_ event: NSEvent) {
        if event.keyCode == 53 { finish(); return }
        if event.keyCode == 48 { finish(); if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }; return }
        guard let binding = ShortcutBinding.from(event) else {
            if !event.modifierFlags.contains(.command) { title = chinese ? "需包含 ⌘ 键" : "Include Command" }
            else { title = chinese ? "此组合键不可用" : "Shortcut unavailable" }
            toolTip = chinese ? "使用 Command 加字母、数字或符号；系统编辑、退出和窗口快捷键保留。" : "Use Command with a letter, number or symbol. Standard editing, quit and window shortcuts are reserved."
            needsDisplay = true; return
        }
        value = binding; finish(); didRecord?(binding)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { receive(event); return true }
        return super.performKeyEquivalent(with: event)
    }
    func finish() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false; selected = false; toolTip = nil; title = value.display; needsDisplay = true
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { finish() } }
}

/// Resolves bindings at key-down time, before terminal input or menu equivalents.
@MainActor final class ApplicationShortcutDispatcher {
    private var monitor: Any?
    private let resolveStore: (NSWindow) -> AppStore?
    init(resolveStore: @escaping (NSWindow) -> AppStore?) { self.resolveStore = resolveStore }
    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window = event.window ?? NSApp.keyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              (window.firstResponder as? ShortcutRecorderButton)?.recording != true,
              let store = resolveStore(window), let binding = ShortcutBinding.from(event),
              let action = ShortcutAction.allCases.first(where: { $0 != .saveSettings && store.workspace.preferences.shortcut($0) == binding }) else { return false }
        if event.isARepeat { return true }
        switch action {
        case .fontIncrease, .fontDecrease, .fontReset:
            guard let session = store.fontAdjustmentSession else { return false }
            if action == .fontReset { session.setFontSize(nil) }
            else { session.adjustFontSize(action == .fontIncrease ? 1 : -1) }
        case .newTab, .search: store.openLauncher()
        case .localTerminal: store.connect()
        case .split: store.split()
        case .settings: store.openPreferences()
        case .saveSettings:
            guard store.section == "settings" else { return false }
            NotificationCenter.default.post(name: .axonSaveSettingsShortcut, object: store)
        case .find:
            guard let session = store.sessions.first(where: { $0.id == store.activeSession }) else { return false }
            store.showTerminalSection()
            let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            session.terminal?.performFindPanelAction(item)
        case .closeSession:
            if store.sceneWindowID != nil, store.section == "scene" { SceneWindowController.closeFocused() }
            else if store.section == "scene", let id = store.activeSceneID { store.closeScene(id) }
            else if store.section == "logviewer", let id = store.activeLogViewer { store.closeLogViewer(id) }
            else if let id = store.activeSession { store.closeTerminalTab(id) }
        }
        return true
    }
}
extension Notification.Name {
    static let axonSaveSettingsShortcut = Notification.Name("axonSaveSettingsShortcut")
}
