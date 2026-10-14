import AppKit
import SwiftUI
import SwiftTerm

/// The font picker and size editor use AppKit controls so the full visible
/// field, label and button padding participate in native hit testing.
struct TerminalPreferencesPane: View {
    @Binding var draft: Preferences
    @Binding var scrollbackValid: Bool
    @Binding var fontSizeValid: Bool
    let chinese: Bool
    var fontSizeInput: Binding<String>? = nil
    private func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            card(text("Font & preview", "字体与预览")) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(text("Font family", "字体")).foregroundStyle(Palette.muted)
                    TerminalFontPicker(selection: $draft.fontName, chinese: chinese).frame(height: 38)
                    note(text("Choose an installed monospaced font. The menu previews each font's letter shapes.", "选择本机已安装的等宽字体，菜单会展示每种字体的字形。"))
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text("Font size", "字号"))
                        note(text("Type a size, or use − / + · 10–40 pt", "直接输入，或点击 − / + · 10–40 pt"))
                    }
                    Spacer(minLength: 4)
                    TerminalFontSizeEditor(value: $draft.fontSize, valid: $fontSizeValid, chinese: chinese, input: fontSizeInput).frame(width: 180, height: 42)
                }
                if !fontSizeValid {
                    Text(text("Enter a size from 10 to 40 to apply it.", "请输入 10–40 的有效字号后自动应用。"))
                        .font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(text("Live preview", "实时预览")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(draft.fontName + " · " + TerminalFontSizeNativeEditor.display(draft.fontSize) + " pt")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    TerminalPreferencesPreview(preferences: draft, chinese: chinese).frame(height: 166)
                        .padding(12).background(Color(hex: draft.background))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                note(text("Font, size and cursor changes appear here immediately. Changes apply automatically to open terminals and new sessions.", "字体、字号与光标会立即显示在预览中。修改后自动应用到所有已打开终端及新会话。"))
            }
            card(text("History & cursor", "历史与光标")) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(text("Scrollback lines", "回滚行数")).foregroundStyle(Palette.muted)
                    IntegerInput(value: $draft.scrollback, valid: $scrollbackValid, range: 0...1_000_000,
                                 placeholder: "250000", label: text("Scrollback lines", "回滚行数"))
                    note(text("0 keeps only the current screen. Reducing the limit discards the oldest history when applied.", "0 表示仅保留当前屏幕；减小行数后，超出范围的旧历史会被丢弃。"))
                }
                Text(text("Cursor shape", "光标形状")).foregroundStyle(Palette.muted)
                HStack(spacing: 8) {
                    cursor("block", text("▊  Block", "▊  方块"))
                    cursor("bar", text("│  Bar", "│  竖线"))
                    cursor("underline", text("▁  Underline", "▁  下划线"))
                }
                TerminalCursorBlinkButton(selection: $draft.cursorBlink, title: text("Blink cursor", "光标闪烁")).frame(height: 40)
                note(text("The preview above follows the cursor shape and blinking immediately. Changes apply automatically to terminals; programs can request their own style.", "上方预览会实时显示光标形状与闪烁。修改后自动应用到终端；终端内程序仍可指定自己的光标样式。"))
            }
        }
    }
    private func cursor(_ shape: String, _ title: String) -> some View {
        TerminalCursorShapeButton(title: title, selected: draft.cursorShape == shape, identifier: "axon-terminal-cursor-" + shape) { draft.cursorShape = shape }
            .frame(maxWidth: .infinity).frame(height: 40)
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { Text(title).font(.system(size: 14, weight: .semibold)); content() }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func note(_ value: String) -> some View {
        Text(value).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}

enum TerminalFontCatalog {
    @MainActor static func names(including selected: String) -> [String] {
        let manager = NSFontManager.shared
        var names = manager.availableFonts.filter { name in
            guard let font = NSFont(name: name, size: 14), font.isFixedPitch else { return false }
            let traits = manager.traits(of: font)
            return !traits.contains(.boldFontMask) && !traits.contains(.italicFontMask)
        }
        // An existing installed font remains selectable even if a legacy profile
        // chose a proportional font. Merely opening settings must not change it.
        if NSFont(name: selected, size: 14) != nil { names.append(selected) }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct TerminalFontPicker: View {
    @Binding var selection: String
    let chinese: Bool
    var body: some View {
        NativeSelectionField(title: selection, symbol: "textformat", label: chinese ? "选择终端字体" : "Choose terminal font", identifier: "axon-terminal-font-picker") { button in
            AxonMenuPopover.show(makeMenu(width: button.bounds.width), from: button)
        }
    }
    @MainActor func makeMenu(width: CGFloat = 280) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.minimumWidth = width
        for name in TerminalFontCatalog.names(including: selection) {
            let item = NSMenuItem(title: name, action: #selector(SelectionMenuAction.selectGroup(_:)), keyEquivalent: "")
            let target = SelectionMenuAction { selection = name }
            item.target = target; item.representedObject = target; item.state = selection == name ? .on : .off
            if let font = NSFont(name: name, size: 13) { item.attributedTitle = NSAttributedString(string: name, attributes: [.font: font]) }
            menu.addItem(item)
        }
        return menu
    }
}

struct TerminalFontSizeEditor: NSViewRepresentable {
    @Binding var value: Double
    @Binding var valid: Bool
    let chinese: Bool
    var input: Binding<String>? = nil
    func makeNSView(context: Context) -> TerminalFontSizeNativeEditor { TerminalFontSizeNativeEditor() }
    func updateNSView(_ view: TerminalFontSizeNativeEditor, context: Context) {
        view.onChange = { value = $0 }; view.onValidity = { valid = $0 }; view.onInput = { input?.wrappedValue = $0 }
        view.configure(value: value, chinese: chinese, input: input?.wrappedValue, inputValid: valid)
    }
}

final class TerminalFontSizeNativeEditor: NSView, NSTextFieldDelegate {
    let decrease = PreferencesRectNativeButton()
    let increase = PreferencesRectNativeButton()
    let field = NSTextField()
    private(set) var value: Double = 19
    private(set) var valid = true
    var onChange: ((Double) -> Void)?
    var onValidity: ((Bool) -> Void)?
    var onInput: ((String) -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 42) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("axon-terminal-font-size-editor")
        decrease.title = "−"; increase.title = "+"
        decrease.identifier = NSUserInterfaceItemIdentifier("axon-terminal-font-size-decrease")
        increase.identifier = NSUserInterfaceItemIdentifier("axon-terminal-font-size-increase")
        decrease.actionBlock = { [weak self] in self?.step(-1) }
        increase.actionBlock = { [weak self] in self?.step(1) }
        field.identifier = NSUserInterfaceItemIdentifier("axon-terminal-font-size")
        field.cell = TerminalSizeTextFieldCell(textCell: "19")
        field.font = .systemFont(ofSize: 14, weight: .medium); field.alignment = .center
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.delegate = self
        field.stringValue = "19"
        [decrease, field, increase].forEach(addSubview)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        decrease.frame = NSRect(x: 0, y: 0, width: 42, height: bounds.height)
        field.frame = NSRect(x: 48, y: 1, width: max(20, bounds.width - 96), height: max(0, bounds.height - 2))
        increase.frame = NSRect(x: bounds.width - 42, y: 0, width: 42, height: bounds.height)
    }
    func configure(value incoming: Double, chinese: Bool, input: String? = nil, inputValid: Bool = true) {
        if incoming.isFinite, (10...40).contains(incoming), incoming != value {
            value = incoming; field.stringValue = Self.display(incoming); setValid(true)
        }
        if let input {
            field.stringValue = input
            valid = inputValid
        }
        field.setAccessibilityLabel(chinese ? "终端字号，10 至 40 点" : "Terminal font size, 10 to 40 points")
        decrease.setAccessibilityLabel(chinese ? "减小终端字号" : "Decrease terminal font size")
        increase.setAccessibilityLabel(chinese ? "增大终端字号" : "Increase terminal font size")
        updateEnabled(); needsDisplay = true
    }
    static func display(_ value: Double) -> String { value.isFinite ? (value == value.rounded() ? String(Int(value)) : String(value)) : "19" }
    static func parsed(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let number = Double(trimmed), number.isFinite, (10...40).contains(number) else { return nil }
        return number
    }
    func controlTextDidChange(_ notification: Notification) {
        onInput?(field.stringValue)
        guard let number = Self.parsed(field.stringValue) else { setValid(false); return }
        value = number; setValid(true); updateEnabled(); onChange?(number)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if valid { field.stringValue = Self.display(value); onInput?(field.stringValue) }
    }
    private func step(_ delta: Double) {
        value = min(40, max(10, value + delta)); field.stringValue = Self.display(value)
        if let editor = field.currentEditor() { editor.string = field.stringValue }
        setValid(true); updateEnabled(); onInput?(field.stringValue); onChange?(value)
    }
    private func updateEnabled() { decrease.isEnabled = value > 10 || !valid; increase.isEnabled = value < 40 || !valid }
    private func setValid(_ newValue: Bool) {
        if valid != newValue { valid = newValue; onValidity?(newValue) }
        field.setAccessibilityHelp(newValue ? nil : "10–40 pt")
        needsDisplay = true; updateEnabled()
    }
    override func draw(_ dirtyRect: NSRect) {
        let area = NSRect(x: 47, y: 0.5, width: max(0, bounds.width - 94), height: max(0, bounds.height - 1))
        NSColor(Palette.field).setFill(); let outline = NSBezierPath(roundedRect: area, xRadius: 7, yRadius: 7); outline.fill()
        (valid ? NSColor(Palette.border) : NSColor.systemRed).setStroke(); outline.lineWidth = valid ? 1 : 2; outline.stroke()
    }
}

final class TerminalSizeTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let original = super.drawingRect(forBounds: rect)
        let height = min(original.height, ceil((font?.ascender ?? 14) - (font?.descender ?? -3) + 3))
        return NSRect(x: original.minX, y: rect.minY + (rect.height - height) / 2, width: original.width, height: height)
    }
}

