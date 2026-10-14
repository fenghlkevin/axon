import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class AIOptimizationTests: XCTestCase {
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-optimization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out")
    }
    func testOversizedDraftRejectedBeforeHistoryUsageOrModelChanges() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in calls += 1; return "answer" })
        ai.question = String(repeating: "中文", count: 4001)
        XCTAssertFalse(ai.send()); XCTAssertEqual(calls, 0); XCTAssertTrue(ai.taskRecords.isEmpty)
        XCTAssertEqual(ai.usage.requests, 0); XCTAssertFalse(ai.busy); XCTAssertEqual(ai.question.utf8.count, 24006)
        ai.question = "smaller"; XCTAssertTrue(ai.send()); try await wait { !ai.busy }; XCTAssertEqual(calls, 1)
        ai.question = String(repeating: "中文", count: 4001); XCTAssertFalse(ai.send()); ai.question = ""; XCTAssertFalse(ai.canRetryConversation)
    }
    func testQueueKeepsMessageWhenTerminalOwnershipOrRestoreBlocksSend() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in try AIStructuredReply(answer: "done", action: nil).serialized() })
        var allowed = true; ai.mayExecute = { _ in allowed }
        let ex = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: root.path, valid: { true }, execute: { _, _ in .init(output: "Darwin", exitCode: 0) })
        ai.question = "first"; XCTAssertTrue(ai.send(executor: ex)); try await wait { !ai.busy }
        XCTAssertTrue(ai.enqueue("second")); let id = try XCTUnwrap(ai.queuedPrompts.first?.id)
        XCTAssertTrue(ai.beginFileRestore()); ai.resumeQueue(); XCTAssertEqual(ai.queuedPrompts.first?.id, id); ai.endFileRestore()
        allowed = false; ai.resumeQueue(); XCTAssertEqual(ai.queuedPrompts.first?.id, id); XCTAssertTrue(ai.question.isEmpty); XCTAssertFalse(ai.busy)
        allowed = true; ai.resumeQueue(); try await wait { !ai.busy }; XCTAssertTrue(ai.queuedPrompts.isEmpty); XCTAssertEqual(ai.submittedQuestion, "second")
    }
    func testChatRetryPreservesNewDraftAndMarksInterruptedHistory() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, hold = true
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, publish in
            calls += 1
            if calls == 1 { publish("partial answer"); while hold { try await Task.sleep(for: .milliseconds(10)) } }
            return "complete answer"
        })
        ai.question = "original"; ai.send(); try await wait { !ai.answer.isEmpty }; ai.cancel(); hold = false
        XCTAssertTrue(ai.canRetryConversation)
        ai.question = "new unsent draft"; XCTAssertFalse(ai.retryConversation()); XCTAssertEqual(ai.question, "new unsent draft")
        ai.question = ""; XCTAssertTrue(ai.retryConversation()); try await wait { !ai.busy }
        XCTAssertEqual(ai.answer, "complete answer"); XCTAssertEqual(calls, 2)
        XCTAssertEqual(ai.conversation.first?.answer, "partial answer"); XCTAssertTrue(ai.conversation.first?.error.contains("interrupted") == true)
    }
    func testClosedConversationReopensFromInboxWithoutExecutionOrApproval() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); _ = store.ai
        let id = UUID(), journal = store.aiConversationDirectory.appendingPathComponent(id.uuidString + ".json")
        let assistant = AIAssistant(fileURL: root.appendingPathComponent("ai-settings.json"), sessionJournalURL: journal, modelResponder: { _, _, _ in "saved answer" })
        store.ai = assistant; assistant.question = "saved question"; assistant.send(); try await wait { !assistant.busy }
        store.closeAI(assistant); XCTAssertFalse(store.aiSessions.contains { $0.id == id })
        XCTAssertTrue(store.openAIConversation(id)); XCTAssertEqual(store.ai.id, id); XCTAssertEqual(store.ai.answer, "saved answer")
        XCTAssertFalse(store.ai.busy); XCTAssertNil(store.ai.pendingApproval); XCTAssertTrue(store.ai.queuedPrompts.isEmpty)
        let count = store.aiSessions.count; XCTAssertTrue(store.openAIConversation(id)); XCTAssertEqual(store.aiSessions.count, count)
        XCTAssertFalse(store.openAIConversation(UUID())); XCTAssertEqual(store.aiSessions.count, count); XCTAssertFalse(store.aiNotifications.status.isEmpty)
        XCTAssertGreaterThan(store.aiNotifications.unreadCount, 0); store.aiNotifications.markAllRead(); XCTAssertEqual(store.aiNotifications.unreadCount, 0)
        XCTAssertEqual(AINotifications(root: root).unreadCount, 0)
    }
    func testPrimaryConversationReopensAfterClosing() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let record = AITaskRecord(id: UUID(), sessionID: UUID(), hostID: nil, target: "saved primary", question: "primary question", transcript: "", summary: "primary answer", state: "finished", updated: Date(), executed: false)
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("ai-settings.tasks.json"))
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); let primary = store.ai
        primary.restoreTask(record); XCTAssertTrue(store.createAIConversation()); store.closeAI(primary)
        XCTAssertTrue(store.openAIConversation(primary.id)); XCTAssertEqual(store.ai.id, primary.id); XCTAssertEqual(store.ai.answer, "primary answer"); XCTAssertFalse(store.ai.busy)
    }
    func testRecentSavedConversationsLoadBeforeOlderOnes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("AISessions"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var ids: [UUID] = []
        for number in 0..<22 {
            let id = UUID(); ids.append(id)
            let record = AITaskRecord(id: UUID(), sessionID: UUID(), hostID: nil, target: "fixture", question: "saved \(number)", transcript: "", summary: "answer", state: "finished", updated: Date(), executed: false)
            let file = folder.appendingPathComponent(id.uuidString + ".json")
            try JSONEncoder().encode([record]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + number))], ofItemAtPath: file.path)
        }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); _ = store.ai
        XCTAssertEqual(store.aiSessions.count, 20); XCTAssertEqual(store.aiSessions.dropFirst().map(\.id), Array(ids.suffix(19).reversed()))
    }
    func testRejectedResumeLeavesCurrentHistoryDraftAndQueueUntouched() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in try AIStructuredReply(answer: "done", action: nil).serialized() })
        let ex = AICommandExecutor(sessionID: UUID(), source: "original", directory: root.path, valid: { true }, execute: { _, _ in .init(output: "Darwin", exitCode: 0) })
        ai.question = "first"; ai.send(executor: ex); try await wait { !ai.busy }
        ai.restoreTask(try XCTUnwrap(ai.taskRecords.last)); ai.question = "continue original"; XCTAssertTrue(ai.enqueue("next"))
        let turns = ai.conversation.map(\.id), requests = ai.usage.requests, queued = ai.queuedPrompts.map(\.id)
        let other = AICommandExecutor(sessionID: UUID(), source: "different", directory: root.path, valid: { true }, execute: { _, _ in XCTFail("wrong target"); return .init(output: "", exitCode: 1) })
        XCTAssertFalse(ai.send(executor: other)); XCTAssertEqual(ai.conversation.map(\.id), turns); XCTAssertEqual(ai.usage.requests, requests)
        XCTAssertEqual(ai.queuedPrompts.map(\.id), queued); XCTAssertEqual(ai.question, "continue original"); XCTAssertFalse(ai.busy)
    }
    func testCumulativeUsageNeverDecreasesWithRepeatedOrLateSamples() throws {
        var sample = AIUsageSample(input: 120, output: 20, cached: 30, cacheWrite: 10, reasoning: 4)
        sample.merge(.init(input: 100, output: 0, cached: 0, cacheWrite: 0, reasoning: 0))
        XCTAssertEqual(sample, .init(input: 120, output: 20, cached: 30, cacheWrite: 10, reasoning: 4))
        var settings = AISettings(); var policy = settings.policy; policy.tokenBudget = 140; settings.executionPolicy = policy
        var ledger = AIUsageLedger(); let id = ledger.begin(settings); ledger.report(id, sample); ledger.report(id, .init(input: 1, output: 1)); ledger.finish(id, success: true)
        XCTAssertEqual(ledger.tokens.total, 140); XCTAssertThrowsError(try ledger.check(settings))
        var stream = AIStreamEvents()
        func emit(_ json: String) throws { try stream.line("data: " + json, backend: .claude); try stream.line("", backend: .claude) }
        try emit(#"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":0}}}"#)
        try emit(#"{"type":"message_delta","usage":{"input_tokens":100,"output_tokens":10}}"#)
        XCTAssertEqual(stream.usage.total, 130)
    }
    func testStallRemainsLatchedUntilNewEvidenceOrExplicitReset() {
        var guardrail = AIProgressGuard()
        for _ in 0..<4 { guardrail.rejected("same denied action") }; XCTAssertTrue(guardrail.stalled)
        guardrail.rejected("different denied action"); XCTAssertTrue(guardrail.stalled)
        guardrail.reset(); XCTAssertFalse(guardrail.stalled)
        for _ in 0..<4 { guardrail.observed(tool: "read_file", argument: "/f", output: "old", exitCode: 0) }
        guardrail.observed(tool: "read_file", argument: "/other", output: "old", exitCode: 0); XCTAssertTrue(guardrail.stalled)
        guardrail.observed(tool: "read_file", argument: "/f", output: "changed", exitCode: 0); XCTAssertFalse(guardrail.stalled)
    }
    func testLivePlanContextDoesNotAccumulateInDecisionHistory() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var prompts: [String] = []
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            prompts.append(prompt)
            return try AIStructuredReply(answer: "inspect", action: .init(tool: "inspect_port", argument: "8080", reason: "inspect", path: nil, find: nil, replacement: nil)).serialized()
        })
        XCTAssertTrue(ai.revisePlan(.init(title: "Read only", items: [.init(id: "read", title: "Inspect", status: "pending")])))
        XCTAssertTrue(ai.selectPlanStages(["read"]))
        var policy = ai.settings.policy; policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        ai.question = "inspect"
        ai.send(executor: .init(sessionID: UUID(), source: "fixture", directory: root.path, valid: { true }, execute: { command, _ in .init(output: command.contains("uname") ? "Darwin" : "unchanged", exitCode: 0) }))
        try await wait { !ai.busy }; XCTAssertEqual(prompts.count, 4)
        for prompt in prompts { XCTAssertEqual(prompt.components(separatedBy: "Application-selected stages:").count - 1, 1) }
        XCTAssertFalse(ai.taskRecords.last?.transcript.contains("Application-selected stages:") == true)
        XCTAssertEqual(ai.taskRecords.last?.planExecution?.selected, ["read"])
    }
    func testOversizedMCPCatalogKeepsCompleteSchemasAndReportsOmissions() throws {
        let large = "large-tool\nInput schema: " + String(decoding: try JSONSerialization.data(withJSONObject: ["type": "object", "description": String(repeating: "x", count: 24000)]), as: UTF8.self)
        let schema = #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        let small = "read-tool\nInput schema: " + schema
        let result = AIMCPManager.boundedCatalog([("server-1", [large, small]), ("server-2", [small])])
        XCTAssertLessThanOrEqual(result.count, 24000); XCTAssertFalse(result.contains("large-tool")); XCTAssertTrue(result.contains("1 tool(s) omitted"))
        XCTAssertEqual(result.components(separatedBy: schema).count - 1, 2); XCTAssertTrue(result.contains("server-1")); XCTAssertTrue(result.contains("server-2"))
    }
    func testIncrementalIndexHonorsChunkLimitForUnchangedFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let backend = LocalFiles(); var documents: [AIProjectIndex.Document] = []
        for index in 0..<251 {
            let file = source.appendingPathComponent(String(format: "%04d.swift", index)); let data = Data("func fixture() {}".utf8); try data.write(to: file)
            if index < 250 {
                let entry = try await backend.stat(file.path)
                documents.append(.init(path: file.path, digest: AIProjectIndex.digest(data), size: entry.size, modified: entry.modified,
                    chunks: (0..<8).map { .init(line: $0 * 32 + 1, text: "fixture", vector: nil) }, symbols: [], imports: []))
            }
        }
        let path = root.appendingPathComponent("index.json")
        try JSONEncoder().encode([AIProjectIndex.Project(endpoint: "fixture", root: source.path, documents: documents)]).write(to: path)
        let index = AIProjectIndex(fileURL: path)
        let ex = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: source.path, valid: { true }, execute: { _, _ in XCTFail("no shell"); return .init(output: "", exitCode: 1) }); ex.fileBackend = { LocalFiles() }
        for _ in 0..<3 {
            try await index.sync(index.projects[0].id, executor: ex, policy: AIExecutionPolicy())
            XCTAssertEqual(index.projects[0].documents.count, 250); XCTAssertEqual(index.projects[0].documents.reduce(0) { $0 + $1.chunks.count }, 2000)
            XCTAssertEqual(index.projects[0].state, "limited")
        }
    }
    func testRetryAndInboxNativeControlsAndMessageLimitRendering() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"), previous = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: ax); defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: ax) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        var fail = true
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in if fail { throw AppFailure.message("Fixture unavailable / 示例服务暂不可用") }; return "重试成功，保留原问题" })
        store.ai = ai; ai.question = "解释当前输出，不执行命令"; ai.send(); try await wait { !ai.busy }
        let folder = URL(fileURLWithPath: "/tmp/axon-ai-optimization-ui"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for width in [320, 600] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, availableHeight: 900).environmentObject(store).frame(width: CGFloat(width), height: 900)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150)); try snapshot(host, folder.appendingPathComponent("retry-\(width).png"))
            XCTAssertNotNil(objects(host).first { read($0, "accessibilityIdentifier") as? String == "axon-ai-retry-chat" })
            if width == 600 { fail = false; try press(host, "axon-ai-retry-chat"); try await wait { !ai.busy }; XCTAssertTrue(ai.error.isEmpty); XCTAssertEqual(ai.answer, "重试成功，保留原问题") }
            ai.question = String(repeating: "长消息", count: 3000); try await Task.sleep(for: .milliseconds(100))
            try snapshot(host, folder.appendingPathComponent("limit-\(width).png")); XCTAssertTrue(ai.messageTooLong)
            ai.question = ai.submittedQuestion; window.close()
        }
        store.aiNotifications.receive(ai, state: "failed")
        let inbox = NSHostingView(rootView: AISessionInbox(notifications: store.aiNotifications).environmentObject(store)); inbox.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 580), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = inbox; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); try snapshot(inbox, folder.appendingPathComponent("inbox.png"))
        try press(inbox, "axon-ai-inbox-read-all"); XCTAssertEqual(store.aiNotifications.unreadCount, 0)
        let field = try XCTUnwrap(objects(inbox).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "搜索会话、目标和任务状态" })
        field.stringValue = "没有匹配"; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field)); field.sendAction(field.action, to: field.target)
        try await Task.sleep(for: .milliseconds(100)); try snapshot(inbox, folder.appendingPathComponent("inbox-empty.png")); XCTAssertNotNil(objects(inbox).first { read($0, "accessibilityIdentifier") as? String == "axon-ai-inbox-empty" })
    }
    private func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
    private func objects(_ view: NSView) -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) { guard seen.insert(ObjectIdentifier(object)).inserted else { return }; result.append(object); for child in read(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }; if let view = object as? NSView { for child in view.subviews { visit(child) } } }
        visit(view); return result
    }
    private func press(_ view: NSView, _ id: String) throws {
        let target = try XCTUnwrap(objects(view).first { read($0, "accessibilityIdentifier") as? String == id })
        let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(target.method(for: selector), to: Press.self)(target, selector))
    }
    private func snapshot(_ view: NSView, _ path: URL) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: path)
    }
}
