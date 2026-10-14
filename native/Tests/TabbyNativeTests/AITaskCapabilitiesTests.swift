import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import TabbyNative

@MainActor final class AITaskCapabilitiesTests: XCTestCase {
    private func root() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("axon-capabilities-" + UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
    private func action(_ tool: String, _ argument: String = "", extra: [String: String] = [:]) throws -> String {
        var value = extra; value["tool"] = tool; value["argument"] = argument; value["reason"] = "检查并恢复测试服务"
        return "正在检查。\n```axon_action\n" + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n```"
    }
    private func wait(_ condition: () -> Bool) async throws { for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }; XCTFail("Timed out") }
    func testIncrementalHookCaptureOwnsExactOutputAndHidesMarkers() throws {
        func report(_ value: String) -> String { "\u{1b}]7;axon-command;fixture-token;" + value + "\u{7}" }
        let first = Data("printf first".utf8).base64EncodedString(), second = Data("printf second".utf8).base64EncodedString()
        let bytes = Array(("old prompt\n" + report(first) + report("meta;" + Data("/owned".utf8).base64EncodedString()) + "first output\n" + report("end;7;1") + "next prompt\n" + report(second) + "second output\n" + report("end;0;1") + "new prompt\n").utf8)
        for chunkSize in [1, 2, 7, bytes.count] {
            var capture = AICommandCapture()
            for offset in stride(from: 0, to: bytes.count, by: chunkSize) { capture.receive(Array(bytes[offset..<min(offset + chunkSize, bytes.count)]), token: "fixture-token") }
            XCTAssertEqual(capture.finished.count, 2); XCTAssertEqual(capture.finished[0].command, "printf first"); XCTAssertEqual(capture.finished[0].directory, "/owned"); XCTAssertEqual(capture.finished[0].exitCode, 7)
            XCTAssertEqual(String(decoding: capture.finished[0].output, as: UTF8.self), "first output\n"); XCTAssertEqual(String(decoding: capture.finished[1].output, as: UTF8.self), "second output\n")
            XCTAssertFalse(String(decoding: capture.recent, as: UTF8.self).contains("fixture-token")); XCTAssertFalse(String(decoding: capture.recent, as: UTF8.self).contains(first))
        }
        var stale = AICommandCapture(); stale.receive(bytes, token: "other-token"); XCTAssertTrue(stale.finished.isEmpty)
        let hidden = "\u{1b}]7;axon-command;fixture-token;" + first + "\u{7}\u{1b}[31mERROR\u{1b}[0m {\"password\":\"owned-secret\"}"
        let clean = AIContext.sanitize(hidden); XCTAssertFalse(clean.contains("fixture-token")); XCTAssertFalse(clean.contains(first)); XCTAssertFalse(clean.contains("owned-secret")); XCTAssertTrue(clean.contains("ERROR"))
    }
    func testExplicitIndependentChannelRejectsTerminalTools() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")), session = TerminalSession(host: nil, store: store)
        session.connected = true; let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); session.terminal = terminal
        for channel in [AIAssistant.ExecutionChannel.independent] {
            var round = 0, executions = 0, prompts: [String] = []
            let ai = AIAssistant(fileURL: root.appendingPathComponent(UUID().uuidString), modelResponder: { prompt, _, publish in
                prompts.append(prompt); round += 1
                let response: String
                if round == 1 { response = try self.action(channel == .currentTerminal ? "command" : "terminal_read", channel == .currentTerminal ? "pwd" : "") }
                else if round == 2 { response = try self.action(channel == .currentTerminal ? "terminal_read" : "inspect_port", channel == .currentTerminal ? "" : "8080") }
                else { response = "Completed the chosen channel observation." }
                publish(response); return response
            })
            var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = channel
            let executor = AICommandExecutor(sessionID: session.id, source: "owned fixture", directory: root.path, valid: { true }, execute: { _, _ in executions += 1; return AICommandResult(output: "Darwin\n" + root.path, exitCode: 0) }); executor.terminalBridge = AITerminalBridge(session: session)
            ai.prepare(source: "fixture", text: "", sessionID: session.id, question: "Check memory"); ai.send(executor: executor); try await wait { !ai.busy }
            XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(executions, channel == .currentTerminal ? 0 : 2)
            XCTAssertTrue(prompts.last?.contains("Action rejected") == true); XCTAssertEqual(ai.steps.count, 2)
        }
        store.monitoring.stop()
    }
    func testExecutionChoicePopoverAndCompactComposer() async throws {
        _ = NSApplication.shared
        let key = "axon.ai.executionStyle", old = UserDefaults.standard.object(forKey: "axon.ai.executionStyle"); UserDefaults.standard.removeObject(forKey: key)
        defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: "/tmp/axon-0153-ui"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
        store.ai.context = AIContext(source: "fixture-user@long-fixture-host.example:22", text: "fixture output", sessionID: session.id); store.ai.answer = "内存总量 8 GiB，可用 6 GiB。\n\n```sh\nfree -h\n```"; store.ai.question = "看看还有多少内存"
        for (width, panel) in [(1050, 320), (1400, 500)] {
            let host = NSHostingView(rootView: HStack(spacing: 0) { Color.black; AIAssistantPane(ai: store.ai, terminal: true, availableHeight: 760).frame(width: CGFloat(panel)) }.environmentObject(store).frame(width: CGFloat(width), height: 760)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); try snapshot(host, output.appendingPathComponent("composer-\(width).png"))
            let field = try XCTUnwrap(accessible(host).compactMap { $0 as? SelectionFieldButton }.first { $0.accessibilityIdentifier() == "axon-ai-execution-style" }); XCTAssertEqual(field.title, width == 1050 ? "当前终端" : "独立命令")
            field.performClick(nil); try await Task.sleep(for: .milliseconds(150)); let popup = try XCTUnwrap(AxonMenuPopover.active)
            XCTAssertEqual(popup.menu.items.count, 3); try snapshot(try XCTUnwrap(popup.popover.contentViewController?.view), output.appendingPathComponent("execution-choice-\(width).png"))
            popup.highlighted = width == 1050 ? 1 : 2; XCTAssertTrue(popup.handleKey(36)); try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(UserDefaults.standard.string(forKey: key), width == 1050 ? "independent" : "analysis")
            window.close()
        }
    }
    func testPolicyMigrationAndScopedDenyPriority() throws {
        var policy = AIExecutionPolicy()
        policy.rules = "allow|fixture@host:22|command|printf allowed\ndeny|fixture@host:22|command|.*secret.*\nallow|fixture@host:22|command|.*\nask|fixture@host:22|command|sudo .*"
        try policy.validate()
        XCTAssertEqual(policy.decision(target: "fixture@host:22", tool: "command", argument: "printf allowed", automatic: false), .allow)
        XCTAssertEqual(policy.decision(target: "other@host:22", tool: "command", argument: "printf allowed", automatic: false), .ask)
        XCTAssertEqual(policy.decision(target: "fixture@host:22", tool: "command", argument: "printf secret", automatic: false), .deny)
        XCTAssertEqual(policy.decision(target: "fixture@host:22", tool: "command", argument: "sudo test", automatic: false), .ask)
        XCTAssertEqual(policy.decision(target: "fixture@host:22", tool: "replace_file", argument: "/tmp/x", automatic: false), .ask)
        policy.rules = "allow|[|command|.*"; XCTAssertThrowsError(try policy.validate())
        let fileAction = try XCTUnwrap(AIAgentAction.parse(action("replace_file", extra: ["path": "/owned/service.conf", "find": "old", "replacement": "new"])))
        XCTAssertEqual(fileAction.targetArgument, "/owned/service.conf")
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AISettings())) as? [String: Any]); encoded.removeValue(forKey: "executionPolicy")
        let old = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: encoded)); XCTAssertEqual(old.policy.maximumSteps, 60)
        XCTAssertTrue(AICommandExecutor.wrapper(command: "printf x", directory: nil, marker: "fixture", timeout: 120).contains("sleep 120"))
        for pair in [("tcp_probe", "localhost:80;touch x"), ("dns_lookup", "-x"), ("service_status", "x;echo y"), ("docker_logs", "--help"), ("http_health", "https://user:pass@host"), ("terminal_key", "unknown")] {
            let parsed = try XCTUnwrap(AIAgentAction.parse(action(pair.0, pair.1))); XCTAssertThrowsError(try parsed.command(os: "Linux"))
        }
    }
    func testConfigurationConflictBackupAndBytes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("service.conf"); try Data("upstream=broken\npassword=owned-secret\n".utf8).write(to: file)
        let proposal = try await AIFileProposal(backend: LocalFiles(), path: file.path, find: "upstream=broken", replacement: "upstream=ready")
        XCTAssertTrue(proposal.preview.contains("upstream=ready")); XCTAssertFalse(proposal.preview.contains("owned-secret"))
        try Data("changed-by-user\n".utf8).write(to: file)
        do { _ = try await proposal.apply(); XCTFail("Conflict must prevent write") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed-by-user\n")
        try Data("upstream=broken\npassword=owned-secret\n".utf8).write(to: file)
        let fresh = try await AIFileProposal(backend: LocalFiles(), path: file.path, find: "upstream=broken", replacement: "upstream=ready")
        let result = try await fresh.apply(); XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "upstream=ready\npassword=owned-secret\n")
        XCTAssertEqual(try String(contentsOfFile: fresh.edit.backupPath, encoding: .utf8), "upstream=broken\npassword=owned-secret\n")
        XCTAssertTrue(result.output.contains("NOT yet been verified")); XCTAssertTrue(result.output.contains(fresh.edit.backupPath))
        do { _ = try await AIFileProposal(backend: LocalFiles(), path: file.path, find: "missing", replacement: "x"); XCTFail("Must not guess replacement") } catch { }
    }
    func testNetworkServiceConfigDiffApplyRecoveryAndHistory() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("service.conf"), portFile = root.appendingPathComponent("port")
        try Data("upstream=broken\n".utf8).write(to: config)
        let python = Process(); python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-u", "-c", """
        import http.server, pathlib, sys
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                ready = 'upstream=ready' in pathlib.Path(sys.argv[1]).read_text()
                self.send_response(200 if ready else 503); self.end_headers(); self.wfile.write(b'healthy' if ready else b'broken')
            def log_message(self, *args): pass
        server=http.server.HTTPServer(('127.0.0.1',0),Handler)
        pathlib.Path(sys.argv[2]).write_text(str(server.server_port)); server.serve_forever()
        """, config.path, portFile.path]
        python.standardOutput = FileHandle.nullDevice; python.standardError = FileHandle.nullDevice; try python.run(); defer { if python.isRunning { python.terminate() } }
        try await wait { FileManager.default.fileExists(atPath: portFile.path) }
        let port = try String(contentsOf: portFile, encoding: .utf8), id = UUID(); var round = 0, prompts: [String] = []
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, publish in
            prompts.append(prompt); round += 1
            let response: String
            switch round {
            case 1: response = try self.action("tcp_probe", "127.0.0.1:" + port)
            case 2: response = try self.action("inspect_port", port)
            case 3: response = try self.action("read_file", config.path)
            case 4: response = try self.action("replace_file", extra: ["path": config.path, "find": "upstream=broken", "replacement": "upstream=ready"])
            case 5: response = "文件已改好。" // Must not finish without a recovery check.
            case 6: response = try self.action("http_health", "http://127.0.0.1:" + port)
            default: response = "HTTP 200，healthy。测试服务已恢复。"
            }
            publish(response); return round == 4 ? try p0FixtureReply(response, goal: "检查网络、服务、配置，修复后验证恢复", tool: "http_health", argument: "http://127.0.0.1:" + port, expected: "healthy") : response
        })
        let executor = AICommandExecutor(sessionID: id, source: "owned localhost fixture", directory: root.path, valid: { true }, execute: { command, publish in try await AICommandExecutor.local(command: command, directory: root.path, update: publish) })
        executor.fileBackend = { LocalFiles() }
        ai.prepare(source: executor.source, text: "503 upstream unavailable", sessionID: id, question: "检查网络、服务、配置，修复后验证恢复")
        ai.send(executor: executor); try await wait { ai.pendingApproval != nil }
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "upstream=broken\n"); XCTAssertTrue(ai.approvalPreview.contains("upstream=ready"))
        ai.approveAction(); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertTrue(ai.answer.contains("已恢复"), prompts.joined(separator: "\n---\n")); XCTAssertEqual(round, 7)
        XCTAssertTrue(prompts[5].contains("requires a read-only")); XCTAssertTrue(prompts[6].contains("healthy")); XCTAssertEqual(ai.steps.count, 6)
        XCTAssertEqual(ai.taskRecords.last?.state, "finished")
        let loaded = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); XCTAssertEqual(loaded.taskRecords.count, 1); XCTAssertTrue(loaded.taskRecords[0].transcript.contains("healthy"))
        loaded.restoreTask(loaded.taskRecords[0]); XCTAssertTrue(loaded.question.isEmpty); XCTAssertEqual(loaded.submittedQuestion, ai.submittedQuestion); XCTAssertEqual(loaded.steps.count, ai.steps.count)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("ai.tasks.json").path)[.posixPermissions] as? NSNumber; XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testLongTasksRulesAndFollowupDoNotReplay() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }; var round = 0, calls = 0, lastPrompt = ""
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in round += 1; lastPrompt = prompt; return round <= 15 ? try p0FixtureReply(self.action("command", "printf owned"), goal: "执行长任务", tool: "verify_command", argument: "cat /owned/verification", expected: "owned") : round == 16 ? try self.action("verify_command", "cat /owned/verification") : "完成" })
        var policy = AIExecutionPolicy(); policy.rules = "allow|owned fixture|command|printf owned\nallow|owned fixture|verify_command|cat /owned/verification"; ai.settings.executionPolicy = policy
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned fixture", directory: root.path, valid: { true }, execute: { command, _ in calls += 1; return AICommandResult(output: command == "uname -s; pwd" ? "Darwin\n/tmp" : "owned", exitCode: 0) })
        ai.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: "执行长任务"); ai.send(executor: executor); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty); XCTAssertEqual(calls, 17); XCTAssertEqual(ai.steps.count, 17); XCTAssertNil(ai.pendingApproval)
        ai.prepare(source: executor.source, text: "latest", sessionID: executor.sessionID, question: "继续检查"); ai.send(executor: executor); try await wait { !ai.busy }
        XCTAssertTrue(lastPrompt.contains("Previous task evidence")); XCTAssertEqual(calls, 18, "Follow-up refreshes environment; never replays mutations")
        XCTAssertEqual(ai.taskRecords.count, 1)
    }
    func testAIEditorsAreHardDeniedEvenWithFullAccessAndRememberedAllow() async throws {
        for mode in AIExecutionPolicy.Mode.allCases {
            var policy = AIExecutionPolicy(); policy.approvalMode = mode; policy.commandWhitelist = ".*"; policy.rules = "allow|.*|command|.*"
            for command in ["vim test.sh", "/usr/bin/vi test.sh", "sudo nano test.sh", "env EDITOR=vi emacs test.sh", "printf ok; nvim test.sh", "bash -c 'vim test.sh'"] {
                XCTAssertEqual(policy.decision(target: "owned", tool: "command", argument: command, automatic: true), .deny, command)
            }
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); session.connected = true; session.commandHistoryToken = "fixture"
        let bridge = AITerminalBridge(session: session)
        let marker = "\u{1b}]7;axon-command;fixture;" + Data("vim test.sh".utf8).base64EncodedString() + "\u{7}"
        session.captureOutput(Array(marker.utf8)); session.aiShellInput.invalidate()
        let input = try XCTUnwrap(AIAgentAction.parse(action("terminal_send", "ihello")))
        let permission = bridge.permission(input, fallback: "ihello")
        XCTAssertTrue(AIBuiltInDeny.matches(permission.command))
        XCTAssertEqual(permission.tool, "terminal_editor")
        XCTAssertThrowsError(try AIExecutableInspection.programCommand(":wq", program: "vim test.sh", insertMode: false))
    }
    func testLiveTerminalShellREPLDatabaseAndFullScreen() async throws {
        _ = NSApplication.shared
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); session.connected = true
        let terminal = LocalTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 400)); terminal.ownerSession = session; session.terminal = terminal; terminal.terminalDelegate = session; session.commandHistoryStore = CommandHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let hook = root.appendingPathComponent("hooks.sh"); try Data(ShellCommandIntegration.script(token: "fixture-token").utf8).write(to: hook)
        session.commandHistoryToken = "fixture-token"
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--rcfile", hook.path, "-i"], environment: ["HOME=" + root.path, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color", "PS1=AXON_FIXTURE> "], currentDirectory: root.path)
        defer { terminal.terminate() }
        try await wait { session.commandHistoryReady && session.aiShellInput.line == "" }
        let bridge = AITerminalBridge(session: session)
        func perform(_ tool: String, _ value: String = "") async throws -> AICommandResult { let action = try XCTUnwrap(AIAgentAction.parse(self.action(tool, value))); _ = try action.command(os: "Darwin"); return try await bridge.run(action) { _ in } }
        _ = try await perform("terminal_send", "export AXON_FIXTURE_ENV=shared"); _ = try await perform("terminal_key", "enter")
        _ = try await perform("terminal_send", "printf 'ENV=%s\\n' \"$AXON_FIXTURE_ENV\""); let shell = try await perform("terminal_key", "enter"); XCTAssertTrue(shell.output.contains("ENV=shared")); XCTAssertTrue(shell.output.contains("Verified hook exit: 0"))
        _ = try await perform("terminal_send", "python3 -q"); _ = try await perform("terminal_key", "enter")
        _ = try await perform("terminal_send", "print('REPL_RESULT=' + str(6 * 7))"); let repl = try await perform("terminal_key", "enter"); XCTAssertTrue(repl.output.contains("REPL_RESULT=42"))
        _ = try await perform("terminal_key", "ctrl-d")
        _ = try await perform("terminal_send", "sqlite3 :memory:"); _ = try await perform("terminal_key", "enter")
        _ = try await perform("terminal_send", "select 'DATABASE_RESULT=' || (6 * 7);"); let database = try await perform("terminal_key", "enter"); XCTAssertTrue(database.output.contains("DATABASE_RESULT=42")); _ = try await perform("terminal_key", "ctrl-d")
        let script = root.appendingPathComponent("screen.py"); try Data("import sys,tty,termios\nfd=0; old=termios.tcgetattr(fd); tty.setraw(fd)\ntry:\n print('\\033[?1049h\\033[2J\\033[HAXON_FULLSCREEN',end='',flush=True); c=sys.stdin.read(1); print('\\r\\nKEY='+c,end='',flush=True); sys.stdin.read(1)\nfinally:\n print('\\033[?1049l',end='',flush=True); termios.tcsetattr(fd,termios.TCSADRAIN,old)\n".utf8).write(to: script)
        _ = try await perform("terminal_send", "python3 " + SnippetParameters.shellArgument(script.path)); let screen = try await perform("terminal_key", "enter"); XCTAssertTrue(screen.output.contains("AXON_FULLSCREEN"))
        let key = try await perform("terminal_send", "q"); XCTAssertTrue(key.output.contains("KEY=q")); _ = try await perform("terminal_send", "x")
        session.writeInput(Array("manual".utf8))
        do { _ = try await perform("terminal_send", "stale"); XCTFail("User input must invalidate the action") } catch { XCTAssertTrue(error.localizedDescription.contains("交回")) }
        _ = try await perform("terminal_read")
        bridge.acquireControl(UUID()) // Explicit handback is required after manual input.
        _ = try await perform("terminal_key", "ctrl-c")
        // Interactive fixtures may leave CR translation disabled; restore the owned PTY
        // using LF before installing the shell hook, instead of assuming Return is LF.
        _ = try await perform("terminal_send", "stty sane")
        _ = try await perform("terminal_key", "ctrl-j")
        try await wait { session.commandHistoryReady }
        let hookObservation = try await perform("terminal_read"); XCTAssertTrue(session.commandHistoryReady, hookObservation.output); XCTAssertEqual(session.aiShellInput.line, "")
        _ = try await perform("terminal_send", "printf 'HOOK_RANGE_FIXTURE\\n'; false"); let captured = try await perform("terminal_key", "enter")
        XCTAssertTrue(captured.output.contains("HOOK_RANGE_FIXTURE")); XCTAssertTrue(captured.output.contains("Verified hook exit: 1")); XCTAssertFalse(captured.output.contains("axon-command;fixture-token"))
        XCTAssertEqual(session.aiCommandCapture.finished.last?.exitCode, 1)
        session.captureOutput(Array("\u{1b}[?1".utf8)); session.captureOutput(Array("h".utf8)); XCTAssertTrue(session.aiApplicationCursor)
        session.captureOutput(Array("\u{1b}[?1l".utf8)); XCTAssertFalse(session.aiApplicationCursor)
        session.commandHistoryReady = true
        XCTAssertTrue(session.receiveCommandHistory("axon-command;fixture-token;end;7;0.1"))
        let verified = try await perform("terminal_read"); XCTAssertFalse(verified.output.contains("Verified shell-hook completion")); XCTAssertFalse(verified.output.contains("exit 7"))
        let waitTask = Task { @MainActor in try await perform("terminal_wait", "30") }; try await Task.sleep(for: .milliseconds(100)); waitTask.cancel()
        do { _ = try await waitTask.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertTrue(session.connected, "Stopping agent observation must retain user's terminal")
    }
    func testRememberedPermissionIsExactAndSystemDenyRunsNothing() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID(), settingsFile = root.appendingPathComponent("ai.json"); var round = 0, calls = 0
        let responder: (String, String, @escaping (String) -> Void) async throws -> String = { prompt, _, _ in round += 1; let goal = String(prompt.components(separatedBy: "Goal: ").last?.components(separatedBy: "\n").first ?? ""); return round == 1 ? try p0FixtureReply(self.action("command", "printf 'owned|fixture'"), goal: goal, tool: "http_health", argument: "http://owned-fixture/health", expected: "healthy") : round == 2 ? try self.action("http_health", "http://owned-fixture/health") : "验证完成" }
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned fixture", directory: root.path, valid: { true }, execute: { command, _ in calls += 1; return AICommandResult(output: command == "uname -s; pwd" ? "Darwin\n/tmp" : "HTTP/1.1 200 OK\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 0) }); executor.hostID = hostID
        let ai = AIAssistant(fileURL: settingsFile, modelResponder: responder); ai.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: "执行操作"); ai.send(executor: executor)
        try await wait { ai.pendingApproval != nil }; XCTAssertEqual(calls, 1); ai.rememberExactAction(); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(calls, 3); XCTAssertEqual(ai.settings.policy.exactAllows?.first?.argument, "printf 'owned|fixture'")
        round = 0
        let loaded = AIAssistant(fileURL: settingsFile, modelResponder: responder); loaded.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: "再做一次"); loaded.send(executor: executor); try await wait { !loaded.busy }
        XCTAssertNil(loaded.pendingApproval); XCTAssertTrue(loaded.error.isEmpty); XCTAssertEqual(calls, 6)
        round = 0; executor.hostID = UUID()
        loaded.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: "另一条路线"); loaded.send(executor: executor); try await wait { loaded.pendingApproval != nil }; loaded.resolveApproval(false); try await wait { !loaded.busy }; XCTAssertEqual(calls, 7, "Permission does not cross host IDs")
        var policy = AIExecutionPolicy(); policy.rules = "deny|.*|system_info|.*"; loaded.settings.executionPolicy = policy; loaded.question = "检查禁止规则"; loaded.send(executor: executor); try await wait { !loaded.busy }
        XCTAssertEqual(calls, 7); XCTAssertTrue(loaded.error.contains("禁止"))
    }
    func testTerminalTaskConsentUIAndScope() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"); let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute); defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: "/tmp/axon-task-capabilities-ui"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
        let terminal = LocalTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 760)); terminal.ownerSession = session; session.terminal = terminal
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--norc", "-i"], environment: ["HOME=" + root.path, "PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=OWNED> "], currentDirectory: root.path); defer { terminal.terminate() }
        try await wait { session.aiTerminalOutputRevision > 0 }
        // This consent fixture models a tracked interactive Bash without completion hooks.
        // Seed its start event; it still cannot claim a verified program exit.
        let start = "\u{1b}]7;axon-command;consent-fixture;" + Data("bash".utf8).base64EncodedString() + "\u{7}"
        session.aiCommandCapture.receive(Array(start.utf8), token: "consent-fixture")
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in round += 1; switch round { case 1: return try p0FixtureReply(self.action("terminal_send", "printf 'OWNED_INTERACTIVE_TASK\\n'"), goal: "在当前终端执行这项测试操作", tool: "verify_command", argument: "cat /owned/verification", expected: "OWNED_INTERACTIVE_TASK"); case 2: return try self.action("terminal_key", "enter"); case 3: try await Task.sleep(for: .milliseconds(200)); return try self.action("terminal_read"); default: return try self.action("report_blocker", "测试 Shell 没有配置 completion hooks，不能核验退出状态") } }); store.ai = ai
        let executor = AICommandExecutor(sessionID: session.id, source: "Local macOS / 本机 macOS", directory: root.path, valid: { session.connected }, execute: { _, _ in AICommandResult(output: "Darwin\n" + root.path, exitCode: 0) }); executor.terminalBridge = AITerminalBridge(session: session)
        let host = NSHostingView(rootView: HStack(spacing: 0) { CapabilityTerminal(view: terminal); AIAssistantPane(ai: ai, terminal: true, availableHeight: 760).frame(width: 320) }.environmentObject(store).frame(width: 1050, height: 760))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); defer { window.close() }
        ai.prepare(source: "本地终端", text: "", sessionID: session.id, question: "在当前终端执行这项测试操作"); ai.send(executor: executor); try await wait { ai.pendingApproval != nil }; try await Task.sleep(for: .milliseconds(150)); try snapshot(host, output.appendingPathComponent("terminal-consent-1050.png"))
        try press(host, "axon-ai-approval-scope"); try await Task.sleep(for: .milliseconds(150)); let scope = try XCTUnwrap(AxonMenuPopover.active); scope.highlighted = 1; XCTAssertTrue(scope.handleKey(36)); try await Task.sleep(for: .milliseconds(100)); try press(host, "axon-ai-approve"); try await wait { !ai.busy }; XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(ai.steps.count, 4); XCTAssertTrue(ai.steps.last?.output.contains("OWNED_INTERACTIVE_TASK") == true, ai.steps.last?.output ?? "no read output"); XCTAssertNil(ai.steps.last?.exitCode); XCTAssertTrue(ai.interactiveTaskApproved, "task scope approval was not retained")
        try await Task.sleep(for: .milliseconds(150)); try snapshot(host, output.appendingPathComponent("terminal-complete-1050.png"))
        round = 0; ai.prepare(source: "本地终端", text: "", sessionID: session.id, question: "新任务"); ai.send(executor: executor); try await wait { ai.pendingApproval != nil }; XCTAssertFalse(ai.interactiveTaskApproved); ai.cancel(); XCTAssertTrue(session.connected)
    }
    func testDiffApprovalHistoryAndPermissionUI() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let output = URL(fileURLWithPath: "/tmp/axon-task-capabilities-ui"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for width in [1050, 1400] {
            let file = root.appendingPathComponent("service-" + String(width) + ".conf"); try Data("upstream=http://fixture-old:8848\n".utf8).write(to: file)
            let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
            let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
            let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 760)); terminal.feed(text: "ERROR fixture: connection refused\r\n"); session.terminal = terminal
            var round = 0
            let ai = AIAssistant(fileURL: root.appendingPathComponent("ai-" + String(width) + ".json"), modelResponder: { _, _, _ in
                round += 1
                if round == 1 { return try p0FixtureReply(self.action("replace_file", extra: ["path": file.path, "find": "upstream=http://fixture-old:8848", "replacement": "upstream=http://fixture-new:8848"]), goal: "修复连接配置并验证服务恢复", tool: "http_health", argument: "http://fixture-owned:8848/health", expected: "healthy") }
                if round == 2 { return try self.action("http_health", "http://fixture-owned:8848/health") }
                return "服务已恢复，健康检查 HTTP 200。"
            })
            store.ai = ai
            ai.prepare(source: "本地终端", text: "ERROR fixture", sessionID: session.id, question: "修复连接配置并验证服务恢复")
            let executor = AICommandExecutor(sessionID: session.id, source: "Local macOS / 本机 macOS", directory: root.path, valid: { true }, execute: { command, _ in AICommandResult(output: command == "uname -s; pwd" ? "Darwin\n" + root.path : "HTTP/1.1 200 OK\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 0) }); executor.fileBackend = { LocalFiles() }
            let host = NSHostingView(rootView: HStack(spacing: 0) { CapabilityTerminal(view: terminal); AIAssistantPane(ai: ai, terminal: true, availableHeight: 760).frame(width: 320) }.environmentObject(store).frame(width: CGFloat(width), height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            ai.send(executor: executor); try await wait { ai.pendingApproval != nil }; try await Task.sleep(for: .milliseconds(150))
            try snapshot(host, output.appendingPathComponent("diff-approval-" + String(width) + ".png"))
            try press(host, "axon-ai-approve"); try await wait { !window.sheets.isEmpty }; try await Task.sleep(for: .milliseconds(200))
            let sheet = try XCTUnwrap(window.sheets.first?.contentView); try snapshot(sheet, output.appendingPathComponent("diff-sheet-" + String(width) + ".png"))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "upstream=http://fixture-old:8848\n")
            try press(sheet, "axon-ai-apply-diff"); try await wait { !ai.busy && window.sheets.isEmpty }; XCTAssertTrue(ai.error.isEmpty, ai.error)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "upstream=http://fixture-new:8848\n")
            try await Task.sleep(for: .milliseconds(150)); try snapshot(host, output.appendingPathComponent("verified-" + String(width) + ".png"))
            try press(host, "axon-ai-task-history"); try await wait { !window.sheets.isEmpty }; try await Task.sleep(for: .milliseconds(200))
            let history = try XCTUnwrap(window.sheets.first?.contentView); try snapshot(history, output.appendingPathComponent("history-" + String(width) + ".png")); try press(history, "axon-ai-continue-task")
            try await wait { window.sheets.isEmpty }; XCTAssertTrue(ai.question.isEmpty); XCTAssertEqual(ai.submittedQuestion, "修复连接配置并验证服务恢复"); XCTAssertFalse(ai.steps.isEmpty)
            window.close()
        }
        let store = AppStore(fileURL: root.appendingPathComponent("settings-workspace.json")); store.workspace.preferences.language = "zh-CN"; store.ai.settings.backend = .chatgpt
        store.ai.settings.executionPolicy = AIExecutionPolicy(rules: "allow|fixture-user@fixture-host:22|command|systemctl restart fixture-service\ndeny|.*|command|rm .*\nask|.*|terminal_key|enter")
        let host = NSHostingView(rootView: ScrollView { AISettingsPane(ai: store.ai).padding(20) }.environmentObject(store).frame(width: 840, height: 850).background(Palette.background).colorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 850), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150)); try snapshot(host, output.appendingPathComponent("permission-settings.png")); XCTAssertNotNil(accessible(host).first { read($0, "accessibilityIdentifier") as? String == "axon-ai-permission-rules" }); window.close()
    }
    func testOrdinaryFileWritesAreNotDiskOperationProhibitions() throws {
        XCTAssertTrue(AICommandExecutor.instructions.contains("using direct file operations or literal shell writes"))
        for command in ["touch /root/test.sh", "printf 'echo hello\\n' > /root/test.sh", "chmod +x /root/test.sh"] {
            XCTAssertFalse(AIBuiltInDeny.matches(command), command)
        }
        for command in ["mkfs.ext4 /dev/sdb", "wipefs /dev/sdb", "dd if=/tmp/image of=/dev/sdb", "fdisk /dev/sdb", "parted /dev/sdb mkpart primary 1 100"] {
            XCTAssertTrue(AIBuiltInDeny.matches(command), command)
        }
    }
    func testBuiltInRmDenyCannotBeOverriddenByConfiguration() throws {
        for mode in AIExecutionPolicy.Mode.allCases {
            var policy = AIExecutionPolicy(); policy.approvalMode = mode
            policy.commandWhitelist = ".*"; policy.commandBlacklist = ""; policy.rules = "allow|.*|*|.*"
            policy.exactAllows = [AIExactPermission(target: "fixture", tool: "command", argument: "rm a", global: true)]
            policy = try JSONDecoder().decode(AIExecutionPolicy.self, from: JSONEncoder().encode(policy))
            for command in ["rm a", "sudo rm -rf a", "/bin/rm a", "pwd && rm a", "r'm' a", "r\\m a"] {
                XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: command, automatic: true), .deny)
            }
            XCTAssertEqual(policy.decision(target: "other", tool: "terminal_execute", argument: "rm a", automatic: true), .deny)
        }
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess
        XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "rmdir a", automatic: false), .deny)
    }
    func testCommandNameListsBlockVariantsAndCompoundCommands() throws {
        var policy = AIExecutionPolicy(); policy.commandBlacklist = "rm"; policy.commandWhitelist = "printf"
        try policy.validate()
        for mode in AIExecutionPolicy.Mode.allCases {
            policy.approvalMode = mode
            for command in ["rm a", "sudo rm -rf a", "/bin/rm a", "pwd && rm a", "sh -c 'rm a'", "r\\m a", "r'm' a"] {
                XCTAssertEqual(policy.decision(target: "fixture", tool: "terminal_execute", argument: command, automatic: false), .deny, command)
            }
        }
        policy.approvalMode = .assisted
        XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "printf hello", automatic: false), .allow)
        XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "printf hello; touch a", automatic: false), .ask)
        XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "rmdir a", automatic: false), .deny)
        XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "cat rm.txt", automatic: false), .ask)
        var host = Host(name: "fixture", address: "fixture"); host.aiCommandBlacklist = "rm"
        let merged = AIExecutionPolicy().mergingCommandLists(host)
        XCTAssertEqual(merged.decision(target: "fixture", tool: "command", argument: "rm a", automatic: true), .deny)
    }
    func testApprovalModesListsAndEditableRulePersistence() throws {
        let old = Data("{\"maximumSteps\":60,\"commandSeconds\":120,\"taskMinutes\":30,\"rules\":\"\"}".utf8)
        var policy = try JSONDecoder().decode(AIExecutionPolicy.self, from: old)
        XCTAssertEqual(policy.mode, .assisted)
        let host = UUID()
        policy.exactAllows = [AIExactPermission(target: "fixture", tool: "command", argument: "printf allowed", hostID: host)]
        policy.commandWhitelist = "printf .*"
        policy.commandBlacklist = ".*secret.*\nrm .*"
        for mode in AIExecutionPolicy.Mode.allCases {
            policy.approvalMode = mode
            XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "printf secret", automatic: false, hostID: host), .deny)
            XCTAssertEqual(policy.decision(target: "fixture", tool: "read_file", argument: "/tmp/a", automatic: true, command: "rm /tmp/a"), .deny)
            XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "printf allowed", automatic: false, hostID: host), mode == .everyTime ? .ask : .allow)
            XCTAssertEqual(policy.decision(target: "fixture", tool: "replace_file", argument: "/tmp/a", automatic: false), mode == .fullAccess ? .allow : .ask)
            XCTAssertEqual(policy.decision(target: "fixture", tool: "system_info", argument: "", automatic: true), mode == .everyTime ? .ask : .allow)
        }
        policy.rules = "ask|.*|command|printf .*"
        XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "printf allowed", automatic: false, hostID: host), .ask)
        policy.rules = "deny|.*|command|.*"
        XCTAssertEqual(policy.decision(target: "fixture", tool: "command", argument: "printf allowed", automatic: false, hostID: host), .deny)
        policy.rules = ""; policy.commandBlacklist = "["; XCTAssertThrowsError(try policy.validate())
        policy.commandBlacklist = "rm .*"; policy.exactAllows?[0].argument = "printf changed"
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("settings.json")); var settings = ai.settings; settings.executionPolicy = policy
        try ai.save(settings, key: "")
        let restored = AIAssistant(fileURL: root.appendingPathComponent("settings.json"))
        XCTAssertEqual(restored.settings.policy, policy)
        XCTAssertEqual(restored.settings.policy.exactAllows?.first?.hostID, host)
    }
    func testEveryTimeAndFullAccessExecuteThroughAgent() async throws {
        for mode in [AIExecutionPolicy.Mode.everyTime, .fullAccess] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("service.conf"); try Data("old=value".utf8).write(to: file)
            var round = 0, executed = 0
            let ai = AIAssistant(fileURL: root.appendingPathComponent("settings.json"), modelResponder: { _, _, publish in
                round += 1
                let response: String
                if round == 1 { response = try p0FixtureReply(self.action("replace_file", extra: ["path": file.path, "find": "old=value", "replacement": "new=value"]), goal: "Repair and verify", tool: "verify_command", argument: "cat " + file.path, expected: "new=value") }
                else if round == 2 { response = try self.action("verify_command", "cat " + file.path) }
                else { response = "Service verified healthy" }
                publish(response); return response
            })
            var policy = AIExecutionPolicy(); policy.approvalMode = mode; policy.commandWhitelist = ".*"; ai.settings.executionPolicy = policy
            let executor = AICommandExecutor(sessionID: UUID(), source: "owned permissions fixture", directory: root.path, valid: { true }, execute: { command, _ in executed += 1; return AICommandResult(output: command.contains("uname") ? "Darwin\n" + root.path : "new=value", exitCode: 0) })
            executor.fileBackend = { LocalFiles() }
            ai.prepare(source: executor.source, text: "broken service", sessionID: executor.sessionID, question: "Repair and verify"); ai.send(executor: executor)
            if mode == .everyTime {
                try await wait { ai.pendingApproval != nil }; XCTAssertEqual(executed, 0); XCTAssertEqual(ai.pendingTool, "system_info"); ai.approveAction()
                try await wait { ai.pendingTool == "replace_file" }; XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old=value"); ai.approveAction()
                try await wait { ai.pendingTool == "verify_command" }; ai.approveAction()
            }
            try await wait { !ai.busy }; XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(executed, 2)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new=value")
            XCTAssertTrue(ai.steps.contains { $0.tool == "replace_file" && $0.output.contains("new=value") && $0.output.contains("@@ line") && $0.output.contains("Backup:") })
            XCTAssertTrue(ai.answer.contains("healthy")); XCTAssertNil(ai.pendingApproval)
        }
    }
    func testPermissionModePopoverAndRuleEditingUI() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: "/tmp/axon-0150-ui"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        var policy = AIExecutionPolicy(); policy.commandBlacklist = "rm .*"; policy.commandWhitelist = "printf .*"
        policy.exactAllows = [AIExactPermission(target: "fixture-user@long-fixture-host.example:22", tool: "command", argument: "systemctl restart fixture-service", hostID: UUID())]
        store.ai.settings.executionPolicy = policy
        for width in [1050, 1400] {
            let host = NSHostingView(rootView: ScrollView { ObservedPolicyFixture(ai: store.ai).frame(maxWidth: 800).padding(20) }.environmentObject(store).frame(width: CGFloat(width), height: 1050).background(Palette.background).colorScheme(.light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1050), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); try snapshot(host, output.appendingPathComponent("permissions-\(width).png"))
            try accessible(host).map { "\(read($0, "accessibilityRole") ?? "") \(read($0, "accessibilityIdentifier") ?? "") \(read($0, "accessibilityLabel") ?? "")" }.joined(separator: "\n").write(to: output.appendingPathComponent("ax-tree.txt"), atomically: true, encoding: .utf8)
            try press(host, "axon-ai-edit-rule-0"); try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotNil(accessible(host).first { ($0 as? NSTextField)?.placeholderString == "Argument" })
            try snapshot(host, output.appendingPathComponent("edit-rule-\(width).png"))
            try press(host, "axon-ai-rule-scope"); try await Task.sleep(for: .milliseconds(100))
            let scopeMenu = try XCTUnwrap(AxonMenuPopover.active)
            scopeMenu.highlighted = 1; XCTAssertTrue(scopeMenu.handleKey(36)); try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.ai.settings.policy.exactAllows?.first?.global, true)
            try snapshot(host, output.appendingPathComponent("global-rule-\(width).png"))
            try press(host, "axon-ai-rule-scope"); try await Task.sleep(for: .milliseconds(100))
            let originalScope = try XCTUnwrap(AxonMenuPopover.active); originalScope.highlighted = 0; XCTAssertTrue(originalScope.handleKey(36))
            XCTAssertNil(store.ai.settings.policy.exactAllows?.first?.global)
            let argumentField = try XCTUnwrap(accessible(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Argument" })
            argumentField.stringValue = "systemctl restart edited-fixture"
            argumentField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: argumentField))
            _ = argumentField.sendAction(argumentField.action, to: argumentField.target)
            XCTAssertEqual(store.ai.settings.policy.exactAllows?.first?.argument, "systemctl restart edited-fixture")

            let button = try XCTUnwrap(accessible(host).first { read($0, "accessibilityIdentifier") as? String == "axon-ai-approval-mode" } as? SelectionFieldButton)
            button.performClick(nil); try await Task.sleep(for: .milliseconds(150))
            let popup = try XCTUnwrap(AxonMenuPopover.active)
            try snapshot(try XCTUnwrap(popup.popover.contentViewController?.view.window?.contentView), output.appendingPathComponent("mode-popover-\(width).png"))
            XCTAssertTrue(popup.handleKey(125)); XCTAssertTrue(popup.handleKey(36))
            XCTAssertEqual(store.ai.settings.policy.mode, .fullAccess)
            store.ai.settings.executionPolicy?.approvalMode = .assisted
            if width == 1400 { try press(host, "axon-ai-remove-rule-0"); XCTAssertTrue(store.ai.settings.policy.exactAllows?.isEmpty == true) }
            window.close()
        }
    }
    private func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
    private func accessible(_ view: NSView) -> [NSObject] { var result: [NSObject] = [], seen = Set<ObjectIdentifier>(); func visit(_ object: NSObject) { guard seen.insert(ObjectIdentifier(object)).inserted else { return }; result.append(object); for child in read(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }; if let native = object as? NSView { for child in native.subviews { visit(child) } } }; visit(view); return result }
    private func press(_ view: NSView, _ identifier: String) throws { let object = try XCTUnwrap(accessible(view).first { read($0, "accessibilityIdentifier") as? String == identifier || ($0 as? NSView)?.identifier?.rawValue == identifier }); if let button = object as? NSButton { button.performClick(nil); return }; let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c) (AnyObject, Selector) -> Bool; XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)) }
    private func snapshot(_ view: NSView, _ url: URL) throws { view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep); try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url) }

}

private struct CapabilityTerminal: NSViewRepresentable {
    let view: TerminalView
    func makeNSView(context: Context) -> TerminalView { view }
    func updateNSView(_ view: TerminalView, context: Context) { }
}

private struct ObservedPolicyFixture: View {
    @ObservedObject var ai: AIAssistant
    var body: some View { AITaskPolicyFields(policy: Binding(get: { ai.settings.policy }, set: { ai.settings.executionPolicy = $0 })) }
}