struct TerminalCursorShapeButton: NSViewRepresentable {
    let title: String
    let selected: Bool
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesRectNativeButton { AxonChoiceCardNativeButton() }
    func updateNSView(_ button: PreferencesRectNativeButton, context: Context) {
        button.title = title; button.selected = selected; button.prominent = selected; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityLabel(title)
        button.setAccessibilityValue(selected ? "Selected" : ""); button.needsDisplay = true
    }
}

struct TerminalCursorBlinkButton: NSViewRepresentable {
    @Binding var selection: Bool
    let title: String
    func makeNSView(context: Context) -> TerminalCursorBlinkNativeButton { TerminalCursorBlinkNativeButton() }
    func updateNSView(_ button: TerminalCursorBlinkNativeButton, context: Context) {
        button.title = title; button.selected = selection; button.actionBlock = { selection.toggle() }
        button.identifier = NSUserInterfaceItemIdentifier("axon-terminal-cursor-blink"); button.setAccessibilityLabel(title)
        button.setAccessibilityRole(.checkBox); button.setAccessibilityValue(selection ? 1 : 0); button.needsDisplay = true
    }
}

final class TerminalCursorBlinkNativeButton: PreferencesRectNativeButton {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(selected || hovering || isHighlighted ? Palette.selected : Palette.sidebar).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        AxonSelectionDrawing.mark(in: NSRect(x: 12, y: (bounds.height - 14) / 2, width: 14, height: 14), selected: selected, enabled: isEnabled)
        drawText(title, rect: NSRect(x: 38, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 50), height: 17), color: NSColor(Palette.text), font: .systemFont(ofSize: 12))
        drawFocus()
    }
}

