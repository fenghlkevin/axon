import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import TabbyNative

@MainActor final class AIP0ReliabilityTests: XCTestCase {
    private func action(_ tool: String, _ argument: String = "") -> AIAgentAction {
        AIAgentAction(tool: tool, argument: argument, reason: "检查原目标", path: nil, find: nil, replacement: nil)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out")
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axon-p0-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testNativeToolStreamsBufferUntilCompleteAndRejectMultipleCalls() throws {
        let reply = AIStructuredReply(answer: "检查 8080", action: action("inspect_port", "8080"))
        let json = try reply.serialized()
        for backend in [AIBackend.chatgpt, .claude] {
            var stream = AIStreamEvents(structured: true)
            func emit(_ event: [String: Any]) throws {
                let data = try JSONSerialization.data(withJSONObject: event)
                try stream.line("data: " + String(decoding: data, as: UTF8.self), backend: backend)
                try stream.line("", backend: backend)
            }
            if backend == .claude { try emit(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "fixture-call", "name": "axon_step", "input": [:]]]) }
            else { try emit(["choices": [["delta": ["tool_calls": [["index": 0, "id": "fixture-call", "type": "function", "function": ["name": "axon_step"]]]]]]]) }
            for fragment in [String(json.prefix(20)), String(json.dropFirst(20))] {
                if backend == .claude { try emit(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": fragment]]) }
                else { try emit(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": fragment]]]]]]]) }
                XCTAssertTrue(stream.text.isEmpty); XCTAssertThrowsError(try stream.result())
            }
            if backend == .claude {
                try emit(["type": "content_block_stop", "index": 1]); try emit(["type": "message_delta", "delta": ["stop_reason": "tool_use"]]); try emit(["type": "message_stop"])
            } else { try emit(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]); try stream.line("data: [DONE]", backend: backend); try stream.line("", backend: backend) }
            XCTAssertEqual(try AIStructuredReply.decode(stream.result()).action, reply.action)
        }
        var multiple = AIStreamEvents(structured: true)
        try multiple.line(#"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"axon_step"}}]}}]}"#, backend: .chatgpt)
        XCTAssertThrowsError(try multiple.line("", backend: .chatgpt))
        XCTAssertThrowsError(try AIStructuredReply.decode(#"{"answer":"done","action":null,"memory":null,"checks":null,"extra":"ignored"}"#))
    }
    func testRetryClassificationBoundsAndCancellation() {
        for code in [408, 429, 500, 502, 503, 504, 529] { XCTAssertNotNil(AIModelRetry.delay(for: AIModelError.http(code, 300), attempt: 0)); XCTAssertEqual(AIModelRetry.delay(for: AIModelError.http(code, 300), attempt: 0), 30) }
        for code in [400, 401, 403, 404] { XCTAssertNil(AIModelRetry.delay(for: AIModelError.http(code, nil), attempt: 0)) }
        XCTAssertNil(AIModelRetry.delay(for: CancellationError(), attempt: 0)); XCTAssertNil(AIModelRetry.delay(for: AIModelError.http(503, nil), attempt: 2))
        XCTAssertEqual(AIModelRetry.retryAfter("2"), 2); XCTAssertNil(AIModelRetry.retryAfter("nan"))
    }
    func testVerificationRejectsUnrelatedTargetsFakeSuccessAndInvalidatesAllChecks() throws {
        let a = AIVerificationCheck(goal: "恢复服务", tool: "http_health", argument: "http://owned/health", expectedOutput: "healthy")
        let b = AIVerificationCheck(goal: "恢复服务", tool: "read_file", argument: "/owned/service.conf", expectedOutput: "upstream=ready")
        var state = AIVerificationState(); try state.configure([a, b], goal: "恢复服务"); state.changed()
        state.observe(tool: "http_health", argument: "http://unrelated/health", result: .init(output: "HTTP/1.1 200 OK\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 0)); XCTAssertTrue(state.passed.isEmpty)
        state.observe(tool: "http_health", argument: a.argument, result: .init(output: "HTTP/1.1 302 Found\nhealthy", exitCode: 0)); XCTAssertTrue(state.passed.isEmpty)
        XCTAssertFalse(a.accepts(.init(output: "HTTP/1.1 200 Connection established\nHTTP/2 302\nhealthy\nAXON_HTTP_STATUS:200\nAXON_HTTP_STATUS:302\n", exitCode: 0)))
        state.observe(tool: "http_health", argument: a.argument, result: .init(output: "HTTP/2 200\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 1)); XCTAssertTrue(state.passed.isEmpty)
        state.observe(tool: "http_health", argument: a.argument, result: .init(output: "HTTP/2 200\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 0)); XCTAssertEqual(state.passed, [0]); XCTAssertTrue(state.pending)
        XCTAssertThrowsError(try state.configure([b], goal: "恢复服务"))
        state.changed(); XCTAssertTrue(state.passed.isEmpty)
        state.observe(tool: "read_file", argument: b.argument, result: .init(output: "upstream=ready", exitCode: 0)); XCTAssertTrue(state.pending)
        state.observe(tool: "http_health", argument: a.argument, result: .init(output: "HTTP/2 200\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 0)); XCTAssertFalse(state.pending)
        for command in ["printf healthy", "true", "echo healthy", "cat /file > /tmp/change", "rg --pre=script healthy", "systemctl restart service", "docker exec c script"] { XCTAssertFalse(AIVerificationCheck.readOnlyCommand(command)) }
        XCTAssertThrowsError(try a.validate(goal: "不同目标"))
    }
    func testMemoryKeepsPinnedGoalFailuresDecisionsAndPendingChecksAcrossTruncationAndDisk() throws {
        var memory = AITaskMemory(goal: "修复原服务且保留配置", target: "owned@host", directory: "/owned")
        memory.merge(.init(facts: ["root cause hypothesis"], decisions: ["保留原配置"], remaining: ["验收原端口"]))
        memory.observe(.init(command: "inspect", reason: "fixture", output: "ORIGINAL_FAILURE", exitCode: 7, state: "finished", tool: "inspect_port"))
        for _ in 0..<80 { memory.observe(.init(command: "inspect", reason: "fixture", output: String(repeating: "logs", count: 5000), exitCode: 0, state: "finished", tool: "read_file")) }
        var state = AIVerificationState(); try state.configure([.init(goal: memory.goal, tool: "inspect_port", argument: "8080", expectedOutput: "LISTEN")], goal: memory.goal); state.changed()
        let prompt = AITaskWorkingContext.prompt(String(repeating: "huge log ", count: 100000), memory: memory, verification: state)
        XCTAssertLessThan(prompt.count, 80000)
        for value in [memory.goal, "ORIGINAL_FAILURE", "保留原配置", "验收原端口", "PENDING", "8080"] { XCTAssertTrue(prompt.contains(value), value) }
        let record = AITaskRecord(id: UUID(), sessionID: UUID(), hostID: nil, target: memory.target, question: memory.goal, transcript: "", summary: "", state: "interrupted", updated: Date(), workingMemory: memory, verification: state)
        let decoded = try JSONDecoder().decode(AITaskRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.workingMemory, memory); XCTAssertEqual(decoded.verification, state)
    }
    func testOversizedSingleTaskRemainsReloadableWithFrozenChecksAndMemory() throws {
        let memory = AITaskMemory(goal: "原目标", target: "owned", directory: "/owned")
        var state = AIVerificationState(); try state.configure([.init(goal: memory.goal, tool: "read_file", argument: "/owned/config", expectedOutput: "ready")], goal: memory.goal); state.changed()
        let text = String(repeating: "verbose-output ", count: 1800)
        let steps = (0..<200).map { _ in AIAgentStep(command: "head /owned/config", reason: "fixture", output: text, exitCode: 0, state: "finished", tool: "read_file") }
        let turn = AIAssistant.ConversationTurn(question: memory.goal, answer: "unfinished", steps: steps, error: "", executed: true)
        let record = AITaskRecord(id: UUID(), sessionID: UUID(), hostID: nil, target: memory.target, question: memory.goal, transcript: "recent", summary: "", state: "interrupted", updated: Date(), turns: [turn], workingMemory: memory, verification: state)
        XCTAssertGreaterThan(try JSONEncoder().encode([record]).count, AITaskJournal.maximumBytes)
        let journal = try AITaskJournal.bounded([record])
        XCTAssertLessThanOrEqual(journal.data.count, AITaskJournal.maximumBytes)
        let loaded = try JSONDecoder().decode([AITaskRecord].self, from: journal.data)
        XCTAssertEqual(loaded[0].verification, state); XCTAssertEqual(loaded[0].workingMemory, memory)
        XCTAssertEqual(loaded[0].turns?.first?.steps.count, 200); XCTAssertTrue(loaded[0].turns?.first?.steps.last?.output.contains("omitted") == true)
    }
    func testEmptyChecksDuringInspectionAndAfterMutationKeepVerification() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        var round = 0, commands: [String] = []
        let goal = "用 vim 打开 s.sh 输出 hello world"
        let check = AIVerificationCheck(goal: goal, tool: "read_file", argument: "/owned/s.sh", expectedOutput: "hello world")
        let ai = AIAssistant(fileURL: directory.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            round += 1
            switch round {
            case 1: return try AIStructuredReply(answer: "检查", action: self.action("list_directory", "/owned"), checks: []).serialized()
            case 2: return try AIStructuredReply(answer: "修改", action: self.action("command", "printf repair"), checks: [check]).serialized()
            case 3: return try AIStructuredReply(answer: "完成", action: nil, checks: []).serialized()
            case 4:
                XCTAssertTrue(prompt.contains("PENDING"))
                return try AIStructuredReply(answer: "验证", action: self.action("read_file", check.argument), checks: []).serialized()
            default: return try AIStructuredReply(answer: "验收通过", action: nil, checks: []).serialized()
            }
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned fixture", directory: directory.path, valid: { true }, execute: { command, _ in
            commands.append(command)
            return .init(output: command == "uname -s; pwd" ? "Linux\n/owned" : "hello world", exitCode: 0)
        })
        ai.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: goal); ai.send(executor: executor)
        try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(round, 5)
        XCTAssertEqual(commands.filter { $0 == "printf repair" }.count, 1)
        XCTAssertEqual(ai.taskRecords.last?.verification?.checks, [check])
        XCTAssertEqual(ai.taskRecords.last?.verification?.pending, false)
    }
    func testGoalWhitespaceCanonicalizationAndFieldRepairHints() throws {
        let goal = "新建一个脚本 ,能让脚本输出 hello world,最后再执行一次"
        let proposed = AIVerificationCheck(goal: "新建一个脚本, 能让脚本输出 hello world, 最后再执行一次", tool: "read_file", argument: "/owned/s.sh", expectedOutput: "hello world")
        var state = AIVerificationState()
        try state.configure([proposed], goal: goal)
        XCTAssertEqual(state.checks[0].goal, goal)
        XCTAssertTrue(state.prompt.contains("goal"))
        XCTAssertThrowsError(try AIVerificationCheck(goal: "新建一个脚本", tool: "read_file", argument: "/owned/s.sh", expectedOutput: "hello world").validate(goal: goal))
        let malformed = #"{"answer":"create","action":{"tool":"command","argument":"printf hello","reason":"create"},"memory":null,"checks":null}"#
        do { _ = try AIStructuredReply.decode(malformed); XCTFail("Must reject missing fields") }
        catch let error as AIModelError { XCTAssertTrue(error.repairHint?.contains("action") == true) }
    }
    func testVerificationRepairExplainsGoalAndScriptRejections() throws {
        for check in [AIVerificationCheck(goal: "wrong goal", tool: "read_file", argument: "/owned/s.sh", expectedOutput: "hello world"),
                      AIVerificationCheck(goal: "goal", tool: "verify_command", argument: "bash /owned/s.sh", expectedOutput: "hello world")] {
            do { try check.validate(goal: "goal"); XCTFail("Must reject") }
            catch let failure as AIModelError { XCTAssertNotNil(failure.repairHint); XCTAssertFalse(failure.repairHint!.isEmpty) }
        }
    }
    func testMalformedReplyRecoveryAndNoPrematureFinalAnswer() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        var round = 0, commands: [String] = []
        let check = AIVerificationCheck(goal: "修复服务", tool: "http_health", argument: "http://owned/health", expectedOutput: "healthy")
        let ai = AIAssistant(fileURL: directory.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            round += 1
            switch round {
            case 1: return "{broken"
            case 2: XCTAssertTrue(prompt.contains("No operation was executed")); return try AIStructuredReply(answer: "修复", action: self.action("command", "printf repair"), checks: [check]).serialized()
            case 3: return try AIStructuredReply(answer: "完成", action: nil).serialized()
            case 4: XCTAssertTrue(prompt.contains("PENDING")); return try AIStructuredReply(answer: "检查其他服务", action: self.action("http_health", "http://unrelated/health")).serialized()
            case 5: return try AIStructuredReply(answer: "检查原服务", action: self.action("http_health", check.argument)).serialized()
            default: return try AIStructuredReply(answer: "原服务验收通过", action: nil).serialized()
            }
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned fixture", directory: directory.path, valid: { true }, execute: { command, _ in commands.append(command); return .init(output: command == "uname -s; pwd" ? "Darwin\n/owned" : "HTTP/1.1 200 OK\nhealthy\nAXON_HTTP_STATUS:200\n", exitCode: 0) })
        ai.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: check.goal); ai.send(executor: executor); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(commands.filter { $0 == "printf repair" }.count, 1)
        XCTAssertEqual(commands.count, 4); XCTAssertEqual(round, 6); XCTAssertEqual(ai.taskRecords.last?.state, "finished")
        XCTAssertEqual(ai.taskRecords.last?.verification?.pending, false); XCTAssertTrue(ai.verificationStatus.contains("通过"))
    }
    func testAPIRateLimitAndInterruptedNativeToolRetryNeverReplayCommands() async throws {
        _ = NSApplication.shared
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.py"), portFile = directory.appendingPathComponent("port")
        let python = #"""
        import http.server,json,pathlib,sys
        counts={}
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                n=counts.get(self.path,0)+1;counts[self.path]=n
                pathlib.Path(sys.argv[2]+'/'+self.path[1:]+'.count').write_text(str(n))
                if self.path=='/auth':
                    self.send_response(401);self.end_headers();return
                claude=self.path=='/claude'
                assert body['tools'][0].get('name',body['tools'][0].get('function',{}).get('name'))=='axon_step'
                if n==1:
                    self.send_response(429);self.send_header('Retry-After','0');self.end_headers();return
                action=None;checks=None
                if n in [2,3]:
                    action={'tool':'command','argument':'printf repair','reason':'Repair owned fixture','path':None,'find':None,'replacement':None}
                    checks=[{'goal':'修复配置','tool':'read_file','argument':'/owned/config','expectedOutput':'upstream=ready'}]
                elif n==4:action={'tool':'read_file','argument':'/owned/config','reason':'Verify original goal','path':None,'find':None,'replacement':None}
                text=json.dumps({'answer':'配置验收通过' if action is None else '检查配置','action':action,'memory':None,'checks':checks})
                self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
                def emit(event):self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode());self.wfile.flush()
                if claude:emit({'type':'content_block_start','index':0,'content_block':{'type':'tool_use','id':'call_'+str(n),'name':'axon_step','input':{}}})
                parts=[text[:len(text)//2],text[len(text)//2:]]
                for i,part in enumerate(parts):
                    if n==2 and i==1:return
                    if claude:emit({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json':part}})
                    else:emit({'choices':[{'delta':{'tool_calls':[dict({'index':0,'function':dict({'arguments':part},**({'name':'axon_step'} if i==0 else {}))},**({'id':'call_'+str(n)} if i==0 else {}))]}}]})
                if claude:
                    emit({'type':'content_block_stop','index':0});emit({'type':'message_delta','delta':{'stop_reason':'tool_use'}});emit({'type':'message_stop'})
                else:
                    emit({'choices':[{'delta':{},'finish_reason':'tool_calls'}]});self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
        server=http.server.HTTPServer(('127.0.0.1',0),Handler)
        pathlib.Path(sys.argv[1]).write_text(str(server.server_port));server.serve_forever()
        """#
        try python.write(to: script, atomically: true, encoding: .utf8)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [script.path, portFile.path, directory.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        try await wait { FileManager.default.fileExists(atPath: portFile.path) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let screenshots = URL(fileURLWithPath: "/tmp/axon-p0-ui"); try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        for backend in [AIBackend.claude, .chatgpt] {
            let store = AppStore(fileURL: directory.appendingPathComponent(backend.rawValue + "-workspace.json")); store.workspace.preferences.language = "zh-CN"
            let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
            let ai = AIAssistant(fileURL: directory.appendingPathComponent(backend.rawValue + ".json"), apiKeyReader: { _ in "owned-fixture" }); store.ai = ai
            ai.settings.backend = backend
            let provider = AIProviderSettings(endpoint: "http://127.0.0.1:" + port + "/" + backend.rawValue, model: "fixture")
            if backend == .claude { ai.settings.claude = provider } else { ai.settings.chatgpt = provider }
            var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
            var commands: [String] = []
            let executor = AICommandExecutor(sessionID: session.id, source: "owned-user@long-production-fixture.example:22", directory: "/owned", valid: { true }, execute: { command, _ in commands.append(command); return .init(output: command == "uname -s; pwd" ? "Linux\n/owned" : command == "printf repair" ? "repair" : "upstream=ready", exitCode: 0) })
            ai.prepare(source: executor.source, text: "synthetic fixture", sessionID: session.id, question: "修复配置"); ai.send(executor: executor)
            try await wait { ai.activity.contains("Reconnecting") }
            XCTAssertEqual(commands, ["uname -s; pwd"])
            for width in [1050, 1400] {
                let host = NSHostingView(rootView: HStack(spacing: 0) { WorkspaceNavigation(settingsPage: .constant(.ai)).frame(width: 190); Color.black; AIAssistantPane(ai: ai, terminal: true, availableHeight: 760).frame(width: width == 1050 ? 320 : 500) }.environmentObject(store).frame(width: CGFloat(width), height: 760))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100)); try snapshot(host, screenshots.appendingPathComponent("reconnecting-\(backend.rawValue)-\(width).png")); window.close()
            }
            try await wait { !ai.busy }
            XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(commands.filter { $0 == "printf repair" }.count, 1); XCTAssertEqual(commands.count, 3)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(backend.rawValue + ".count"), encoding: .utf8), "5")
            XCTAssertEqual(ai.answer, "配置验收通过"); XCTAssertEqual(ai.taskRecords.last?.verification?.pending, false)
            let loaded = AIAssistant(fileURL: directory.appendingPathComponent(backend.rawValue + ".json")); XCTAssertNotNil(loaded.taskRecords.last?.workingMemory)
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 760).environmentObject(store).frame(width: 500, height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); try snapshot(host, screenshots.appendingPathComponent("verified-\(backend.rawValue).png"))
            ai.settings.backend = .chatgpt; ai.settings.chatgpt = .init(endpoint: "http://127.0.0.1:" + port + "/auth", model: "fixture"); ai.question = "继续只读检查"; ai.send(executor: executor); try await wait { !ai.busy }
            XCTAssertTrue(ai.error.contains("401")); XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("auth.count"), encoding: .utf8), backend == .claude ? "1" : "2")
            try await Task.sleep(for: .milliseconds(100)); try snapshot(host, screenshots.appendingPathComponent("credentials-error-\(backend.rawValue).png")); window.close()
        }
    }
    func testCancelDuringRetryAndResumePendingVerificationWithoutReplay() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        var requests = 0, commands = 0
        let ai = AIAssistant(fileURL: directory.appendingPathComponent("retry.json"), modelResponder: { _, _, _ in requests += 1; throw AIModelError.http(429, 30) })
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: directory.path, valid: { true }, execute: { _, _ in commands += 1; return .init(output: "Darwin\n/owned", exitCode: 0) })
        ai.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: "检查"); ai.send(executor: executor); try await wait { ai.activity.contains("Reconnecting") }; ai.cancel()
        try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(requests, 1); XCTAssertEqual(commands, 1); XCTAssertFalse(ai.busy); XCTAssertTrue(ai.stopped)
        var state = AIVerificationState(); try state.configure([.init(goal: "原目标", tool: "read_file", argument: "/owned/config", expectedOutput: "ready")], goal: "原目标"); state.changed()
        let record = AITaskRecord(id: UUID(), sessionID: executor.sessionID, hostID: nil, target: executor.source, question: "原目标", transcript: "Previous command already executed", summary: "", state: "interrupted", updated: Date(), executed: true,
                                  workingMemory: .init(goal: "原目标", target: executor.source, directory: directory.path), verification: state)
        try JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("resume.tasks.json"))
        var rounds = 0
        let resumed = AIAssistant(fileURL: directory.appendingPathComponent("resume.json"), modelResponder: { prompt, _, _ in
            XCTAssertTrue(prompt.contains("Goal: 原目标")); rounds += 1
            if rounds == 1 { return try AIStructuredReply(answer: "检查原目标", action: self.action("read_file", "/owned/config")).serialized() }
            return try AIStructuredReply(answer: "原目标验收通过", action: nil).serialized()
        })
        resumed.restoreTask(try XCTUnwrap(resumed.taskRecords.first)); resumed.question = "继续"
        var replayed: [String] = []
        let observer = AICommandExecutor(sessionID: executor.sessionID, source: executor.source, directory: directory.path, valid: { true }, execute: { command, _ in replayed.append(command); return .init(output: command == "uname -s; pwd" ? "Darwin\n/owned" : "ready", exitCode: 0) })
        resumed.send(executor: observer); try await wait { !resumed.busy }
        XCTAssertTrue(resumed.error.isEmpty, resumed.error); XCTAssertEqual(replayed.count, 2); XCTAssertFalse(resumed.taskRecords.last?.verification?.pending ?? true)
    }
    func testCurrentTerminalUsesFreshHookEvidenceForMultipleChecksWithoutInvalidatingReadOnlyChecks() async throws {
        _ = NSApplication.shared
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
        let hook = directory.appendingPathComponent("hooks.sh"), a = directory.appendingPathComponent("a.conf"), b = directory.appendingPathComponent("b.conf")
        try ShellCommandIntegration.script(token: "p0-fixture-token").write(to: hook, atomically: true, encoding: .utf8)
        try "old-a".write(to: a, atomically: true, encoding: .utf8); try "old-b".write(to: b, atomically: true, encoding: .utf8)
        session.commandHistoryToken = "p0-fixture-token"
        let terminal = LocalTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); terminal.ownerSession = session; terminal.terminalDelegate = session; session.terminal = terminal
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--rcfile", hook.path, "-i"], environment: ["HOME=" + directory.path, "PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=OWNED> "], currentDirectory: directory.path)
        defer { terminal.terminate() }
        try await wait { session.commandHistoryReady && session.aiShellInput.line == "" }
        let readA = "head -n 120 -- " + SnippetParameters.shellArgument(a.path), readB = "head -n 120 -- " + SnippetParameters.shellArgument(b.path)
        let checks = [AIVerificationCheck(goal: "更新两个文件", tool: "verify_command", argument: readA, expectedOutput: "ready-a"), AIVerificationCheck(goal: "更新两个文件", tool: "verify_command", argument: readB, expectedOutput: "ready-b")]
        var round = 0
        let ai = AIAssistant(fileURL: directory.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in
            round += 1
            let step: AIAgentAction?
            switch round {
            case 1: step = self.action("terminal_send", "printf ready-a > " + SnippetParameters.shellArgument(a.path) + "; printf ready-b > " + SnippetParameters.shellArgument(b.path))
            case 2, 4, 6: step = self.action("terminal_key", "enter")
            case 3: step = self.action("terminal_send", readA)
            case 5: XCTAssertTrue(prompt.contains("Passed check indexes: [0]")); step = self.action("terminal_send", readB)
            default: step = nil
            }
            return try AIStructuredReply(answer: step == nil ? "两个文件验收通过" : "更新并验证", action: step, checks: round == 1 ? checks : nil).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned current shell", directory: nil, valid: { session.connected }, execute: { _, _ in XCTFail("No independent channel"); return .init(output: "", exitCode: 0) }); executor.terminalBridge = AITerminalBridge(session: session)
        ai.prepare(source: executor.source, text: "", sessionID: session.id, question: "更新两个文件"); ai.send(executor: executor); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(ai.answer, "两个文件验收通过"); XCTAssertEqual(round, 7)
        XCTAssertEqual(ai.taskRecords.last?.verification?.passed.sorted(), [0, 1]); XCTAssertFalse(ai.taskRecords.last?.verification?.pending ?? true)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "ready-a"); XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "ready-b")
    }
    func testHelloWorldScriptCreationExecutionAndFinalVerificationInRealTerminal() async throws {
        _ = NSApplication.shared
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); session.connected = true
        let work = directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let hook = directory.appendingPathComponent("hooks.sh"), script = work.appendingPathComponent("test.sh")
        try ShellCommandIntegration.script(token: "hello-fixture").write(to: hook, atomically: true, encoding: .utf8)
        session.commandHistoryToken = "hello-fixture"
        let terminal = LocalTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); terminal.ownerSession = session; terminal.terminalDelegate = session; session.terminal = terminal
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--rcfile", hook.path, "-i"], environment: ["HOME=" + directory.path, "PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=OWNED> "], currentDirectory: directory.path)
        defer { terminal.terminate() }
        try await wait { session.commandHistoryReady && session.aiShellInput.line == "" }
        let goal = "新建脚本输出 hello world", read = "cat ./test.sh"
        session.writeInput(Array(("cd " + SnippetParameters.shellArgument(work.path) + "\r").utf8))
        try await wait { session.currentDirectory == work.path && session.aiShellInput.line == "" }
        let check = AIVerificationCheck(goal: goal, tool: "verify_command", argument: read, expectedOutput: "echo 'hello world'")
        let create = "(set -C; printf '%s\\n' '#!/bin/sh' \"echo 'hello world'\" > ./test.sh)"
        var round = 0
        let ai = AIAssistant(fileURL: directory.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in
            round += 1
            let step: AIAgentAction?
            switch round {
            case 1: step = self.action("terminal_execute", create)
            case 2, 4: step = self.action("terminal_execute", read)
            case 3: step = self.action("command", "sh ./test.sh")
            default: step = nil
            }
            return try AIStructuredReply(answer: step == nil ? "脚本执行及验收通过" : "创建并检查脚本", action: step, checks: round == 1 ? [check] : nil).serialized()
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned fixture", directory: nil, valid: { session.connected }, execute: { _, _ in XCTFail("No independent command"); return .init(output: "", exitCode: 0) })
        executor.terminalBridge = AITerminalBridge(session: session); executor.fileBackend = { LocalFiles() }
        ai.prepare(source: executor.source, text: "", sessionID: session.id, question: goal); ai.send(executor: executor); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(round, 5)
        XCTAssertEqual(session.currentDirectory, work.path)
        XCTAssertEqual(ai.answer, "脚本执行及验收通过"); XCTAssertFalse(ai.taskRecords.last?.verification?.pending ?? true)
        XCTAssertTrue(session.aiCommandCapture.finished.contains { $0.command == "sh ./test.sh" && $0.exitCode == 0 && String(decoding: $0.output, as: UTF8.self).contains("hello world") })
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "#!/bin/sh\necho 'hello world'\n")
    }
    func testRealCodexNativeHelloWorldInCurrentTerminal() async throws { try await realHelloWorld(runtime: .codexNative) }
    func testRealOriginalAxonHelloWorldInCurrentTerminal() async throws { try await realHelloWorld(runtime: .axon) }
    private func realHelloWorld(runtime: AIAgentRuntime) async throws {
        guard ProcessInfo.processInfo.environment["AXON_TEST_CODEX"] == "1" else { throw XCTSkip("Opt-in authenticated native-tool fixture") }
        _ = NSApplication.shared
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); session.connected = true
        session.commandHistoryStore = CommandHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let work = directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let hook = directory.appendingPathComponent("hooks.sh"), script = work.appendingPathComponent("test.sh")
        try ShellCommandIntegration.script(token: "hello-fixture").write(to: hook, atomically: true, encoding: .utf8)
        session.commandHistoryToken = "hello-fixture"
        let terminal = LocalTerminal(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); terminal.ownerSession = session; terminal.terminalDelegate = session; session.terminal = terminal
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--rcfile", hook.path, "-i"], environment: ["HOME=" + directory.path, "PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=OWNED> "], currentDirectory: directory.path)
        defer { terminal.terminate() }
        try await wait { session.commandHistoryReady && session.aiShellInput.line == "" }
        let goal = "新建脚本输出 hello world", read = "cat ./test.sh"
        session.writeInput(Array(("cd " + SnippetParameters.shellArgument(work.path) + "\r").utf8))
        try await wait { session.currentDirectory == work.path && session.aiShellInput.line == "" }
        let ai = AIAssistant(fileURL: directory.appendingPathComponent("ai.json")); ai.settings.agentRuntime = runtime
        let models = try await CodexModelCatalog.discover(settings: ai.settings)
        let model = try XCTUnwrap(models.first { $0.efforts.contains("low") }); ai.settings.codexModel = model.slug; ai.settings.codexReasoningEffort = "low"
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; policy.maximumSteps = 15; ai.settings.executionPolicy = policy; ai.executionChannel = .currentTerminal
        let executor = AICommandExecutor(sessionID: session.id, source: "owned fixture", directory: nil, valid: { session.connected }, execute: { _, _ in XCTFail("No independent command"); return .init(output: "", exitCode: 0) })
        executor.terminalBridge = AITerminalBridge(session: session); executor.fileBackend = { LocalFiles() }
        ai.prepare(source: executor.source, text: "", sessionID: session.id, question: goal + "，仅在当前测试目录新建 test.sh，最后执行一次。不要访问其他路径。"); ai.send(executor: executor)
        for _ in 0..<3000 where ai.busy { try await Task.sleep(for: .milliseconds(100)) }
        defer { ai.cancel() }; XCTAssertFalse(ai.busy)
        XCTAssertTrue(ai.error.isEmpty, ai.error + "\n" + (ai.taskRecords.last?.transcript.suffix(12000).description ?? ""))
        XCTAssertEqual(session.currentDirectory, work.path)
        XCTAssertFalse(ai.taskRecords.last?.verification?.pending ?? true)
        XCTAssertTrue(session.aiCommandCapture.finished.contains { $0.command.contains("test.sh") && !$0.command.contains("cat ") && $0.exitCode == 0 && String(decoding: $0.output, as: UTF8.self).contains("hello world") })
        XCTAssertTrue(try String(contentsOf: script, encoding: .utf8).contains("hello world"))
        XCTAssertTrue(ai.steps.contains { $0.modelCallID != nil })
    }
    func testModelRepairErrorNativeRendering() async throws {
        _ = NSApplication.shared
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let ai = AIAssistant(fileURL: directory.appendingPathComponent("ai.json"))
        ai.prepare(source: "owned fixture", text: "", sessionID: nil, question: "新建脚本输出 hello world")
        ai.error = AIModelError.invalidTaskReply("Invalid action terminal_execute: 参数无效。Use one complete shell command without literal newline/control characters.").localizedDescription
        let screenshots = URL(fileURLWithPath: "/tmp/axon-0187-ui")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        for width: CGFloat in [320, 600] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 760).environmentObject(store).frame(width: width, height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            try snapshot(host, screenshots.appendingPathComponent("model-error-" + String(Int(width)) + ".png"))
            window.close()
        }
    }
    private func snapshot(_ view: NSView, _ url: URL) throws {
        view.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
