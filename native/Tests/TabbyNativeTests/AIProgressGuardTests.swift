import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

final class AIProgressGuardTests: XCTestCase {
    func testRepeatedFailuresStopButChangedEvidenceResets() {
        var guardrail = AIProgressGuard()
        for _ in 0..<3 { guardrail.rejected("forbidden-operation") }
        XCTAssertFalse(guardrail.stalled)
        guardrail.rejected("forbidden-operation"); XCTAssertTrue(guardrail.stalled)
        guardrail.reset(); XCTAssertFalse(guardrail.stalled)
        for _ in 0..<4 { guardrail.observed(tool: "read_file", argument: "/file", output: "old", exitCode: 0) }
        XCTAssertTrue(guardrail.stalled)
        guardrail.observed(tool: "read_file", argument: "/file", output: "new", exitCode: 0)
        XCTAssertFalse(guardrail.stalled)
    }
    @MainActor func testAgentPausesUnchangedObservationsAndRetainsHistory() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-stalled-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var rounds = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in
            rounds += 1
            return try AIStructuredReply(answer: "检查当前状态", action: .init(tool: "inspect_port", argument: "8080", reason: "检查端口", path: nil, find: nil, replacement: nil)).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: "/owned", valid: { true }, execute: { command, _ in .init(output: command.contains("uname") ? "Linux" : "unchanged result", exitCode: 0) })
        ai.prepare(source: "fixture", text: "fixture", sessionID: executor.sessionID, question: "检查端口状态")
        ai.send(executor: executor)
        for _ in 0..<300 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertEqual(rounds, 4)
        XCTAssertTrue(ai.answer.contains("任务已暂停")); XCTAssertFalse(ai.taskRecords.isEmpty)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"; store.ai = ai
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0197-ui", withIntermediateDirectories: true)
        for width in [320, 600] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 900).environmentObject(store).frame(width: CGFloat(width), height: 900)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-0197-ui/stalled-" + String(width) + ".png"))
            window.close()
        }
    }

}
