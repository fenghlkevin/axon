import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import TabbyNative

@MainActor final class WorkspaceNavigationTests: XCTestCase {
    func testHostInspectorAnimatesOpeningAndClosingWithoutResizingWindow() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        for width: CGFloat in [1050, 1400] {
            let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            store.workspace.preferences.language = "en-US"
            var host = TabbyNative.Host(); host.name = "Inspector animation fixture"; host.address = "fixture.invalid"
            store.workspace.hosts = [host]
            let hosting = NSHostingView(rootView: MainView().environmentObject(store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 900))
            defer { window.close(); store.monitoring.stop() }
            try await settle(hosting)
            let originalFrame = window.frame
            func searchWidth() throws -> CGFloat {
                try XCTUnwrap(find(NSTextField.self, in: hosting).first { $0.placeholderString == "Find a host or ssh user@hostname…" }).frame.width
            }
            let expandedCenter = try searchWidth()
            let edit = try XCTUnwrap(find(HostCardNativeActionButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-host-edit-" + host.id.uuidString })
            edit.performClick(nil)
            var opening: [CGFloat] = []
            for pause in [30, 40, 50] {
                try await Task.sleep(for: .milliseconds(pause)); hosting.layoutSubtreeIfNeeded()
                opening.append(try searchWidth())
            }
            try await Task.sleep(for: .milliseconds(220)); try await settle(hosting)
            let collapsedCenter = try searchWidth()
            XCTAssertEqual(expandedCenter - collapsedCenter, 341, accuracy: 2)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertTrue(opening.contains { $0 > collapsedCenter + 2 && $0 < expandedCenter - 2 }, "Opening must have intermediate layout frames: \(opening)")
            }
            try captureAndAudit(hosting, name: "host-inspector-open-\(Int(width))")
            let close = try XCTUnwrap(nodes(hosting).first { $0.role == .button && $0.text == "Close details" })
            let selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(close.object.method(for: selector), to: Press.self)(close.object, selector))
            var closing: [CGFloat] = []
            for pause in [30, 40, 50] {
                try await Task.sleep(for: .milliseconds(pause)); hosting.layoutSubtreeIfNeeded()
                closing.append(try searchWidth())
            }
            try await Task.sleep(for: .milliseconds(220)); try await settle(hosting)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertTrue(closing.contains { $0 > collapsedCenter + 2 && $0 < expandedCenter - 2 }, "Closing must have intermediate layout frames: \(closing)")
            }
            XCTAssertEqual(try searchWidth(), expandedCenter, accuracy: 2)
            XCTAssertEqual(window.frame, originalFrame)
            XCTAssertTrue(store.sessions.isEmpty)
            try captureAndAudit(hosting, name: "host-inspector-closed-\(Int(width))")
        }
    }

    func testLauncherTabIsConsumedWhenOpeningHost() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [1050, 1400] {
            let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            store.workspace.preferences.language = "zh-CN"
            var host = TabbyNative.Host(); host.name = "标签复用验收服务器"; host.address = "fixture.invalid"
            store.workspace.hosts = [host]
            store.connect()
            store.sessions[0].terminal = TerminalView(frame: .zero)
            let preservedID = store.activeSession
            let hosting = NSHostingView(rootView: MainView().environmentObject(store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 900))
            defer { window.close(); store.monitoring.stop() }
            store.openLauncher(); try await settle(hosting)
            XCTAssertTrue(store.newTabOpen)
            try captureAndAudit(hosting, name: "launcher-reuse-before-\(Int(width))")
            store.connect(host)
            let session = try XCTUnwrap(store.sessions.last)
            let terminal = TerminalView(frame: .zero); terminal.feed(text: "标签复用验收：当前新标签已打开 SSH 会话\r\n")
            session.terminal = terminal
            try await Task.sleep(for: .milliseconds(400))
            try await settle(hosting)
            terminal.feed(text: "标签复用验收：当前新标签已打开 SSH 会话\r\n")
            try await settle(hosting)
            XCTAssertFalse(store.newTabOpen)
            XCTAssertEqual(store.sessions.count, 2)
            XCTAssertEqual(store.sessions.first?.id, preservedID)
            XCTAssertEqual(store.activeSession, session.id)
            try captureAndAudit(hosting, name: "launcher-reuse-after-\(Int(width))")
        }
    }

    func testMainNavigationAndSettingsReuseOneSidebarAndPreserveTheSession() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        for width: CGFloat in [1050, 1400] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-workspace-navigation-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
            var host = TabbyNative.Host(); host.name = "Preserved fixture"; host.address = "fixture.invalid"; host.username = "qa"
            store.workspace.hosts = [host]
            let session = TerminalSession(host: host, store: store)
            // A cached local rendering surface lets MainView preserve and lay
            // out a real TerminalSession without starting SSH or a shell.
            let terminal = TerminalView(frame: .zero); session.terminal = terminal
            store.sessions = [session]; store.activeSession = session.id
            let hosting = NSHostingView(rootView: MainView().environmentObject(store).preferredColorScheme(.light).tint(Palette.accent))
            let window = show(hosting, size: NSSize(width: width, height: 900)); defer { window.close(); store.monitoring.stop() }
            try await settle(hosting)
            try assertOneWorkspaceColumn(in: hosting, expected: 10)
            try captureAndAudit(hosting, name: "workspace-sidebar-main-\(Int(width))")

            for section in ["hosts", "monitoring", "credentials", "forwards", "snippets", "batchTasks", "known", "logs", "scenes"] {
                for pointIndex in 0..<6 {
                    let button = try navigation("axon-navigation-" + section, in: hosting)
                    try activateAtPoint(button, point: points(button)[pointIndex]); try await settle(hosting)
                    XCTAssertEqual(store.section, section, "Icon, text, whitespace and corners must all change the actual workspace section")
                    XCTAssertTrue(try navigation("axon-navigation-" + section, in: hosting).selected)
                    try assertSessionUnchanged(session, terminal: terminal, store: store)
                }
                try captureAndAudit(hosting, name: "workspace-page-\(section)-\(Int(width))")
            }
            store.openLauncher(); try await settle(hosting)
            try captureAndAudit(hosting, name: "workspace-page-launcher-\(Int(width))")
            store.section = "hosts"; try await settle(hosting)

            // Settings replaces these same rows; each activation uses a newly
            // looked-up native button after returning from settings.
            for pointIndex in 0..<6 {
                let settings = try navigation("axon-navigation-settings", in: hosting)
                try activateAtPoint(settings, point: points(settings)[pointIndex]); try await settle(hosting)
                XCTAssertEqual(store.section, "settings")
                try assertSettingsColumn(in: hosting)
                try activateAtPoint(try navigation("axon-settings-back", in: hosting), point: NSPoint(x: 50, y: 22)); try await settle(hosting)
                XCTAssertEqual(store.section, "hosts")
                try assertOneWorkspaceColumn(in: hosting, expected: 10)
                try assertSessionUnchanged(session, terminal: terminal, store: store)
            }

            try activateAtPoint(try navigation("axon-navigation-settings", in: hosting), point: NSPoint(x: 160, y: 41)); try await settle(hosting)
            let pageMarkers: [(PreferencesPage, String)] = [
                (.general, "Application icon"), (.terminal, "Font & preview"), (.appearance, "Scheme library"),
                (.keywords, "Priority: host"), (.keyboard, "Keyboard & mouse"), (.connection, "SSH & SFTP"), (.importHosts, "Import SSH hosts"), (.storage, "Encrypted backup"),
                (.shortcuts, "Keyboard shortcuts"), (.about, "fenghlkevin")
            ]
            for (page, marker) in pageMarkers {
                let button = try navigation("axon-preferences-page-" + page.rawValue, in: hosting)
                for point in points(button) {
                    try activateAtPoint(button, point: point); try await settle(hosting)
                    XCTAssertEqual(store.settingsPage, page)
                    XCTAssertTrue(button.selected)
                    try assertSettingsColumn(in: hosting)
                    XCTAssertTrue(nodes(hosting).contains { $0.role == .staticText && $0.text.contains(marker) }, "Selecting \(page) must display the corresponding settings body")
                    try assertSessionUnchanged(session, terminal: terminal, store: store)
                }
                let viewport = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
                let heading = try XCTUnwrap(nodes(hosting).first { $0.role == .staticText && $0.text == page.title(chinese: false) && $0.frame.minX > viewport.minX + 184 })
                XCTAssertLessThan(heading.frame.minX, viewport.minX + 225, "Settings content starts directly after the one 184pt workspace sidebar")
                try captureAndAudit(hosting, name: "workspace-settings-\(page.rawValue)-\(Int(width))")
            }

            store.openPreferences(.storage); try await settle(hosting)
            for id in ["axon-cloud-upload", "axon-cloud-download", "axon-cloud-folder-save"] {
                let control = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == id })
                XCTAssertFalse(control.isEnabled, "Cloud actions stay disabled without credentials or a backup password")
                XCTAssertFalse(control.accessibilityPerformPress())
                control.performClick(nil)
            }
            let saveConnection = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-cloud-save" })
            XCTAssertTrue(saveConnection.isEnabled, "Saving connection metadata does not require a backup password")
            XCTAssertFalse(FileManager.default.fileExists(atPath: CloudConnectionPersistence.url(workspaceURL: store.fileURL).path))
            // The menu/toolbar import route binds to the same settings column.
            store.openPreferences(.importHosts); try await settle(hosting)
            XCTAssertEqual(store.section, "settings"); XCTAssertEqual(store.settingsPage, .importHosts)
            try assertSettingsColumn(in: hosting)
            let choose = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-import-choose" })
            let confirm = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-import-confirm" })
            XCTAssertTrue(choose.isEnabled); XCTAssertFalse(confirm.isEnabled)
            // SwiftUI excludes disabled content from mouse hit testing. Its
            // native target/action and accessibility press must also reject
            // activation without a selected file.
            XCTAssertFalse(confirm.accessibilityPerformPress())
            confirm.performClick(nil)
            XCTAssertEqual(store.workspace.hosts, [host], "An empty import cannot commit a change")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "Browsing navigation and an unselected import must not save a workspace")
            try assertSessionUnchanged(session, terminal: terminal, store: store)
            try activateAtPoint(try navigation("axon-settings-back", in: hosting), point: NSPoint(x: 2, y: 2)); try await settle(hosting)
            XCTAssertEqual(store.section, "hosts")
            XCTAssertEqual(store.settingsPage, .importHosts, "Returning to the workspace retains the chosen settings category")
            try assertOneWorkspaceColumn(in: hosting, expected: 10)
        }
    }

    private func assertSessionUnchanged(_ session: TerminalSession, terminal: TerminalView, store: AppStore) throws {
        XCTAssertEqual(store.sessions.map(\.id), [session.id]); XCTAssertTrue(store.sessions.first === session)
        XCTAssertEqual(store.activeSession, session.id); XCTAssertTrue(session.terminal === terminal)
        XCTAssertEqual(session.generation, 0); XCTAssertNil(session.task); XCTAssertNil(session.client); XCTAssertNil(session.writer)
        XCTAssertFalse(session.connected)
    }
    private func assertSettingsColumn(in hosting: NSView) throws {
        let buttons = find(PreferencesNavigationNativeButton.self, in: hosting)
        XCTAssertEqual(buttons.count, PreferencesPage.allCases.count + 1, "Settings categories plus Back share the existing sidebar")
        XCTAssertEqual(Set(buttons.compactMap { $0.identifier?.rawValue }), Set(PreferencesPage.allCases.map { "axon-preferences-page-" + $0.rawValue } + ["axon-settings-back"]))
        XCTAssertEqual(buttons.filter(\.selected).count, 1)
        for button in buttons { try assertSidebarGeometry(button, in: hosting) }
    }
    private func assertOneWorkspaceColumn(in hosting: NSView, expected: Int) throws {
        let buttons = find(PreferencesNavigationNativeButton.self, in: hosting)
        XCTAssertEqual(buttons.count, expected)
        XCTAssertTrue(buttons.allSatisfy { $0.identifier?.rawValue.hasPrefix("axon-navigation-") == true })
        for button in buttons { try assertSidebarGeometry(button, in: hosting) }
    }
    private func assertSidebarGeometry(_ button: NSView, in hosting: NSView) throws {
        let frame = button.convert(button.bounds, to: hosting)
        XCTAssertEqual(frame.minX, 10, accuracy: 1); XCTAssertEqual(frame.width, 164, accuracy: 1)
        XCTAssertLessThanOrEqual(frame.maxX, 184); XCTAssertEqual(frame.height, 44, accuracy: 1)
    }
    private func navigation(_ identifier: String, in hosting: NSView) throws -> PreferencesNavigationNativeButton {
        try XCTUnwrap(find(PreferencesNavigationNativeButton.self, in: hosting).first { $0.identifier?.rawValue == identifier }, "Missing native navigation row " + identifier)
    }
    private func points(_ button: NSView) -> [NSPoint] {
        [NSPoint(x: 2, y: 2), NSPoint(x: button.bounds.width - 2, y: 2), NSPoint(x: 2, y: button.bounds.height - 2), NSPoint(x: button.bounds.width - 2, y: button.bounds.height - 2), NSPoint(x: 48, y: 22), NSPoint(x: button.bounds.width - 16, y: 22)]
    }
    private func activateAtPoint(_ button: NSButton, point: NSPoint) throws {
        let content = try XCTUnwrap(button.window?.contentView)
        let hit = try XCTUnwrap(content.hitTest(button.convert(point, to: content.superview)))
        XCTAssertTrue(hit === button, "The real window hierarchy must route the complete row to its native action")
        // performClick tests native target/action after validating the real hit
        // target. It does not spoof AppKit's hardware mouse tracking state.
        try XCTUnwrap(hit as? NSButton).performClick(nil)
    }
    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) } }
    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); return window
    }
    private func settle(_ view: NSView) async throws { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key); NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
    private struct Node {
        let object: NSObject
        func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        var role: NSAccessibility.Role? { (read("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        var text: String { [read("accessibilityLabel") as? String, read("accessibilityTitle") as? String, read("accessibilityValue") as? String].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }
    private func nodes(_ root: NSView) -> [Node] {
        var result = [Node](), seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 60, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
    private func captureAndAudit(_ view: NSView, name: String) throws {
        let window = try XCTUnwrap(view.window), viewport = window.convertToScreen(view.convert(view.bounds, to: nil))
        let leafRoles: Set<NSAccessibility.Role> = [.staticText, .button, .checkBox, .popUpButton]
        for node in nodes(view) where node.role.map(leafRoles.contains) == true {
            let frame = node.frame
            guard frame.width > 0, frame.height > 0, frame.intersects(viewport) else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, "\(name): \(node.text) overflows left")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, "\(name): \(node.text) overflows right")
        }
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        try nodes(view).map { "\($0.role?.rawValue ?? "")\t\($0.frame)\t\($0.text)" }.joined(separator: "\n").write(to: directory.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
    }
}
