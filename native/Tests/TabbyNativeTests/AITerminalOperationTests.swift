import XCTest
import AppKit
import SwiftTerm
import SwiftUI
@testable import TabbyNative

@MainActor final class AITerminalOperationTests: XCTestCase {
    private var fixtureStores: [AppStore] = []
    private func action(_ tool: String, _ value: String) -> AIAgentAction {
        .init(tool: tool, argument: value, reason: "本地执行夹具", path: nil, find: nil, replacement: nil)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Fixture state timeout")
    }
    private func fixture() async throws -> (URL, TerminalSession, LocalTerminal, AITerminalBridge) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); fixtureStores.append(store)
        let session = TerminalSession(host: nil, store: store); session.connected = true; session.commandHistoryToken = "operation"
        session.commandHistoryStore = CommandHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let hook = root.appendingPathComponent("hooks.sh")
        try ShellCommandIntegration.script(token: "operation").write(to: hook, atomically: true, encoding: .utf8)
        let terminal = LocalTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 450))
        terminal.ownerSession = session; terminal.terminalDelegate = session; session.terminal = terminal
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--rcfile", hook.path, "-i"], environment: ["HOME=" + root.path, "PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=OWNED> "], currentDirectory: root.path)
        try await wait { session.commandHistoryReady && session.aiShellInput.line == "" }
        return (root, session, terminal, AITerminalBridge(session: session))
    }
    func testLeaseRevocationQueuedWriteDetachAndExplicitInterrupt() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let owner = UUID(); bridge.acquireControl(owner)
        let token = session.aiControl.claim(owner, session: session)
        session.aiControl.takeover()
        let revision = session.aiTerminalInputRevision
        do { try await session.writeAgentInput(Array("SHOULD_NOT_WRITE".utf8), expectedRevision: revision, controlLease: token); XCTFail("Revoked input lease accepted") } catch { }
        XCTAssertEqual(session.aiTerminalInputRevision, revision)
        bridge.acquireControl(owner)
        let running = try await bridge.run(action("terminal_execute", "sleep 20"), update: { _ in })
        let id = try XCTUnwrap(running.executionID)
        let detached = try await bridge.run(action("terminal_detach", id.uuidString), update: { _ in })
        XCTAssertEqual(detached.status, "detached"); XCTAssertEqual(session.aiControl.mode, .monitoring)
        XCTAssertTrue(session.aiControl.canInterrupt(id, session: session))
        do { _ = try await bridge.run(action("terminal_key", "ctrl-c"), update: { _ in }); XCTFail("Detached bridge retained input lease") } catch { }
        try await session.aiControl.interrupt(id, session: session)
        try await wait { session.aiCommandCapture.entry(id)?.exitCode != nil }
        session.aiControl.refresh(session)
        XCTAssertEqual(session.aiControl.programs.first?.state, "completed")
        XCTAssertNotEqual(session.aiControl.programs.first?.exitCode, 0)
        XCTAssertFalse(session.aiControl.canInterrupt(id, session: session))
    }
    func testAtomicREPLInputAndManualProgramIsNeverInterruptible() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let running = try await bridge.run(action("terminal_execute", "while IFS= read -r line; do printf 'REPLY:%s\\n' \"$line\"; done"), update: { _ in })
        let id = try XCTUnwrap(running.executionID)
        _ = try await bridge.run(action("terminal_input", "hello world"), update: { _ in })
        try await wait { session.aiCommandCapture.entry(id)?.output.range(of: Data("REPLY:hello world".utf8)) != nil }
        XCTAssertEqual(session.aiCommandCapture.current?.id, id)
        session.aiControl.takeover()
        XCTAssertFalse(session.aiControl.canInterrupt(id, session: session))
        session.writeInput([3]); try await wait { session.aiCommandCapture.current == nil && session.aiShellInput.line == "" }
        let manualID = UUID()
        session.aiCommandCapture.request(manualID, command: "sleep 20")
        try await session.writeAgentInput(Array("sleep 20\r".utf8), expectedCommand: "")
        try await wait { session.aiCommandCapture.current?.id == manualID }
        let attached = AITerminalBridge(session: session)
        XCTAssertFalse(session.aiControl.programs.first { $0.id == manualID }!.startedByAgent)
        XCTAssertFalse(session.aiControl.canInterrupt(manualID, session: session))
        _ = try await attached.run(action("terminal_read", ""), update: { _ in })
        session.writeInput([3]); try await wait { session.aiCommandCapture.current == nil && session.aiShellInput.line == "" }
    }
    func testProgramManagerRenderedAtNarrowAndWideWidths() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-control-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); fixtureStores.append(store)
        store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true
        store.sessions = [session]; store.activeSession = session.id
        let owner = UUID(), id = UUID()
        session.aiControl.register(id, owner: owner, command: "python3 /srv/long-directory-name/application/worker.py --port 8081", revision: 0, directory: "/srv/application")
        session.aiControl.monitor()
        session.aiControl.register(UUID(), owner: owner, command: "psql production_readonly", revision: 0, directory: nil, startedByAgent: false)
        let shots = URL(fileURLWithPath: "/tmp/axon-0199-ui"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        for width: CGFloat in [320, 600] {
            let host = NSHostingView(rootView: AIProgramsView().environmentObject(store).frame(width: width, height: 500)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: shots.appendingPathComponent("programs-\(Int(width)).png"))
            XCTAssertEqual(host.bounds.width, width)
            store.activeSession = nil; try pressControl(host, "axon-program-show-terminal"); XCTAssertEqual(store.activeSession, session.id)
            window.close()
        }
    }
    private func pressControl(_ view: NSView, _ id: String) throws {
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
    func testActualTakeoverAndHandbackButtonsCancelModelAndRetainProgram() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(fixtureStores.last)
        store.sessions = [session]; store.activeSession = session.id
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("handoff.json"), modelResponder: { _,_,_ in
            round += 1
            if round == 1 {
                return try AIStructuredReply(answer: "运行程序", action: self.action("terminal_execute", "sleep 20"), checks: [.init(goal: "保持程序运行", tool: "read_file", argument: root.appendingPathComponent("ready.txt").path, expectedOutput: "ready")]).serialized()
            }
            try await Task.sleep(for: .seconds(50)); throw CancellationError()
        })
        store.ai = ai
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "Local macOS / 本机 macOS", directory: root.path, valid: { session.connected }, execute: { _,_ in XCTFail("Independent shell used"); return .init(output: "", exitCode: -1) })
        executor.terminalBridge = bridge; executor.fileBackend = { LocalFiles() }
        ai.prepare(source: "Local macOS / 本机 macOS", text: "", sessionID: session.id, question: "保持程序运行"); ai.send(executor: executor)
        try await wait { session.aiCommandCapture.current != nil }
        let id = try XCTUnwrap(session.aiCommandCapture.current?.id)
        let host = NSHostingView(rootView: AITerminalControlView(session: session).environmentObject(store).frame(width: 320, height: 80).background(Palette.background))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { ai.cancel(); window.close() }
        try await Task.sleep(for: .milliseconds(200)); try pressControl(host, "axon-terminal-takeover")
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.canResume); XCTAssertEqual(session.aiControl.mode, .human)
        XCTAssertNil(session.aiCommandCapture.entry(id)?.exitCode)
        let shots = URL(fileURLWithPath: "/tmp/axon-0199-ui"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: shots.appendingPathComponent("handoff-human-320.png"))
        try pressControl(host, "axon-terminal-handback")
        XCTAssertTrue(ai.busy); XCTAssertEqual(session.aiControl.mode, .agent)
        ai.cancel(); XCTAssertEqual(session.aiControl.mode, .monitoring)
        XCTAssertNil(session.aiCommandCapture.entry(id)?.exitCode)
        try await session.aiControl.interrupt(id, session: session)
    }
    func testAgentCanLeavePersistentProgramRunningWithoutClaimingVerification() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("detach.json"), modelResponder: { _,_,_ in
            round += 1
            let step = round == 1 ? self.action("terminal_execute", "sleep 20") : self.action("terminal_detach", try XCTUnwrap(session.aiCommandCapture.current?.id).uuidString)
            return try AIStructuredReply(answer: "程序继续运行", action: step, checks: round == 1 ? [.init(goal: "保持程序运行", tool: "read_file", argument: root.appendingPathComponent("ready.txt").path, expectedOutput: "ready")] : nil).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned", directory: root.path, valid: { session.connected }, execute: { _,_ in XCTFail("Independent shell used"); return .init(output: "", exitCode: -1) })
        executor.terminalBridge = bridge; executor.fileBackend = { LocalFiles() }
        ai.prepare(source: "owned", text: "", sessionID: session.id, question: "保持程序运行"); ai.send(executor: executor)
        try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(round, 2); XCTAssertTrue(ai.canResume)
        XCTAssertEqual(ai.taskRecords.last?.state, "interrupted"); XCTAssertTrue(ai.taskRecords.last?.verification?.pending ?? false)
        XCTAssertEqual(session.aiControl.mode, .monitoring)
        let id = try XCTUnwrap(session.aiCommandCapture.current?.id)
        XCTAssertTrue(ai.answer.contains("尚未结束")); XCTAssertNil(session.aiCommandCapture.entry(id)?.exitCode)
        try await session.aiControl.interrupt(id, session: session)
    }
    func testAgentVerifiesInteractiveResultOnlyAfterActualProgramCompletion() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let check = AIVerificationCheck(goal: "计算结果", tool: "program_result", argument: "python3 -I -S -q", expectedOutput: "42")
        XCTAssertFalse(check.accepts(.init(output: ">>> print(42)\r\n>>> ", exitCode: 0)))
        XCTAssertTrue(check.accepts(.init(output: "\r\n42\r\n>>> ", exitCode: 0)))
        XCTAssertFalse(check.accepts(.init(output: "42\n", exitCode: -1)))
        let goal = "用 Python 计算 6 乘 7 并退出"
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("program-verification.json"), modelResponder: { _,_,_ in
            round += 1
            let step: AIAgentAction?
            switch round {
            case 1: step = self.action("terminal_execute", "python3 -I -S -q")
            case 2: step = self.action("terminal_input", "print(6 * 7)")
            case 3: step = self.action("terminal_input", "raise SystemExit")
            case 4:
                step = self.action("terminal_result", try XCTUnwrap(session.aiCommandCapture.current?.id ?? session.aiCommandCapture.finished.last?.id).uuidString)
            default: step = nil
            }
            return try AIStructuredReply(answer: step == nil ? "实际结果为 42，Python 已正常退出" : "继续交互", action: step, checks: round == 1 ? [.init(goal: goal, tool: "program_result", argument: "python3 -I -S -q", expectedOutput: "42")] : nil).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned", directory: root.path, valid: { session.connected }, execute: { _,_ in XCTFail("Independent shell used"); return .init(output: "", exitCode: -1) })
        executor.terminalBridge = bridge; executor.fileBackend = { LocalFiles() }
        ai.prepare(source: "owned", text: "", sessionID: session.id, question: goal); ai.send(executor: executor)
        for _ in 0..<1500 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        defer { ai.cancel() }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error)
        XCTAssertTrue(ai.answer.contains("42")); XCTAssertFalse(ai.taskRecords.last?.verification?.pending ?? true)
        XCTAssertEqual(round, 5)
    }
    func testSequencedMarkersRejectOldAndMalformedCompletion() {
        var capture = AICommandCapture()
        func marker(_ payload: String) -> [UInt8] { Array(("\u{1b}]7;axon-command;t;" + payload + "\u{7}").utf8) }
        let encoded = Data("printf current".utf8).base64EncodedString()
        capture.receive(marker("begin;8;" + encoded) + Array("CURRENT".utf8), token: "t")
        capture.receive(marker("end;7;0;1"), token: "t"); XCTAssertNil(capture.current?.exitCode)
        capture.receive(marker("end;8;0;nan"), token: "t"); XCTAssertEqual(capture.completionRevision, 0)
        capture.receive(marker("end;8;0;1"), token: "t")
        XCTAssertEqual(capture.completionRevision, 1); XCTAssertEqual(capture.finished.last?.exitCode, 0)
        XCTAssertEqual(String(decoding: capture.finished.last!.output, as: UTF8.self), "CURRENT")
    }
    func testAtomicPythonAndSQLiteInputUsesRealPTYResults() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let python = try await bridge.run(action("terminal_execute", "python3 -q"), update: { _ in })
        let pythonID = try XCTUnwrap(python.executionID)
        _ = try await bridge.run(action("terminal_input", "print('PY_RESULT=' + str(6 * 7))"), update: { _ in })
        try await wait { session.aiCommandCapture.entry(pythonID)?.output.range(of: Data("PY_RESULT=42".utf8)) != nil }
        _ = try await bridge.run(action("terminal_input", "exit()"), update: { _ in })
        try await wait { session.aiShellInput.line == "" && session.aiCommandCapture.current == nil }
        let pythonResult = try await bridge.run(action("terminal_result", pythonID.uuidString), update: { _ in })
        XCTAssertEqual(pythonResult.status, "completed"); XCTAssertEqual(pythonResult.exitCode, 0)
        let database = try await bridge.run(action("terminal_execute", "sqlite3 :memory:"), update: { _ in })
        let databaseID = try XCTUnwrap(database.executionID)
        _ = try await bridge.run(action("terminal_input", "select 'SQL_RESULT=' || (6 * 7);"), update: { _ in })
        try await wait { session.aiCommandCapture.entry(databaseID)?.output.range(of: Data("SQL_RESULT=42".utf8)) != nil }
        _ = try await bridge.run(action("terminal_input", ".quit"), update: { _ in })
        try await wait { session.aiCommandCapture.current == nil }
        let databaseResult = try await bridge.run(action("terminal_result", databaseID.uuidString), update: { _ in })
        XCTAssertEqual(databaseResult.exitCode, 0)
        XCTAssertFalse(databaseResult.commandOutput?.contains("PY_RESULT=42") ?? true)
        session.aiShellInput.invalidate()
        do { _ = try await bridge.run(action("terminal_send", "unknown"), update: { _ in }); XCTFail("Unknown state accepted input") } catch { }
    }
    func testCommandIDsDoNotMixIdenticalCommandsOrLaterOutput() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let first = try await bridge.run(action("terminal_execute", "printf 'FIRST_OUTPUT\\n'"), update: { _ in })
        let second = try await bridge.run(action("terminal_execute", "printf 'SECOND_OUTPUT\\n'"), update: { _ in })
        XCTAssertEqual(first.status, "completed"); XCTAssertEqual(first.exitCode, 0)
        XCTAssertNotEqual(first.executionID, second.executionID); XCTAssertFalse(second.output.contains("FIRST_OUTPUT"))
        for _ in 0..<5 { _ = try await bridge.run(action("terminal_execute", "printf 'SAME_OUTPUT\\n'"), update: { _ in }) }
        let old = try await bridge.run(action("terminal_result", try XCTUnwrap(first.executionID).uuidString), update: { _ in })
        XCTAssertTrue(old.output.contains("FIRST_OUTPUT")); XCTAssertFalse(old.output.contains("SECOND_OUTPUT"))
        XCTAssertEqual(session.aiCommandCapture.completionRevision, 7)
        let failure = try await bridge.run(action("terminal_execute", "false"), update: { _ in })
        XCTAssertEqual(failure.status, "completed"); XCTAssertEqual(failure.exitCode, 1)
        do { _ = try await bridge.run(action("terminal_result", UUID().uuidString), update: { _ in }); XCTFail("Unknown ID accepted") } catch { }
    }
    func testLongRunningCommandPollAndHumanTakeover() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let running = try await bridge.run(action("terminal_execute", "sleep 3; printf 'FINISHED_ONCE\\n'"), update: { _ in })
        XCTAssertEqual(running.status, "running"); XCTAssertEqual(running.exitCode, -1)
        do { _ = try await bridge.run(action("terminal_execute", "printf duplicate"), update: { _ in }); XCTFail("Busy shell accepted command") } catch { }
        let done = try await bridge.run(action("terminal_result", try XCTUnwrap(running.executionID).uuidString), update: { _ in })
        XCTAssertEqual(done.status, "completed"); XCTAssertEqual(done.exitCode, 0); XCTAssertTrue(done.output.contains("FINISHED_ONCE"))
        let again = try await bridge.run(action("terminal_execute", "sleep 5"), update: { _ in })
        let revision = session.aiTerminalInputRevision
        session.writeInput([3]); try await wait { session.aiTerminalInputRevision > revision }
        let interrupted = try await bridge.run(action("terminal_result", try XCTUnwrap(again.executionID).uuidString), update: { _ in })
        XCTAssertEqual(interrupted.status, "interrupted"); XCTAssertEqual(interrupted.exitCode, -1)
    }
    func testCancellationDoesNotInterruptProgram() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let task = Task { try await bridge.run(action("terminal_execute", "sleep 1; printf 'SURVIVED_CANCEL\\n'"), update: { _ in }) }
        try await wait { session.aiCommandCapture.current != nil }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled action completed") } catch is CancellationError { }
        try await wait { session.aiCommandCapture.finished.last?.exitCode != nil }
        XCTAssertTrue(String(decoding: session.aiCommandCapture.finished.last!.output, as: UTF8.self).contains("SURVIVED_CANCEL"))
    }
    func testAgentCannotFinishWhileCommandIsRunningOrRepeatIt() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("check.txt"), goal = "运行长任务"
        try "ready".write(to: file, atomically: true, encoding: .utf8)
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("long.json"), modelResponder: { prompt,_,_ in
            round += 1
            let step: AIAgentAction?
            switch round {
            case 1: step = self.action("terminal_execute", "sleep 3; printf 'DONE_ONCE\\n'")
            case 2: step = nil // Application must reject this premature final answer.
            case 3:
                XCTAssertTrue(prompt.contains("Command still running"))
                let entry = try XCTUnwrap(session.aiCommandCapture.current ?? session.aiCommandCapture.finished.last)
                step = self.action("terminal_result", entry.id.uuidString)
            case 4: step = self.action("read_file", file.path)
            default: step = nil
            }
            return try AIStructuredReply(answer: step == nil ? "完成" : "执行并检查", action: step, checks: round == 1 ? [.init(goal: goal, tool: "read_file", argument: file.path, expectedOutput: "ready")] : nil).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned", directory: root.path, valid: { session.connected }, execute: { _,_ in XCTFail("Independent shell used"); return .init(output: "", exitCode: -1) })
        executor.terminalBridge = bridge; executor.fileBackend = { LocalFiles() }
        ai.prepare(source: "owned", text: "", sessionID: session.id, question: goal); ai.send(executor: executor)
        try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(round, 5)
        XCTAssertEqual(session.aiCommandCapture.finished.filter { $0.command.contains("DONE_ONCE") }.count, 1)
        XCTAssertTrue(ai.steps.contains { $0.executionID != nil && $0.exitCode == 0 && $0.output.contains("DONE_ONCE") })
    }
    func testCompleteCommandAsksOnceAndGoalCheckUsesOnlyActualOutput() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.txt"), goal = "写入并检查"
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("approval.json"), modelResponder: { _,_,_ in
            round += 1
            let step = round == 1 ? self.action("terminal_execute", "printf 'APPROVED_ONCE\\n' > " + SnippetParameters.shellArgument(file.path)) : round == 2 ? self.action("read_file", file.path) : nil
            return try AIStructuredReply(answer: step == nil ? "已完成" : "写入并检查", action: step, checks: round == 1 ? [.init(goal: goal, tool: "read_file", argument: file.path, expectedOutput: "APPROVED_ONCE")] : nil).serialized()
        })
        ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned", directory: root.path, valid: { session.connected }, execute: { _,_ in XCTFail("Independent shell used"); return .init(output: "", exitCode: -1) })
        executor.terminalBridge = bridge; executor.fileBackend = { LocalFiles() }
        ai.prepare(source: "owned", text: "", sessionID: session.id, question: goal); ai.send(executor: executor)
        try await wait { ai.pendingApproval != nil }
        XCTAssertEqual(ai.pendingTool, "terminal_execute"); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        ai.approveAction(); try await wait { !ai.busy || ai.pendingApproval != nil }
        XCTAssertNil(ai.pendingApproval); XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error)
        XCTAssertEqual(round, 3); XCTAssertEqual(ai.answer, "已完成")
        bridge.acquireControl(UUID()) // The completed Agent released its input lease.
        let result = try await bridge.run(action("terminal_execute", "grep NEVER_ACTUALLY_OUTPUT " + SnippetParameters.shellArgument(file.path)), update: { _ in })
        XCTAssertTrue(result.output.contains("NEVER_ACTUALLY_OUTPUT")) // command metadata is not output evidence.
        XCTAssertFalse(result.commandOutput?.contains("NEVER_ACTUALLY_OUTPUT") ?? true)
        XCTAssertEqual(result.exitCode, 1)
    }
    func testCurrentTerminalCanReadEditVerifyFilesWithoutIndependentShell() async throws {
        let (root, session, terminal, bridge) = try await fixture()
        defer { terminal.terminate(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("service.conf")
        try "state=old\n".write(to: file, atomically: true, encoding: .utf8)
        var round = 0
        let goal = "修改配置"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            round += 1
            let step: AIAgentAction?
            switch round {
            case 1, 3: step = self.action("read_file", file.path)
            case 2: step = .init(tool: "replace_file", argument: nil, reason: "修改配置", path: file.path, find: "state=old", replacement: "state=new")
            default: step = nil
            }
            return try AIStructuredReply(answer: step == nil ? "已修改并检查" : "检查配置", action: step, checks: round == 1 ? [.init(goal: goal, tool: "read_file", argument: file.path, expectedOutput: "state=new")] : nil).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned", directory: root.path, valid: { session.connected }, execute: { _,_ in XCTFail("Independent shell used"); return .init(output: "", exitCode: -1) })
        executor.terminalBridge = bridge; executor.fileBackend = { LocalFiles() }
        ai.prepare(source: "owned", text: "", sessionID: session.id, question: goal); ai.send(executor: executor)
        try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(round, 4); XCTAssertEqual(ai.answer, "已修改并检查")
        XCTAssertFalse(ai.taskRecords.last?.verification?.pending ?? true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "state=new\n")
    }
}
