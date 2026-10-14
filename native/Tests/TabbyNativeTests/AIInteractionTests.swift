import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AIInteractionTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Interaction timed out")
    }
    private func reply(_ action: AIAgentAction? = nil, answer: String = "done") throws -> String {
        try AIStructuredReply(answer: answer, action: action).serialized()
    }
    private func executor(_ writes: @escaping (String) -> Void = { _ in }) -> AICommandExecutor {
        AICommandExecutor(sessionID: UUID(), source: "fixture", directory: "/tmp", valid: { true }, execute: { command, _ in writes(command); return AICommandResult(output: "Darwin\n/tmp", exitCode: 0) })
    }
    func testQueueOrderEditingAndConversationGrouping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var held = true, prompts: [String] = []
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            prompts.append(prompt)
            if prompts.count == 1 { while held { try await Task.sleep(for: .milliseconds(10)) } }
            return "answer"
        })
        ai.question = "first"; ai.send(); try await wait { prompts.count == 1 }
        XCTAssertTrue(ai.enqueue("third")); XCTAssertTrue(ai.enqueue("second"))
        let second = ai.queuedPrompts[1].id
        ai.moveQueued(second, offset: -1); XCTAssertTrue(ai.editQueued(second, text: "second revised"))
        held = false; try await wait { ai.taskRecords.first?.messageCount == 3 && !ai.busy }
        XCTAssertEqual(ai.taskRecords.count, 1)
        XCTAssertEqual(ai.taskRecords.first?.turns?.map(\.question), ["first", "second revised", "third"])
        XCTAssertTrue(prompts[2].contains("second revised")); XCTAssertTrue(ai.queuedPrompts.isEmpty)
    }
    func testCancelledQueueDoesNotRunAndCannotCrossTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in calls += 1; try await Task.sleep(for: .seconds(10)); return "answer" })
        ai.question = "first"; ai.send(); try await wait { calls == 1 }; XCTAssertTrue(ai.enqueue("next")); ai.cancel()
        try await Task.sleep(for: .milliseconds(50)); XCTAssertEqual(calls, 1); XCTAssertEqual(ai.queuedPrompts.count, 1)
        ai.prepare(source: "other", text: "", sessionID: UUID(), question: "")
        XCTAssertTrue(ai.queuedPrompts.isEmpty)
    }
    func testClarificationPausesWithoutExecutingOrGrantingApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, commands: [String] = [], lastPrompt = ""
        let question = AIClarification(question: "Which service?", options: ["web", "worker"])
        let argument = String(decoding: try JSONEncoder().encode(question), as: UTF8.self)
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            calls += 1; lastPrompt = prompt
            return try self.reply(calls == 1 ? AIAgentAction(tool: "ask_user", argument: argument, reason: "Need service", path: nil, find: nil, replacement: nil) : nil)
        })
        ai.question = "inspect service"; ai.send(executor: executor { commands.append($0) })
        try await wait { ai.pendingQuestion != nil }; XCTAssertTrue(ai.busy); XCTAssertNil(ai.pendingApproval); XCTAssertEqual(commands.count, 1)
        ai.answerQuestion("worker"); try await wait { !ai.busy }
        XCTAssertEqual(calls, 2); XCTAssertTrue(lastPrompt.contains("Human response (not execution permission): worker")); XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(ai.error.isEmpty, ai.error)
    }
    func testSteeringDiscardsInFlightActionBeforeSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var held = true, calls = 0, commands: [String] = [], feedback = ""
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            calls += 1; feedback = prompt
            if calls == 1 {
                while held { try await Task.sleep(for: .milliseconds(10)) }
                return try self.reply(AIAgentAction(tool: "command", argument: "touch stale-action", reason: "stale decision", path: nil, find: nil, replacement: nil))
            }
            return try self.reply()
        })
        ai.question = "inspect"; ai.send(executor: executor { commands.append($0) }); try await wait { calls == 1 }
        XCTAssertTrue(ai.steer("Only inspect, do not write")); held = false; try await wait { !ai.busy }
        XCTAssertEqual(commands.count, 1); XCTAssertTrue(feedback.contains("Only inspect, do not write")); XCTAssertTrue(ai.error.isEmpty, ai.error)
    }
    func testPlanVersionsPersistAndNeverExecuteAsCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ai.json")
        let plan = AIAgentPlan(title: "Inspect services", items: [.init(id: "inspect", title: "Inspect service", status: "pending")])
        let argument = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        var calls = 0, commands: [String] = []
        let ai = AIAssistant(fileURL: path, modelResponder: { _, _, _ in calls += 1; return try self.reply(calls == 1 ? AIAgentAction(tool: "update_plan", argument: argument, reason: "Plan", path: nil, find: nil, replacement: nil) : nil) })
        ai.question = "inspect"; ai.send(executor: executor { commands.append($0) }); try await wait { !ai.busy }
        XCTAssertEqual(ai.plans, [plan]); XCTAssertEqual(commands.count, 1)
        var revised = plan; revised.items[0].title = "Check worker service"
        XCTAssertTrue(ai.revisePlan(revised)); XCTAssertEqual(ai.plans.count, 2)
        let restored = AIAssistant(fileURL: path); restored.restoreTask(try XCTUnwrap(restored.taskRecords.first)); XCTAssertEqual(restored.plans, [plan, revised])
    }
    func testInteractionLimitsAndMalformedControlTools() throws {
        let ai = AIAssistant(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertFalse(ai.enqueue(" ")); XCTAssertFalse(ai.enqueue(String(repeating: "a", count: 24001)))
        for index in 0..<12 { XCTAssertTrue(ai.enqueue("message \(index)")) }; XCTAssertFalse(ai.enqueue("overflow"))
        XCTAssertThrowsError(try AIClarification.decode(#"{"question":"", "options":[]}"#))
        XCTAssertThrowsError(try AIClarification.decode(#"{"question":"which", "options":["one","one"]}"#))
        XCTAssertThrowsError(try AIAgentPlan.decode(#"{"title":"p", "items":[{"id":"1","title":"a","status":"running"},{"id":"2","title":"b","status":"running"}]}"#))
        XCTAssertFalse(ai.steer("not running"))
    }
    func testRunningComposerQueueAndSteeringButtons() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
        var held = true, calls = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in
            calls += 1; if calls == 1 { while held { try await Task.sleep(for: .milliseconds(10)) } }; return try self.reply()
        }); store.ai = ai
        ai.prepare(source: session.displayTitle, text: "fixture", sessionID: session.id, question: "只读检查服务"); ai.send(executor: executor()); try await wait { calls == 1 }
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0192-ui", withIntermediateDirectories: true)
        for width in [320, 600] {
            ai.question = "检查完成后读取错误日志"
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 760).environmentObject(store).frame(width: CGFloat(width), height: 760)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150)); try snapshot(host, "/tmp/axon-0192-ui/running-\(width).png")
            if width == 600 {
                try press(host, "axon-ai-send"); XCTAssertEqual(ai.queuedPrompts.count, 1); XCTAssertTrue(ai.question.isEmpty)
                ai.question = "保持只读，不要修改文件"; try await Task.sleep(for: .milliseconds(100)); try press(host, "axon-ai-steer"); XCTAssertTrue(ai.question.isEmpty)
                try await Task.sleep(for: .milliseconds(100)); try snapshot(host, "/tmp/axon-0192-ui/running-with-queue.png")
            }
            window.close()
        }
        held = false; try await wait { !ai.busy && ai.queuedPrompts.isEmpty }
        XCTAssertEqual(ai.taskRecords.first?.messageCount, 2); XCTAssertEqual(calls, 3)
    }
    func testRunningComposerClarificationAndPlanRendered() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
        let clarification = AIClarification(question: "需要检查哪个服务？请选择目标，或输入其他服务名称。", options: ["网站服务 nginx", "后台任务 worker"])
        let argument = String(decoding: try JSONEncoder().encode(clarification), as: UTF8.self)
        var calls = 0
        store.ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in calls += 1; return try self.reply(calls == 1 ? AIAgentAction(tool: "ask_user", argument: argument, reason: "确认服务名称", path: nil, find: nil, replacement: nil) : nil) })
        let ai = store.ai; ai.prepare(source: session.displayTitle, text: "fixture", sessionID: session.id, question: "检查服务"); ai.send(executor: executor()); try await wait { ai.pendingQuestion != nil }
        XCTAssertTrue(ai.enqueue("完成后查看近期日志")); XCTAssertTrue(ai.enqueue("只读检查，不要修改配置"))
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0192-ui", withIntermediateDirectories: true)
        for width in [320, 600] {
            let view = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 900).environmentObject(store).frame(width: CGFloat(width), height: 900)); view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); XCTAssertNotNil(ai.pendingQuestion); XCTAssertTrue(ai.busy); XCTAssertEqual(ai.queuedPrompts.count, 2); try snapshot(view, "/tmp/axon-0192-ui/clarification-\(width).png")
            if width == 600 {
                try press(view, "axon-ai-question-option-0-0")
                try await Task.sleep(for: .milliseconds(100))
                try press(view, "axon-ai-question-answer")
                try await wait { !ai.busy && ai.queuedPrompts.isEmpty }
                XCTAssertEqual(ai.taskRecords.first?.messageCount, 3)
            }
            window.close()
        }
        ai.cancel(); try await wait { !ai.busy }; ai.question = "继续查看错误日志"
        _ = ai.revisePlan(AIAgentPlan(title: "检查服务与日志", items: [.init(id: "1", title: "检查服务运行状态", status: "completed"), .init(id: "2", title: "定位近期错误并验证结果", status: "pending")]))
        let planView = NSHostingView(rootView: AIPlanSheet(ai: ai).environmentObject(store)); planView.sizingOptions = []
        let planWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480), styleMask: [.titled], backing: .buffered, defer: false); planWindow.isReleasedWhenClosed = false; planWindow.contentView = planView; planWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200)); try snapshot(planView, "/tmp/axon-0192-ui/plan.png"); planWindow.close()
    }
    private func press(_ view: NSView, _ id: String) throws {
        var seen = Set<ObjectIdentifier>(), objects: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; objects.append(object)
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(visit) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(view)
        let object = try XCTUnwrap(objects.first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id })
        if let button = object as? NSButton { button.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
    private func snapshot(_ view: NSView, _ path: String) throws {
        view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
