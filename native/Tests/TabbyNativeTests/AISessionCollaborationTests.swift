import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AISessionCollaborationTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out")
    }
    func testConcurrentConversationsQueuesAndCancellationAreIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var holdA = true, holdB = true, callsA = 0, callsB = 0
        let a = AIAssistant(fileURL: root.appendingPathComponent("settings.json"), modelResponder: { _, _, _ in callsA += 1; while holdA { try await Task.sleep(for: .milliseconds(10)) }; return "A" })
        let b = AIAssistant(fileURL: root.appendingPathComponent("settings.json"), sessionJournalURL: root.appendingPathComponent("AISessions/\(UUID().uuidString).json"), modelResponder: { _, _, _ in callsB += 1; while holdB { try await Task.sleep(for: .milliseconds(10)) }; return "B" })
        store.ai = a; a.question = "A"; a.send(); try await wait { callsA == 1 }
        store.ai = b; b.question = "B"; b.send(); try await wait { callsB == 1 }
        XCTAssertTrue(a.busy && b.busy); XCTAssertTrue(a.enqueue("A2")); XCTAssertTrue(b.enqueue("B2"))
        store.selectAI(a); XCTAssertTrue(b.busy); a.cancel(); XCTAssertTrue(b.busy)
        holdA = false; holdB = false; try await wait { !b.busy && b.queuedPrompts.isEmpty }
        XCTAssertEqual(callsA, 1); XCTAssertEqual(callsB, 2); XCTAssertEqual(a.queuedPrompts.count, 1)
        XCTAssertEqual(b.taskRecords.first?.turns?.map(\.question), ["B", "B2"])
        XCTAssertTrue(store.aiNotifications.events.contains { $0.conversation == b.id && $0.state == "finished" })
    }
    func testChatSteeringDiscardsStaleResponseAndPreservesQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, lastPrompt = "", held = true
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, publish in
            calls += 1; let current = calls; lastPrompt = prompt
            if current == 1 { while held { try await Task.sleep(for: .milliseconds(10)) }; publish("stale"); return "stale" }
            return "corrected"
        })
        ai.question = "original question"; ai.send(); try await wait { calls == 1 }
        XCTAssertTrue(ai.enqueue("next")); XCTAssertTrue(ai.canSteer); XCTAssertTrue(ai.steer("Only explain the logs")); held = false
        try await wait { !ai.busy && ai.queuedPrompts.isEmpty }
        XCTAssertEqual(calls, 3); XCTAssertEqual(ai.answer, "corrected"); XCTAssertTrue(lastPrompt.contains("Only explain the logs")); XCTAssertFalse(ai.taskRecords.first?.summary.contains("stale") == true)
    }
    func testSameTerminalExecutionCannotReplaceOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")), target = UUID()
        var held = true
        let a = AIAssistant(fileURL: root.appendingPathComponent("a.json"), modelResponder: { _, _, _ in while held { try await Task.sleep(for: .milliseconds(10)) }; return try AIStructuredReply(answer: "done", action: nil).serialized() })
        store.ai = a
        a.prepare(source: "fixture", text: "", sessionID: target, question: "inspect")
        let executor = AICommandExecutor(sessionID: target, source: "fixture", directory: "/tmp", valid: { true }, execute: { _, _ in AICommandResult(output: "Darwin\n/tmp", exitCode: 0) })
        a.send(executor: executor); try await wait { a.busy }
        XCTAssertTrue(store.createAIConversation()); let b = store.ai; b.question = "second"; b.send(executor: executor)
        XCTAssertFalse(b.busy); XCTAssertTrue(b.error.contains("另一个会话")); XCTAssertTrue(a.busy)
        store.takeOverAI(sessionID: target) // independent commands retain their original cancellation semantics
        held = false; try await wait { !a.busy }
    }
    func testBatchQuestionValidationAndDeterministicAnswers() throws {
        let value = try AIClarification.decode(#"{"questions":[{"question":"Services?","options":["web","worker"],"multiple":true},{"question":"Environment?","options":["dev","prod"]}]}"#)
        XCTAssertNil(value.response(selections: [0: ["web"]], text: [:]))
        XCTAssertEqual(value.response(selections: [0: ["worker", "web"], 1: ["dev"]], text: [1: "read only"]), "1. Services?: web; worker\n2. Environment?: dev; read only")
        XCTAssertNil(value.response(selections: [0: ["unknown"], 1: ["dev"]], text: [:]))
        XCTAssertNil(value.response(selections: [0: ["web"], 1: ["dev", "prod"]], text: [:]))
        XCTAssertThrowsError(try AIClarification.decode(#"{"questions":[]}"#))
        XCTAssertThrowsError(try AIClarification.decode(#"{"questions":[{"question":"a","options":[]},{"question":"b","options":[]},{"question":"c","options":[]},{"question":"d","options":[]}]}"#))
    }
    func testSessionJournalsAndInboxSurviveRestartWithoutQueues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("AISessions/\(UUID().uuidString).json")
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai-settings.json"), sessionJournalURL: path, modelResponder: { _, _, _ in "saved" })
        store.ai = ai; ai.question = "saved conversation"; ai.send(); try await wait { !ai.busy }
        XCTAssertTrue(ai.enqueue("not persisted"))
        let restored = AppStore(fileURL: root.appendingPathComponent("workspace.json")); _ = restored.ai
        let session = try XCTUnwrap(restored.aiSessions.first { $0.id == ai.id })
        XCTAssertEqual(session.submittedQuestion, "saved conversation"); XCTAssertFalse(session.busy); XCTAssertTrue(session.queuedPrompts.isEmpty)
        XCTAssertEqual(restored.aiNotifications.events.last?.conversation, ai.id)
        restored.aiNotifications.markRead(try XCTUnwrap(restored.aiNotifications.events.last?.id))
        XCTAssertTrue(restored.aiNotifications.events.last?.read == true)
    }
    func testCollaborationViewsRenderedAndButtonsWork() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let ai = store.ai
        let question = try AIClarification.decode(#"{"questions":[{"question":"需要检查哪些服务？可选择多个服务，或补充完整名称。","options":["网站服务 nginx","后台任务 worker 和较长名称的应用服务"],"multiple":true},{"question":"使用哪个环境？","options":["开发环境","生产环境"]},{"question":"还有哪些限制或补充信息？","options":[]}]}"#)
        let folder = URL(fileURLWithPath: "/tmp/axon-01913-ui"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for width in [320, 600] {
            let host = NSHostingView(rootView: AIClarificationView(ai: ai, question: question).environmentObject(store).frame(width: CGFloat(width), height: 430).background(Palette.background)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 430), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            try press(host, "axon-ai-question-option-0-0"); try press(host, "axon-ai-question-option-0-1")
            try await Task.sleep(for: .milliseconds(100)); try snapshot(host, folder.appendingPathComponent("questions-\(width).png")); window.close()
        }
        ai.prepare(source: "具有代表性长名称的本机终端会话和服务目标", text: "fixture", sessionID: nil, question: "")
        store.aiNotifications.receive(ai, state: "approval"); store.aiNotifications.receive(ai, state: "failed")
        let inbox = NSHostingView(rootView: AISessionInbox(notifications: store.aiNotifications).environmentObject(store)); inbox.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 580), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = inbox; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150)); try snapshot(inbox, folder.appendingPathComponent("inbox.png")); try press(inbox, "axon-ai-session-create"); XCTAssertEqual(store.aiSessions.count, 2); window.close()
        let pane = NSHostingView(rootView: AIAssistantPane(ai: store.ai, availableHeight: 760).environmentObject(store).frame(width: 320, height: 760)); pane.sizingOptions = []
        let paneWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 760), styleMask: [.titled], backing: .buffered, defer: false); paneWindow.isReleasedWhenClosed = false; paneWindow.contentView = pane; paneWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150)); try snapshot(pane, folder.appendingPathComponent("pane-320.png")); paneWindow.close()
    }
    func testBatchControlsSubmitAllSelectedAnswers() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let argument = #"{"questions":[{"question":"Services?","options":["web","worker"],"multiple":true},{"question":"Environment?","options":["dev","prod"]}]}"#
        var calls = 0, feedback = ""
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            calls += 1; feedback = prompt
            return try AIStructuredReply(answer: "done", action: calls == 1 ? AIAgentAction(tool: "ask_user", argument: argument, reason: "Need information", path: nil, find: nil, replacement: nil) : nil).serialized()
        })
        ai.question = "inspect"; ai.send(executor: AICommandExecutor(sessionID: UUID(), source: "fixture", directory: "/tmp", valid: { true }, execute: { _, _ in AICommandResult(output: "Darwin", exitCode: 0) }))
        try await wait { ai.pendingQuestion != nil }
        let host = NSHostingView(rootView: AIClarificationView(ai: ai, question: try XCTUnwrap(ai.pendingQuestion)).environmentObject(store).frame(width: 320, height: 420)); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        try press(host, "axon-ai-question-option-0-0"); try press(host, "axon-ai-question-option-0-1"); try press(host, "axon-ai-question-option-1-0")
        try await Task.sleep(for: .milliseconds(100)); try press(host, "axon-ai-question-answer"); try await wait { !ai.busy }
        XCTAssertTrue(feedback.contains("1. Services?: web; worker")); XCTAssertTrue(feedback.contains("2. Environment?: dev")); XCTAssertNil(ai.pendingApproval); XCTAssertEqual(calls, 2)
    }
    func testSceneWindowsUseDifferentJournalsAndInboxes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AppStore(fileURL: root.appendingPathComponent("workspace.json")), sceneID = UUID()
        let scene = AppStore(fileURL: first.fileURL, aiNamespace: sceneID)
        XCTAssertNotEqual(first.ai.id, scene.ai.id); XCTAssertNotEqual(first.aiConversationDirectory, scene.aiConversationDirectory)
        first.aiNotifications.receive(first.ai, state: "finished"); scene.aiNotifications.receive(scene.ai, state: "failed")
        XCTAssertEqual(first.aiNotifications.events.count, 1); XCTAssertEqual(scene.aiNotifications.events.count, 1)
        let restored = AppStore(fileURL: first.fileURL, aiNamespace: sceneID)
        XCTAssertEqual(restored.ai.id, scene.ai.id); XCTAssertEqual(restored.aiNotifications.events.first?.state, "failed")
    }
    func testVoicePermissionDenialAndCancellationNeverRecord() async throws {
        var microphoneCalls = 0
        let denied = AIVoiceInput(speechPermission: { false }, microphonePermission: { microphoneCalls += 1; return true })
        denied.start(chinese: true); try await wait { denied.status.contains("系统设置") }
        XCTAssertFalse(denied.recording); XCTAssertEqual(microphoneCalls, 0); XCTAssertTrue(denied.transcript.isEmpty)
        var released = false
        let cancelled = AIVoiceInput(speechPermission: { while !released { await Task.yield() }; return true }, microphonePermission: { microphoneCalls += 1; return true })
        cancelled.start(chinese: false); await Task.yield(); cancelled.stop(); released = true
        try await Task.sleep(for: .milliseconds(30)); XCTAssertFalse(cancelled.recording); XCTAssertEqual(microphoneCalls, 0); XCTAssertTrue(cancelled.status.isEmpty)
        var inserted = "unexpected"; cancelled.finish { inserted = $0 }; XCTAssertEqual(inserted, "")
    }
    func testRealWorkspaceQuestionsAtNarrowAndWideWindows() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id; store.section = "terminal"
        let argument = #"{"questions":[{"question":"需要检查哪些服务？","options":["网站服务 nginx","后台任务 worker"],"multiple":true},{"question":"目标环境？","options":["开发环境","生产环境"]},{"question":"需要保留哪些限制？","options":[]}]}"#
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai-settings.json"), modelResponder: { _, _, _ in try AIStructuredReply(answer: "", action: AIAgentAction(tool: "ask_user", argument: argument, reason: "Need context", path: nil, find: nil, replacement: nil)).serialized() }); store.ai = ai
        ai.prepare(source: session.displayTitle, text: "fixture", sessionID: session.id, question: "检查服务")
        ai.send(executor: AICommandExecutor(sessionID: session.id, source: "fixture", directory: "/tmp", valid: { true }, execute: { _, _ in AICommandResult(output: "Darwin\n/tmp", exitCode: 0) }))
        try await wait { ai.pendingQuestion != nil }
        let host = NSHostingView(rootView: MainView().environmentObject(store).frame(minWidth: 1050, minHeight: 680))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { ai.cancel(); window.close() }
        try await Task.sleep(for: .milliseconds(200)); try press(host, "axon-terminal-tools-toggle"); try await Task.sleep(for: .milliseconds(300)); try press(host, "axon-terminal-tool-ai")
        for size in [NSSize(width: 1400, height: 860), NSSize(width: 1050, height: 680)] {
            window.setContentSize(size); try await Task.sleep(for: .milliseconds(300))
            try snapshot(host, URL(fileURLWithPath: "/tmp/axon-01913-ui/workspace-\(Int(size.width)).png"))
            XCTAssertNotNil(ai.pendingQuestion); XCTAssertTrue(ai.busy)
        }
    }
    private func snapshot(_ view: NSView, _ file: URL) throws {
        view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap); try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
    private func press(_ view: NSView, _ id: String) throws {
        var seen = Set<ObjectIdentifier>(), objects: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; objects.append(object)
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(visit) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(view)
        let object = try XCTUnwrap(objects.first { if let view = $0 as? NSView, view.identifier?.rawValue == id { return true }; return $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id })
        if let button = object as? NSButton { button.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
}
