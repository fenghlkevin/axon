import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class PasswordVisibilityTests: XCTestCase {
    func testEmptyPasswordClickShowsContrastingCaretInBothModes() async throws {
        let state = FixtureState()
        let (window, hosting, input) = try await show(state)
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await settle(hosting)
        for revealed in [false, true] {
            if revealed { input.visibilityButton.performClick(nil) }
            window.makeFirstResponder(nil)
            let point = input.convert(NSPoint(x: 8, y: 2), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            input.mouseDown(with: event)
            try await settle(hosting)
            let editor = try XCTUnwrap(input.activeField.currentEditor() as? NSTextView)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.insertionPointColor, NSColor(Palette.text))
            if let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent(revealed ? "caret-visible.png" : "caret-secure.png"))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), root.appendingPathComponent(revealed ? "caret-visible-window.png" : "caret-secure-window.png").path]
                try capture.run(); capture.waitUntilExit()
            }
            editor.insertText("x", replacementRange: editor.selectedRange())
            try await settle(hosting)
            XCTAssertEqual(state.password, "x")
            editor.selectAll(nil); editor.deleteBackward(nil)
        }
    }
    func testDefaultHiddenRevealAndHideUseOneFieldAndClearTheReplacedField() async throws {
        let state = FixtureState(); state.password = "fixture-password"
        let (window, hosting, input) = try await show(state)
        defer { window.close() }
        let secure = try XCTUnwrap(input.activeField as? NSSecureTextField)
        XCTAssertFalse(input.isRevealed)
        XCTAssertEqual(secure.stringValue, state.password)
        XCTAssertEqual(input.visibilityButton.accessibilityIdentifier(), "fixture-secret-visibility")
        XCTAssertEqual(input.visibilityButton.accessibilityLabel(), "Show password")
        XCTAssertTrue(input.visibilityButton.accessibilityPerformPress())
        try await settle(hosting)
        XCTAssertTrue(input.isRevealed)
        XCTAssertFalse(input.activeField is NSSecureTextField)
        XCTAssertEqual(input.activeField.stringValue, state.password)
        XCTAssertEqual(input.activeField.accessibilityIdentifier(), "fixture-secret")
        XCTAssertEqual(input.activeField.accessibilityLabel(), "Fixture password")
        XCTAssertEqual(input.visibilityButton.accessibilityLabel(), "Hide password")
        XCTAssertEqual(secure.stringValue, "")
        XCTAssertNil(secure.superview)
        XCTAssertEqual(find(NSTextField.self, in: input).count, 1)
        let revealed = input.activeField
        input.visibilityButton.performClick(nil)
        try await settle(hosting)
        XCTAssertTrue(input.activeField is NSSecureTextField)
        XCTAssertEqual(input.activeField.stringValue, state.password)
        XCTAssertEqual(revealed.stringValue, "")
        XCTAssertNil(revealed.superview)
        XCTAssertEqual(find(NSTextField.self, in: input).count, 1)
    }

    func testRevealedEditsClearingAndBindingUpdatesImmediatelyAffectActions() async throws {
        let state = FixtureState()
        let (window, hosting, input) = try await show(state)
        defer { window.close() }
        let submit = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first)
        input.visibilityButton.performClick(nil)
        let editor = try beginEditing(input.activeField, in: window)
        editor.insertText("plain-fixture", replacementRange: editor.selectedRange())
        try await settle(hosting)
        XCTAssertEqual(state.password, "plain-fixture"); XCTAssertTrue(submit.isEnabled)
        editor.selectAll(nil); editor.deleteBackward(nil)
        try await settle(hosting)
        XCTAssertEqual(state.password, ""); XCTAssertFalse(submit.isEnabled)
        XCTAssertFalse(submit.accessibilityPerformPress())
        input.visibilityButton.performClick(nil)
        try await settle(hosting)
        XCTAssertEqual(input.activeField.stringValue, "")
        XCTAssertTrue(input.activeField is NSSecureTextField)
        state.password = "replacement-fixture"
        try await settle(hosting)
        XCTAssertEqual(input.activeField.stringValue, "replacement-fixture")
        input.visibilityButton.performClick(nil)
        try await settle(hosting)
        XCTAssertEqual(input.activeField.stringValue, "replacement-fixture")
        XCTAssertEqual(state.submissions, [])
    }

    func testTogglingWhileEditingPreservesFocusSelectionAndReturnSubmission() async throws {
        let state = FixtureState(); state.password = "fixture-password"
        let (window, hosting, input) = try await show(state)
        defer { window.close() }
        let editor = try beginEditing(input.activeField, in: window)
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        input.visibilityButton.performClick(nil)
        try await settle(hosting)
        let visibleEditor = try XCTUnwrap(input.activeField.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === visibleEditor)
        XCTAssertEqual(visibleEditor.selectedRange(), NSRange(location: 3, length: 4))
        visibleEditor.insertText("NEW", replacementRange: visibleEditor.selectedRange())
        try await settle(hosting)
        XCTAssertEqual(state.password, "fixNEW-password")
        let nextSelection = visibleEditor.selectedRange()
        input.visibilityButton.performClick(nil)
        try await settle(hosting)
        let secureEditor = try XCTUnwrap(input.activeField.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === secureEditor)
        XCTAssertEqual(secureEditor.selectedRange(), nextSelection)
        if secureEditor !== visibleEditor { XCTAssertEqual(visibleEditor.string, "") }
        input.visibilityButton.performClick(nil)
        try await settle(hosting)
        let returnEditor = try XCTUnwrap(input.activeField.currentEditor() as? NSTextView)
        returnEditor.insertNewline(nil)
        try await settle(hosting)
        XCTAssertEqual(state.submissions, ["fixNEW-password"])
    }

    func testRevealedEditorKeepsLiteralCharactersWithoutSystemReplacements() async throws {
        let state = FixtureState()
        let (window, hosting, input) = try await show(state)
        defer { window.close() }
        input.visibilityButton.performClick(nil)
        let editor = try beginEditing(input.activeField, in: window)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(editor.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(editor.isAutomaticLinkDetectionEnabled)
        let literal = #" "fixture"--密码🙂 "#
        editor.insertText(literal, replacementRange: editor.selectedRange())
        try await settle(hosting)
        input.visibilityButton.performClick(nil)
        try await settle(hosting)
        XCTAssertEqual(state.password, literal)
        XCTAssertEqual(input.activeField.stringValue, literal)
    }

    func testDisabledFieldHidesPasswordAndRejectsNativeAndAccessibilityRevealActions() async throws {
        let state = FixtureState(); state.password = "fixture-password"; state.chinese = true
        let (window, hosting, input) = try await show(state)
        defer { window.close() }
        XCTAssertEqual(input.visibilityButton.accessibilityLabel(), "显示密码")
        input.visibilityButton.performClick(nil)
        XCTAssertEqual(input.visibilityButton.accessibilityLabel(), "隐藏密码")
        let visible = input.activeField
        state.disabled = true
        try await settle(hosting)
        XCTAssertFalse(input.activeField.isEnabled); XCTAssertFalse(input.visibilityButton.isEnabled)
        XCTAssertTrue(input.activeField is NSSecureTextField)
        XCTAssertEqual(visible.stringValue, "")
        XCTAssertEqual(state.password, "fixture-password")
        XCTAssertFalse(input.visibilityButton.accessibilityPerformPress())
        input.visibilityButton.performClick(nil)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(input.visibilityButton.action), to: input.visibilityButton.target, from: input.visibilityButton))
        XCTAssertFalse(input.isRevealed)
        state.disabled = false
        try await settle(hosting)
        XCTAssertTrue(input.activeField.isEnabled); XCTAssertTrue(input.visibilityButton.isEnabled)
        XCTAssertTrue(input.visibilityButton.accessibilityPerformPress())
        XCTAssertEqual(input.activeField.stringValue, "fixture-password")
    }

    func testClosingAWindowImmediatelyClearsRevealedNativeFieldAndEditor() async throws {
        let state = FixtureState(); state.password = "fixture-password"
        let (window, hosting, input) = try await show(state)
        input.visibilityButton.performClick(nil)
        let visible = input.activeField
        let editor = try beginEditing(visible, in: window)
        editor.selectAll(nil); editor.insertText("edited-fixture", replacementRange: editor.selectedRange())
        try await settle(hosting)
        window.close()
        XCTAssertEqual(visible.stringValue, "")
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(input.activeField.stringValue, "")
        XCTAssertFalse(input.isRevealed)
    }

    func testRestoreModalRevealedPasswordReturnsCorrectValueAndClearsBothModes() throws {
        _ = NSApplication.shared
        let controller = BackupRestorePasswordWindowController(chinese: false, error: nil)
        var secure: NSTextField?; var visible: NSTextField?; var input: PasswordInputView?
        var entered = false
        let timer = Timer(timeInterval: 0.04, repeats: true) { timer in
            guard let window = controller.window, NSApp.modalWindow === window, let root = window.contentView else { return }
            do {
                if !entered {
                    let value = try XCTUnwrap(self.find(PasswordInputView.self, in: root).first)
                    input = value; secure = value.activeField
                    value.visibilityButton.performClick(nil)
                    visible = value.activeField
                    let editor = try self.beginEditing(value.activeField, in: window)
                    editor.insertText("restore-visible-fixture", replacementRange: editor.selectedRange())
                    entered = true
                    return
                }
                let button = try XCTUnwrap(self.find(PreferencesRectNativeButton.self, in: root).first { $0.identifier?.rawValue == "axon-restore-password-submit" })
                guard button.isEnabled else { return }
                timer.invalidate(); button.performClick(nil)
            } catch { XCTFail("Could not exercise restore field: \(error)"); timer.invalidate(); controller.cancel() }
        }
        let watchdog = Timer(timeInterval: 3, repeats: false) { _ in XCTFail("Restore modal did not complete"); controller.cancel() }
        RunLoop.main.add(timer, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer { timer.invalidate(); watchdog.invalidate() }
        XCTAssertEqual(controller.present(), "restore-visible-fixture")
        XCTAssertTrue(entered)
        XCTAssertEqual(controller.model.password, "")
        XCTAssertEqual(secure?.stringValue, "")
        XCTAssertEqual(visible?.stringValue, "")
        XCTAssertEqual(input?.activeField.stringValue, "")
        XCTAssertEqual(input?.isRevealed, false)
        XCTAssertNil(controller.window); XCTAssertNil(NSApp.modalWindow)
    }

    private final class FixtureState: ObservableObject {
        @Published var password = ""
        @Published var disabled = false
        @Published var chinese = false
        var submissions: [String] = []
    }
    private struct Fixture: View {
        @ObservedObject var state: FixtureState
        var body: some View {
            VStack {
                PreferencesSecureField(title: "Fixture password", text: $state.password, identifier: "fixture-secret", chinese: state.chinese,
                                       onSubmit: { state.submissions.append(state.password) }).appInput().disabled(state.disabled)
                PreferencesActionButton(title: "Submit", enabled: !state.password.isEmpty) { state.submissions.append(state.password) }.frame(height: 38)
            }.padding(12)
        }
    }
    private func show(_ state: FixtureState) async throws -> (NSWindow, NSView, PasswordInputView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Fixture(state: state))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        try await settle(hosting)
        return (window, hosting, try XCTUnwrap(find(PasswordInputView.self, in: hosting).first))
    }
    private func beginEditing(_ field: NSTextField, in window: NSWindow) throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        return try XCTUnwrap(field.currentEditor() as? NSTextView)
    }
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); view.layoutSubtreeIfNeeded()
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }
}