enum TerminalPreviewSample: Equatable {
    case font, palette, paletteExtended
}

/// A real SwiftTerm renderer, shared by font/cursor and color settings. It has
/// no shell, SSH client, or outgoing delegate and cannot capture input.
struct TerminalPreferencesPreview: NSViewRepresentable {
    let preferences: Preferences
    var sample: TerminalPreviewSample = .font
    var identifier = "axon-terminal-font-preview"
    var chinese = false
    func makeNSView(context: Context) -> TerminalPreferencesPreviewNativeView {
        let view = TerminalPreferencesPreviewNativeView(frame: NSRect(x: 0, y: 0, width: 400, height: 166), options: .init(cols: 40, rows: 6, scrollback: 0))
        try? view.setUseMetal(false)
        // A preview must show the selected cursor, even while the user's focus
        // stays in a text field or on one of the settings controls.
        view.caretViewTracksFocus = false
        return view
    }
    func updateNSView(_ view: TerminalPreferencesPreviewNativeView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.configure(preferences: preferences, sample: sample)
        let shape: String
        switch preferences.cursorShape {
        case "bar": shape = chinese ? "竖线光标" : "bar cursor"
        case "underline": shape = chinese ? "下划线光标" : "underline cursor"
        default: shape = chinese ? "方块光标" : "block cursor"
        }
        view.setAccessibilityLabel((chinese ? "终端实时预览，" : "Live terminal preview, ") + shape + (preferences.cursorBlink ? (chinese ? "闪烁" : ", blinking") : (chinese ? "不闪烁" : ", steady")))
    }
}

