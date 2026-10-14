import XCTest
@testable import TabbyNative

@MainActor final class AIProjectGuidanceTests: XCTestCase {
    func testRepositoryScopePriorityAndPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-guidance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "parent coding style".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "child generic guidance".write(to: child.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "child axon style".write(to: child.appendingPathComponent("AXON.md"), atomically: true, encoding: .utf8)
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: child.path, valid: { true }, execute: { _, _ in XCTFail("Guidance must not use shell"); return .init(output: "", exitCode: 0) })
        executor.fileBackend = { LocalFiles() }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        let items = try await AIProjectGuidance.collect(directory: child.path, executor: executor, policy: policy)
        XCTAssertEqual(items.map { ($0.path as NSString).lastPathComponent }, ["AGENTS.md", "AXON.md"])
        XCTAssertTrue(items[0].text.contains("parent coding style")); XCTAssertTrue(items[1].text.contains("child axon style"))
        let prompt = AIProjectGuidance.prompt(items, global: "Prefer concise comments")
        XCTAssertTrue(prompt.contains("never execution permission")); XCTAssertTrue(prompt.contains("Prefer concise comments"))
        policy.approvalMode = .everyTime
        let denied = try await AIProjectGuidance.collect(directory: child.path, executor: executor, policy: policy)
        XCTAssertTrue(denied.isEmpty)
    }
    func testNoRepositoryDoesNotLoadParentAndSymlinkIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-guidance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "unrelated parent".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("AGENTS.md"), withDestinationURL: root.appendingPathComponent("AGENTS.md"))
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: child.path, valid: { true }, execute: { _, _ in .init(output: "", exitCode: 0) }); executor.fileBackend = { LocalFiles() }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        let items = try await AIProjectGuidance.collect(directory: child.path, executor: executor, policy: policy)
        XCTAssertTrue(items.isEmpty)
    }
    func testChildGuidanceIsNotPromotedAndLongInstructionsAreComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-guidance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let text = String(repeating: "Workflow preferences. ", count: 350) + "END-SCOPE-REQUIREMENT"
        try text.write(to: child.appendingPathComponent("AXON.md"), atomically: true, encoding: .utf8)
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: child.path, valid: { true }, execute: { _, _ in .init(output: "", exitCode: 0) })
        executor.fileBackend = { LocalFiles() }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        let items = try await AIProjectGuidance.collect(directory: child.path, executor: executor, policy: policy)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.path, child.appendingPathComponent("AXON.md").path)
        XCTAssertTrue(items.first?.text.hasSuffix("END-SCOPE-REQUIREMENT") == true)
    }

}
