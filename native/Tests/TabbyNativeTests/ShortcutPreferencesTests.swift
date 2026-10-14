import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

@MainActor final class ShortcutPreferencesTests: XCTestCase {
    func testDefaultsMigrationRoundTripConflictAndReservedCommands() throws {
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(preferences.shortcut(.newTab).display, "⌘ T")
        XCTAssertNil(ShortcutBinding.validationIssue(preferences, chinese: false))
        preferences.shortcuts[ShortcutAction.newTab.rawValue] = .init(key: "n", shift: true, option: true)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
        XCTAssertTrue(preferences.shortcut(.newTab).modifiers.contains(.option))
        preferences.shortcuts[ShortcutAction.search.rawValue] = preferences.shortcut(.newTab)
        XCTAssertThrowsError(try PreferencesValidation.validated(preferences, chinese: true))
        XCTAssertNotNil(ShortcutBinding.validationIssue(preferences, chinese: true))
        for key in ["q", "w", "c", "v", "z", "\u{1b}", "aa"] { XCTAssertFalse(ShortcutBinding(key: key).valid) }
        XCTAssertTrue(ShortcutBinding(key: "w", shift: true).valid)
    }
    func testArchivePreservesCustomShortcutsAndRejectsConflicts() throws {
        var workspace = Workspace(); workspace.preferences.shortcuts["newTab"] = .init(key: "n", shift: true)
        let encoded = try WorkspaceArchiveCodec.encode(workspace: workspace, password: nil)
        XCTAssertEqual(try WorkspaceArchiveCodec.decode(encoded, password: nil).workspace.preferences.shortcuts, workspace.preferences.shortcuts)
        workspace.preferences.shortcuts["search"] = .init(key: "n", shift: true)
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: workspace, password: nil))
    }
    func testRecorderRecordsCancelsAndReleasesCaptureOnFocusChange() throws {
        _ = NSApplication.shared
        let button = ShortcutRecorderButton(); button.frame = NSRect(x: 20, y: 20, width: 160, height: 38)
        let other = NSButton(title: "Other", target: nil, action: nil); other.frame = NSRect(x: 20, y: 70, width: 160, height: 38)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 140)); content.addSubview(button); content.addSubview(other)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.makeKeyAndOrderFront(nil)
        defer { button.finish(); window.close() }
        var recorded: [ShortcutBinding] = []; button.didRecord = { recorded.append($0) }
        func event(_ chars: String, code: UInt16 = 45, flags: NSEvent.ModifierFlags = [.command, .shift]) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        button.performClick(nil); XCTAssertTrue(button.recording)
        button.receive(try event("n", flags: [])); XCTAssertTrue(button.recording); XCTAssertTrue(recorded.isEmpty)
        button.receive(try event("n")); XCTAssertEqual(recorded, [.init(key: "n", shift: true)]); XCTAssertFalse(button.recording)
        button.performClick(nil); button.receive(try event("\u{1b}", code: 53, flags: [])); XCTAssertFalse(button.recording); XCTAssertEqual(recorded.count, 1)
        button.performClick(nil); window.makeFirstResponder(other); XCTAssertFalse(button.recording)
    }
    func testWindowEventLoopRecordsCommandNAndControlCombinationWithoutMenuAction() async throws {
        _ = NSApplication.shared
        let button = ShortcutRecorderButton(); button.frame = NSRect(x: 20, y: 20, width: 180, height: 38)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100)); content.addSubview(button)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.makeKeyAndOrderFront(nil)
        defer { button.finish(); window.close() }
        var recorded: [ShortcutBinding] = []; button.didRecord = { recorded.append($0) }
        for flags: CGEventFlags in [.maskCommand, [.maskCommand, .maskControl], [.maskCommand, .maskAlternate, .maskShift]] {
            button.performClick(nil)
            XCTAssertTrue(window.firstResponder === button)
            let native = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: true)); native.flags = flags
            let event = try XCTUnwrap(NSEvent(cgEvent: native))
            NSApp.postEvent(event, atStart: true)
            if let delivered = NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.2), inMode: .default, dequeue: true) { NSApp.sendEvent(delivered) }
            XCTAssertFalse(button.recording, "The application event loop must finish recording")
        }
        XCTAssertEqual(recorded, [.init(key: "n"), .init(key: "n", control: true), .init(key: "n", shift: true, option: true)])
        let preferences = Preferences()
        let commandN = ShortcutBinding(key: "n")
        var changed = preferences; changed.shortcuts["newTab"] = commandN
        XCTAssertNil(ShortcutBinding.validationIssue(changed, chinese: true))
        let item = NSMenuItem(title: "New tab", action: nil, keyEquivalent: commandN.key); item.keyEquivalentModifierMask = [.command]
        XCTAssertEqual(item.keyEquivalent, "n")
    }
    func testSettingsViewReceivesActualKeyAndShowsRecordedBinding() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"; store.section = "settings"
        let hosting = NSHostingView(rootView: PreferencesView(page: .shortcuts).environmentObject(store).preferredColorScheme(.light)); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        let dispatcher = ApplicationShortcutDispatcher { $0 === window ? store : nil }; dispatcher.start()
        defer { dispatcher.stop(); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        func buttons(_ view: NSView) -> [ShortcutRecorderButton] { ((view as? ShortcutRecorderButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        let button = try XCTUnwrap(buttons(hosting).first { $0.identifier?.rawValue == "axon-shortcut-newTab" })
        button.performClick(nil); XCTAssertTrue(button.recording)
        let native = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: true)); native.flags = .maskCommand
        NSApp.postEvent(try XCTUnwrap(NSEvent(cgEvent: native)), atStart: true)
        if let delivered = NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.2), inMode: .default, dequeue: true) { NSApp.sendEvent(delivered) }
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(button.recording); XCTAssertEqual(button.title, "⌘ N")
        XCTAssertEqual(store.workspace.preferences.shortcut(.newTab).key, "n", "Recording a valid shortcut applies it without saving")
        let persisted = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL))
        XCTAssertEqual(persisted.preferences.shortcut(.newTab).key, "n")
        if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("shortcut-command-n-saved.png"))
        }
    }
    func testSavedBindingDispatchesFromFocusedInputAndChangesImmediately() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppStore(fileURL: url)
        let input = NSTextField(frame: NSRect(x: 20, y: 20, width: 220, height: 30))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100)); content.addSubview(input)
        let window = ShortcutDispatchTestWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(input)
        let dispatcher = ApplicationShortcutDispatcher { $0 === window ? store : nil }; dispatcher.start()
        defer { dispatcher.stop(); window.close() }
        func send(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            NSApp.postEvent(event, atStart: true)
            if let next = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.2), inMode: .default, dequeue: true) { NSApp.sendEvent(next) }
        }
        try await Task.sleep(for: .milliseconds(150))
        window.makeKey()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(window.firstResponder is NSTextView)
        var draft = store.workspace.preferences; draft.shortcuts["newTab"] = .init(key: "n", control: true)
        try store.commitPreferences(draft)
        try send("n", code: 45, flags: [.command, .control])
        XCTAssertEqual(store.section, "launcher"); XCTAssertEqual(store.launcherRequest, 1)
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 280, height: 80)); content.addSubview(terminal); window.makeFirstResponder(terminal)
        XCTAssertTrue(window.firstResponder === terminal)
        draft.shortcuts["newTab"] = .init(key: "b", option: true); try store.commitPreferences(draft)
        try send("n", code: 45, flags: [.command, .control]); XCTAssertEqual(store.launcherRequest, 1)
        try send("b", code: 11, flags: [.command, .option]); XCTAssertEqual(store.launcherRequest, 2)
        try send(",", code: 43, flags: [.command]); XCTAssertEqual(store.section, "settings")
        let recorder = ShortcutRecorderButton(); content.addSubview(recorder); recorder.begin()
        try send("b", code: 11, flags: [.command, .option]); XCTAssertEqual(recorder.value, .init(key: "b", option: true)); XCTAssertEqual(store.launcherRequest, 2)
        window.makeFirstResponder(input)
        let other = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.makeKeyAndOrderFront(nil)
        defer { other.close() }
        let ignored = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: other.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        XCTAssertFalse(dispatcher.handle(ignored)); XCTAssertEqual(store.launcherRequest, 2)
    }
    func testConflictSaveDoesNotMutateWorkspaceAndValidBindingPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppStore(fileURL: url); let original = store.workspace.preferences
        var draft = original; draft.shortcuts["newTab"] = .init(key: "k")
        XCTAssertThrowsError(try store.commitPreferences(draft)); XCTAssertEqual(store.workspace.preferences, original); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        draft.shortcuts["newTab"] = .init(key: "n", shift: true)
        try store.commitPreferences(draft)
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.preferences.shortcut(.newTab), .init(key: "n", shift: true))
    }
}

private final class ShortcutDispatchTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
