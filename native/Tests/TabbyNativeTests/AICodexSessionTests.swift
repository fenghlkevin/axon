import XCTest
@testable import TabbyNative

@MainActor final class AICodexSessionTests: XCTestCase {
    private func fixture(_ mode: String = "normal") throws -> (URL, AISettings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-native-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent(mode)
        try #"""
        #!/usr/bin/python3
        import sys,json,pathlib
        root=pathlib.Path(__file__).parent
        native=True
        def emit(x): print(json.dumps(x),flush=True)
        def call(rpc,cid):
            if pathlib.Path(__file__).name=='usage':
                n=1 if cid=='call-1' else 2
                emit({'method':'thread/tokenUsage/updated','params':{'threadId':'T','tokenUsage':{'total':{'inputTokens':100*n,'outputTokens':10*n,'cachedInputTokens':20*n,'reasoningOutputTokens':2*n}}}})
                emit({'method':'thread/tokenUsage/updated','params':{'threadId':'T','tokenUsage':{'total':{'inputTokens':100*n,'outputTokens':10*n,'cachedInputTokens':20*n,'reasoningOutputTokens':2*n}}}})
            tool='axon_read_file';args={'argument':'/owned/service.log','reason':'read'}
            if cid=='call-1' and pathlib.Path(__file__).name=='denied':tool='axon_command';args={'argument':'rm /owned/test.sh','reason':'remove'}
            if cid=='call-1' and pathlib.Path(__file__).name=='malformed':args['action']={}
            if not native:tool='axon_step';args={'answer':'check','action':{'tool':'read_file','argument':'/owned/service.log','reason':'read','path':None,'find':None,'replacement':None},'memory':None,'checks':None}
            emit({'id':rpc,'method':'item/tool/call','params':{'threadId':'T','turnId':'TURN','callId':cid,'tool':tool,'arguments':args}})
        turns=0
        for line in sys.stdin:
            e=json.loads(line)
            with (root/'requests.jsonl').open('a') as f:f.write(json.dumps(e)+'\n')
            if e.get('method')=='initialize':emit({'id':e['id'],'result':{}})
            elif e.get('method')=='config/read':emit({'id':e['id'],'result':{'config':{'mcp_servers':{'external-fixture':{'enabled':True}}}}})
            elif e.get('method')=='thread/start':
                native=any(t['name']=='axon_read_file' for t in e['params']['dynamicTools'])
                emit({'id':e['id'],'result':{'thread':{'id':'T'}}})
            elif e.get('method')=='turn/start':
                turns+=1;emit({'id':e['id'],'result':{'turn':{'id':'TURN'}}})
                if pathlib.Path(__file__).name=='flaky' and (root/'lost').exists():emit({'method':'turn/completed','params':{'turn':{'status':'completed','items':[{'type':'agentMessage','text':'RECOVERED'}]}}})
                elif turns==1:call('rpc-1','call-1')
                else:emit({'method':'turn/completed','params':{'turn':{'status':'completed','items':[{'type':'agentMessage','text':'FOLLOW_UP_OK'}]}}})
            elif e.get('id')=='rpc-1':
                if pathlib.Path(__file__).name=='flaky':(root/'lost').write_text('lost');sys.exit(0)
                elif pathlib.Path(__file__).name=='duplicate':call('rpc-2','call-1')
                else:call('rpc-2','call-2')
            elif e.get('id')=='rpc-2':emit({'method':'turn/completed','params':{'turn':{'status':'completed','items':[{'type':'agentMessage','text':'NATIVE_FINAL'}]}}})
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var settings = AISettings(); settings.codexPath = script.path; settings.agentRuntime = .codexNative
        return (root, settings)
    }
    func testNativeUsageCumulativeDeltasAreNotCountedTwice() async throws {
        let (root, settings) = try fixture("usage"); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AICodexSession(settings:settings,environment:ProcessInfo.processInfo.environment,instructions:"fixture"); defer { session.close() }
        var total = AIUsageSample(input:0,output:0,cached:0,reasoning:0), reports = 0
        session.usageHandler = { sample in total.add(sample); reports += 1 }
        _ = try await session.next("initial",publish:{_ in})
        _ = try await session.next("first result",publish:{_ in})
        _ = try await session.next("second result",publish:{_ in})
        XCTAssertEqual(reports,4); XCTAssertEqual(total.total,220); XCTAssertEqual(total.cached,40); XCTAssertEqual(total.reasoning,4)
    }
    func testOneThreadNativeCallResultsAndFollowUp() async throws {
        let (root, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AICodexSession(settings: settings, environment: ProcessInfo.processInfo.environment, instructions: "fixture")
        defer { session.close() }
        let pid = session.process.processIdentifier
        let first = try await session.next("INITIAL_CONTEXT", publish: { _ in }); XCTAssertEqual(try AIStructuredReply.decode(first).action?.tool, "read_file")
        XCTAssertEqual(session.lastCallID, "call-1")
        _ = try await session.next("RESULT_ONE", publish: { _ in })
        XCTAssertEqual(session.lastCallID, "call-2")
        let final = try await session.next("RESULT_TWO", publish: { _ in }); XCTAssertEqual(try AIStructuredReply.decode(final).answer, "NATIVE_FINAL")
        let followUp = try await session.next("NEW_USER_MESSAGE", publish: { _ in }); XCTAssertEqual(try AIStructuredReply.decode(followUp).answer, "FOLLOW_UP_OK")
        XCTAssertEqual(session.process.processIdentifier, pid)
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/start" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/start" }.count, 2)
        let start = try XCTUnwrap(requests.first { $0["method"] as? String == "thread/start" })
        let params = try XCTUnwrap(start["params"] as? [String: Any])
        let config = try XCTUnwrap(params["config"] as? [String: Any])
        let tools = try XCTUnwrap(params["dynamicTools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set(AIAgentAction.tools.map { "axon_" + $0 }))
        XCTAssertFalse((params["developerInstructions"] as? String ?? "").contains("Request ONE action per response via the axon_step"))
        let servers = try XCTUnwrap(config["mcp_servers"] as? [String: Any])
        XCTAssertEqual((servers["external-fixture"] as? [String: Bool])?["enabled"], false)
        let responses = requests.filter { $0["result"] != nil }
        XCTAssertEqual(responses.map { $0["id"] as? String }, ["rpc-1", "rpc-2"])
        XCTAssertFalse(String(describing: responses).contains("INITIAL_CONTEXT"))
        XCTAssertTrue(String(describing: responses).contains("RESULT_ONE"))
        session.close(); for _ in 0..<100 where session.process.isRunning { try await Task.sleep(for: .milliseconds(10)) }; XCTAssertFalse(session.process.isRunning)
    }
    func testAssistantReturnsResultsToNativeCallsAndKeepsFollowUpThread() async throws {
        let (root, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); ai.settings = settings
        var commands: [String] = []
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: root.path, valid: { true }, execute: { command, _ in
            commands.append(command); return AICommandResult(output: command == "uname -s; pwd" ? "Linux\n" + root.path : "FILE_RESULT", exitCode: 0)
        })
        ai.prepare(source: "owned", text: "", sessionID: executor.sessionID, question: "read the fixture")
        ai.send(executor: executor)
        for _ in 0..<1000 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(ai.answer, "NATIVE_FINAL")
        XCTAssertEqual(ai.steps.compactMap(\.modelCallID), ["call-1", "call-2"])
        XCTAssertEqual(commands.count, 3)
        ai.prepare(source: executor.source, text: "updated context", sessionID: executor.sessionID, question: "follow up"); ai.send(executor: executor)
        for _ in 0..<1000 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(ai.answer, "FOLLOW_UP_OK")
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertEqual(requests.components(separatedBy: "thread/start").count - 1, 1)
        XCTAssertTrue(requests.contains("FILE_RESULT"))
        ai.newConversation(); ai.cancel()
    }
    func testDuplicateCallCannotExecuteTwice() async throws {
        let (root, settings) = try fixture("duplicate"); defer { try? FileManager.default.removeItem(at: root) }
        let session = try AICodexSession(settings: settings, environment: ProcessInfo.processInfo.environment, instructions: "fixture"); defer { session.close() }
        _ = try await session.next("initial", publish: { _ in })
        do { _ = try await session.next("result", publish: { _ in }); XCTFail("Duplicate must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未授权")) }
    }
    func testLostModelConnectionRehydratesResultsWithoutRepeatingTools() async throws {
        let (root, settings) = try fixture("flaky"); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); ai.settings = settings
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
        var reads = 0
        let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: "/owned", valid: { true }, execute: { command,_ in
            if command.contains("service.log") { reads += 1; return .init(output: "RESULT_ALREADY_RECEIVED", exitCode: 0) }
            return .init(output: "Linux\n/owned", exitCode: 0)
        })
        ai.executionChannel = .independent; ai.prepare(source: "owned", text: "", sessionID: executor.sessionID, question: "inspect")
        ai.send(executor: executor)
        for _ in 0..<1500 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(ai.answer, "RECOVERED"); XCTAssertEqual(reads, 1)
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertEqual(requests.components(separatedBy: "thread/start").count - 1, 2)
        XCTAssertTrue(requests.contains("RESULT_ALREADY_RECEIVED")); XCTAssertTrue(requests.contains("Recovery checkpoint"))
    }

    func testOriginalAgentProtocolRemainsAvailable() async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var settings = configuration; settings.agentRuntime = nil
        let session = try AICodexSession(settings: settings, environment: ProcessInfo.processInfo.environment, instructions: AICommandExecutor.instructions); defer { session.close() }
        let first = try await session.next("initial", publish: { _ in })
        XCTAssertEqual(try AIStructuredReply.decode(first).action?.tool, "read_file")
        _ = try await session.next("result one", publish: { _ in })
        let final = try await session.next("result two", publish: { _ in })
        XCTAssertEqual(try AIStructuredReply.decode(final).answer, "NATIVE_FINAL")
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let start = try XCTUnwrap(requests.first { $0["method"] as? String == "thread/start" })
        let params = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual((params["dynamicTools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["axon_step"])
        XCTAssertTrue((params["developerInstructions"] as? String ?? "").contains(AICommandExecutor.replyProtocol))
    }

    func testNativeToolSchemasRejectWrappersUnknownToolsAndPreserveChecks() throws {
        let read = try AIStructuredReply.decode(AINativeAgentTools.reply(name: "axon_read_file", arguments: ["reason": "inspect", "argument": "/owned/test.sh"]))
        XCTAssertEqual(read.action?.tool, "read_file"); XCTAssertNil(read.checks)
        let check: [String: Any] = ["goal": "create hello", "tool": "read_file", "argument": "/owned/test.sh", "expectedOutput": "hello world"]
        let write = try AIStructuredReply.decode(AINativeAgentTools.reply(name: "axon_replace_file", arguments: ["reason": "edit", "path": "/owned/test.sh", "find": "hello", "replacement": "hello world", "checks": [check]]))
        XCTAssertEqual(write.action?.path, "/owned/test.sh"); XCTAssertEqual(write.checks?.first?.expectedOutput, "hello world")
        XCTAssertThrowsError(try AINativeAgentTools.reply(name: "axon_read_file", arguments: ["reason": "inspect", "argument": "/owned/test.sh", "action": [:]]))
        XCTAssertThrowsError(try AINativeAgentTools.reply(name: "axon_step", arguments: [:]))
        XCTAssertThrowsError(try AINativeAgentTools.reply(name: "exec_command", arguments: ["reason": "shell"]))
        XCTAssertThrowsError(try AINativeAgentTools.reply(name: "axon_read_file", arguments: ["reason": "inspect", "argument": 12]))
        XCTAssertThrowsError(try AINativeAgentTools.reply(name: "axon_replace_file", arguments: ["reason": "edit", "path": "/owned/test.sh", "replacement": "new"]))
        let rm = try AIStructuredReply.decode(AINativeAgentTools.reply(name: "axon_command", arguments: ["reason": "delete", "argument": "rm /owned/test.sh"]))
        XCTAssertEqual(AIExecutionPolicy().decision(target: "owned", tool: "command", argument: rm.action!.argument!, automatic: false, command: rm.action!.argument!), .deny)
    }

    func testNativeDeniedAndMalformedCallsReturnToAgentWithoutExecuting() async throws {
        for mode in ["denied", "malformed"] {
            let (root, settings) = try fixture(mode); defer { try? FileManager.default.removeItem(at: root) }
            let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); ai.settings = settings
            var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy
            var commands: [String] = []
            let executor = AICommandExecutor(sessionID: UUID(), source: "owned", directory: "/owned", valid: { true }, execute: { command, _ in
                commands.append(command); return .init(output: command == "uname -s; pwd" ? "Linux\n/owned" : "FILE_RESULT", exitCode: 0)
            })
            ai.executionChannel = .independent; ai.prepare(source: executor.source, text: "", sessionID: executor.sessionID, question: "inspect fixture"); ai.send(executor: executor)
            for _ in 0..<1000 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error)
            XCTAssertEqual(ai.answer, "NATIVE_FINAL"); XCTAssertEqual(commands.count, 2)
            XCTAssertFalse(commands.contains { $0.contains("rm ") })
            let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            XCTAssertTrue(requests.contains("rpc-1")); XCTAssertTrue(requests.contains("rpc-2"))
            if mode == "malformed" { XCTAssertTrue(requests.contains("Rejection reason:")); XCTAssertTrue(requests.contains("\\\"success\\\": false") || requests.contains("\"success\": false")) }
            ai.newConversation()
        }
    }

}
