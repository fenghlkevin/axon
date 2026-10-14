import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

@MainActor final class AIProjectContinuityTests: XCTestCase {
    func testProviderToolHistoryPairsAndBounds() throws {
        let reply = try AIStructuredReply(answer: "inspect", action: .init(tool: "read_file", argument: "/app/a", reason: "inspect", path: nil, find: nil, replacement: nil)).serialized()
        for backend in [AIBackend.claude, .chatgpt] {
            var history = AIProviderConversation()
            XCTAssertEqual(history.messages(backend: backend, feedback: "goal").count, 1)
            for i in 0..<12 { try history.accept(reply, id: "call_\(i)", feedback: "actual result \(i)") }
            let messages = history.messages(backend: backend, feedback: "latest actual result")
            XCTAssertEqual(messages.count, 17)
            let data = try JSONSerialization.data(withJSONObject: messages)
            let body = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(body.contains("call_11")); XCTAssertTrue(body.contains("latest actual result")); XCTAssertFalse(body.contains("call_0"))
            if backend == .chatgpt { XCTAssertEqual(messages.last?["role"] as? String, "tool") }
            else { XCTAssertEqual((messages.last?["content"] as? [[String: Any]])?.first?["type"] as? String, "tool_result") }
            XCTAssertThrowsError(try history.accept(reply, id: "call_11", feedback: "duplicate"))
        }
    }
    private func fixture() throws -> (URL, AICommandExecutor, AIExecutionPolicy) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-project-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: root.path, valid: { true }, execute: { _,_ in .init(output: "Linux", exitCode: 0) })
        executor.fileBackend = { LocalFiles() }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        return (root, executor, policy)
    }
    func testProjectSearchRespectsIgnoreSecretsAndLinks() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "listen_port = 8080".write(to: root.appendingPathComponent("src/server.py"), atomically: true, encoding: .utf8)
        try "ignored/\n*.private\n".write(to: root.appendingPathComponent(".axonignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try "8080 private".write(to: root.appendingPathComponent("ignored/server.py"), atomically: true, encoding: .utf8)
        try "token=sk-privateabcdefgh".write(to: root.appendingPathComponent("secret.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let items = try await AIAutomaticContext.collect(goal: "检查项目 server 8080", directory: root.path, executor: executor, policy: policy)
        XCTAssertTrue(items.contains { $0.path.hasSuffix("src/server.py") })
        XCTAssertFalse(items.contains { $0.path.contains("ignored") || $0.path.contains("secret") || $0.path.contains("escape") })
        XCTAssertTrue(AIAutomaticContext.ignored("src/a.private", patterns: ["*.private"]))
        var restricted = policy; restricted.approvalMode = .everyTime
        let denied = try await AIAutomaticContext.collect(goal: "检查项目 server 8080", directory: root.path, executor: executor, policy: restricted)
        XCTAssertTrue(denied.isEmpty)
    }
    func testDeepContentRetrievalBeyondFileHeaderAndCandidatePrefix() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<30 { try "unrelated = true".write(to: root.appendingPathComponent(String(format: "a%02d.py", i)), atomically: true, encoding: .utf8) }
        let path = root.appendingPathComponent("zworker.py")
        try (String(repeating: "# unrelated padding\n", count: 180) + "def resolveInvoice():\n    return 8081\n").write(to: path, atomically: true, encoding: .utf8)
        let items = try await AIAutomaticContext.collect(goal: "检查项目 resolveInvoice 8081", directory: root.path, executor: executor, policy: policy)
        let item = try XCTUnwrap(items.first { $0.path == path.path })
        XCTAssertTrue(item.text.contains("181: def resolveInvoice")); XCTAssertFalse(item.text.contains("1: # unrelated"))
        XCTAssertLessThanOrEqual(item.text.utf8.count, 4096)
        XCTAssertTrue(AIAutomaticContext.searchTerms("查找8081端口 resolveInvoice").contains("8081"))
    }

    func testChildGuidanceReplansBeforeAnyEdit() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let file = child.appendingPathComponent("service.conf")
        try "port=8080".write(to: file, atomically: true, encoding: .utf8)
        try "Child workflow: ask before updating port settings.".write(to: child.appendingPathComponent("AXON.md"), atomically: true, encoding: .utf8)
        let goal = "Update service port", check = AIVerificationCheck(goal: "Update service port", tool: "read_file", argument: file.path, expectedOutput: "port=8081")
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { feedback, _, _ in
            round += 1
            if round == 1 { return try AIStructuredReply(answer: "Update port", action: .init(tool: "replace_file", argument: nil, reason: "Update port", path: file.path, find: "8080", replacement: "8081"), checks: [check]).serialized() }
            XCTAssertTrue(feedback.contains("Newly discovered directory guidance"))
            XCTAssertTrue(feedback.contains("Child workflow"))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "port=8080")
            return try AIStructuredReply(answer: "Need clarification", action: .init(tool: "report_blocker", argument: "Need approval for child workflow", reason: "Respect child guidance", path: nil, find: nil, replacement: nil)).serialized()
        })
        ai.settings.executionPolicy = policy
        ai.prepare(source: executor.source, text: "fixture", sessionID: executor.sessionID, question: goal); ai.send(executor: executor)
        for _ in 0..<300 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertEqual(round, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "port=8080")
    }
    func testCombinedEditConflictAndCheckpointRecovery() async throws {
        let (root, executor, policy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.conf"), b = root.appendingPathComponent("b.conf")
        try "port=8080".write(to: a, atomically: true, encoding: .utf8)
        try "port=8080".write(to: b, atomically: true, encoding: .utf8)
        let changes = [a,b].map { AIProjectReplacement(path: $0.path, find: "8080", replacement: "8081") }
        let batch = try await AIProjectEdit(backend: LocalFiles(), changes: changes)
        XCTAssertTrue(batch.preview.contains(a.path)); XCTAssertTrue(batch.preview.contains(b.path))
        try "manual change".write(to: b, atomically: true, encoding: .utf8)
        do { _ = try await batch.apply(); XCTFail("Conflict should stop whole group before first write") } catch { }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "port=8080")
        try "port=8080".write(to: b, atomically: true, encoding: .utf8)
        let next = try await AIProjectEdit(backend: LocalFiles(), changes: changes)
        var checkpoint = AITaskRecovery(goal: "ports", channel: "independent")
        checkpoint.operations.append(.init(tool: "replace_files", argument: "group", mutation: true, files: next.checkpoints))
        _ = try await checkpoint.reconcileFiles(executor: executor, policy: policy)
        XCTAssertEqual(checkpoint.operations[0].state, "not_applied")
        XCTAssertFalse(checkpoint.blocks(tool: "replace_files", argument: "group", mutation: true))
        _ = try await next.apply()
        _ = try await checkpoint.reconcileFiles(executor: executor, policy: policy)
        XCTAssertEqual(checkpoint.operations[0].state, "completed")
        XCTAssertTrue(checkpoint.blocks(tool: "replace_files", argument: "group", mutation: true))
        try "manual concurrent content".write(to: b, atomically: true, encoding: .utf8)
        let report = try await checkpoint.reconcileFiles(executor: executor, policy: policy)
        XCTAssertTrue(report.contains("concurrent")); XCTAssertTrue(checkpoint.uncertainMutation)
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "manual concurrent content")
    }
    func testPolicyChangeBetweenCommitsRestoresWholeGroup() async throws {
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("first.conf"), b = root.appendingPathComponent("second.conf")
        for file in [a,b] { try "port=8080".write(to: file, atomically: true, encoding: .utf8) }
        let edit = try await AIProjectEdit(backend: LocalFiles(), changes: [a,b].map { .init(path: $0.path, find: "8080", replacement: "8081") })
        do {
            var visits = 0
            _ = try await edit.apply { path in visits += 1; if path == b.path && visits == 4 { throw AppFailure.message("policy changed") } }
            XCTFail("Must stop before second commit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("originals restored")) }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "port=8080")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "port=8080")
    }
    func testProjectPolicyCannotBypassGroupOrPerFileDeny() async throws {
        let (root, executor, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("service.conf")
        try "port=8080".write(to: file, atomically: true, encoding: .utf8)
        let argument = String(decoding: try JSONEncoder().encode([AIProjectReplacement(path: file.path, find: "8080", replacement: "8081")]), as: UTF8.self)
        XCTAssertThrowsError(try AIProjectReplacement.decode(String(decoding: JSONEncoder().encode([AIProjectReplacement(path: root.path + "/unused/../service.conf", find: "8080", replacement: "8081")]), as: UTF8.self)))
        for group in [true,false] {
            var round = 0
            let ai = AIAssistant(fileURL: root.appendingPathComponent("deny-\(group).json"), modelResponder: { _,_,_ in
                round += 1
                if round == 1 { return try AIStructuredReply(answer: "change", action: .init(tool: "replace_files", argument: argument, reason: "test", path: nil, find: nil, replacement: nil), checks: [.init(goal: "change", tool: "read_configuration", argument: file.path, expectedOutput: "port=8081")]).serialized() }
                return try AIStructuredReply(answer: "blocked", action: .init(tool: "report_blocker", argument: "denied by policy", reason: "blocked", path: nil, find: nil, replacement: nil)).serialized()
            })
            var policy = AIExecutionPolicy(); policy.approvalMode = group ? .assisted : .fullAccess
            policy.rules = "deny|owned|" + (group ? "replace_files|.*" : "replace_file|" + NSRegularExpression.escapedPattern(for: file.path))
            ai.settings.executionPolicy = policy; ai.executionChannel = .independent
            ai.prepare(source: "owned", text: "", sessionID: executor.sessionID, question: "change"); ai.send(executor: executor)
            for _ in 0..<500 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(ai.busy); XCTAssertNil(ai.pendingApproval); XCTAssertEqual(ai.taskRecords.last?.state, "blocked")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "port=8080")
        }
    }
    func testCombinedProjectDiffNativeApprovalAndVerification() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["application-server.conf", "client-service.conf"].map { root.appendingPathComponent($0) }
        for path in paths { try "port=8080".write(to: path, atomically: true, encoding: .utf8) }
        let goal = "将两个服务配置端口改为8081并检查"
        let changes = paths.map { AIProjectReplacement(path: $0.path, find: "8080", replacement: "8081") }
        let argument = String(decoding: try JSONEncoder().encode(changes), as: UTF8.self)
        let checks = paths.map { AIVerificationCheck(goal: goal, tool: "read_configuration", argument: $0.path, expectedOutput: "port=8081") }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; session.updateShellDirectory(root.path)
        store.sessions = [session]; store.activeSession = session.id
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            round += 1
            if round == 1 { return try AIStructuredReply(answer: "将一起审阅服务和客户端的配置差异，再分别验证端口。", action: .init(tool: "replace_files", argument: argument, reason: "同步更新关联配置", path: nil, find: nil, replacement: nil), checks: checks).serialized() }
            if round <= 3 { return try AIStructuredReply(answer: "检查修改结果", action: .init(tool: "read_configuration", argument: paths[round - 2].path, reason: "检查文件", path: nil, find: nil, replacement: nil)).serialized() }
            return try AIStructuredReply(answer: "两个配置文件已修改并验证。", action: nil).serialized()
        })
        store.ai = ai; ai.executionChannel = .independent
        let executor = AICommandExecutor(sessionID: session.id, source: "Local macOS / 本机 macOS", directory: root.path, valid: { true }, execute: { command,_ in
            if command.contains("uname") { return .init(output: "Darwin", exitCode: 0) }
            return .init(output: "port=8081", exitCode: 0)
        }); executor.fileBackend = { LocalFiles() }
        ai.prepare(source: executor.source, text: "", sessionID: session.id, question: goal); ai.send(executor: executor)
        for _ in 0..<500 { if ai.pendingApproval != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(ai.pendingApproval)
        let shots = URL(fileURLWithPath: "/tmp/axon-0190-ui"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        for width: CGFloat in [320,600] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 900).environmentObject(store).frame(width: width, height: 900)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: width,height: 900), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            try capture(host, to: shots.appendingPathComponent("project-approval-\(Int(width)).png"))
            if width == 600 {
                try press(host, identifier: "axon-ai-approve")
                try await Task.sleep(for: .milliseconds(300))
                let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
                try capture(sheet, to: shots.appendingPathComponent("project-combined-diff.png"))
                try press(sheet, identifier: "axon-ai-apply-diff")
                for _ in 0..<500 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(ai.answer, "两个配置文件已修改并验证。")
                XCTAssertEqual(ai.taskRecords.last?.recovery?.operations.first?.files?.count, 2)
                try await Task.sleep(for: .milliseconds(200)); try capture(host, to: shots.appendingPathComponent("project-verified.png"))
            }
            window.close()
        }
        for path in paths { XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "port=8081") }
    }
    private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
    private func press(_ view: NSView, identifier: String) throws {
        var seen = Set<ObjectIdentifier>(), values: [NSObject] = []
        func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; values.append(object)
            for child in read(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(view)
        let object = try XCTUnwrap(values.first { read($0, "accessibilityIdentifier") as? String == identifier })
        let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c)(AnyObject,Selector)->Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object,selector))
    }

}
