import XCTest
@testable import TabbyNative

@MainActor final class AIProjectReadTests: XCTestCase {
    func testFurtherLinesRetrievalAndSymlinkRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-project-read-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("service.swift")
        try (1...300).map { "line \($0) ServiceHealth" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: root.path, valid: { true }, execute: { _, _ in XCTFail("No shell for project reads"); return .init(output: "", exitCode: 0) })
        executor.fileBackend = { LocalFiles() }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        func action(_ tool: String, _ values: [String: Any]) throws -> AIAgentAction {
            .init(tool: tool, argument: String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8), reason: "Inspect project", path: nil, find: nil, replacement: nil)
        }
        let range = try action("read_file_range", ["path": file.path, "startLine": 150, "endLine": 152])
        _ = try range.command(os: "Linux")
        let result = try await executor.readProjectAction(range, policy: policy)
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.output.contains("150: line 150")); XCTAssertFalse(result.output.contains("149: line"))
        let search = try action("search_files", ["path": root.path, "query": "ServiceHealth"])
        let found = try await executor.readProjectAction(search, policy: policy)
        XCTAssertTrue(found.output.contains(file.path)); XCTAssertTrue(found.output.contains("NOT exhaustive"))
        let link = root.appendingPathComponent("link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linked = try action("read_file_range", ["path": link.path, "startLine": 1, "endLine": 3])
        let rejected = try await executor.readProjectAction(linked, policy: policy)
        XCTAssertEqual(rejected.exitCode, 1)
        XCTAssertThrowsError(try AIProjectReadRequest.decode("{\"path\":\"/file\",\"startLine\":1,\"endLine\":500}", search: false))
        let secret = try action("read_file_range", ["path": root.appendingPathComponent(".env").path, "startLine": 1, "endLine": 3])
        let protected = try await executor.readProjectAction(secret, policy: policy)
        XCTAssertEqual(protected.exitCode, 1)
    }
}
