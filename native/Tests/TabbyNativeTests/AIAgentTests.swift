import XCTest
import AppKit
import SwiftUI
@testable import Citadel
import NIOSSH
import NIO
import SwiftTerm
@testable import TabbyNative

@MainActor final class AIAgentTests: XCTestCase {
    private func action(_ tool: String, _ argument: String = "") -> String {
        let json: [String: String] = ["tool": tool, "argument": argument, "reason": "检查当前服务"]
        return "正在检查。\n```axon_action\n" + String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self) + "\n```"
    }
    private func wait(_ condition: () -> Bool) async throws { for _ in 0..<250 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }; XCTFail("Timed out") }
    func testAutomaticActionsRejectInjectionAndUnknownTools() throws {
        XCTAssertEqual(try AIAgentAction.parse(action("inspect_port", "8080"))?.command(os: "Darwin").text, "lsof -nP -iTCP:8080 -sTCP:LISTEN")
        XCTAssertEqual(try AIAgentAction.parse(action("inspect_port", "8080"))?.command(os: "Linux").text, "ss -lntup 'sport = :8080'")
        for pair in [("inspect_port", "8080; rm -rf /"), ("inspect_process", "1 && echo pwn"), ("list_directory", "--help"), ("unknown", "x"), ("command", "echo x\nrm x")] {
            let parsed = try XCTUnwrap(AIAgentAction.parse(action(pair.0, pair.1))); XCTAssertThrowsError(try parsed.command(os: "Linux"))
        }
        let path = "/tmp/a'; touch /tmp/unwanted; '"
        let parsed = try XCTUnwrap(AIAgentAction.parse(action("read_file", path)))
        XCTAssertEqual(try parsed.command(os: "Darwin").text, "head -n 120 -- " + SnippetParameters.shellArgument(path))
        XCTAssertFalse(try XCTUnwrap(AIAgentAction.parse(action("command", "sudo launchctl stop example"))).command(os: "Darwin").automatic)
        XCTAssertThrowsError(try AIAgentAction.parse(action("inspect_port", "8080") + action("command", "echo x")))
        XCTAssertEqual(AIAgentAction.visible("hello\n```axon_action\n{}"), "hello\n")
    }
    func testReadOnlyLoopAndExactResults() async throws {
        let id = UUID(); var requests: [String] = [], commands: [String] = [], round = 0
        let ai = AIAssistant(fileURL: URL(fileURLWithPath: "/tmp/axon-no-settings-" + UUID().uuidString), modelResponder: { prompt, instructions, update in
            XCTAssertTrue(instructions.contains("ONE action")); requests.append(prompt); round += 1
            let text = round == 1 ? self.action("inspect_port", "8080") : round == 2 ? self.action("inspect_process", "234") : "服务 example-java 正在监听 8080，PID 234。"
            update(text); return text
        })
        let executor = AICommandExecutor(sessionID: id, source: "fixture-user@fixture-host", directory: "/fixture", valid: { true }, execute: { command, update in
            commands.append(command)
            let text = commands.count == 1 ? "Darwin\n/fixture" : commands.count == 2 ? "java 234 fixture TCP *:8080 (LISTEN)" : "234 1 fixture 00:02 java example-java"
            update(text); return AICommandResult(output: text, exitCode: 0)
        })
        ai.prepare(source: executor.source, text: "log", sessionID: id, question: "谁占用8080"); ai.send(executor: executor)
        try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(commands.count, 3); XCTAssertEqual(ai.steps.count, 3)
        XCTAssertTrue(requests[1].contains("java 234")); XCTAssertTrue(requests[2].contains("Exit code: 0")); XCTAssertTrue(ai.answer.contains("234")); XCTAssertEqual(ai.answerSessionID, id)
        XCTAssertFalse(ai.answer.contains("axon_action"))
    }
    func testApprovalDeclineCancelAndDisconnectedTarget() async throws {
        for mode in ["approve", "decline", "cancel", "disconnect", "autoDisconnect"] {
            var valid = true, executed = 0, round = 0
            let id = UUID()
            let ai = AIAssistant(fileURL: URL(fileURLWithPath: "/tmp/axon-no-settings-" + UUID().uuidString), modelResponder: { _, _, _ in round += 1; return round == 1 ? try p0FixtureReply(self.action("command", "printf approved"), goal: "执行操作") : self.action("report_blocker", "Fixture intentionally has no health endpoint") })
            let executor = AICommandExecutor(sessionID: id, source: "original-target", directory: "/tmp", valid: { valid }, execute: { command, _ in
                executed += 1; return AICommandResult(output: command == "uname -s; pwd" ? "Darwin\n/tmp" : "approved", exitCode: 0)
            })
            ai.prepare(source: "target", text: "", sessionID: id, question: "执行操作"); ai.send(executor: executor)
            try await wait { ai.pendingApproval != nil }
            XCTAssertEqual(executed, 1, "No modification before approval")
            switch mode { case "approve": ai.approveAction(); case "decline": ai.resolveApproval(false); case "disconnect": valid = false; ai.approveAction(); case "autoDisconnect": valid = false; default: ai.cancel() }
            try await wait { !ai.busy }
            XCTAssertEqual(executed, mode == "approve" ? 2 : 1)
            XCTAssertNil(ai.pendingApproval)
            if mode == "disconnect" || mode == "autoDisconnect" { XCTAssertTrue(ai.error.contains("原会话")); XCTAssertNil(ai.answerSessionID) }
            if mode == "cancel" { XCTAssertTrue(ai.stopped) }
        }
    }
    func testLocalOutputExitCodeCwdAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-agent-test-" + UUID().uuidString + "' quoted")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var partial = ""
        let result = try await AICommandExecutor.local(command: "printf 'first\\n'; sleep .3; printf 'password=secret-value\\n' >&2; exit 7", directory: root.path) { partial = $0 }
        XCTAssertEqual(result.exitCode, 7); XCTAssertTrue(result.output.contains("first")); XCTAssertFalse(result.output.contains("secret-value")); XCTAssertTrue(partial.contains("first"))
        let cwd = try await AICommandExecutor.local(command: "pwd", directory: root.path) { _ in }
        XCTAssertTrue(cwd.output.contains(root.lastPathComponent))
        let file = root.appendingPathComponent("late-write")
        let work = Task { @MainActor in try await AICommandExecutor.local(command: "trap '' TERM; sleep 1; printf bad > " + SnippetParameters.shellArgument(file.path), directory: root.path) { _ in } }
        try await Task.sleep(for: .milliseconds(200)); work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled command returned success") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .seconds(1.2)); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testBothAPIsDriveExecutionLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-agent-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server.py"), portFile = root.appendingPathComponent("port")
        let python = #"""
        import http.server, json, sys, time
        counts = {}
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                claude=self.path=='/claude'
                instructions=body['system'] if claude else body['messages'][0]['content']
                assert 'ONE action' in instructions
                n=counts.get(self.path,0); counts[self.path]=n+1
                if n:
                    result=body['messages'][-1]['content'][0]['content'] if claude else body['messages'][-1]['content']
                    assert 'Actual result' in result and '321' in result
                    call=body['messages'][-2]['content'][0] if claude else body['messages'][-2]['tool_calls'][0]
                    assert call['id']=='call_0'
                    assert body['messages'][-1]['content'][0]['tool_use_id']=='call_0' if claude else body['messages'][-1]['tool_call_id']=='call_0'
                assert body['tools'][0].get('name',body['tools'][0].get('function',{}).get('name'))=='axon_step'
                action={'tool':'inspect_port','argument':'8080','reason':'查询8080','path':None,'find':None,'replacement':None} if not n else None
                text=json.dumps({'answer':'正在查询。' if not n else '检查完成：PID 321 正在监听 8080。','action':action,'memory':None,'checks':None})
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
                if claude:
                    self.wfile.write(('data: '+json.dumps({'type':'content_block_start','index':0,'content_block':{'type':'tool_use','id':'call_'+str(n),'name':'axon_step','input':{}}})+'\n\n').encode())
                for i,part in enumerate([text[:len(text)//2],text[len(text)//2:]]):
                    event={'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json':part}} if claude else {'choices':[{'delta':{'tool_calls':[dict({'index':0,'function':dict({'arguments':part},**({'name':'axon_step'} if i==0 else {}))},**({'id':'call_'+str(n)} if i==0 else {}))]}}]}
                    self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode()); self.wfile.flush(); time.sleep(.15)
                if claude:
                    for event in [{'type':'content_block_stop','index':0},{'type':'message_delta','delta':{'stop_reason':'tool_use'}}]: self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode())
                else: self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{},'finish_reason':'tool_calls'}]})+'\n\n').encode())
                self.wfile.write(('data: '+(json.dumps({'type':'message_stop'}) if claude else '[DONE]')+'\n\n').encode()); self.wfile.flush()
        server=http.server.HTTPServer(('127.0.0.1',0),Handler)
        open(sys.argv[1],'w').write(str(server.server_port))
        server.serve_forever()
        """#
        try Data(python.utf8).write(to: script)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); child.arguments = [script.path, portFile.path]; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); defer { if child.isRunning { child.terminate() } }
        try await wait { FileManager.default.fileExists(atPath: portFile.path) }
        let port = try String(contentsOf: portFile).trimmingCharacters(in: .whitespacesAndNewlines)
        for backend in [AIBackend.claude, .chatgpt] {
            let ai = AIAssistant(fileURL: root.appendingPathComponent(backend.rawValue + ".json"), apiKeyReader: { _ in "fixture-key" })
            ai.settings.backend = backend
            if backend == .claude { ai.settings.claude = AIProviderSettings(endpoint: "http://127.0.0.1:" + port + "/claude", model: "fixture") }
            else { ai.settings.chatgpt = AIProviderSettings(endpoint: "http://127.0.0.1:" + port + "/chatgpt", model: "fixture") }
            var calls = 0
            let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: "/tmp", valid: { true }, execute: { command, _ in calls += 1; return AICommandResult(output: command == "uname -s; pwd" ? "Darwin\n/tmp" : "java 321 TCP *:8080 (LISTEN)", exitCode: 0) })
            ai.prepare(source: "fixture", text: "", sessionID: executor.sessionID, question: "检查8080"); ai.send(executor: executor)
            try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(calls, 1, "Partial model action must not execute")
            try await wait { !ai.busy }; XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(calls, 2); XCTAssertTrue(ai.answer.contains("321"), ai.answer)
        }
    }
    func testRealCodexAgentReadOnlyTask() async throws {
        guard ProcessInfo.processInfo.environment["AXON_TEST_CODEX"] == "1" else { throw XCTSkip("Opt-in authenticated CLI smoke") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-agent-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("service.log"); try Data("service=AXON_FIXTURE_SERVICE\nport=8080\n".utf8).write(to: file)
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); let models = try await CodexModelCatalog.discover(settings: ai.settings)
        let model = try XCTUnwrap(models.first { $0.efforts.contains("low") }); ai.settings.codexModel = model.slug; ai.settings.codexReasoningEffort = "low"
        let executor = AICommandExecutor(sessionID: UUID(), source: "Owned local fixture", directory: root.path, valid: { true }, execute: { command, update in try await AICommandExecutor.local(command: command, directory: root.path, update: update) })
        ai.prepare(source: executor.source, text: "No file contents supplied", sessionID: executor.sessionID, question: "请使用 read_file 读取绝对路径 " + file.path + "，告诉我文件里的服务名。只读此文件，不请求其他命令。")
        ai.send(executor: executor)
        for _ in 0..<1300 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(100)) }
        defer { ai.cancel() }
        XCTAssertFalse(ai.busy); XCTAssertNil(ai.pendingApproval); XCTAssertTrue(ai.error.isEmpty, ai.error)
        XCTAssertGreaterThanOrEqual(ai.steps.count, 2); XCTAssertTrue(ai.steps.contains { $0.command.hasPrefix("head -n 120 -- ") })
        XCTAssertTrue(ai.answer.contains("AXON_FIXTURE_SERVICE"), ai.answer)
    }
    func testSSHExecStreamingCancellationKeepsConnection() async throws {
        final class FixtureExec: ExecDelegate, @unchecked Sendable {
            final class Context: ExecCommandContext {
                let child: Process
                init(_ child: Process) { self.child = child }
                func terminate() async throws { /* Simulate a server that does not kill on channel close. */ }
            }
            func setEnvironmentValue(_ value: String, forKey key: String) async throws { }
            func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
                let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/bash"); child.arguments = ["--noprofile", "--norc", "-c", command]
                child.standardInput = FileHandle.nullDevice; child.standardOutput = outputHandler.stdoutPipe; child.standardError = outputHandler.stderrPipe
                child.terminationHandler = { process in
                    try? outputHandler.stdoutPipe.fileHandleForWriting.close(); try? outputHandler.stderrPipe.fileHandleForWriting.close()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { outputHandler.succeed(exitCode: Int(process.terminationStatus)) }
                }
                try child.run(); return Context(child)
            }
        }
        final class FixtureAuth: NIOSSHServerUserAuthenticationDelegate {
            var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
            func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
                switch request.request {
                case .password(let value) where request.username == "axon-fixture" && value.password == "local-fixture": responsePromise.succeed(.success)
                default: responsePromise.succeed(.failure)
                }
            }
        }
        let auth = FixtureAuth()
        let server = try await SSHServer.host(host: "127.0.0.1", port: 0, hostKeys: [NIOSSHPrivateKey(p521Key: .init())], authenticationDelegate: auth)
        let delegate = FixtureExec(); server.enableExec(withDelegate: delegate)
        let port = try XCTUnwrap(server.channel.localAddress?.port)
        let client = try await SSHClient.connect(host: "127.0.0.1", port: port, authenticationMethod: .passwordBased(username: "axon-fixture", password: "local-fixture"), hostKeyValidator: .acceptAnything(), reconnect: .never)
        defer { Task { try? await client.close(); try? await server.close() } }
        var partial = ""
        let result = try await AICommandExecutor.remote(client: client, command: "printf 'first\\n'; sleep .2; printf 'second\\n' >&2; exit 9", directory: "/tmp") { partial = $0 }
        XCTAssertEqual(result.exitCode, 9); XCTAssertTrue(result.output.contains("first")); XCTAssertTrue(result.output.contains("second")); XCTAssertTrue(partial.contains("first"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ssh-exec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("late-write")
        let work = Task { @MainActor in try await AICommandExecutor.remote(client: client, command: "trap '' TERM; sleep 1; printf bad > " + SnippetParameters.shellArgument(file.path), directory: root.path) { _ in } }
        try await Task.sleep(for: .milliseconds(200)); work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch { }
        try await Task.sleep(for: .seconds(1.2)); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(client.isConnected)
        let after = try await AICommandExecutor.remote(client: client, command: "printf preserved", directory: "/tmp") { _ in }
        XCTAssertEqual(after.output, "preserved"); XCTAssertEqual(after.exitCode, 0)
    }
    func testExecutionUIApprovalAndEmptyStates() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-agent-ui-" + UUID().uuidString)
        let output = "/tmp/axon-agent-ui"; try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
        var round = 0, executed = 0; var roundGoal = "检查服务并修复"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in round += 1; return round == 1 ? try p0FixtureReply(self.action("command", "printf 'fixture approved'"), goal: roundGoal, tool: "http_health", argument: "http://owned-fixture:8080/health", expected: "healthy") : round == 2 ? self.action("http_health", "http://owned-fixture:8080/health") : "检查完成，服务正常。" })
        ai.prepare(source: "fixture-long-production-host", text: "ERROR test", sessionID: session.id, question: "检查服务并修复")
        let executor = AICommandExecutor(sessionID: session.id, source: "fixture-user@long-production-host.example:22", directory: "/srv/fixture project", valid: { true }, execute: { command, update in
            executed += 1
            if command != "uname -s; pwd" { update("Checking fixture service…"); try await Task.sleep(for: .milliseconds(350)) }
            return AICommandResult(output: command == "uname -s; pwd" ? "Linux\n/srv/fixture project" : "HTTP/1.1 200 OK\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 0)
        })
        store.ai = ai
        let terminalView = TerminalView(frame: NSRect(x:0,y:0,width:600,height:760)); terminalView.feed(text: "service example-java\r\nERROR upstream connection refused\r\n"); session.terminal = terminalView
        for width in [1050, 1400] {
            session.connected = true
            ai.prepare(source: "fixture-long-production-host", text: "ERROR test", sessionID: session.id, question: "检查服务并修复")
            let panelWidth = TerminalToolsPanel.allocatedWidth(selection: "ai", workspace: CGFloat(width))
            let host = NSHostingView(rootView: HStack(spacing: 0) { AgentPreviewTerminal(view: terminalView); TerminalToolsPanel(selection: .constant("ai"), isVisible: .constant(true), availableHeight: 760, panelWidth: panelWidth) }.environmentObject(store).frame(width: CGFloat(width), height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: width,height: 760),styleMask: [.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try snapshot(host, "\(output)/empty-\(width).png")
            round = 0; roundGoal = ai.question; ai.send(executor: executor); try await wait { ai.pendingApproval != nil }
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try snapshot(host, "\(output)/approval-\(width).png")
            let approve = try XCTUnwrap(accessible(host).first { read($0,"accessibilityIdentifier") as? String == "axon-ai-approve" })
            let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(approve.method(for: selector), to: Press.self)(approve, selector))
            try await wait { ai.steps.count == 2 }
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try snapshot(host, "\(output)/executing-\(width).png")
            try await wait { !ai.busy }; XCTAssertTrue(ai.error.isEmpty)
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try snapshot(host, "\(output)/finished-\(width).png")
            session.connected = false; ai.stopped = true; ai.error = "原会话已断开，任务停止。"; ai.steps[ai.steps.count - 1].state = "failed"; ai.steps[ai.steps.count - 1].exitCode = nil
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try snapshot(host, "\(output)/error-\(width).png")
            ai.prepare(source: "fixture", text: "", sessionID: nil, question: "检查服务")
            window.close()
        }
    }
    private func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
    private func accessible(_ view: NSView) -> [NSObject] { var result: [NSObject] = [], seen = Set<ObjectIdentifier>(); func visit(_ o: NSObject) { guard seen.insert(ObjectIdentifier(o)).inserted else { return }; result.append(o); for c in read(o,"accessibilityChildren") as? [NSObject] ?? [] { visit(c) } }; visit(view); return result }
    private func snapshot(_ view: NSView, _ path: String) throws { let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:rep); try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path)) }
}

private struct AgentPreviewTerminal: NSViewRepresentable {
    let view: TerminalView
    func makeNSView(context: Context) -> TerminalView { view }
    func updateNSView(_ nsView: TerminalView, context: Context) { }
}
