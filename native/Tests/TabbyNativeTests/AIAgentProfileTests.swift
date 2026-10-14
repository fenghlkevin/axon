import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

@MainActor final class AIAgentProfileTests: XCTestCase {
    func testProfileRoundTripAndImmutableDeny() throws {
        var settings = AISettings(); settings.backend = .chatgpt; settings.chatgpt.model = "fixture-model"
        settings.agentRuntime = .codexNative; settings.globalInstructions = "Prefer read-only checks"; settings.projectInstructionsEnabled = true
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; settings.executionPolicy = policy
        let profile = AIAgentProfile(name: "Development", settings: settings); try profile.validate()
        settings.agentProfiles = [profile]
        let restored = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        let applied = try XCTUnwrap(restored.agentProfiles?.first).applying(to: AISettings())
        XCTAssertEqual(applied.effectiveAgentRuntime, .codexNative); XCTAssertEqual(applied.backend, .chatgpt); XCTAssertEqual(applied.chatgpt.model, "fixture-model")
        XCTAssertEqual(applied.globalInstructions, "Prefer read-only checks"); XCTAssertEqual(applied.selectedProfileID, profile.id)
        XCTAssertEqual(applied.policy.decision(target: "server", tool: "command", argument: "rm /owned/file", automatic: false), .deny)
        XCTAssertEqual(applied.policy.decision(target: "server", tool: "terminal_execute", argument: "vim /owned/file", automatic: false), .deny)
    }
    func testProfileValidationAndLegacySettingsCompatibility() throws {
        let legacy = try JSONDecoder().decode(AISettings.self, from: Data(#"{"backend":"codex","claude":{"endpoint":"https://api.anthropic.com/v1/messages","model":""},"chatgpt":{"endpoint":"https://api.openai.com/v1/chat/completions","model":""},"codexPath":"","codexModel":""}"#.utf8))
        XCTAssertEqual(legacy.effectiveAgentRuntime, .axon); XCTAssertNil(legacy.agentProfiles); XCTAssertNil(legacy.globalInstructions)
        XCTAssertThrowsError(try AIAgentProfile(name: " ", settings: legacy).validate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"))
        var draft = legacy; let profile = AIAgentProfile(name: "fixture", settings: draft); draft.agentProfiles = [profile, profile]
        XCTAssertThrowsError(try ai.save(draft, key: ""))
    }
    func testProfileAndGuidanceSettingsRendered() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        var settings = AISettings(); settings.backend = .chatgpt; settings.chatgpt.model = "fixture-model"
        let profile = AIAgentProfile(name: "只读服务器诊断 · 长名称配置示例", settings: settings)
        settings.agentProfiles = [profile]; settings.selectedProfileID = profile.id; settings.globalInstructions = "先检查真实结果，再提出修改建议。"
        store.ai.settings = settings
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0192-ui", withIntermediateDirectories: true)
        for width in [560, 820] {
        let host = NSHostingView(rootView: ScrollView { AISettingsPane(ai: store.ai).padding(16) }.environmentObject(store).foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light).frame(width: CGFloat(width), height: 1400)); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1400), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); try snapshot(host, "/tmp/axon-0192-ui/settings-\(width).png")
        try press(host, "axon-ai-profile-choice"); try await Task.sleep(for: .milliseconds(100))
        let menu = try XCTUnwrap(AxonMenuPopover.active); XCTAssertTrue(menu.menu.items.contains { $0.title == profile.name })
        try snapshot(try XCTUnwrap(menu.popover.contentViewController?.view), "/tmp/axon-0192-ui/profile-menu-\(width).png"); XCTAssertTrue(menu.handleKey(53))
        }
    }
    func testAgentRuntimeChoiceKeyboardPersistenceAndDisabledRendering() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"))
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0196-ui", withIntermediateDirectories: true)
        for width in [320, 600] {
            ai.settings.agentRuntime = nil
            let host = NSHostingView(rootView: AgentRuntimeFixture(ai: ai).environmentObject(store).frame(width: CGFloat(width), height: 250)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 250), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); try snapshot(host, "/tmp/axon-0196-ui/runtime-\(width).png")
            try press(host, "axon-ai-agent-runtime"); try await Task.sleep(for: .milliseconds(100))
            let menu = try XCTUnwrap(AxonMenuPopover.active)
            XCTAssertEqual(menu.menu.items.map(\.title), ["Axon Agent · 原有方式", "Codex Agent · 原生工具"])
            try snapshot(try XCTUnwrap(menu.popover.contentViewController?.view), "/tmp/axon-0196-ui/runtime-menu-\(width).png")
            XCTAssertTrue(menu.handleKey(125)); XCTAssertTrue(menu.handleKey(36))
            XCTAssertEqual(ai.settings.effectiveAgentRuntime, .codexNative)
            try await Task.sleep(for: .milliseconds(100)); try snapshot(host, "/tmp/axon-0196-ui/native-\(width).png")
            window.close()
        }
        try ai.save(ai.settings, key: "")
        XCTAssertEqual(AIAssistant(fileURL: root.appendingPathComponent("ai.json")).settings.effectiveAgentRuntime, .codexNative)
        let disabled = NSHostingView(rootView: AgentRuntimeFixture(ai: ai).disabled(true).environmentObject(store).frame(width: 320, height: 250)); disabled.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 250), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = disabled; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); try press(disabled, "axon-ai-agent-runtime"); XCTAssertNil(AxonMenuPopover.active)
        try snapshot(disabled, "/tmp/axon-0196-ui/disabled.png")
        store.ai.settings.codexPath = "/missing/fixture-codex"
        let full = NSHostingView(rootView: ScrollView { AISettingsPane(ai: store.ai).padding(16) }.environmentObject(store).foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light).frame(width: 820, height: 1200)); full.sizingOptions = []
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 1200), styleMask: [.titled], backing: .buffered, defer: false); settingsWindow.isReleasedWhenClosed = false; settingsWindow.contentView = full; settingsWindow.orderFront(nil); defer { settingsWindow.close() }
        try await Task.sleep(for: .milliseconds(200)); try snapshot(full, "/tmp/axon-0196-ui/settings.png")
    }
    private func snapshot(_ view: NSView, _ path: String) throws {
        view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    private func press(_ view: NSView, _ id: String) throws {
        var objects: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; objects.append(object)
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(visit) }
            if let native = object as? NSView { native.subviews.forEach(visit) }
        }
        visit(view)
        let object = try XCTUnwrap(objects.first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id })
        if let button = object as? NSButton { button.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
}

private struct AgentRuntimeFixture: View {
    @ObservedObject var ai: AIAssistant
    var body: some View {
        AIAgentRuntimeField(selection: Binding(get: { ai.settings.effectiveAgentRuntime }, set: { ai.settings.agentRuntime = $0 }))
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light)
    }
}
