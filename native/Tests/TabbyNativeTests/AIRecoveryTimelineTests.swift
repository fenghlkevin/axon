import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

@MainActor final class AIRecoveryTimelineTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-rc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func executor(_ root: URL) -> AICommandExecutor {
        let value = AICommandExecutor(sessionID: UUID(), source: "owned local", directory: root.path, valid: { true }, execute: { command, _ in .init(output: command.contains("uname") ? "Darwin" : "verified", exitCode: 0) }); value.fileBackend = { LocalFiles() }; return value
    }
    private func wait(_ predicate: () -> Bool) async throws { for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTFail("Timed out") }
    private func prepare(_ root: URL, names: [String] = ["one.txt", "two.txt"]) async throws -> [AIFileProposal] {
        var result: [AIFileProposal] = []
        for name in names { let file = root.appendingPathComponent(name); try "oldA\nkeep\noldB\n".write(to: file, atomically: true, encoding: .utf8); result.append(try await AIFileProposal(backend: LocalFiles(), path: file.path, find: "oldA\nkeep\noldB", replacement: "newA\nkeep\nnewB")) }
        return result
    }
    func testPersistedGroupUndoRedoHunksAndConflict() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = executor(root), timeline = AIFileTimeline(url: root.appendingPathComponent("timeline.json")), proposals = try await prepare(root)
        let id = try timeline.begin(proposals: proposals, executor: executor, taskID: nil, title: "change")
        XCTAssertEqual(timeline.entries.first?.state, "pending")
        _ = try await AIProjectEdit(proposals: proposals).apply(); try timeline.finish(id, state: "applied")
        let loaded = AIFileTimeline(url: timeline.url), entry = try XCTUnwrap(loaded.entries.first)
        XCTAssertEqual(entry.files.count, 2)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: timeline.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let review = AIFileTimelineReview(timeline: loaded, executor: executor, policy: { AIExecutionPolicy() })
        await review.prepare(entry, after: false, paths: [proposals[0].path]); XCTAssertTrue(review.error.isEmpty, review.error)
        XCTAssertEqual(review.review?.files[0].hunks.count, 2)
        review.review?.files[0].hunks[1].selected = false
        await review.apply(origin: entry) { XCTAssertEqual($0, [proposals[0].path]) }
        XCTAssertTrue(review.error.isEmpty, review.error)
        XCTAssertEqual(review.states[proposals[0].path], "recorded")
        XCTAssertEqual(try String(contentsOfFile: proposals[0].path, encoding: .utf8), "oldA\nkeep\nnewB\n")
        XCTAssertEqual(try String(contentsOfFile: proposals[1].path, encoding: .utf8), "newA\nkeep\nnewB\n")
        // Partial hunk undo is its own recorded version; redo it from that entry.
        let undo = try XCTUnwrap(loaded.entries.last)
        await review.prepare(undo, after: false, paths: [proposals[0].path]); await review.apply(origin: undo) { _ in }
        XCTAssertEqual(try String(contentsOfFile: proposals[0].path, encoding: .utf8), "newA\nkeep\nnewB\n")
        await review.prepare(entry, after: false, paths: Set(entry.files.map(\.path))); await review.apply(origin: entry) { _ in }
        XCTAssertEqual(try String(contentsOfFile: proposals[0].path, encoding: .utf8), "oldA\nkeep\noldB\n")
        XCTAssertEqual(try String(contentsOfFile: proposals[1].path, encoding: .utf8), "oldA\nkeep\noldB\n")
        await review.prepare(entry, after: true, paths: Set(entry.files.map(\.path))); await review.apply(origin: entry) { _ in }
        XCTAssertTrue(review.error.isEmpty, review.error)
        try "human\n".write(toFile: proposals[0].path, atomically: true, encoding: .utf8)
        await review.prepare(entry, after: false, paths: Set(entry.files.map(\.path)))
        XCTAssertFalse(review.error.isEmpty); XCTAssertNil(review.review)
        XCTAssertEqual(try String(contentsOfFile: proposals[1].path, encoding: .utf8), "newA\nkeep\nnewB\n")
    }
    func testMixedCrashCheckpointCanBeExplicitlyRolledBackAndContinued() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = executor(root), timeline = AIFileTimeline(url: root.appendingPathComponent("timeline.json")), proposals = try await prepare(root)
        let id = try timeline.begin(proposals: proposals, executor: executor, taskID: nil, title: "crash group")
        _ = try await proposals[0].apply() // Simulates process exit between group commits.
        var checkpoint = AITaskRecovery(goal: "change", channel: "independent", operations: [.init(tool: "replace_files", argument: "group", mutation: true, files: proposals.map(\.checkpoint), timelineID: id)])
        _ = try await checkpoint.reconcileFiles(executor: executor, policy: AIExecutionPolicy())
        XCTAssertTrue(checkpoint.uncertainMutation)
        let restored = AIFileTimeline(url: timeline.url), entry = try XCTUnwrap(restored.entries.first)
        let state = try await restored.inspect(entry, executor: executor, policy: AIExecutionPolicy())
        XCTAssertEqual(Set(state.values), ["before", "after"])
        let review = AIFileTimelineReview(timeline: restored, executor: executor, policy: { AIExecutionPolicy() })
        await review.prepare(entry, after: false, paths: Set(entry.files.map(\.path))); await review.apply(origin: entry) { _ in }
        XCTAssertTrue(review.error.isEmpty, review.error)
        _ = try await checkpoint.reconcileFiles(executor: executor, policy: AIExecutionPolicy())
        XCTAssertFalse(checkpoint.uncertainMutation); XCTAssertEqual(checkpoint.operations[0].state, "not_applied")
        XCTAssertFalse(checkpoint.blocks(tool: "replace_files", argument: "group", mutation: true))
    }
    func testTargetPolicyCorruptStoreAndPrepareApplyRaceAreProtected() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = executor(root), timeline = AIFileTimeline(url: root.appendingPathComponent("timeline.json")), proposals = try await prepare(root, names: ["one.txt"])
        let id = try timeline.begin(proposals: proposals, executor: executor, taskID: nil, title: "change"); _ = try await proposals[0].apply(); try timeline.finish(id, state: "applied")
        let entry = try XCTUnwrap(timeline.entries.first)
        let otherRoot = root.appendingPathComponent("other"); let other = self.executor(otherRoot)
        let wrong = AIFileTimelineReview(timeline: timeline, executor: other, policy: { AIExecutionPolicy() })
        await wrong.prepare(entry, after: false, paths: [proposals[0].path]); XCTAssertNil(wrong.review)
        var denied = AIExecutionPolicy(); denied.rules = "deny|owned local|replace_file|" + proposals[0].path
        let blocked = AIFileTimelineReview(timeline: timeline, executor: executor, policy: { denied })
        await blocked.prepare(entry, after: false, paths: [proposals[0].path]); XCTAssertNil(blocked.review)
        let valid = AIFileTimelineReview(timeline: timeline, executor: executor, policy: { AIExecutionPolicy() })
        await valid.prepare(entry, after: false, paths: [proposals[0].path]); XCTAssertNotNil(valid.review)
        try "newer".write(toFile: proposals[0].path, atomically: true, encoding: .utf8)
        await valid.apply(origin: entry) { _ in XCTFail("Conflict restored") }; XCTAssertFalse(valid.error.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: proposals[0].path, encoding: .utf8), "newer")
        try Data("invalid".utf8).write(to: timeline.url)
        XCTAssertThrowsError(try timeline.begin(proposals: proposals, executor: executor, taskID: nil, title: "blocked"))
        XCTAssertEqual(try Data(contentsOf: timeline.url), Data("invalid".utf8))
    }
    func testLatestFileVersionSupersedesHistoricalCompletedCheckpoints() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }; let file = root.appendingPathComponent("x")
        try "third".write(to: file, atomically: true, encoding: .utf8)
        func hash(_ s: String) -> String { AIFileCheckpoint.digest(Data(s.utf8)) }
        var recovery = AITaskRecovery(goal: "change", channel: "independent", operations: [
            .init(tool: "replace_file", argument: "first", mutation: true, state: "completed", files: [.init(path: file.path, before: hash("first"), after: hash("second"))]),
            .init(tool: "replace_file", argument: "second", mutation: true, state: "completed", files: [.init(path: file.path, before: hash("second"), after: hash("third"))])])
        _ = try await recovery.reconcileFiles(executor: executor(root), policy: AIExecutionPolicy())
        XCTAssertFalse(recovery.uncertainMutation)
        try "second".write(to: file, atomically: true, encoding: .utf8)
        _ = try await recovery.reconcileFiles(executor: executor(root), policy: AIExecutionPolicy())
        XCTAssertEqual(recovery.operations[1].state, "reverted"); XCTAssertFalse(recovery.uncertainMutation)
    }
    func testTimelinePersistFailurePreventsActualAgentFileWrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }; let file = root.appendingPathComponent("config")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            try AIStructuredReply(answer: "write", action: .init(tool: "replace_file", argument: nil, reason: "fixture", path: file.path, find: "old", replacement: "new"), checks: [.init(goal: "modify", tool: "read_file", argument: file.path, expectedOutput: "new")]).serialized()
        })
        try FileManager.default.createDirectory(at: ai.fileTimeline.url, withIntermediateDirectories: true)
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        let executor = executor(root); ai.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: "modify"); ai.send(executor: executor)
        try await wait { !ai.busy }; XCTAssertFalse(ai.error.isEmpty); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
    }
    func testUnknownCommandCannotClaimSuccessEvenAfterGoalCheckPasses() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }; let file = root.appendingPathComponent("config")
        try "new".write(to: file, atomically: true, encoding: .utf8)
        let goal = "modify", check = AIVerificationCheck(goal: "modify", tool: "read_file", argument: file.path, expectedOutput: "new")
        let value = AICommandExecutor(sessionID: UUID(), source: "owned local", directory: root.path, valid: { true }, execute: { command, _ in if command.contains("printf") { throw URLError(.networkConnectionLost) }; return .init(output: command.contains("uname") ? "Darwin" : try String(contentsOf: file, encoding: .utf8), exitCode: 0) }); value.fileBackend = { LocalFiles() }
        let first = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in try AIStructuredReply(answer: "write", action: .init(tool: "command", argument: "printf unknown", reason: "owned", path: nil, find: nil, replacement: nil), checks: [check]).serialized() })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; first.settings.executionPolicy = policy; first.executionChannel = .independent
        first.prepare(source: value.source, text: "", sessionID: value.sessionID, question: goal); first.send(executor: value); try await wait { !first.busy }
        var round = 0
        let restored = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt,_,_ in
            round += 1
            let action: AIAgentAction?
            if round == 1 { action = .init(tool: "read_file", argument: file.path, reason: "check", path: nil, find: nil, replacement: nil) }
            else if round == 2 { action = nil }
            else { XCTAssertTrue(prompt.contains("Submission outcome is uncertain")); action = .init(tool: "report_blocker", argument: "Unknown command receipt needs manual inspection", reason: "blocked", path: nil, find: nil, replacement: nil) }
            return try AIStructuredReply(answer: "ALL_DONE", action: action).serialized()
        }); restored.settings.executionPolicy = policy
        restored.restoreTask(try XCTUnwrap(restored.taskRecords.first)); restored.resume(executor: value); try await wait { !restored.busy }
        XCTAssertFalse(restored.taskRecords.first?.verification?.pending ?? true)
        XCTAssertEqual(round, 3); XCTAssertEqual(restored.taskRecords.first?.state, "blocked"); XCTAssertTrue(restored.taskRecords.first?.recovery?.uncertainMutation == true)
    }
    func testActualTimelineHunkUndoRedoAndCompactToolbar() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let shots = URL(fileURLWithPath: "/tmp/axon-rc-ui"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        var ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"))
        let executor = executor(root), proposals = try await prepare(root)
        var record = AITaskRecord(id: UUID(), sessionID: executor.sessionID, hostID: nil, target: executor.source, question: "长名称：修改配置并验证恢复 long configuration change", transcript: "fixture", summary: "verified", state: "finished", updated: Date(), messageCount: 1, executed: true)
        record.recovery = AITaskRecovery(goal: record.question, channel: "independent", operations: [.init(tool: "replace_files", argument: "group", mutation: true, state: "completed", files: proposals.map(\.checkpoint))])
        record.verification = AIVerificationState(checks: [.init(goal: record.question, tool: "read_file", argument: proposals[0].path, expectedOutput: "newA")], passed: [0], pending: false, hasChanges: true)
        var other = AITaskRecord(id: UUID(), sessionID: UUID(), hostID: nil, target: "other target", question: record.question, transcript: "fixture", summary: "verified", state: "finished", updated: Date(), messageCount: 1, executed: true)
        other.recovery = record.recovery; other.verification = record.verification
        try JSONEncoder().encode([record, other]).write(to: root.appendingPathComponent("ai.tasks.json"))
        ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); ai.restoreTask(record)
        let id = try ai.fileTimeline.begin(proposals: proposals, executor: executor, taskID: record.id, title: record.question)
        _ = try await AIProjectEdit(proposals: proposals).apply(); try ai.fileTimeline.finish(id, state: "applied")
        func objects(_ view: NSView) -> [NSObject] {
            var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
            func visit(_ o: NSObject) { guard seen.insert(ObjectIdentifier(o)).inserted else { return }; result.append(o); if o.responds(to: NSSelectorFromString("accessibilityChildren")), let children = o.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(visit) }; if let v = o as? NSView { v.subviews.forEach(visit) } }
            visit(view); return result
        }
        func find(_ view: NSView, _ id: String) -> NSObject? { objects(view).first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id } }
        func press(_ view: NSView, _ id: String) throws {
            let o = try XCTUnwrap(find(view,id)); if let b = o as? NSButton { b.performClick(nil); return }
            let sel = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c)(AnyObject,Selector)->Bool
            XCTAssertTrue(unsafeBitCast(o.method(for: sel), to: Press.self)(o,sel))
        }
        func window(_ view: AnyView, width: Int, height: Int) -> NSWindow {
            let host = NSHostingView(rootView: view.preferredColorScheme(.light)); host.sizingOptions = []
            let w = NSWindow(contentRect: NSRect(x:0,y:0,width:width,height:height),styleMask:[.titled],backing:.buffered,defer:false); w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil); return w
        }
        func shot(_ view: NSView, _ name: String) throws { view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap); try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:shots.appendingPathComponent(name+".png")) }
        let sheet = window(AnyView(AIFileTimelineSheet(ai: ai, executor: executor).environmentObject(store)),width:960,height:680)
        defer { sheet.close() }
        let host = try XCTUnwrap(sheet.contentView)
        try await Task.sleep(for:.milliseconds(200)); try press(host,"axon-timeline-entry-"+id.uuidString)
        try await Task.sleep(for:.milliseconds(200)); try shot(host,"timeline-selected")
        try press(host,"axon-timeline-undo"); try await wait { find(host,"axon-timeline-hunk-0-1") != nil }
        try press(host,"axon-timeline-hunk-0-1"); try shot(host,"timeline-hunks")
        try press(host,"axon-timeline-apply"); try await wait { (try? String(contentsOfFile:proposals[0].path,encoding:.utf8)) == "oldA\nkeep\nnewB\n" }
        XCTAssertTrue(ai.taskRecords.first?.verification?.pending == true)
        XCTAssertEqual(ai.taskRecords.last?.state, "finished"); XCTAssertFalse(ai.taskRecords.last?.verification?.pending ?? true)
        let undo = try XCTUnwrap(ai.fileTimeline.entries.last)
        try await Task.sleep(for:.milliseconds(100)); try shot(host,"timeline-restored")
        try press(host,"axon-timeline-entry-"+undo.id.uuidString); try await Task.sleep(for:.milliseconds(100)); try press(host,"axon-timeline-undo"); try await wait { find(host,"axon-timeline-hunk-0-0") != nil }; try press(host,"axon-timeline-apply")
        try await wait { (try? String(contentsOfFile:proposals[0].path,encoding:.utf8)) == "newA\nkeep\nnewB\n" }
        try "human".write(toFile:proposals[0].path,atomically:true,encoding:.utf8)
        try await Task.sleep(for:.milliseconds(100)); try press(host,"axon-timeline-entry-"+id.uuidString); try await Task.sleep(for:.milliseconds(100)); try press(host,"axon-timeline-undo"); try await Task.sleep(for:.milliseconds(100)); try shot(host,"timeline-conflict")
        for width in [320,600] {
            let w = window(AnyView(AIAssistantPane(ai:ai,executionOverride:executor).environmentObject(store)),width:width,height:760)
            let pane = try XCTUnwrap(w.contentView); try await Task.sleep(for:.milliseconds(100)); try shot(pane,"recovery-toolbar-\(width)")
            XCTAssertNotNil(find(pane,"axon-ai-file-timeline")); XCTAssertNotNil(find(pane,"axon-ai-recovery-evidence")); w.close()
        }
        let evidence = window(AnyView(AITaskRecoverySheet(ai:ai).environmentObject(store)),width:680,height:560)
        try await Task.sleep(for:.milliseconds(100)); try shot(try XCTUnwrap(evidence.contentView),"recovery-evidence"); evidence.close()
        store.monitoring.stop()
    }

    func testActualBashZshRunningReceiptAndInterruptionMatrix() async throws {
        _ = NSApplication.shared
        for shell in ["/bin/bash", "/bin/zsh"] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
            let session = TerminalSession(host: nil, store: store); session.connected = true; session.commandHistoryToken = "matrix"
            session.commandHistoryStore = CommandHistoryStore(fileURL: root.appendingPathComponent("history.json"))
            let hook = root.appendingPathComponent(shell.hasSuffix("zsh") ? ".zshrc" : "hooks.sh")
            try ShellCommandIntegration.script(token: "matrix").write(to: hook, atomically: true, encoding: .utf8)
            let terminal = LocalTerminal(frame: NSRect(x:0,y:0,width:700,height:450)); terminal.ownerSession = session; terminal.terminalDelegate = session; session.terminal = terminal
            terminal.startProcess(executable: shell, args: shell.hasSuffix("zsh") ? ["-d","-i"] : ["--noprofile","--rcfile",hook.path,"-i"], environment: ["HOME="+root.path,"ZDOTDIR="+root.path,"PATH=/usr/bin:/bin","TERM=xterm-256color","PS1=OWNED> "], currentDirectory: root.path)
            defer { terminal.terminate(); store.monitoring.stop() }
            try await wait { session.commandHistoryReady && session.aiShellInput.line == "" }
            func action(_ tool: String, _ argument: String) -> AIAgentAction { .init(tool: tool, argument: argument, reason: "matrix", path: nil, find: nil, replacement: nil) }
            let bridge = AITerminalBridge(session: session)
            let fail = try await bridge.run(action("terminal_execute","false"),update:{ _ in })
            XCTAssertEqual(fail.status,"completed",shell); XCTAssertEqual(fail.exitCode,1,shell)
            let file = root.appendingPathComponent("once")
            let running = try await bridge.run(action("terminal_execute","sleep 3; printf once >> "+SnippetParameters.shellArgument(file.path)),update:{ _ in })
            XCTAssertEqual(running.status,"running",shell)
            let id = try XCTUnwrap(running.executionID)
            // A new bridge instance recovers the same live session by receipt, not by replaying input.
            let resumed = AITerminalBridge(session: session)
            let result = try await resumed.run(action("terminal_result",id.uuidString),update:{ _ in })
            XCTAssertEqual(result.status,"completed",shell); XCTAssertEqual(result.exitCode,0,shell)
            XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"once",shell)
            do { _ = try await resumed.run(action("terminal_result",UUID().uuidString),update:{ _ in }); XCTFail("Unknown receipt accepted") } catch { }
            let second = try await resumed.run(action("terminal_execute","sleep 5"),update:{ _ in })
            let revision = session.aiTerminalInputRevision; session.writeInput([3]); try await wait { session.aiTerminalInputRevision > revision }
            let interrupted = try await resumed.run(action("terminal_result",try XCTUnwrap(second.executionID).uuidString),update:{ _ in })
            XCTAssertEqual(interrupted.status,"interrupted",shell); XCTAssertEqual(interrupted.exitCode,-1,shell)
        }
    }

    func testOlderTimelineVersionCanRestoreFromNewerRecordedEdits() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = executor(root), timeline = AIFileTimeline(url: root.appendingPathComponent("timeline.json")), first = try await prepare(root, names: ["one.txt"])
        let id = try timeline.begin(proposals: first, executor: executor, taskID: nil, title: "first")
        _ = try await first[0].apply(); try timeline.finish(id, state: "applied")
        let entry = try XCTUnwrap(timeline.entries.first)
        let second = try await AIFileProposal(backend: LocalFiles(), path: first[0].path, find: "newA", replacement: "thirdA")
        let next = try timeline.begin(proposals: [second], executor: executor, taskID: nil, title: "second")
        _ = try await second.apply(); try timeline.finish(next, state: "applied")
        let states = try await timeline.inspect(entry, executor: executor, policy: AIExecutionPolicy())
        XCTAssertEqual(states[first[0].path], "recorded")
        let review = AIFileTimelineReview(timeline: timeline, executor: executor, policy: { AIExecutionPolicy() })
        await review.prepare(entry, after: false, paths: [first[0].path]); await review.apply(origin: entry) { _ in }
        XCTAssertTrue(review.error.isEmpty, review.error)
        XCTAssertEqual(try String(contentsOfFile: first[0].path, encoding: .utf8), "oldA\nkeep\noldB\n")
    }

    func testIncompleteModelTransportRechecksFilesWithoutReplayingWrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }; let file = root.appendingPathComponent("config")
        try "old".write(to:file,atomically:true,encoding:.utf8)
        var round = 0
        let ai = AIAssistant(fileURL:root.appendingPathComponent("ai.json"), recoverModelTransport:true, modelResponder:{ prompt,_,_ in
            round += 1
            if round == 1 { return try AIStructuredReply(answer:"modify",action:.init(tool:"replace_file",argument:nil,reason:"fixture",path:file.path,find:"old",replacement:"new"),checks:[.init(goal:"modify",tool:"read_file",argument:file.path,expectedOutput:"new")]).serialized() }
            if round == 2 { throw AIModelError.incompleteStream }
            if round == 3 { XCTAssertTrue(prompt.contains("Fresh file recovery inspection after reconnect")); return try AIStructuredReply(answer:"check",action:.init(tool:"read_file",argument:file.path,reason:"fixture",path:nil,find:nil,replacement:nil)).serialized() }
            return try AIStructuredReply(answer:"verified",action:nil).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned local", directory: root.path, valid: { true }, execute: { command, _ in .init(output: command.contains("uname") ? "Darwin" : try String(contentsOf: file, encoding: .utf8), exitCode: 0) }); executor.fileBackend = { LocalFiles() }; ai.prepare(source:executor.source,text:"",sessionID:executor.sessionID,question:"modify"); ai.send(executor:executor); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty,ai.error); XCTAssertEqual(ai.answer,"verified"); XCTAssertEqual(round,4)
        XCTAssertEqual(ai.fileTimeline.entries.count,1); XCTAssertEqual(ai.fileTimeline.entries[0].state,"applied")
        XCTAssertEqual(ai.taskRecords.first?.recovery?.operations.filter { $0.mutation }.count,1)
        XCTAssertFalse(ai.taskRecords.first?.verification?.pending ?? true)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"new")
    }

}