final class TerminalPreferencesPreviewNativeView: TerminalView {
    private var sample = TerminalPreviewSample.font
    private var applied: Preferences?
    func configure(preferences: Preferences, sample: TerminalPreviewSample) {
        var preview = preferences; preview.scrollback = 0
        if sample == .palette { preview.fontSize = min(14, preferences.fontSize) }
        guard applied != preview || self.sample != sample else { return }
        applied = preview; self.sample = sample
        caretViewTracksFocus = false
        TerminalAppearance.apply(preview, to: self)
        renderSample()
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if size.width > 0 && size.height > 0 { renderSample() }
    }
    func renderSample() {
        let reset = "\u{1B}[0m\u{1B}[2J\u{1B}[H"
        switch sample {
        case .font:
            feed(text: reset + "axon@server ~ %\r\n\u{1B}[32mREADME.md\u{1B}[0m  \u{1B}[34msrc\u{1B}[0m\r\n0123456789 AaBbCc")
        case .palette:
            let normal = (0..<8).map { "\u{1B}[\(40 + $0)m  \u{1B}[0m " }.joined()
            let bright = (0..<8).map { "\u{1B}[\(100 + $0)m  \u{1B}[0m " }.joined()
            feed(text: reset + "axon@server ~ % ls\r\n\u{1B}[32mREADME.md\u{1B}[0m  \u{1B}[34msrc\u{1B}[0m\r\n\u{1B}[31merror\u{1B}[0m \u{1B}[33mwarning\u{1B}[0m \u{1B}[36minfo\u{1B}[0m\r\n" + normal + "\r\n" + bright + "\r\n$ ")
        case .paletteExtended:
            feed(text: reset + extendedPaletteSample())
        }
        needsDisplay = true
    }
    private func extendedPaletteSample() -> String {
        let dimensions = terminalStateSnapshot().dimensions
        let columns = max(2, dimensions.cols)
        let rows = max(1, dimensions.rows)
        // Limit visible characters before adding SGR sequences, so resizing or
        // choosing a large font cannot wrap samples off the preview canvas.
        func line(_ parts: [(String, Int?)]) -> String {
            var remaining = columns - 1
            return parts.map { text, color in
                let visible = String(text.prefix(max(0, remaining)))
                remaining -= visible.count
                guard let color else { return visible }
                return "\u{1B}[\(color)m" + visible + "\u{1B}[0m"
            }.joined()
        }
        func swatches(bright: Bool) -> String {
            let width = max(1, min(4, (columns - 1) / 8))
            return (0..<8).map { "\u{1B}[\((bright ? 100 : 40) + $0)m" + String(repeating: " ", count: width) + "\u{1B}[0m" }.joined()
        }
        var lines: [String] = []
        if rows >= 2 {
            let command = columns >= 34 ? "axon@server ~/workspace % ls -lah" : columns >= 24 ? "axon@server ~ % ls -lah" : "$ ls -lah"
            lines.append(line([(command, nil)]))
        }
        if rows >= 10 {
            let directoryInfo = columns >= 64 ? "drwxr-xr-x  4 axon staff  128B  " : "128B  "
            let fileInfo = columns >= 64 ? "-rw-r--r--  1 axon staff  2.4K  " : "2.4K  "
            lines.append(line([(directoryInfo, nil), ("src/", 34), ("  tests/", 36)]))
            lines.append(line([(fileInfo, nil), ("README.md", 32), ("  package.json", nil)]))
        } else if rows >= 4 {
            lines.append(line([("README.md", 32), ("  src/", 34), ("  build/", 36)]))
        }
        if rows >= 13 { lines.append(line([("$ ./deploy.sh --check", nil)])) }
        if rows >= 9 {
            lines.append(line([("[INFO] ", 36), ("SSH connected; configuration loaded", nil)]))
            lines.append(line([("[WARN] ", 33), ("Using a cached configuration", nil)]))
            lines.append(line([("[ERROR] ", 31), ("Example: permission denied", nil)]))
        } else if rows >= 3 {
            lines.append(line([("info", 36), ("  warning", 33), ("  error", 31)]))
        }
        if rows >= 12 {
            lines.append(line([("$ git diff -- app.swift", nil)]))
            lines.append(line([("- let theme = previous", 31)]))
            lines.append(line([("+ let theme = selected", 32)]))
        } else if rows >= 7 {
            lines.append(line([("- previous", 31), ("  + selected", 32)]))
        }
        if rows >= 6, columns >= 9 {
            lines.append(swatches(bright: false))
            lines.append(swatches(bright: true))
        }
        let prompt = columns >= 28 ? "axon@server ~/workspace % " : columns >= 18 ? "axon@server ~ % " : "$ "
        lines.append(line([(prompt, nil)]))
        return lines.joined(separator: "\r\n")
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var canBecomeKeyView: Bool { false }
}
