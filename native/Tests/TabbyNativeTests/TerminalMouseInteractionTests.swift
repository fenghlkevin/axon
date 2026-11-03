import XCTest
import AppKit
@testable import TabbyNative

final class TerminalMouseInteractionTests: XCTestCase {
    @MainActor func testSelectedTextCopiesAndRightClickPastesWithoutOpeningMenu() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.copyOnSelect = true
        store.workspace.preferences.rightClickPaste = true
        let clipboard = NSPasteboard.general
        let saved = clipboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            clipboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            clipboard.writeObjects(items)
        }
        for width in [CGFloat(600), 1000] {
            let terminal = MousePasteTerminal(frame: NSRect(x: 0, y: 0, width: width, height: 300))
            terminal.store = store; terminal.sessionID = UUID()
            try terminal.setUseMetal(false)
            TerminalAppearance.apply(store.workspace.preferences, to: terminal)
            terminal.feed(text: "CONTAINER ID       NAMES\r\n87be1e00486a       superin\r\n")
            let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
            defer { window.close() }
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 80, y: 200), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            terminal.selectAll(nil)
            let selection = try XCTUnwrap(terminal.getSelection())
            XCTAssertTrue(selection.contains("87be1e00486a"))
            terminal.mouseUp(with: try event(.leftMouseUp))
            XCTAssertEqual(clipboard.string(forType: .string), selection)
            terminal.rightMouseDown(with: try event(.rightMouseDown))
            XCTAssertEqual(terminal.pasted, [selection])
            XCTAssertEqual(terminal.menuRequests, 0)
            XCTAssertEqual(store.activeSession, terminal.sessionID)
            XCTAssertTrue(window.firstResponder === terminal)
            try await Task.sleep(for: .milliseconds(100))
            terminal.displayIfNeeded()
            let bitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
            terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-terminal-right-click-\(Int(width)).png"))
            terminal.selectAll(nil) // Keep selection active while clipboard changes independently.
            clipboard.clearContents(); clipboard.setString("new clipboard text", forType: .string)
            terminal.rightMouseDown(with: try event(.rightMouseDown))
            XCTAssertEqual(terminal.pasted.last, "new clipboard text")
            terminal.selectNone()
            terminal.rightMouseDown(with: try event(.rightMouseDown))
            XCTAssertEqual(terminal.pasted.count, 3)
            XCTAssertEqual(terminal.menuRequests, 0)
            store.workspace.preferences.rightClickPaste = false
            terminal.rightMouseDown(with: try event(.rightMouseDown))
            XCTAssertEqual(terminal.pasted.count, 3)
            store.workspace.preferences.rightClickPaste = true
        }
    }
}

@MainActor private final class MousePasteTerminal: RemoteTerminal {
    var pasted: [String] = []
    var menuRequests = 0
    override func paste(_ sender: Any) { pasted.append(NSPasteboard.general.string(forType: .string) ?? "") }
    override func menu(for event: NSEvent) -> NSMenu? { menuRequests += 1; return nil }
}
