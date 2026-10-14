import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AIPlanningKnowledgeTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func plan() -> AIAgentPlan { .init(title: "检查、修改与验收", items: [.init(id: "read", title: "检查当前配置和错误信息", status: "pending"), .init(id: "write", title: "修改配置并验证服务与日志", status: "pending", dependencies: ["read"])]) }
    func testDependenciesSelectionAndEvidenceBoundary() throws {
        let value = plan(); var selection = AIPlanExecution(selected: ["read", "write"])
        XCTAssertThrowsError(try selection.begin("write", plan: value)); try selection.begin("read", plan: value)
        var finished = value; finished.items[0].status = "completed"
        XCTAssertFalse(selection.accepts(finished, previous: value, unverified: true))
        XCTAssertTrue(selection.accepts(finished, previous: value, unverified: false)); XCTAssertFalse(selection.complete(finished))
        try selection.begin("write", plan: finished); XCTAssertTrue(selection.allowsMutation(finished)); XCTAssertFalse(selection.allowsMutation(value)); selection.paused = true; XCTAssertFalse(selection.allowsMutation(finished))
        XCTAssertThrowsError(try selection.begin("write", plan: finished))
        var cycle = value; cycle.items[0].dependencies = ["write"]
        XCTAssertThrowsError(try AIAgentPlan.decode(String(decoding: JSONEncoder().encode(cycle), as: UTF8.self)))
        var removed = value; removed.items.removeLast(); XCTAssertFalse(selection.accepts(removed, previous: value, unverified: false))
    }
    func testDiffIncludesDependencyOrderAndDeletion() {
        let value = plan(); var changed = value; changed.items.reverse(); changed.items[0].dependencies = []
        XCTAssertEqual(Set(changed.differences(from: value).map(\.id)), ["read", "write"])
        changed.items.removeLast(); XCTAssertNotNil(changed.differences(from: value).first { $0.id == "read" }?.before)
    }
    func testLibraryScopePersistenceOptInAndMerge() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json"); let library = AIKnowledgeLibrary(fileURL: url)
        let memory = AIKnowledgeEntry(title: "服务目录", body: "service uses /srv/project", kind: .memory, endpoint: "host-a", project: "/srv/project")
        XCTAssertTrue(library.save(memory)); XCTAssertEqual(AIKnowledgeLibrary(fileURL: url).entries.count, 1)
        XCTAssertTrue(library.context(endpoint: "host-a", directory: "/srv/project/sub", memory: false).isEmpty)
        XCTAssertTrue(library.context(endpoint: "host-b", directory: "/srv/project", memory: true).isEmpty)
        XCTAssertTrue(library.context(endpoint: "host-a", directory: "/srv/project-other", memory: true).isEmpty)
        XCTAssertTrue(library.context(endpoint: "host-a", directory: "/srv/project/sub", memory: true).contains(memory.body))
        var conflicting = memory; conflicting.body = "new observation"
        XCTAssertTrue(library.importData(try JSONEncoder().encode([conflicting]))); XCTAssertEqual(library.entries.count, 2)
        XCTAssertEqual(library.entries.first?.body, memory.body)
        let roundTrip = AIKnowledgeLibrary(fileURL: dir.appendingPathComponent("copy.json")); XCTAssertTrue(roundTrip.importData(try library.exportData())); XCTAssertEqual(roundTrip.entries, library.entries)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
    func testMalformedLibraryPreservedAndParameterIsLiteral() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }; try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("broken.json"); let data = Data("broken".utf8); try data.write(to: url)
        let library = AIKnowledgeLibrary(fileURL: url); let entry = AIKnowledgeEntry(title: "Review", body: "Review {{input}}", kind: .prompt)
        XCTAssertFalse(library.save(entry)); XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try entry.expanded(input: "$(touch /tmp/never) {{input}}"), "Review $(touch /tmp/never) {{input}}")
        XCTAssertThrowsError(try entry.expanded(input: String(repeating: "a", count: 8001)))
        XCTAssertThrowsError(try AIKnowledgeLibrary.decode(try JSONEncoder().encode([entry, entry])))
    }
    func testReusableInsertsDraftOnlyAndRejectsStaleEntry() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        var calls = 0; let ai = AIAssistant(fileURL: dir.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in calls += 1; return "unused" })
        let entry = AIKnowledgeEntry(title: "检查", body: "只读检查 {{input}}", kind: .workflow)
        XCTAssertTrue(ai.knowledge.save(entry)); let current = try XCTUnwrap(ai.knowledge.entries.first)
        XCTAssertTrue(ai.applyReusable(current, input: "服务", endpoint: "analysis", directory: nil)); XCTAssertTrue(ai.question.contains("只读检查 服务")); XCTAssertEqual(calls, 0)
        XCTAssertTrue(ai.knowledge.remove(current.id)); XCTAssertFalse(ai.applyReusable(current, input: "", endpoint: "analysis", directory: nil))
    }
    func testShellLiteralDestinationAndDynamicRejection() throws {
        XCTAssertTrue(try AIShellGuidanceScope.paths("printf 'a > b' > '/tmp/sub/file'", directory: "/tmp").contains("/tmp/sub/file"))
        XCTAssertEqual(try AIShellGuidanceScope.paths("touch '/tmp/long path/file'", directory: "/tmp"), ["/tmp/long path/file"])
        XCTAssertThrowsError(try AIShellGuidanceScope.paths("echo hi > $TARGET", directory: "/tmp"))
        XCTAssertThrowsError(try AIShellGuidanceScope.paths("cd sub && echo hi > file", directory: "/tmp"))
        XCTAssertFalse(try AIShellGuidanceScope.paths("echo 'a > b'", directory: "/tmp").contains("/tmp/b"))
    }
    func testSelectedStageRejectsMutationAndPersistsControlState() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }; let path = dir.appendingPathComponent("ai.json")
        var commands: [String] = [], calls = 0
        let ai = AIAssistant(fileURL: path, modelResponder: { _, _, _ in
            calls += 1
            return try AIStructuredReply(answer: "done", action: calls == 1 ? .init(tool: "command", argument: "touch /tmp/SHOULD_NOT_EXECUTE", reason: "write", path: nil, find: nil, replacement: nil) : nil).serialized()
        })
        XCTAssertTrue(ai.revisePlan(plan())); var revision = plan(); revision.title += "第二版"; XCTAssertTrue(ai.revisePlan(revision)); XCTAssertTrue(ai.selectPlanStages(["read"]))
        ai.question = "仅执行检查阶段"; ai.send(executor: .init(sessionID: UUID(), source: "fixture", directory: "/tmp", valid: { true }, execute: { command, _ in commands.append(command); return .init(output: "Darwin\n/tmp", exitCode: 0) }))
        for _ in 0..<400 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertEqual(calls, 2); XCTAssertFalse(commands.contains { $0.contains("SHOULD_NOT_EXECUTE") }); XCTAssertEqual(ai.taskRecords.first?.state, "blocked")
        let restored = AIAssistant(fileURL: path); restored.restoreTask(try XCTUnwrap(restored.taskRecords.first)); XCTAssertEqual(restored.planExecution?.selected, ["read"]); XCTAssertEqual(restored.plans.count, 2)
    }
    func testMemoryProposalAndTodoRequireReviewAndPersist() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }; let path = dir.appendingPathComponent("ai.json"); var calls = 0
        let ai = AIAssistant(fileURL: path, modelResponder: { _, _, _ in
            calls += 1
            return try AIStructuredReply(answer: "done", action: calls == 1 ? .init(tool: "suggest_memory", argument: #"{"title":"服务位置","body":"服务使用 /srv/app"}"#, reason: "remember", path: nil, find: nil, replacement: nil) : nil, memory: .init(facts: [], decisions: [], remaining: ["复查日志"])).serialized()
        })
        ai.question = "检查服务"; ai.send(executor: .init(sessionID: UUID(), source: "fixture", directory: "/tmp", valid: { true }, execute: { _, _ in .init(output: "Darwin\n/tmp", exitCode: 0) }))
        for _ in 0..<400 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.knowledge.entries.isEmpty); XCTAssertEqual(ai.memorySuggestions.count, 1); XCTAssertEqual(ai.todos.first?.title, "复查日志"); XCTAssertFalse(ai.plans.isEmpty)
        let suggestion = try XCTUnwrap(ai.memorySuggestions.first); XCTAssertTrue(ai.knowledge.save(suggestion))
        let restored = AIAssistant(fileURL: path); restored.restoreTask(try XCTUnwrap(restored.taskRecords.first)); XCTAssertEqual(restored.todos.first?.title, "复查日志"); XCTAssertEqual(restored.knowledge.entries.count, 1)
    }
    func testChatMemoryRequiresOptInAndComposerSlash() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        var prompts: [String] = []; let ai = AIAssistant(fileURL: dir.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in prompts.append(prompt); return "answer" })
        XCTAssertTrue(ai.knowledge.save(.init(title: "偏好", body: "UNIQUE_REVIEWED_MEMORY", kind: .memory)))
        ai.question = "first"; ai.send(); for _ in 0..<400 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(try XCTUnwrap(prompts.first).contains("UNIQUE_REVIEWED_MEMORY"))
        ai.settings.persistentMemoryEnabled = true; ai.question = "second"; ai.send(); for _ in 0..<400 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try XCTUnwrap(prompts.last).contains("UNIQUE_REVIEWED_MEMORY"))
        let editor = AIComposerTextView(); var opened = 0; editor.onSkill = { opened += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        editor.keyDown(with: event); XCTAssertEqual(opened, 1); XCTAssertTrue(editor.string.isEmpty)
        editor.string = "path"; editor.keyDown(with: event); XCTAssertEqual(opened, 1)
    }
    func testPlanAndKnowledgeActualRenderingAndEditScope() async throws {
        _ = NSApplication.shared; NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(fileURL: dir.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let ai = AIAssistant(fileURL: dir.appendingPathComponent("ai.json")); store.ai = ai
        XCTAssertTrue(ai.revisePlan(plan())); var revised = plan(); revised.items[1].title += "（需再次读取配置）"; XCTAssertTrue(ai.revisePlan(revised))
        let entry = AIKnowledgeEntry(title: "生产项目的只读检查工作流与较长说明", body: "先检查 {{input}}，记录证据，再决定下一阶段。", kind: .workflow, endpoint: "other-host", project: "/srv/original")
        XCTAssertTrue(ai.knowledge.save(entry)); let current = try XCTUnwrap(ai.knowledge.entries.first)
        let reusable = AIKnowledgeEntry(title: "只读检查提示", body: "检查 {{input}}，记录可核验结果。", kind: .prompt); XCTAssertTrue(ai.knowledge.save(reusable))
        try FileManager.default.createDirectory(atPath: "/tmp/axon-pl-ui", withIntermediateDirectories: true)
        let views: [(String, AnyView, Int, Int)] = [
            ("plan", AnyView(AIPlanSheet(ai: ai).environmentObject(store)), 660, 600),
            ("knowledge", AnyView(AIKnowledgeSheet(ai: ai, library: ai.knowledge, endpoint: "this-host", directory: "/tmp", executor: nil).environmentObject(store)), 620, 620),
            ("editor", AnyView(AIKnowledgeEditor(library: ai.knowledge, initial: current, endpoint: "this-host", directory: "/tmp").environmentObject(store)), 580, 520),
            ("pane-narrow", AnyView(AIAssistantPane(ai: ai, terminal: false, availableHeight: 760).environmentObject(store).frame(width: 320, height: 760)), 320, 760),
            ("pane-wide", AnyView(AIAssistantPane(ai: ai, terminal: false, availableHeight: 760).environmentObject(store).frame(width: 600, height: 760)), 600, 760)
        ]
        for (name, view, width, height) in views {
            let host = NSHostingView(rootView: view); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); try snapshot(host, name)
            if name == "knowledge" {
                try press(host, "axon-ai-library-use-" + reusable.id.uuidString); try await Task.sleep(for: .milliseconds(200))
                let sheet = try XCTUnwrap(window.sheets.first); let content = try XCTUnwrap(sheet.contentView); try snapshot(content, "knowledge-use"); try press(content, "axon-ai-library-insert"); XCTAssertTrue(ai.question.contains("记录可核验结果")); XCTAssertFalse(ai.busy)
            }
            if name == "editor" { try press(host, "axon-ai-library-save"); XCTAssertEqual(ai.knowledge.entries.first?.endpoint, "other-host"); XCTAssertEqual(ai.knowledge.entries.first?.project, "/srv/original") }
            if name == "plan" { try press(host, "axon-ai-plan-select-read"); try await Task.sleep(for: .milliseconds(100)); try snapshot(host, "plan-selected"); try press(host, "axon-ai-plan-mode"); try await Task.sleep(for: .milliseconds(100)); if let popover = NSApp.windows.first(where: { $0 != window && $0.isVisible && $0.contentView != nil }) { try snapshot(try XCTUnwrap(popover.contentView), "plan-menu") }; for key: UInt16 in [125, 36] { NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!) }; try await Task.sleep(for: .milliseconds(100)); try snapshot(host, "plan-diff"); try press(host, "axon-ai-plan-apply-stages"); XCTAssertEqual(ai.planExecution?.selected, ["read"]) }
            window.close()
        }
    }
    private func press(_ view: NSView, _ id: String) throws {
        var seen = Set<ObjectIdentifier>(), objects: [NSObject] = []
        func visit(_ object: NSObject) { guard seen.insert(ObjectIdentifier(object)).inserted else { return }; objects.append(object); if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(visit) }; if let v = object as? NSView { v.subviews.forEach(visit) } }
        visit(view); let object = try XCTUnwrap(objects.first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id })
        if let b = object as? NSButton { b.performClick(nil); return }; let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
    private func snapshot(_ view: NSView, _ name: String) throws { view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap); try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-pl-ui/" + name + ".png")) }
}
