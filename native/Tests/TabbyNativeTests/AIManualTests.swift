import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

@MainActor final class AIManualTests: XCTestCase {
    func testDirectoryHoverRendering() async throws {
        _ = NSApplication.shared
        var clicks = 0
        let host = NSHostingView(rootView: Button { clicks += 1 } label: {
            Text("03 · 选择执行方式与 Agent").frame(width: 250, height: 44)
        }.buttonStyle(WorkspaceMenuItemStyle()).padding(16).background(Palette.sidebar))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 290, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        try capture(host, "hover-before")
        let tracking = try XCTUnwrap(objects(host).compactMap { $0 as? AxonHoverTrackingView }.first)
        tracking.updateTrackingAreas()
        XCTAssertTrue(tracking.trackingAreas.contains { $0.options.contains(.inVisibleRect) })
        XCTAssertNil(tracking.hitTest(NSPoint(x: 50, y: 20)))
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 100, y: 40), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        tracking.mouseEntered(with: entered)
        try await Task.sleep(for: .milliseconds(150)); try capture(host, "hover-entered")
        XCTAssertEqual(clicks, 0)
        let directory = URL(fileURLWithPath: "/tmp/axon-manual-ui")
        XCTAssertNotEqual(try Data(contentsOf: directory.appendingPathComponent("hover-before.png")), try Data(contentsOf: directory.appendingPathComponent("hover-entered.png")))
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        tracking.mouseExited(with: exited)
        try await Task.sleep(for: .milliseconds(150)); try capture(host, "hover-exited")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("hover-before.png")), try Data(contentsOf: directory.appendingPathComponent("hover-exited.png")))
    }
    func testAboutPanelPlacement() async throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 160, y: 180, width: 720, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        let panel = try XCTUnwrap(AxonAboutPanel.show(relativeTo: parent))
        XCTAssertFalse(panel === parent)
        let expected = AxonAboutPanel.centeredFrame(size: panel.frame.size, parent: parent.frame, visible: try XCTUnwrap(parent.screen).visibleFrame)
        XCTAssertEqual(panel.frame.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, expected.minY, accuracy: 1)
        parent.setFrameOrigin(NSPoint(x: 240, y: 240))
        XCTAssertTrue(AxonAboutPanel.show(relativeTo: parent) === panel)
        let repositioned = AxonAboutPanel.centeredFrame(size: panel.frame.size, parent: parent.frame, visible: try XCTUnwrap(parent.screen).visibleFrame)
        XCTAssertEqual(panel.frame.minX, repositioned.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, repositioned.minY, accuracy: 1)
        // The test runner has no application bundle metadata; supply a display fixture.
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Axon", .applicationVersion: "0.19.21", .version: "186", NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Axon contributors. Based on open-source SwiftTerm and Citadel."])
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(250))
        try capture(try XCTUnwrap(panel.contentView), "about-centered")
        let edge = AxonAboutPanel.centeredFrame(size: NSSize(width: 300, height: 240), parent: NSRect(x: -100, y: -100, width: 200, height: 200), visible: NSRect(x: 0, y: 24, width: 900, height: 700))
        XCTAssertEqual(edge.origin, NSPoint(x: 0, y: 24))
        panel.close(); parent.close()
    }
    func testBundledManualCoverageAndSearch() throws {
        let chapters = try AIManualContent.load()
        XCTAssertEqual(chapters.count, 24)
        XCTAssertEqual(Set(chapters.map(\.id)).count, chapters.count)
        for chapter in chapters {
            XCTAssertFalse(chapter.entry.isEmpty)
            XCTAssertGreaterThanOrEqual(chapter.steps.count, 4)
            XCTAssertEqual(chapter.flow.count, 4)
            XCTAssertFalse(chapter.example.isEmpty)
            XCTAssertFalse(chapter.check.isEmpty)
            XCTAssertFalse(chapter.note.isEmpty)
            XCTAssertFalse(chapter.illustrations.isEmpty, chapter.id)
            XCTAssertEqual(Set(chapter.illustrations.map(\.id)).count, chapter.illustrations.count)
            for illustration in chapter.illustrations {
                XCTAssertFalse(illustration.title.isEmpty)
                XCTAssertTrue(illustration.caption.contains("1．"))
                XCTAssertTrue(illustration.caption.contains("2．"))
                XCTAssertTrue(illustration.caption.contains("3．"))
                let picture = try XCTUnwrap(NSImage(contentsOf: try XCTUnwrap(AIManualContent.resource(illustration.image))))
                XCTAssertGreaterThanOrEqual(picture.size.width, 800)
            }
        }
        XCTAssertTrue(chapters.first { $0.id == "mcp" }!.matches("JSON 凭据"))
        XCTAssertTrue(chapters.first { $0.id == "usage" }!.matches("token"))
        XCTAssertFalse(chapters.contains { $0.matches("impossiblekeyword456") })
        XCTAssertEqual(chapters.filter { $0.matches(" \n ") }.count, chapters.count)
    }
    private func objects(_ view: NSView) -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ o: NSObject) {
            guard seen.insert(ObjectIdentifier(o)).inserted else { return }; result.append(o)
            if o.responds(to: NSSelectorFromString("accessibilityChildren")) { for child in o.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] { visit(child) } }
            if let v = o as? NSView { for child in v.subviews { visit(child) } }
        }
        visit(view); return result
    }
    private func find(_ view: NSView, _ id: String) throws -> NSObject {
        try XCTUnwrap(objects(view).first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && ($0.value(forKey: "accessibilityIdentifier") as? String) == id }, id)
    }
    private func press(_ view: NSView, _ id: String) throws {
        let object = try find(view, id)
        XCTAssertTrue(object.responds(to: NSSelectorFromString("accessibilityPerformPress")), id)
        if let button = object as? NSButton { button.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector), id)
    }
    private func search(_ view: NSView, _ text: String) throws {
        let field = try XCTUnwrap(objects(view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "搜索全部章节、步骤、示例" })
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        _ = field.sendAction(field.action, to: field.target)
    }
    private func capture(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let directory = URL(fileURLWithPath: "/tmp/axon-manual-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
    func testCaptureManualEntryPoints() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-manual-entry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in "示例：配置中的监听端口与日志不一致。先核对配置路径和日志来源，再决定是否修改。" })
        store.ai = ai
        ai.prepare(source: "示例 · 本机项目", text: "service port = 8080", sessionID: nil, question: "请先分析配置与错误日志，不执行命令。")
        ai.send()
        for _ in 0..<100 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        ai.question = "下一步应核对哪些文件和配置项？"
        let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 820).environmentObject(store).frame(width: 560, height: 820))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250)); try capture(host, "guide-assistant")
        try press(host, "axon-ai-execution-style")
        try await Task.sleep(for: .milliseconds(150))
        if let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil }) {
            try capture(try XCTUnwrap(popover.contentView), "guide-execution-options")
            popover.orderOut(nil)
        }
        window.close()
        let running = AIAssistant(fileURL: root.appendingPathComponent("running.json"), modelResponder: { _, _, _ in
            try? await Task.sleep(for: .seconds(10)); return "示例检查已结束。"
        })
        let executor = AICommandExecutor(sessionID: UUID(), source: "示例 · 本机项目", directory: "/srv/example", valid: { true }, execute: { _, _ in .init(output: "示例输出", exitCode: 0) })
        running.prepare(source: executor.source, text: "示例配置与日志", sessionID: executor.sessionID, question: "先只读检查服务配置。")
        running.send(executor: executor)
        XCTAssertTrue(running.enqueue("随后整理发现的问题，不修改文件。"))
        running.question = "请补充当前配置的检查步骤。"
        let runningHost = NSHostingView(rootView: AIAssistantPane(ai: running, executionOverride: executor, availableHeight: 900).environmentObject(store).frame(width: 600, height: 900))
        let runningWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        runningWindow.isReleasedWhenClosed = false; runningWindow.contentView = runningHost; runningWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        if let disclosure = objects(runningHost).first(where: { object in
            object.responds(to: NSSelectorFromString("accessibilityLabel")) && (object.value(forKey: "accessibilityLabel") as? String ?? "").hasPrefix("排队消息") && object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }) {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            _ = unsafeBitCast(disclosure.method(for: selector), to: Press.self)(disclosure, selector)
        }
        try await Task.sleep(for: .milliseconds(150)); try capture(runningHost, "guide-queue-current")
        running.cancel(); runningWindow.close()
        ai.settings.backend = .chatgpt
        ai.settings.chatgpt.endpoint = "https://api.example.com/v1/chat/completions"
        ai.settings.chatgpt.model = "your-model-id"
        let settings = NSHostingView(rootView: ScrollView { AISettingsPane(ai: ai).environmentObject(store).padding(20) }.frame(width: 840, height: 940).background(Palette.background).preferredColorScheme(.light))
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 940), styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false; settingsWindow.contentView = settings; settingsWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250)); try capture(settings, "guide-provider")
        settingsWindow.close()
        let fields: [(String, AnyView, CGFloat, CGFloat)] = [
            ("guide-policy", AnyView(ScrollView { AITaskPolicyFields(policy: .constant(AIExecutionPolicy())).padding(24) }.environmentObject(store).background(Palette.background)), 760, 1100),
            ("guide-runtime", AnyView(AIAgentRuntimeField(selection: .constant(.codexNative)).environmentObject(store).padding(24).background(Palette.card)), 600, 200)
        ]
        for (name, view, width, height) in fields {
            let fieldHost = NSHostingView(rootView: view.frame(width: width, height: height).preferredColorScheme(.light))
            let fieldWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            fieldWindow.isReleasedWhenClosed = false; fieldWindow.contentView = fieldHost; fieldWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); try capture(fieldHost, name); fieldWindow.close()
        }
    }
    func testManualRenderingAndInteractions() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-manual-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        for width in [720, 1060, 1400] {
            let host = NSHostingView(rootView: AIManualView().environmentObject(store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250)); try capture(host, "start-\(width)")
            _ = try find(host, "axon-manual-contents")
            try press(host, "axon-manual-group-6"); try await Task.sleep(for: .milliseconds(150))
            _ = try find(host, "axon-manual-chapter-recovery")
            try capture(host, "directory-\(width)")
            try press(host, "axon-manual-group-0"); try await Task.sleep(for: .milliseconds(150))
            try press(host, "axon-manual-next"); try await Task.sleep(for: .milliseconds(150))
            _ = try find(host, "axon-manual-chapter-provider")
            try press(host, "axon-manual-previous"); try await Task.sleep(for: .milliseconds(150))
            // Search exercises full chapter text and reveals chapters outside the initial scroll viewport.
            try search(host, "MCP")
            try await Task.sleep(for: .milliseconds(200))
            try press(host, "axon-manual-chapter-mcp"); try await Task.sleep(for: .milliseconds(200)); try capture(host, "mcp-\(width)")
            try press(host, "axon-manual-image-mcp"); try await Task.sleep(for: .milliseconds(200))
            let sheet = try XCTUnwrap(window.sheets.first); try capture(try XCTUnwrap(sheet.contentView), "zoom-\(width)")
            try press(try XCTUnwrap(sheet.contentView), "axon-manual-image-close"); try await Task.sleep(for: .milliseconds(150)); XCTAssertTrue(window.sheets.isEmpty)
            try search(host, "impossiblekeyword456"); try await Task.sleep(for: .milliseconds(150)); try capture(host, "empty-\(width)"); _ = try find(host, "axon-manual-empty")
            try press(host, "axon-manual-clear"); try await Task.sleep(for: .milliseconds(150)); window.close()
        }
        // Each image opens its own caption and bitmap, including later images in a chapter.
        let gallery = NSHostingView(rootView: AIManualView(initialChapter: "sessions").environmentObject(store))
        let galleryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 4000), styleMask: [.titled], backing: .buffered, defer: false)
        galleryWindow.isReleasedWhenClosed = false; galleryWindow.contentView = gallery; galleryWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let illustrations = try XCTUnwrap(try AIManualContent.load().first { $0.id == "sessions" }).illustrations
        for index in [1, 2] {
            try press(gallery, "axon-manual-image-sessions-" + String(index))
            try await Task.sleep(for: .milliseconds(150))
            let sheet = try XCTUnwrap(galleryWindow.sheets.first), content = try XCTUnwrap(sheet.contentView)
            _ = try find(content, "axon-manual-zoom-image-" + illustrations[index].image)
            try capture(content, "gallery-zoom-" + String(index))
            try press(content, "axon-manual-image-close"); try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(galleryWindow.sheets.isEmpty)
        }
        galleryWindow.close()
        // Copy operates only on the clipboard; no model request or terminal action exists.
        let host = NSHostingView(rootView: AIManualView(initialChapter: "faq").environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 2600), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200)); try press(host, "axon-manual-copy")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), try AIManualContent.load().last?.example)
        try capture(host, "faq-full"); window.close()
        let fixture = AIAssistant(fileURL: root.appendingPathComponent("fixture.json"), modelResponder: { _, _, _ in "退出码 0 通常表示命令正常结束；非 0 表示错误或特定状态。还要结合输出与原目标核对，不能只看退出码。此回答仅分析，没有执行命令。" })
        fixture.prepare(source: "示例 · 只读对话", text: "", sessionID: nil, question: "请解释退出码，并说明如何判断命令是否成功。")
        fixture.send()
        for _ in 0..<100 { if !fixture.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        fixture.question = "如果日志仍有错误，应怎样继续检查？"
        let pane = NSHostingView(rootView: AIAssistantPane(ai: fixture, availableHeight: 760).environmentObject(store).frame(width: 480, height: 760))
        let assistantWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760), styleMask: [.titled], backing: .buffered, defer: false); assistantWindow.isReleasedWhenClosed = false; assistantWindow.contentView = pane; assistantWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200)); try capture(pane, "assistant")
        try press(pane, "axon-ai-manual"); XCTAssertNotNil(AIManualWindowController.shared.window); XCTAssertFalse(store.ai.busy)
        AIManualWindowController.shared.window?.close(); assistantWindow.close()
    }
}
