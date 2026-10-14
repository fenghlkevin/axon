import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AIConversationForkTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTFail("Timed out")
    }
    func testBranchTruncationIndependentPersistenceAndHistoricalEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ai.json")
        var prompts: [String] = []
        let ai = AIAssistant(fileURL: file, modelResponder: { prompt, _, _ in prompts.append(prompt); return "answer \(prompts.count)" })
        for question in ["first", "second", "excluded third"] { ai.question = question; ai.send(); try await wait { !ai.busy } }
        let original = try XCTUnwrap(ai.taskRecords.first)
        XCTAssertTrue(ai.forkConversation(original, through: 2)); XCTAssertEqual(ai.taskRecords.count, 2)
        let branch = try XCTUnwrap(ai.taskRecords.last)
        XCTAssertEqual(branch.parentConversationID, original.id); XCTAssertEqual(branch.forkTurnCount, 2)
        XCTAssertEqual(branch.turns?.map(\.question), ["first", "second"])
        XCTAssertFalse(branch.transcript.contains("excluded third")); XCTAssertNil(branch.recovery); XCTAssertNil(branch.verification); XCTAssertNil(branch.workingMemory)
        XCTAssertEqual(prompts.count, 3); XCTAssertNil(ai.pendingApproval); XCTAssertFalse(ai.interactiveTaskApproved)
        ai.question = "branch follow-up"; ai.send(); try await wait { !ai.busy }
        XCTAssertFalse(prompts.last!.contains("excluded third")); XCTAssertTrue(prompts.last!.contains("second"))
        XCTAssertEqual(ai.taskRecords.first?.turns?.map(\.question), original.turns?.map(\.question))
        XCTAssertEqual(ai.taskRecords.last?.messageCount, 3)
        let reloaded = AIAssistant(fileURL: file); XCTAssertEqual(reloaded.taskRecords.count, 2)
        XCTAssertEqual(reloaded.taskRecords.last?.parentConversationID, original.id)
        reloaded.deleteTask(original.id); XCTAssertEqual(reloaded.taskRecords.count, 1); reloaded.restoreTask(try XCTUnwrap(reloaded.taskRecords.first)); XCTAssertEqual(reloaded.submittedQuestion, "branch follow-up")
    }
    func testBranchNeverInheritsFailedOperationOrExecutionRights() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ai.json"), targetID = UUID(), hostID = UUID()
        var entry = AITaskRecord(id: UUID(), sessionID: targetID, hostID: hostID, target: "original server", question: "append once", transcript: "old unsafe pending tool", summary: "partial", state: "failed", updated: Date(), messageCount: 1,
            turns: [.init(question: "append once", answer: "partial", steps: [], error: "network loss", executed: true)], executed: true)
        entry.verification = AIVerificationState(); entry.verification?.pending = true
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([entry]).write(to: file.deletingPathExtension().appendingPathExtension("tasks.json"))
        var modelCalls = 0, writes = 0
        let ai = AIAssistant(fileURL: file, modelResponder: { _, _, _ in modelCalls += 1; return try AIStructuredReply(answer: "done", action: nil).serialized() })
        XCTAssertTrue(ai.forkConversation(entry, through: 1)); XCTAssertNil(ai.taskRecords.last?.verification); XCTAssertNil(ai.taskRecords.last?.recovery)
        XCTAssertFalse(ai.taskRecords.last!.transcript.contains("old unsafe pending tool"))
        let wrong = AICommandExecutor(sessionID: UUID(), source: "other server", directory: "/tmp", valid: { true }, execute: { _, _ in writes += 1; return AICommandResult(output: "", exitCode: 0) })
        ai.question = "continue"; ai.send(executor: wrong)
        XCTAssertFalse(ai.busy); XCTAssertEqual(writes, 0); XCTAssertEqual(modelCalls, 0); XCTAssertTrue(ai.error.contains("original target"))
        XCTAssertFalse(ai.forkConversation(entry, through: 0)); XCTAssertFalse(ai.forkConversation(entry, through: 2))
    }
    func testBusyCannotFork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var hold = false
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in while hold { try await Task.sleep(for: .milliseconds(10)) }; return "answer" })
        ai.question = "first"; ai.send(); try await wait { !ai.busy }; let entry = try XCTUnwrap(ai.taskRecords.first)
        hold = true; ai.question = "second"; ai.send(); XCTAssertFalse(ai.forkConversation(entry, through: 1)); XCTAssertEqual(ai.taskRecords.count, 1); ai.cancel()
    }
    func testNativeForkSelectorAndCreate() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in "已检查服务，下一步可以查看日志。" }); store.ai = ai
        for question in ["检查名称很长的网站服务与后台任务运行情况", "查看服务日志与端口情况"] { ai.question = question; ai.send(); try await wait { !ai.busy } }
        let entry = try XCTUnwrap(ai.taskRecords.first); var created = false
        let view = NSHostingView(rootView: AIConversationForkSheet(ai: ai, entry: entry) { created = true }.environmentObject(store)); view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0193-ui", withIntermediateDirectories: true)
        try snapshot(view, "fork.png")
        try press(view, "axon-ai-fork-turn"); try await Task.sleep(for: .milliseconds(200))
        let menu = try XCTUnwrap(AxonMenuPopover.active)
        try snapshot(try XCTUnwrap(menu.popover.contentViewController?.view), "fork-menu.png")
        XCTAssertTrue(menu.handleKey(126)); XCTAssertTrue(menu.handleKey(36))
        try await Task.sleep(for: .milliseconds(150)); try snapshot(view, "fork-first-turn.png")
        try press(view, "axon-ai-create-fork")
        XCTAssertTrue(created); XCTAssertEqual(ai.taskRecords.count, 2); XCTAssertEqual(ai.taskRecords.last?.forkTurnCount, 1)
    }
    func testHistoryToForkRouteAndNarrowConversation() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in "已检查运行状态，没有进行修改。" }); store.ai = ai
        ai.question = "检查服务状态"; ai.send(); try await wait { !ai.busy }
        for width in [320, 600] {
            let view = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: false, availableHeight: 760).environmentObject(store).frame(width: CGFloat(width), height: 760)); view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); try snapshot(view, "conversation-\(width).png")
            if width == 600 {
                try press(view, "axon-ai-task-history"); try await wait { window.attachedSheet != nil }
                let history = try XCTUnwrap(window.attachedSheet); try await Task.sleep(for: .milliseconds(200)); try snapshot(try XCTUnwrap(history.contentView), "history.png")
                try press(try XCTUnwrap(history.contentView), "axon-ai-fork-conversation")
                try await wait { history.attachedSheet != nil }
                let fork = try XCTUnwrap(history.attachedSheet); try await Task.sleep(for: .milliseconds(200)); try snapshot(try XCTUnwrap(fork.contentView), "fork-route.png")
                try press(try XCTUnwrap(fork.contentView), "axon-ai-create-fork")
                try await wait { ai.taskRecords.count == 2 && window.attachedSheet == nil }
                XCTAssertEqual(ai.taskRecords.last?.forkTurnCount, 1)
            }
            window.close()
        }
    }
    private func snapshot(_ view: NSView, _ name: String) throws {
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0193-ui", withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-0193-ui/" + name))
    }
    private func press(_ view: NSView, _ id: String) throws {
        var seen = Set<ObjectIdentifier>(), objects: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; objects.append(object)
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(visit) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }; visit(view)
        let object = try XCTUnwrap(objects.first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id })
        if let button = object as? NSButton { button.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
}
