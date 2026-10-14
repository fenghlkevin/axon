import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class ApplicationIconPreferencesTests: XCTestCase {
    func testLegacyPreferencesRetainBlackIconAndWhiteChoiceRoundTrips() throws {
        let legacy = Data(##"{"language":"zh-CN","fontSize":23,"foreground":"#123456","terminalTheme":"dracula"}"##.utf8)
        var preferences = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertEqual(preferences.applicationIcon, "black")
        XCTAssertEqual(preferences.fontSize, 23)
        XCTAssertEqual(preferences.foreground, "#123456")
        XCTAssertEqual(preferences.terminalTheme, "dracula")
        preferences.applicationIcon = "white"
        let persisted = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: persisted), preferences)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(#"{"preferences":{}}"#.utf8)).preferences.applicationIcon, "black")
    }

    func testIconCardHitRegionsNativeActionsKeyboardAndAccessibilityAtEqualHeight() async throws {
        _ = NSApplication.shared
        let draft = IconDraft()
        let hosting = NSHostingView(rootView: IconPickerHarness(draft: draft).padding(12).preferredColorScheme(.light))
        let window = makeWindow(hosting, size: NSSize(width: 430, height: 136)); defer { window.close() }
        try await settle(hosting)
        let cards = find(ApplicationIconChoiceNativeButton.self, in: hosting)
        XCTAssertEqual(cards.count, 2)
        let black = try XCTUnwrap(cards.first { $0.iconStyle == "black" })
        let white = try XCTUnwrap(cards.first { $0.iconStyle == "white" })
        for card in cards {
            XCTAssertEqual(card.bounds.height, 112, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(card.bounds.width, 180)
            XCTAssertNotNil(card.iconImage)
            XCTAssertEqual(card.accessibilityRole(), .radioButton)
            XCTAssertTrue(card.accessibilityLabel()?.contains("黄色节点") == true)
        }
        for point in [NSPoint(x: 2, y: 2), NSPoint(x: white.bounds.midX, y: 45), NSPoint(x: white.bounds.maxX - 2, y: white.bounds.maxY - 2)] {
            black.performClick(nil); try await settle(hosting)
            try activateHitRegion(white, point: point); try await settle(hosting)
            XCTAssertEqual(draft.selection, "white")
            XCTAssertTrue(white.selected); XCTAssertFalse(black.selected)
            XCTAssertEqual(cards.filter(\.selected).count, 1)
        }
        XCTAssertTrue(black.accessibilityPerformPress()); try await settle(hosting)
        XCTAssertEqual(draft.selection, "black")
        XCTAssertTrue(window.makeFirstResponder(white))
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        white.keyDown(with: space); try await settle(hosting)
        XCTAssertEqual(draft.selection, "white")
        XCTAssertEqual(white.accessibilityValue() as? Int, 1)
        XCTAssertEqual(black.accessibilityValue() as? Int, 0)
        black.performClick(nil); try await settle(hosting)
        XCTAssertEqual(draft.selection, "black")
        draft.enabled = false; try await settle(hosting)
        XCTAssertFalse(white.isEnabled)
        white.keyDown(with: space); try await settle(hosting)
        XCTAssertEqual(draft.selection, "black", "Disabled icon cards must not respond to keyboard activation")
        XCTAssertFalse(white.accessibilityPerformPress())
        XCTAssertEqual(draft.selection, "black")
        try capture(hosting, name: "application-icon-picker")
    }

    func testGeneralIconSelectionAppliesAutomaticallyAt650Width() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-icon-preferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        let original = store.workspace.preferences
        let hosting = NSHostingView(rootView: PreferencesView().environmentObject(store).preferredColorScheme(.light))
        let window = makeWindow(hosting, size: NSSize(width: 650, height: 700)); defer { window.close() }
        try await settle(hosting)
        let cards = find(ApplicationIconChoiceNativeButton.self, in: hosting)
        let white = try XCTUnwrap(cards.first { $0.iconStyle == "white" })
        let black = try XCTUnwrap(cards.first { $0.iconStyle == "black" })
        for card in cards {
            let frame = hosting.convert(card.bounds, from: card)
            XCTAssertGreaterThanOrEqual(frame.minX, 168)
            XCTAssertLessThanOrEqual(frame.maxX, hosting.bounds.maxX - 24)
            XCTAssertEqual(frame.height, 112, accuracy: 0.5)
        }
        XCTAssertTrue(black.selected)
        XCTAssertTrue(white.accessibilityPerformPress()); try await settle(hosting)
        XCTAssertTrue(white.selected); XCTAssertFalse(black.selected)
        XCTAssertEqual(store.workspace.preferences.applicationIcon, "white")
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL)).preferences.applicationIcon, "white")
        try capture(hosting, name: "preferences-application-icon-white-auto-650")
        XCTAssertTrue(black.accessibilityPerformPress()); try await settle(hosting)
        XCTAssertTrue(black.selected); XCTAssertFalse(white.selected)
        XCTAssertEqual(store.workspace.preferences, original)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL)).preferences.applicationIcon, "black")
        try capture(hosting, name: "preferences-application-icon-black-auto-650")
    }

    private final class IconDraft: ObservableObject {
        @Published var selection = "black"
        @Published var enabled = true
    }
    private struct IconPickerHarness: View {
        @ObservedObject var draft: IconDraft
        var body: some View { ApplicationIconPicker(selection: $draft.selection, chinese: true).disabled(!draft.enabled) }
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }
    private func makeWindow<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        return window
    }
    private func settle(_ hosting: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
    }
    private func activateHitRegion(_ button: NSButton, point: NSPoint) throws {
        let hit = try XCTUnwrap(button.hitTest(button.convert(point, to: button.superview)))
        XCTAssertTrue(hit === button)
        // This verifies the full card hit region and native target/action.
        // It deliberately does not claim to simulate physical mouse tracking:
        // AppKit's tracking loop consults real event-queue and pointer state,
        // which the in-process XCTest host cannot reproduce deterministically.
        let control = try XCTUnwrap(hit as? NSButton)
        control.performClick(nil)
    }
    private struct AccessibilityNode {
        let element: NSObject
        func read(_ key: String) -> Any? { element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard element.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(element.method(for: selector), to: Press.self)(element, selector)
        }
    }
    private func nodes(_ root: NSView) -> [AccessibilityNode] {
        var found: [AccessibilityNode] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, _ depth: Int) {
            guard depth < 50, let element = value as? NSObject, seen.insert(ObjectIdentifier(element)).inserted else { return }
            let node = AccessibilityNode(element: element); found.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth + 1) }
            if let view = element as? NSView { for child in view.subviews { visit(child, depth + 1) } }
        }
        visit(root, 0); return found
    }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key); NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
