import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

final class SSHConnectionTestTests: XCTestCase {
    @MainActor func testUnsavedAuthenticationOverridesSavedProfileWithoutPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var saved = TabbyNative.Host(); saved.address = "example.invalid"; saved.username = "saved"
        store.workspace.hosts = [saved]
        var draft = saved; draft.username = "draft-user"; draft.port = 2222
        let session = TerminalSession(host: draft, store: store)
        let settings = try session.settings(for: draft, authenticationPrompt: { _ in XCTFail("Draft password must be used"); throw CancellationError() }, draftMaterial: .init(secret: "draft-password"), useDraftHost: true)
        XCTAssertEqual(settings.port, 2222)
        XCTAssertEqual(store.workspace.hosts.first?.username, "saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    @MainActor func testInvalidJumpRouteDoesNotSaveDraft() async {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.address = "example.invalid"; host.username = "root"; host.jumpHostID = UUID()
        do { try await SSHConnectionTest.run(host: host, material: .init(secret: "fixture"), store: store); XCTFail("Missing hop must fail") }
        catch { XCTAssertTrue(error.localizedDescription == store.text("Invalid jump route", "跳板路线无效")) }
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    @MainActor func testHostEditorRendering() throws {
        _ = NSApplication.shared
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        var host = TabbyNative.Host(); host.address = "example.invalid"; host.username = "root"; host.name = "生产主机 · 长名称用于检查编辑面板与底部操作区"
        let view = NSHostingView(rootView: HostEditor(host: host, isNew: true, done: {}).background(Palette.sidebar).foregroundStyle(Palette.text).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 850), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-host-editor-test.png"))
    }
    @MainActor func testFooterRendering() throws {
        _ = NSApplication.shared
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        var host = TabbyNative.Host(); host.address = "example.invalid"; host.username = "root"
        for (width, running, succeeded) in [(340.0, false, false), (340.0, false, true), (340.0, true, false), (440.0, false, true)] {
            let view = NSHostingView(rootView: HStack(spacing: 10) {
                SSHConnectionTestButton(running: running, succeeded: succeeded, chinese: true, action: {})
                Button("保存") {}.buttonStyle(ChromeButtonStyle())
                Button {} label: { Label("连接", systemImage: "terminal") }.buttonStyle(ChromeButtonStyle(prominent: true))
            }.padding(16).frame(width: width, height: 70).background(Palette.sidebar).environmentObject(store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 70), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-test-footer-\(Int(width))-\(running)-\(succeeded).png"))
            window.close()
        }
    }
}
