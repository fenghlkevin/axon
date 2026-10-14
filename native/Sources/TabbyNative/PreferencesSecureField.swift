import AppKit
import SwiftUI

/// A single native editor publishes every edit, including clearing the field.
/// Revealing a value replaces and clears the old editor rather than retaining a
/// second, potentially stale copy of a secret in a hidden text field.
struct PreferencesSecureField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    var identifier = ""
    var chinese = false
    var focusOnAppear = false
    var onSubmit: (() -> Void)? = nil
    @Environment(\.isEnabled) private var environmentEnabled

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }
    func makeNSView(context: Context) -> PasswordInputView { PasswordInputView() }
    func updateNSView(_ view: PasswordInputView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        view.configure(value: text, title: title, identifier: identifier, chinese: chinese,
                       enabled: environmentEnabled, focusRequested: focusOnAppear, delegate: context.coordinator)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PasswordInputView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 28)
    }
    static func dismantleNSView(_ view: PasswordInputView, coordinator: Coordinator) {
        view.clearSensitiveText()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        init(text: Binding<String>, onSubmit: (() -> Void)? = nil) { self.text = text; self.onSubmit = onSubmit }
        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            configureEditor(fieldEditor as? NSTextView)
            return true
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            configureEditor(field.currentEditor() as? NSTextView)
        }
        private func configureEditor(_ editor: NSTextView?) { configureLiteralPasswordEditor(editor) }
        func controlTextDidChange(_ notification: Notification) { publish(notification) }
        func controlTextDidEndEditing(_ notification: Notification) {
            publish(notification)
            if (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue == NSReturnTextMovement { onSubmit?() }
        }
        private func publish(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}

final class PasswordInputView: NSView {
    private(set) var activeField: NSTextField = NSSecureTextField()
    let visibilityButton = PasswordVisibilityButton()
    private(set) var isRevealed = false
    private var title = ""
    private var fieldIdentifier = ""
    private var chinese = false
    private var enabled = true
    private var focusRequested = false
    private var pendingFocus = false
    private weak var fieldDelegate: NSTextFieldDelegate?
    private weak var observedWindow: NSWindow?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)
        activeField.cell = PasswordSecureTextFieldCell(textCell: "")
        setAccessibilityElement(false)
        addSubview(activeField)
        addSubview(visibilityButton)
        visibilityButton.onPress = { [weak self] in self?.toggleVisibility() }
        configureField()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(value: String, title: String, identifier: String, chinese: Bool,
                   enabled: Bool, focusRequested: Bool, delegate: NSTextFieldDelegate) {
        self.title = title; fieldIdentifier = identifier; self.chinese = chinese; fieldDelegate = delegate
        // End editing before disabling so the latest keystroke is committed.
        if self.enabled && !enabled, activeField.currentEditor() != nil { window?.makeFirstResponder(nil) }
        self.enabled = enabled
        if !enabled && isRevealed { setRevealed(false, restoringFocus: false) }
        configureField()
        if activeField.stringValue != value { activeField.stringValue = value }
        if focusRequested && !self.focusRequested { pendingFocus = true }
        self.focusRequested = focusRequested
        requestInitialFocusIfNeeded()
    }
    override func layout() {
        super.layout()
        let buttonWidth: CGFloat = 28
        let fieldHeight = max(18, activeField.intrinsicContentSize.height)
        activeField.frame = NSRect(x: 0, y: (bounds.height - fieldHeight) / 2,
                                   width: max(0, bounds.width - buttonWidth - 8), height: fieldHeight)
        visibilityButton.frame = NSRect(x: max(0, bounds.width - buttonWidth), y: (bounds.height - 28) / 2, width: buttonWidth, height: 28)
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled, let window else { return }
        window.makeFirstResponder(activeField)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow { NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow) }
        observedWindow = window
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window) }
        requestInitialFocusIfNeeded()
    }
    @objc private func windowWillClose() { clearSensitiveText() }

    /// Window controllers also call this before closing a modal, so neither a
    /// revealed field nor its field editor waits for a later SwiftUI redraw.
    func clearSensitiveText() {
        let field = activeField
        field.delegate = nil
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = ""
            window?.makeFirstResponder(nil)
        }
        field.stringValue = ""
        if isRevealed { setRevealed(false, restoringFocus: false) }
        activeField.delegate = nil
    }
    private func requestInitialFocusIfNeeded() {
        guard pendingFocus, focusRequested, enabled, window != nil else { return }
        pendingFocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusRequested, self.enabled, let window = self.window else { return }
            window.makeFirstResponder(self.activeField)
        }
    }
    private func configureField() {
        activeField.isBordered = false; activeField.isBezeled = false; activeField.drawsBackground = false
        activeField.focusRingType = .none; activeField.font = .systemFont(ofSize: 13)
        activeField.textColor = NSColor(Palette.text)
        activeField.cell?.usesSingleLineMode = true
        activeField.maximumNumberOfLines = 1
        activeField.isAutomaticTextCompletionEnabled = false
        activeField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        activeField.delegate = fieldDelegate
        activeField.isEnabled = enabled
        activeField.isEditable = true; activeField.isSelectable = true
        activeField.placeholderString = title
        activeField.identifier = NSUserInterfaceItemIdentifier(fieldIdentifier)
        activeField.setAccessibilityLabel(title)
        activeField.setAccessibilityIdentifier(fieldIdentifier)
        activeField.nextKeyView = visibilityButton
        let label = isRevealed ? (chinese ? "隐藏密码" : "Hide password") : (chinese ? "显示密码" : "Show password")
        visibilityButton.isEnabled = enabled
        visibilityButton.image = NSImage(systemSymbolName: isRevealed ? "eye.slash" : "eye", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        visibilityButton.contentTintColor = NSColor(Palette.muted)
        visibilityButton.toolTip = label
        visibilityButton.identifier = NSUserInterfaceItemIdentifier(fieldIdentifier + "-visibility")
        visibilityButton.setAccessibilityIdentifier(fieldIdentifier + "-visibility")
        visibilityButton.setAccessibilityLabel(label)
        visibilityButton.setAccessibilityValue(isRevealed ? (chinese ? "已显示" : "Visible") : (chinese ? "已隐藏" : "Hidden"))
        needsLayout = true
    }
    private func toggleVisibility() {
        guard enabled else { return }
        setRevealed(!isRevealed, restoringFocus: true)
    }
    private func setRevealed(_ revealed: Bool, restoringFocus: Bool) {
        guard revealed != isRevealed else { return }
        let oldField = activeField
        let editor = oldField.currentEditor() as? NSTextView
        let selection = editor?.selectedRange()
        let hadFocus = editor != nil || window?.firstResponder === oldField
        // AppKit commits to the Binding before the native editor is replaced.
        if editor != nil { window?.makeFirstResponder(nil) }
        let value = oldField.stringValue
        oldField.delegate = nil
        editor?.string = ""
        oldField.stringValue = ""
        oldField.removeFromSuperview()
        if revealed {
            let field = NSTextField()
            field.cell = RevealedPasswordTextFieldCell(textCell: "")
            field.isEditable = true; field.isSelectable = true
            activeField = field
        } else {
            activeField = NSSecureTextField()
            activeField.cell = PasswordSecureTextFieldCell(textCell: "")
        }
        isRevealed = revealed
        addSubview(activeField, positioned: .below, relativeTo: visibilityButton)
        configureField()
        activeField.stringValue = value
        layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
        if restoringFocus && hadFocus, let window {
            window.makeFirstResponder(activeField)
            if let selection, let newEditor = activeField.currentEditor() as? NSTextView {
                let count = (value as NSString).length
                let location = min(selection.location, count)
                newEditor.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
            }
        }
    }
}

final class PasswordVisibilityButton: NSButton {
    var onPress: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""; imagePosition = .imageOnly; imageScaling = .scaleNone
        setButtonType(.momentaryChange); isBordered = false; focusRingType = .none
        target = self; action = #selector(activate)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { if isEnabled { onPress?() } }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, onPress != nil else { return false }
        performClick(nil)
        return true
    }
}

/// AppKit configures its shared field editor when focus enters a field, before
/// any editing notifications. Apply literal-input options after that setup;
/// delegate callbacks alone run too late to cover the first typed character.
private final class RevealedPasswordTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        configureLiteralPasswordEditor(editor as? NSTextView)
        return editor
    }
}

private final class PasswordSecureTextFieldCell: NSSecureTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        configureLiteralPasswordEditor(editor as? NSTextView)
        return editor
    }
}

private func configureLiteralPasswordEditor(_ editor: NSTextView?) {
    guard let editor else { return }
    // The shared AppKit editor can retain the terminal's dark appearance.
    // Password inputs always use Axon's light surface and dark insertion point.
    editor.insertionPointColor = NSColor(Palette.text)
    editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false; editor.isAutomaticLinkDetectionEnabled = false
}
