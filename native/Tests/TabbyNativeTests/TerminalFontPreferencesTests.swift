import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

final class TerminalFontPreferencesTests: XCTestCase {
    @MainActor func testInstalledFontMenuContainsFixedPitchFacesAndRetainsLegacySelection() throws {
        _ = NSApplication.shared
        let names = TerminalFontCatalog.names(including: "Menlo")
        XCTAssertTrue(names.contains("Menlo")); XCTAssertEqual(names.count, Set(names).count)
        for name in names { XCTAssertTrue(try XCTUnwrap(NSFont(name: name, size: 14)).isFixedPitch) }
        let legacy = TerminalFontCatalog.names(including: "Helvetica")
        XCTAssertTrue(legacy.contains("Helvetica"), "Opening an old saved configuration must not change its installed font")
        XCTAssertFalse(TerminalFontCatalog.names(including: "font-that-is-not-installed").contains("font-that-is-not-installed"))
        var selected = "Menlo"
        let picker = TerminalFontPicker(selection: Binding(get: { selected }, set: { selected = $0 }), chinese: true)
        let menu = picker.makeMenu()
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Menlo"])
        let alternate = try XCTUnwrap(menu.items.first { $0.title != "Menlo" })
        XCTAssertNotNil(alternate.attributedTitle)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(alternate.action), to: alternate.target, from: alternate))
        XCTAssertEqual(selected, alternate.title)
    }

    @MainActor func testSizeEditorAcceptsTypedValuesRejectsMalformedInputAndUsesLargeHitRegions() async throws {
        _ = NSApplication.shared
        let box = FontDraft(); box.preferences.fontSize = 19
        let hosting = NSHostingView(rootView: SizeFixture(box: box))
        let window = show(hosting, size: NSSize(width: 180, height: 42)); defer { window.close() }
        try await settle(hosting)
        let editor = try XCTUnwrap(find(TerminalFontSizeNativeEditor.self, in: hosting).first)
        XCTAssertEqual(editor.increase.bounds.size, NSSize(width: 42, height: 42))
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 41, y: 41), NSPoint(x: 21, y: 21)] {
            try activate(editor.increase, point: point)
        }
        XCTAssertEqual(box.preferences.fontSize, 22)
        try activate(editor.decrease, point: NSPoint(x: 40, y: 2))
        XCTAssertEqual(box.preferences.fontSize, 21)
        editor.field.stringValue = "24.5"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.field))
        XCTAssertEqual(box.preferences.fontSize, 24.5); XCTAssertTrue(box.sizeValid)
        for text in ["", "9", "41", "19pt", "NaN", "∞", "1e1", "１９", "20..5"] {
            editor.field.stringValue = text
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.field))
            XCTAssertFalse(box.sizeValid, text); XCTAssertEqual(box.preferences.fontSize, 24.5, "Invalid input must not write an old or coerced number")
        }
        try activate(editor.increase, point: NSPoint(x: 20, y: 20))
        XCTAssertTrue(box.sizeValid); XCTAssertEqual(box.preferences.fontSize, 25.5)
        editor.field.stringValue = "40"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.field))
        XCTAssertFalse(editor.increase.isEnabled); XCTAssertTrue(editor.decrease.isEnabled)
        editor.increase.performClick(nil); XCTAssertEqual(box.preferences.fontSize, 40)
        editor.field.stringValue = "10"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.field))
        XCTAssertFalse(editor.decrease.isEnabled); XCTAssertTrue(editor.increase.isEnabled)
        try await settle(hosting)
        let fieldPoint = editor.field.convert(NSPoint(x: editor.field.bounds.midX, y: 2), to: hosting.superview)
        XCTAssertTrue(hosting.hitTest(fieldPoint) === editor.field, "The input's top padding must still activate the editable font size field")
    }

    @MainActor func testFontAndSizeControlsUpdateLocalPreviewAndSaveToExistingTerminal() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-font-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let box = FontDraft(); box.preferences = store.workspace.preferences
        let hosting = NSHostingView(rootView: PaneFixture(box: box).environmentObject(store).preferredColorScheme(.light))
        let window = show(hosting, size: NSSize(width: 600, height: 980)); defer { window.close() }
        try await settle(hosting)
        let picker = try XCTUnwrap(find(SelectionFieldButton.self, in: hosting).first { $0.accessibilityIdentifier() == "axon-terminal-font-picker" })
        var openings = 0; picker.onOpen = { openings += 1 }
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: picker.bounds.width - 1, y: 37), NSPoint(x: 45, y: 20)] { try activate(picker, point: point) }
        XCTAssertEqual(openings, 3, "Text and padding share the font menu's complete native action")
        let menu = TerminalFontPicker(selection: Binding(get: { box.preferences.fontName }, set: { box.preferences.fontName = $0 }), chinese: true).makeMenu()
        let alternate = try XCTUnwrap(menu.items.first { $0.title != box.preferences.fontName })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(alternate.action), to: alternate.target, from: alternate))
        let size = try XCTUnwrap(find(TerminalFontSizeNativeEditor.self, in: hosting).first)
        size.field.stringValue = "23"
        size.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: size.field))
        try await settle(hosting)
        let preview = try XCTUnwrap(find(TerminalPreferencesPreviewNativeView.self, in: hosting).first)
        let requested = try XCTUnwrap(NSFont(name: alternate.title, size: 23))
        XCTAssertEqual(preview.font.fontName, requested.fontName); XCTAssertEqual(preview.font.pointSize, 23)
        XCTAssertFalse(preview.canBecomeKeyView)
        XCTAssertNil(preview.hitTest(NSPoint(x: 30, y: 30)), "A preview cannot capture mouse input")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "Previewing must not save settings")
        XCTAssertTrue(store.sessions.isEmpty, "Previewing must not create a shell or connection")
        let bar = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-terminal-cursor-bar" })
        try activate(bar, point: NSPoint(x: bar.bounds.width - 1, y: 2))
        let blink = try XCTUnwrap(find(TerminalCursorBlinkNativeButton.self, in: hosting).first)
        try activate(blink, point: NSPoint(x: blink.bounds.width - 1, y: 38))
        XCTAssertEqual(box.preferences.cursorShape, "bar"); XCTAssertTrue(box.preferences.cursorBlink)
        let session = TerminalSession(host: nil, store: store)
        let terminal = RemoteTerminal(frame: .zero, options: .default)
        session.terminal = terminal; store.sessions = [session]
        try store.commitPreferences(box.preferences)
        XCTAssertEqual(terminal.font.fontName, requested.fontName); XCTAssertEqual(terminal.font.pointSize, 23)
        XCTAssertEqual(terminal.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL)).preferences.fontName, alternate.title)
        XCTAssertFalse(session.connected)
        try capture(hosting, name: "terminal-font-settings")
    }

    @MainActor func testInvalidTypedFontSizePreservesAppliedValueUntilCorrected() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility(); defer { restoreAccessibility() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-font-settings-invalid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        let hosting = NSHostingView(rootView: PreferencesView(page: .terminal).environmentObject(store).preferredColorScheme(.light))
        let window = show(hosting, size: NSSize(width: 900, height: 850)); defer { window.close() }
        try await settle(hosting)
        let size = try XCTUnwrap(find(TerminalFontSizeNativeEditor.self, in: hosting).first)
        try activate(size.increase, point: NSPoint(x: 20, y: 20)); try await settle(hosting)
        XCTAssertEqual(store.workspace.preferences.fontSize, 20)
        size.field.stringValue = "oops"
        size.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: size.field))
        try await settle(hosting)
        XCTAssertEqual(store.workspace.preferences.fontSize, 20)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL)).preferences.fontSize, 20)
        let colorPage = try XCTUnwrap(find(PreferencesNavigationNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-preferences-page-appearance" })
        colorPage.performClick(nil); try await settle(hosting)
        let terminalPage = try XCTUnwrap(find(PreferencesNavigationNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-preferences-page-terminal" })
        terminalPage.performClick(nil); try await settle(hosting)
        let restoredSize = try XCTUnwrap(find(TerminalFontSizeNativeEditor.self, in: hosting).first)
        XCTAssertEqual(restoredSize.field.stringValue, "oops", "Changing categories retains invalid input for correction")
        restoredSize.field.stringValue = "24"
        restoredSize.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: restoredSize.field))
        try await settle(hosting)
        XCTAssertEqual(store.workspace.preferences.fontSize, 24)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL)).preferences.fontSize, 24)
        try capture(hosting, name: "preferences-terminal-900")
    }

    @MainActor private final class FontDraft: ObservableObject {
        @Published var preferences = Preferences()
        @Published var sizeValid = true
        @Published var scrollbackValid = true
    }
    private struct SizeFixture: View {
        @ObservedObject var box: FontDraft
        var body: some View { TerminalFontSizeEditor(value: $box.preferences.fontSize, valid: $box.sizeValid, chinese: true).frame(width: 180, height: 42) }
    }
    private struct PaneFixture: View {
        @ObservedObject var box: FontDraft
        var body: some View { TerminalPreferencesPane(draft: $box.preferences, scrollbackValid: $box.scrollbackValid, fontSizeValid: $box.sizeValid, chinese: true).padding(24).font(.system(size: 13)).foregroundStyle(Palette.text).background(Palette.background) }
    }
    @MainActor private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); return window
    }
    @MainActor private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(120)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    @MainActor private func activate(_ button: NSButton, point: NSPoint) throws {
        let content = try XCTUnwrap(button.window?.contentView)
        let hit = try XCTUnwrap(content.hitTest(button.convert(point, to: content.superview)))
        XCTAssertTrue(hit === button, "The full window must route the control's label and padding to its native action")
        try XCTUnwrap(hit as? NSButton).performClick(nil)
    }
    @MainActor private func read(_ element: NSObject, _ key: String) -> Any? {
        let getter = key == "accessibilityEnabled" ? "isAccessibilityEnabled" : key
        return element.responds(to: NSSelectorFromString(getter)) ? element.value(forKey: key) : nil
    }
    @MainActor private func accessibilityObjects(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in read(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root); return result
    }
    @MainActor private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key)
        NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
    @MainActor private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
