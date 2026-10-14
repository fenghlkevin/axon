import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class AIContextRecoveryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axon-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func action(_ tool: String, _ argument: String) -> AIAgentAction { .init(tool: tool, argument: argument, reason: "fixture", path: nil, find: nil, replacement: nil) }
    private func wait(_ ai: AIAssistant) async throws {
        for _ in 0..<1000 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }; XCTAssertFalse(ai.busy)
    }
    func testAutomaticContextBoundedRedactedAndPermissionAware() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try "port=8080\npassword=hunter2\n".write(to: root.appendingPathComponent("server.conf"), atomically: true, encoding: .utf8)
        try String(repeating: "bounded-text\n", count: 1000).write(to: root.appendingPathComponent("large.log"), atomically: true, encoding: .utf8)
        try "SECRET".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.conf"), withDestinationURL: root.appendingPathComponent("server.conf"))
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: root.path, valid: { true }, execute: { _,_ in .init(output: "Linux", exitCode: 0) })
        executor.fileBackend = { LocalFiles() }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        let items = try await AIAutomaticContext.collect(goal: "检查 server.conf large.log link.conf .env", directory: root.path, executor: executor, policy: policy)
        XCTAssertEqual(items.count, 2); let first = try XCTUnwrap(items.first); let last = try XCTUnwrap(items.last); XCTAssertTrue(first.text.contains("port=8080")); XCTAssertFalse(first.text.contains("hunter2")); XCTAssertLessThan(last.text.count, 4200)
        XCTAssertFalse(AIAutomaticContext.candidates(goal: "/root/.ssh/config /root/credentials.json /tmp/secret.yml", directory: root.path).contains { AIAutomaticContext.sensitive($0) })
        policy.approvalMode = .everyTime
        let denied = try await AIAutomaticContext.collect(goal: "检查 server.conf", directory: root.path, executor: executor, policy: policy)
        XCTAssertTrue(denied.isEmpty)
    }
    func testCheckpointReloadResumePreservesGoalAndBlocksRepeatedMutation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let goal = "创建脚本并检查"; let check = AIVerificationCheck(goal: goal, tool: "verify_command", argument: "cat /owned/script.sh", expectedOutput: "hello world")
        var writes = 0, round = 0
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: root.path, valid: { true }, execute: { cmd,_ in
            if cmd.contains("printf") { writes += 1; return .init(output: "written", exitCode: 0) }
            return .init(output: cmd.contains("uname") ? "Linux\n" + root.path : "hello world", exitCode: 0)
        })
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            round += 1; if round == 1 { return try AIStructuredReply(answer: "write", action: self.action("command", "printf hello"), checks: [check]).serialized() }
            throw URLError(.networkConnectionLost)
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .independent
        ai.prepare(source: "owned", text: "", sessionID: executor.sessionID, question: goal); ai.send(executor: executor); try await wait(ai)
        XCTAssertEqual(writes, 1); XCTAssertTrue(ai.canResume)
        var resumedRound = 0
        let restored = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt,_,_ in
            resumedRound += 1; XCTAssertTrue(prompt.contains("Original goal: " + goal))
            if resumedRound == 1 { return try AIStructuredReply(answer: "duplicate", action: self.action("command", "printf hello")).serialized() }
            if resumedRound == 2 { XCTAssertTrue(prompt.contains("Recovery rejected")); return try AIStructuredReply(answer: "check", action: self.action("verify_command", check.argument)).serialized() }
            return try AIStructuredReply(answer: "verified", action: nil).serialized()
        })
        restored.settings.executionPolicy = policy
        restored.prepare(source: "owned", text: "", sessionID: executor.sessionID, question: "")
        restored.restoreTask(try XCTUnwrap(restored.taskRecords.last)); restored.resume(executor: executor); try await wait(restored)
        XCTAssertTrue(restored.error.isEmpty, restored.error); XCTAssertEqual(restored.answer, "verified"); XCTAssertEqual(writes, 1)
        XCTAssertEqual(restored.executionChannel, .independent)
    }
    func testUncertainSubmissionIsRecordedBeforeExecutionAndCannotReplay() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ai.json")
        let check = AIVerificationCheck(goal: "modify", tool: "verify_command", argument: "cat /owned/file", expectedOutput: "changed")
        var observedCheckpoint = false
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: root.path, valid: { true }, execute: { command,_ in
            if command.contains("printf") {
                let journal = try JSONDecoder().decode([AITaskRecord].self, from: Data(contentsOf: file.deletingPathExtension().appendingPathExtension("tasks.json")))
                observedCheckpoint = journal.last?.recovery?.uncertainMutation == true
                throw URLError(.networkConnectionLost)
            }
            return .init(output: "Linux", exitCode: 0)
        })
        let ai = AIAssistant(fileURL: file, modelResponder: { _,_,_ in try AIStructuredReply(answer: "write", action: self.action("command", "printf changed"), checks: [check]).serialized() })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .independent
        ai.prepare(source: "owned", text: "", sessionID: executor.sessionID, question: "modify"); ai.send(executor: executor); try await wait(ai)
        XCTAssertTrue(observedCheckpoint)
        let recovery = try XCTUnwrap(ai.taskRecords.last?.recovery); XCTAssertTrue(recovery.uncertainMutation)
        XCTAssertTrue(recovery.blocks(tool: "command", argument: "a different write", mutation: true)); XCTAssertFalse(recovery.blocks(tool: "read_file", argument: "/owned/file", mutation: false))
        let other = AICommandExecutor(sessionID: UUID(), source: "wrong", directory: nil, valid: { true }, execute: { _,_ in XCTFail("Wrong target must not execute"); return .init(output: "", exitCode: 0) })
        ai.resume(executor: other); XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.contains("原目标"))
    }
    func testRecoveryAndContextNativeUIAndResumeClick() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try "port=8080".write(to: root.appendingPathComponent("server.conf"), atomically: true, encoding: .utf8)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; session.updateShellDirectory(root.path)
        store.sessions = [session]; store.activeSession = session.id
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            round += 1; if round == 1 { throw AppFailure.message("Temporary model failure / 模型暂时不可用") }
            return try AIStructuredReply(answer: "现场已核对，可继续处理。", action: nil).serialized()
        })
        store.ai = ai; var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .independent
        let executor = AICommandExecutor(sessionID: session.id, source: "Local macOS / 本机 macOS", directory: root.path, valid: { true }, execute: { _,_ in .init(output: "Darwin", exitCode: 0) }); executor.fileBackend = { LocalFiles() }
        ai.prepare(source: executor.source, text: "", sessionID: session.id, question: "检查 server.conf"); ai.send(executor: executor); try await wait(ai)
        XCTAssertTrue(ai.canResume); XCTAssertEqual(ai.automaticContext.count, 1)
        let shots = URL(fileURLWithPath: "/tmp/axon-0189-ui"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        for width: CGFloat in [320,600] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 900).environmentObject(store).frame(width: width, height: 900)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: width,height: 900), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            func shot(_ name: String) throws { host.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds,to: rep); try XCTUnwrap(rep.representation(using: .png,properties: [:])).write(to: shots.appendingPathComponent(name)) }
            try shot("recovery-" + String(Int(width)) + ".png")
            if width == 600 {
                let contextControl = try XCTUnwrap(accessible(host).first { read($0,"accessibilityIdentifier") as? String == "axon-ai-related-context" })
                let contextSelector = NSSelectorFromString("accessibilityPerformPress"); typealias ContextPress = @convention(c)(AnyObject,Selector)->Bool
                XCTAssertTrue(unsafeBitCast(contextControl.method(for: contextSelector), to: ContextPress.self)(contextControl,contextSelector))
                try await Task.sleep(for: .milliseconds(100)); try shot("related-open-600.png")
                XCTAssertTrue(unsafeBitCast(contextControl.method(for: contextSelector), to: ContextPress.self)(contextControl,contextSelector))
                let button = try XCTUnwrap(accessible(host).first { read($0,"accessibilityIdentifier") as? String == "axon-ai-resume" })
                let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c)(AnyObject,Selector)->Bool
                XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button,selector))
                try await wait(ai); XCTAssertEqual(ai.answer, "现场已核对，可继续处理。"); XCTAssertFalse(ai.canResume)
                try await Task.sleep(for: .milliseconds(100)); try shot("resumed-600.png")
            }
            window.close()
        }
    }

    func testRunningTerminalCommandRecoveredByIDWithoutReplay() async throws {
        _ = NSApplication.shared
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let hook = root.appendingPathComponent("hooks.sh"), file = root.appendingPathComponent("once.log")
        try ShellCommandIntegration.script(token: "recovery-fixture").write(to: hook, atomically: true, encoding: .utf8)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); session.connected = true; session.commandHistoryToken = "recovery-fixture"
        let terminal = LocalTerminal(frame: NSRect(x: 0,y: 0,width: 700,height: 500)); terminal.ownerSession = session; terminal.terminalDelegate = session; session.terminal = terminal
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile","--rcfile",hook.path,"-i"], environment: ["HOME=" + root.path,"PATH=/usr/bin:/bin","TERM=xterm-256color","PS1=OWNED> "], currentDirectory: root.path)
        defer { terminal.terminate() }
        for _ in 0..<500 { if session.commandHistoryReady && session.aiShellInput.line == "" { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.commandHistoryReady)
        let check = AIVerificationCheck(goal: "追加一次", tool: "read_file", argument: file.path, expectedOutput: "once")
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            round += 1; if round == 1 { return try AIStructuredReply(answer: "run", action: self.action("terminal_execute", "sleep 4; printf once >> " + SnippetParameters.shellArgument(file.path)), checks: [check]).serialized() }
            throw AppFailure.message("Model unavailable / 模型不可用")
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        func executor() -> AICommandExecutor {
            let value = AICommandExecutor(sessionID: session.id, source: "owned", directory: root.path, valid: { session.connected }, execute: { _,_ in XCTFail("Must use current PTY"); return .init(output: "",exitCode: 0) })
            value.terminalBridge = AITerminalBridge(session: session); value.fileBackend = { LocalFiles() }; return value
        }
        ai.prepare(source: "owned",text: "",sessionID: session.id,question: "追加一次"); ai.send(executor: executor()); try await wait(ai)
        let entry = try XCTUnwrap(ai.taskRecords.last); let id = try XCTUnwrap(entry.recovery?.runningID)
        XCTAssertEqual(entry.turns?.last?.steps.last?.executionID, id)
        var resumed = 0
        let restored = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            resumed += 1
            if resumed == 1 { return try AIStructuredReply(answer: "wait", action: self.action("terminal_result",id.uuidString)).serialized() }
            if resumed == 2 { return try AIStructuredReply(answer: "verify", action: self.action("read_file",file.path)).serialized() }
            return try AIStructuredReply(answer: "verified",action: nil).serialized()
        }); restored.settings.executionPolicy = policy
        restored.prepare(source: "owned",text: "",sessionID: session.id,question: ""); restored.restoreTask(entry); restored.resume(executor: executor()); try await wait(restored)
        XCTAssertTrue(restored.error.isEmpty, restored.error); XCTAssertEqual(restored.answer,"verified")
        XCTAssertEqual(try String(contentsOf: file,encoding: .utf8),"once")
        XCTAssertEqual(session.aiCommandCapture.finished.filter { $0.command.contains("printf once") }.count,1)
    }

    func testJournalWriteFailurePreventsMutationSubmission() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("ai.json")
        try FileManager.default.createDirectory(at: settings.deletingPathExtension().appendingPathExtension("tasks.json"), withIntermediateDirectories: true)
        var writes = 0
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: root.path, valid: { true }, execute: { command,_ in
            if command.contains("printf") { writes += 1 }
            return .init(output: "Linux",exitCode: 0)
        })
        let check = AIVerificationCheck(goal: "write",tool: "verify_command",argument: "cat /owned/file",expectedOutput: "changed")
        let ai = AIAssistant(fileURL: settings, modelResponder: { _,_,_ in try AIStructuredReply(answer: "write",action: self.action("command","printf changed"),checks: [check]).serialized() })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .independent
        ai.prepare(source: "owned",text: "",sessionID: executor.sessionID,question: "write"); ai.send(executor: executor); try await wait(ai)
        XCTAssertEqual(writes,0); XCTAssertFalse(ai.error.isEmpty)
    }
    private func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
    private func accessible(_ view: NSView) -> [NSObject] {
        var values: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) { guard seen.insert(ObjectIdentifier(object)).inserted else { return }; values.append(object); for child in read(object,"accessibilityChildren") as? [NSObject] ?? [] { visit(child) }; if let view = object as? NSView { for child in view.subviews { visit(child) } } }
        visit(view); return values
    }

}
