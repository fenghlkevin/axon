import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class AITextSearchTests: XCTestCase {
    private func fixture() throws -> (URL, AICommandExecutor, AIExecutionPolicy) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-text-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned-search", directory: root.path, valid: { true }, execute: { _, _ in XCTFail("Search must not execute shell commands"); return .init(output: "", exitCode: 0) })
        executor.fileBackend = { LocalFiles() }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        return (root, executor, policy)
    }
    private func action(_ path: String, query: String, limit: Int = 50, cursor: String? = nil, sensitive: Bool = true) throws -> AIAgentAction {
        var fields: [String: Any] = ["path": path, "query": query, "limit": limit, "caseSensitive": sensitive]
        if let cursor { fields["cursor"] = cursor }
        return .init(tool: "search_text", argument: String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self), reason: "查找相关代码内容", path: nil, find: nil, replacement: nil)
    }
    private func next(_ result: AICommandResult) -> String? {
        let value = result.output.components(separatedBy: "\n").first { $0.hasPrefix("Next cursor: ") }.map { String($0.dropFirst("Next cursor: ".count)) }
        return value == "none" ? nil : value
    }
    func testLiteralUnicodePaginationNoDuplicatesAndChangedScopeInvalidatesCursor() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("worker.swift")
        try "第一行 literal.*\nsecond literal.*\n第三行 literal.*\nnot a match".write(to: file, atomically: true, encoding: .utf8)
        let first = try await executor.readProjectAction(action(root.path, query: "literal.*", limit: 1), policy: policy)
        XCTAssertEqual(first.exitCode, 0); XCTAssertTrue(first.output.contains(file.path + ":1:")); XCTAssertFalse(first.output.contains(file.path + ":2:"))
        let cursor = try XCTUnwrap(next(first))
        let second = try await executor.readProjectAction(action(root.path, query: "literal.*", limit: 1, cursor: cursor), policy: policy)
        XCTAssertTrue(second.output.contains(file.path + ":2:")); XCTAssertFalse(second.output.contains(file.path + ":1:"))
        let third = try await executor.readProjectAction(action(root.path, query: "literal.*", cursor: try XCTUnwrap(next(second))), policy: policy)
        XCTAssertTrue(third.output.contains(file.path + ":3:")); XCTAssertNil(next(third))
        let wrongQuery = try await executor.readProjectAction(action(root.path, query: "other", cursor: cursor), policy: policy)
        XCTAssertEqual(wrongQuery.exitCode, 1)
        try "changed search scope".write(to: file, atomically: true, encoding: .utf8)
        let changed = try await executor.readProjectAction(action(root.path, query: "literal.*", cursor: cursor), policy: policy)
        XCTAssertEqual(changed.exitCode, 1); XCTAssertTrue(changed.output.contains("重新搜索"))
        XCTAssertThrowsError(try AITextSearchRequest.decode("{\"path\":\"/tmp\",\"query\":\"x\",\"limit\":0}"))
        XCTAssertThrowsError(try AITextSearchRequest.decode("{\"path\":\"/tmp\",\"query\":\"x\",\"command\":\"rm\"}"))
    }
    func testNestedIgnoresInheritedScopeAndNonNegotiableExclusions() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("src"), excluded = root.appendingPathComponent("excluded"), generated = child.appendingPathComponent("node_modules")
        for directory in [root.appendingPathComponent(".git"), child, excluded, generated] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try "*.log\n/root-only.txt\nexcluded/\n!excluded/file.txt\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "!keep.log\n*.private\n!secret.json\n!node_modules/\n".write(to: child.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for name in ["src/keep.log", "src/drop.log", "src/root-only.txt", "src/config.private", "root-only.txt", "excluded/file.txt", "src/secret.json", "src/node_modules/index.js", "src/worker.txt"] {
            try "NEEDLE".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("link.txt"), withDestinationURL: child.appendingPathComponent("worker.txt"))
        let result = try await executor.readProjectAction(action(root.path, query: "NEEDLE"), policy: policy)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("src/keep.log:1:")); XCTAssertTrue(result.output.contains("src/root-only.txt:1:")); XCTAssertTrue(result.output.contains("src/worker.txt:1:"))
        for hidden in ["src/drop.log", "src/config.private", "excluded/file.txt", "src/secret.json", "src/node_modules/index.js", "src/link.txt"] { XCTAssertFalse(result.output.contains(hidden + ":1:"), hidden) }
        XCTAssertFalse(result.output.contains(root.path + "/root-only.txt:1:"))
        let inside = try await executor.readProjectAction(action(child.path, query: "NEEDLE"), policy: policy)
        XCTAssertFalse(inside.output.contains("src/drop.log:1:")); XCTAssertTrue(inside.output.contains("src/keep.log:1:"))
        let automatic = try await AIAutomaticContext.collect(goal: "项目 NEEDLE worker", directory: root.path, executor: executor, policy: policy)
        XCTAssertFalse(automatic.contains { $0.path.hasSuffix("config.private") || $0.path.hasSuffix("drop.log") || $0.path.contains("excluded/") })
    }
    func testCaseSensitivityRedactionAndPermissionExclusion() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try "Hello\npassword=hiddenvalue HELLO\nhello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "hello".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let exact = try await executor.readProjectAction(action(root.path, query: "hello"), policy: policy)
        XCTAssertFalse(exact.output.contains("a.txt:1:")); XCTAssertTrue(exact.output.contains("a.txt:3:"))
        let folded = try await executor.readProjectAction(action(root.path, query: "hello", sensitive: false), policy: policy)
        XCTAssertTrue(folded.output.contains("a.txt:1:")); XCTAssertTrue(folded.output.contains("a.txt:2:")); XCTAssertFalse(folded.output.contains("hiddenvalue"))
        var denied = policy; denied.rules = "deny|.*|read_file|.*b[.]txt"
        let filtered = try await executor.readProjectAction(action(root.path, query: "hello"), policy: denied)
        XCTAssertFalse(filtered.output.contains("b.txt:1:")); XCTAssertTrue(filtered.output.contains("a.txt:3:"))
        denied.rules = "deny|.*|search_text|.*"
        let blocked = try await executor.readProjectAction(action(root.path, query: "hello"), policy: denied)
        XCTAssertEqual(blocked.exitCode, 1)
    }
    func testUnreadableExistingIgnoreSkipsSubtreeAndPermissionChangesPage() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("private-scope"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "NEEDLE root".write(to: root.appendingPathComponent("allowed.txt"), atomically: true, encoding: .utf8)
        try "NEEDLE hidden".write(to: child.appendingPathComponent("worker.txt"), atomically: true, encoding: .utf8)
        try Data([255]).write(to: child.appendingPathComponent(".axonignore"))
        let result = try await executor.readProjectAction(action(root.path, query: "NEEDLE"), policy: policy)
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.output.contains("allowed.txt:1:")); XCTAssertFalse(result.output.contains("NEEDLE hidden"))
        let automatic = try await AIAutomaticContext.collect(goal: "NEEDLE worker", directory: root.path, executor: executor, policy: policy)
        XCTAssertFalse(automatic.contains { $0.path.contains("private-scope/") })
        try "# valid now".write(to: child.appendingPathComponent(".axonignore"), atomically: true, encoding: .utf8)
        let first = try await executor.readProjectAction(action(root.path, query: "NEEDLE", limit: 1), policy: policy)
        let cursor = try XCTUnwrap(next(first))
        // Advanced path deny changes the permitted search scope; a prior cursor is not authority.
        var denied = policy; denied.rules = "deny|.*|read_file|.*worker[.]txt"
        let second = try await executor.readProjectAction(action(root.path, query: "NEEDLE", cursor: cursor), policy: denied)
        XCTAssertEqual(second.exitCode, 1); XCTAssertTrue(second.output.contains("重新搜索"))
    }
    func testBinaryLongLinesAndIgnoreChangeDuringPage() async throws {
        let (temporary, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: temporary) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("search-change-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("worker.txt")
        try (String(repeating: "a", count: 5000) + "NEEDLE tail").write(to: plain, atomically: true, encoding: .utf8)
        try Data([78,69,69,68,76,69,0]).write(to: root.appendingPathComponent("binary.dat"))
        let result = try await executor.readProjectAction(action(root.path, query: "NEEDLE"), policy: policy)
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.output.contains("worker.txt:1: …")); XCTAssertTrue(result.output.contains("NEEDLE tail"))
        XCTAssertTrue(result.output.contains("non-text skipped: 1")); XCTAssertFalse(result.output.contains("binary.dat:1:")); XCTAssertLessThan(result.output.utf8.count, 1500)
        // Wrapper uses canonical paths: it must not receive special local alias exemptions.
        let canonical = root.resolvingSymlinksInPath()
        let ignore = canonical.appendingPathComponent(".gitignore")
        try "# initially included".write(to: ignore, atomically: true, encoding: .utf8)
        executor.fileBackend = { SearchChangingEndpoint(target: canonical.appendingPathComponent("worker.txt").path, ignore: ignore.path) }
        let changed = try await executor.readProjectAction(action(canonical.path, query: "NEEDLE"), policy: policy)
        XCTAssertEqual(changed.exitCode, 1); XCTAssertTrue(changed.output.contains("重新搜索"), changed.output); XCTAssertFalse(changed.output.contains("NEEDLE tail"))
    }
    func testAgentFollowsSearchPagesAndRenderedResultsToggle() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("worker.swift")
        try "first Needle\nsecond Needle\nthird Needle".write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; session.updateShellDirectory(root.path)
        store.sessions = [session]; store.activeSession = session.id
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { feedback, _, _ in
            round += 1
            var cursor: String?
            if round > 1 {
                let tail = try XCTUnwrap(feedback.range(of: "Next cursor: ", options: .backwards))
                let value = String(feedback[tail.upperBound...].prefix(while: { !$0.isNewline }))
                if value == "none" { return try AIStructuredReply(answer: "查找到 3 行匹配内容，分别位于 worker.swift 第 1、2、3 行。", action: nil).serialized() }
                cursor = value
            }
            return try AIStructuredReply(answer: "继续查找下一页相关内容。", action: self.action(work.path, query: "Needle", limit: 1, cursor: cursor)).serialized()
        })
        store.ai = ai; ai.executionChannel = .independent
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        let executor = AICommandExecutor(sessionID: session.id, source: "本机 macOS", directory: root.path, valid: { true }, execute: { command, _ in
            XCTAssertTrue(command.contains("uname"), command); return .init(output: "Darwin\n" + root.path, exitCode: 0)
        }); executor.fileBackend = { LocalFiles() }
        ai.prepare(source: executor.source, text: "", sessionID: session.id, question: "逐页查找 Needle 的所有匹配行"); ai.send(executor: executor)
        for _ in 0..<600 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(round, 4, ai.taskRecords.last?.transcript ?? "no transcript")
        let pages = ai.steps.filter { $0.tool == "search_text" }
        XCTAssertEqual(pages.count, 3)
        for (index, page) in pages.enumerated() { XCTAssertEqual(page.exitCode, 0); XCTAssertTrue(page.output.contains(file.path + ":\(index + 1):")) }
        XCTAssertTrue(ai.answer.contains("3 行")); XCTAssertEqual(ai.taskRecords.count, 1)
        let shots = URL(fileURLWithPath: "/tmp/axon-0198-ui"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        for width: CGFloat in [320, 600] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 900).environmentObject(store).frame(width: width, height: 900)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(180)); try capture(host, shots.appendingPathComponent("search-closed-\(Int(width)).png"))
            try press(host, "axon-ai-reply-actions"); try await Task.sleep(for: .milliseconds(150))
            try capture(host, shots.appendingPathComponent("search-steps-\(Int(width)).png"))
            try press(host, "axon-ai-search-step"); try await Task.sleep(for: .milliseconds(150))
            try capture(host, shots.appendingPathComponent("search-output-\(Int(width)).png"))
            try press(host, "axon-ai-search-step"); try press(host, "axon-ai-reply-actions")
            try await Task.sleep(for: .milliseconds(100)); try capture(host, shots.appendingPathComponent("search-reclosed-\(Int(width)).png"))
            window.close()
        }
    }
    func testRealOriginalAgentUsesLiteralSearch() async throws {
        guard ProcessInfo.processInfo.environment["AXON_TEST_CODEX"] == "1" else { throw XCTSkip("Opt-in authenticated original Agent search") }
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("health.swift")
        try "first ExactNeedle\nsecond ExactNeedle\nthird ExactNeedle".write(to: file, atomically: true, encoding: .utf8)
        // Initial OS observation is simulated; all project reads below use real filesystem tools.
        let live = AICommandExecutor(sessionID: executor.sessionID, source: "owned real search", directory: work.path, valid: { true }, execute: { command, _ in
            XCTAssertTrue(command.contains("uname"), command); return .init(output: "Darwin\n" + work.path, exitCode: 0)
        }); live.fileBackend = { LocalFiles() }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); ai.settings.executionPolicy = policy; ai.executionChannel = .independent
        let models = try await CodexModelCatalog.discover(settings: ai.settings)
        let model = try XCTUnwrap(models.first { $0.efforts.contains("low") }); ai.settings.codexModel = model.slug; ai.settings.codexReasoningEffort = "low"
        ai.prepare(source: live.source, text: "", sessionID: live.sessionID, question: "使用 search_text 在 " + work.path + " 中逐页搜索字面文本 ExactNeedle，limit 固定为 1，使用下一页 cursor 直到 none。报告每条匹配的文件和行号。只读，不运行命令，不修改文件。")
        ai.send(executor: live); defer { ai.cancel() }
        for _ in 0..<1800 where ai.busy { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error)
        let pages = ai.steps.filter { $0.tool == "search_text" && $0.exitCode == 0 }
        XCTAssertGreaterThanOrEqual(pages.count, 3)
        for line in 1...3 { XCTAssertTrue(pages.contains { $0.output.contains(file.path + ":\(line):") }) }
        XCTAssertTrue(pages.contains { $0.output.contains("Next cursor: none") }); XCTAssertFalse(ai.answer.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first ExactNeedle\nsecond ExactNeedle\nthird ExactNeedle")
    }
    private func capture(_ view: NSView, _ url: URL) throws {
        view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
    private func press(_ view: NSView, _ id: String) throws {
        var objects: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; objects.append(object)
            for child in read(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(view)
        let candidates = objects.filter { read($0, "accessibilityIdentifier") as? String == id }
        XCTAssertFalse(candidates.isEmpty, id)
        let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c)(AnyObject, Selector) -> Bool
        for object in candidates {
            if let button = object as? NSButton { button.performClick(nil); return }
            if unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector) { return }
        }
        XCTFail("Cannot press " + id + ": " + String(describing: candidates.map { [read($0, "accessibilityRole"), read($0, "accessibilityLabel")] }))
    }
    func testIgnorePatternsAgreeWithGitForRepresentativeFilePatterns() throws {
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let patterns = ["*.log", "!keep.log", "/root-only.txt", "a/**/b.txt", "file[0-9].txt", "\\#literal", "\\!literal", "trailing\\ "]
        try patterns.joined(separator: "\n").write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        func git(_ arguments: [String], input: Data? = nil) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", root.path, "-c", "core.excludesFile=/dev/null"] + arguments
            let output = Pipe(); process.standardOutput = output; let errors = Pipe(); process.standardError = errors
            let stdin = Pipe(); process.standardInput = stdin
            try process.run(); if let input { stdin.fileHandleForWriting.write(input) }; try stdin.fileHandleForWriting.close()
            let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); XCTAssertTrue([0,1].contains(process.terminationStatus)); return bytes
        }
        _ = try git(["init", "-q"])
        let paths = ["drop.log", "keep.log", "src/drop.log", "src/keep.log", "root-only.txt", "src/root-only.txt", "a/b.txt", "a/x/y/b.txt", "b.txt", "file7.txt", "filex.txt", "#literal", "!literal", "trailing "]
        let ignored = Set(String(decoding: try git(["check-ignore", "--no-index", "-z", "--stdin"], input: Data((paths.joined(separator: "\0") + "\0").utf8)), as: UTF8.self).split(separator: "\0").map(String.init))
        let rules = patterns.compactMap { AIProjectIgnore.Rule($0, scope: root.path) }
        for path in paths { XCTAssertEqual(AIProjectIgnore.ignored(root.path + "/" + path, directory: false, rules: rules), ignored.contains(path), path) }
    }
}

private actor SearchChangingEndpoint: FileEndpoint {
    let base = LocalFiles(), target: String, ignore: String
    var changed = false
    init(target: String, ignore: String) { self.target = target; self.ignore = ignore }
    func list(_ path: String) async throws -> [FileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> FileEntry { try await base.stat(path) }
    func mkdir(_ path: String) async throws { try await base.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws { try await base.rename(from, to) }
    func delete(_ entry: FileEntry) async throws { try await base.delete(entry) }
    func chmod(_ path: String, _ mode: UInt32) async throws { try await base.chmod(path, mode) }
    func write(_ path: String, offset: UInt64, bytes: Data) async throws { try await base.write(path, offset: offset, bytes: bytes) }
    func read(_ path: String, offset: UInt64, count: Int) async throws -> Data {
        let bytes = try await base.read(path, offset: offset, count: count)
        if path == target && !changed {
            changed = true; try "worker.txt\n".write(toFile: ignore, atomically: true, encoding: .utf8)
        }
        return bytes
    }
}
