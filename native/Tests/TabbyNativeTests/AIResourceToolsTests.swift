import XCTest
import SwiftUI
import AppKit
import SwiftTerm
@testable import TabbyNative

@MainActor final class AIResourceToolsTests: XCTestCase {
    func testUsageAccountingPricesLimitsAndArchive() throws {
        let claude = try XCTUnwrap(AIUsageSample.parse(["input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 40, "cache_creation_input_tokens": 10], backend: .claude))
        XCTAssertEqual(claude.input, 150); XCTAssertEqual(claude.total, 200)
        let pricing = AIUsagePricing(backend: .claude, model: "fixture", inputUSD: 2, outputUSD: 10, cachedUSD: 0.2, cacheWriteUSD: 4)
        XCTAssertEqual(try XCTUnwrap(pricing.cost(claude)), 0.000748, accuracy: 0.00000001)
        XCTAssertNil(AIUsageSample.count(true)); XCTAssertNil(AIUsageSample.count(-1)); XCTAssertNil(AIUsageSample.count(1.5))
        var settings = AISettings(); settings.backend = .claude; settings.claude.model = "fixture"; settings.usagePricing = pricing
        var ledger = AIUsageLedger()
        for _ in 0..<205 { let id = ledger.begin(settings); ledger.report(id, claude); ledger.finish(id, success: true) }
        XCTAssertEqual(ledger.calls.count, 200); XCTAssertEqual(ledger.requests, 205); XCTAssertEqual(ledger.tokens.total, 41000); XCTAssertEqual(ledger.unknown, 0)
        XCTAssertEqual(try JSONDecoder().decode(AIUsageLedger.self, from: JSONEncoder().encode(ledger)), ledger)
        var policy = settings.policy; policy.tokenBudget = 41000; settings.executionPolicy = policy
        XCTAssertThrowsError(try ledger.check(settings))
        policy.tokenBudget = nil; policy.costBudgetUSD = 0.001; settings.executionPolicy = policy
        XCTAssertThrowsError(try ledger.check(settings))
        let missing = ledger.begin(settings); ledger.finish(missing, success: true)
        XCTAssertEqual(ledger.unknown, 1); XCTAssertThrowsError(try ledger.check(settings))
        let first = AIUsageSample(input: 10, output: 5, cached: 2, reasoning: 1)
        XCTAssertNil(first.subtracting(.init(input: 20, output: 10)))
        XCTAssertEqual(AIUsageSample(input: 15, output: 8, cached: 4, reasoning: 2).subtracting(first)?.total, 8)
    }
    func testCompletionMetadataAndUsageAreIndependentOfToolFragments() throws {
        func emit(_ value: [String: Any], _ backend: AIBackend, _ stream: inout AIStreamEvents) throws { try stream.line("data: " + String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self), backend: backend); try stream.line("", backend: backend) }
        var stream = AIStreamEvents()
        try emit(["choices": [["delta": ["content": "visible"]]]], .chatgpt, &stream)
        try emit(["choices": [], "usage": ["prompt_tokens": 100, "completion_tokens": 10, "prompt_tokens_details": ["cached_tokens": 30], "completion_tokens_details": ["reasoning_tokens": 4]]], .chatgpt, &stream)
        XCTAssertEqual(stream.usage.total, 110); XCTAssertEqual(stream.text, "visible")
        XCTAssertThrowsError(try stream.result()); try stream.line("data: [DONE]", backend: .chatgpt); XCTAssertThrowsError(try stream.line("", backend: .chatgpt))
        var truncated = AIStreamEvents()
        XCTAssertThrowsError(try emit(["choices": [["delta": ["content": "partial"], "finish_reason": "length"]]], .chatgpt, &truncated))
        XCTAssertThrowsError(try truncated.result())
        var claude = AIStreamEvents()
        try emit(["type": "message_start", "message": ["usage": ["input_tokens": 20, "output_tokens": 0, "cache_read_input_tokens": 5]]], .claude, &claude)
        try emit(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 7]], .claude, &claude)
        XCTAssertEqual(claude.usage.total, 32)
    }
    private func fixture(_ root: URL) throws -> AIMCPServer {
        let script = root.appendingPathComponent("mcp.py")
        try #"""
        import sys,json,pathlib,socket
        for line in sys.stdin:
            req=json.loads(line); method=req['method']
            if 'id' not in req: continue
            if method=='initialize': result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}}}
            elif method=='tools/list': result={'tools':[{'name':'read_status','description':'Read project status','inputSchema':{'type':'object','required':['text']},'annotations':{'readOnlyHint':True}},{'name':'write_file','inputSchema':{'type':'object'},'annotations':{'readOnlyHint':True}},{'name':'unknown','inputSchema':{'type':'object'}}]}
            elif method=='tools/call':
                denied=[]
                try: pathlib.Path('forbidden.txt').write_text('bad')
                except OSError: denied.append('write denied')
                try: socket.create_connection(('127.0.0.1',9),timeout=.1)
                except OSError as e:
                    if e.errno in (1,13): denied.append('network denied')
                result={'content':[{'type':'text','text':req['params']['arguments']['text']+'; '+', '.join(denied)}]}
            print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        return AIMCPServer(name: "本机只读测试服务与很长的项目说明", command: "/usr/bin/python3", arguments: [script.path], directory: root.path)
    }
    func testRealStdioSandboxDiscoverySelectionAndLiveRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var server = try fixture(root); let manager = AIMCPManager(); manager.credentialReader = { _ in "" }
        await manager.connect(server)
        XCTAssertEqual(manager.tools[server.id]?.count, 3, manager.status[server.id] ?? "")
        XCTAssertEqual(manager.tools[server.id]?.filter(\.readOnly).map(\.name), ["read_status"])
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["server": server.id.uuidString, "tool": "read_status", "arguments": ["text": "status OK"]]), as: UTF8.self)
        let call = try AIMCPCall.decode(raw)
        XCTAssertThrowsError(try manager.permits(call, servers: [server]))
        server.allowedTools = ["read_status"]
        let result = try await manager.call(call, servers: { [server] }, check: {})
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.output.contains("status OK")); XCTAssertTrue(result.output.contains("write denied"), result.output); XCTAssertTrue(result.output.contains("network denied"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden.txt").path))
        XCTAssertTrue(manager.catalog([server]).contains("read_status"))
        server.permission = .deny; XCTAssertThrowsError(try manager.permits(call, servers: [server]))
        server.permission = .ask; server.arguments.append("changed"); manager.synchronize([server]); XCTAssertThrowsError(try manager.permits(call, servers: [server]))
        XCTAssertThrowsError(try AIMCPCall.decode(raw.replacingOccurrences(of: "read_status", with: "write_file")))
        XCTAssertThrowsError(try AIMCPServer.url("http://example.com/mcp")); XCTAssertThrowsError(try AIMCPServer.url("https://user:pass@example.com/mcp"))
        XCTAssertEqual(AIToolCategory.category(for: "mcp_call"), .mcp)
    }
    func testBudgetPreventsToolDispatchAndRetainsHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var ai: AIAssistant!
        ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in
            let id = try XCTUnwrap(ai.usage.calls.last?.id); ai.usage.report(id, .init(input: 90, output: 20))
            var live = ai.settings.policy; live.tokenBudget = 100; ai.settings.executionPolicy = live
            return #"{"answer":"Check","action":{"tool":"inspect_port","argument":"8080","reason":"Check service","path":null,"find":null,"replacement":null},"checks":null,"memory":null}"#
        })
        var policy = ai.settings.policy; policy.tokenBudget = nil; ai.settings.executionPolicy = policy
        var commands: [String] = []
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: root.path, valid: { true }, execute: { command, _ in commands.append(command); return .init(output: "Darwin\n" + root.path, exitCode: 0) })
        ai.prepare(source: "fixture", text: "", sessionID: executor.sessionID, question: "inspect service"); ai.send(executor: executor)
        for _ in 0..<300 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.contains("Token"), ai.error); XCTAssertFalse(commands.contains { $0.contains("8080") }); XCTAssertEqual(ai.usage.tokens.total, 110)
        XCTAssertEqual(ai.taskRecords.last?.state, "limited"); let entry = try XCTUnwrap(ai.taskRecords.last)
        ai.newConversation(); XCTAssertEqual(ai.usage.requests, 0); ai.restoreTask(entry); XCTAssertEqual(ai.usage.tokens.total, 110)
        var legacy = entry; legacy.usage = nil
        let old = AIUsageLedger.restored(legacy); XCTAssertEqual(old.unknown,1); XCTAssertThrowsError(try old.check(ai.settings))
    }
    func testStreamableHTTPJSONAndSSEWithSessionAndCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-mcp-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let script = root.appendingPathComponent("http_fixture.py")
        try #"""
        import http.server,json,pathlib
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                r=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert self.headers['Authorization']=='Bearer fixture-key'
                assert 'text/event-stream' in self.headers['Accept']
                if r['method']!='initialize':
                    assert self.headers['Mcp-Session-Id']=='fixture-session'
                    assert self.headers['MCP-Protocol-Version']=='2025-06-18'
                if 'id' not in r:
                    self.send_response(202);self.end_headers();return
                if r['method']=='initialize': v={'protocolVersion':'2025-06-18','capabilities':{'tools':{}}}
                elif r['method']=='tools/list':v={'tools':[{'name':'read_status','inputSchema':{'type':'object'},'annotations':{'readOnlyHint':True}}]}
                else:v={'content':[{'type':'text','text':'HTTP status OK'}]}
                data=json.dumps({'jsonrpc':'2.0','id':r['id']+(1 if self.path=='/wrong' else 0),'result':v})
                self.send_response(200);self.send_header('Mcp-Session-Id','fixture-session')
                sse=r['method']=='tools/call'
                self.send_header('Content-Type','text/event-stream' if sse else 'application/json');self.end_headers()
                self.wfile.write(('data: '+data+'\n\n' if sse else data).encode());self.wfile.flush()
        s=http.server.HTTPServer(('127.0.0.1',0),Handler)
        pathlib.Path(__file__).with_suffix('.port').write_text(str(s.server_port));s.serve_forever()
        """#.write(to:script,atomically:true,encoding:.utf8)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3");process.arguments=[script.path];process.standardError=FileHandle.nullDevice;try process.run();defer { if process.isRunning { process.terminate() } }
        let portFile=script.deletingPathExtension().appendingPathExtension("port")
        for _ in 0..<100 { if FileManager.default.fileExists(atPath:portFile.path) { break };try await Task.sleep(for:.milliseconds(20)) }
        let port=try String(contentsOf:portFile,encoding:.utf8)
        var server=AIMCPServer(name:"HTTP fixture",transport:.http,endpoint:"http://127.0.0.1:\(port)/mcp",allowedTools:["read_status"])
        let manager=AIMCPManager();manager.credentialReader={_ in "fixture-key"};await manager.connect(server)
        XCTAssertEqual(manager.tools[server.id]?.count,1,manager.status[server.id] ?? "")
        let call=AIMCPCall(server:server.id,tool:"read_status",arguments:[:])
        let result=try await manager.call(call,servers:{[server]},check:{})
        XCTAssertTrue(result.output.contains("HTTP status OK"));XCTAssertFalse(result.output.contains("fixture-key"))
        manager.disconnect(server.id);server.endpoint="http://127.0.0.1:\(port)/wrong";await manager.connect(server)
        XCTAssertNil(manager.tools[server.id]);XCTAssertTrue(manager.status[server.id]?.contains("编号") == true || manager.status[server.id]?.contains("mismatch") == true)
    }
    func testAgentMCPUsesExplicitApprovalAndNeverShellDispatch() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("axon-mcp-agent-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        var server=try fixture(root);server.allowedTools=["read_status"]
        let argument=String(decoding:try JSONSerialization.data(withJSONObject:["server":server.id.uuidString,"tool":"read_status","arguments":["text":"agent MCP OK"]]),as:UTF8.self)
        var round=0
        let ai=AIAssistant(fileURL:root.appendingPathComponent("ai.json"),modelResponder:{_,_,_ in
            round += 1
            if round == 1 {return try AIStructuredReply(answer:"Query MCP",action:.init(tool:"mcp_call",argument:argument,reason:"Read service status",path:nil,find:nil,replacement:nil)).serialized()}
            return try AIStructuredReply(answer:"MCP query complete",action:nil).serialized()
        })
        ai.settings.mcpServers=[server];var policy=ai.settings.policy;policy.approvalMode = .fullAccess;ai.settings.executionPolicy=policy
        ai.mcp.credentialReader={_ in ""};await ai.mcp.connect(server)
        var shell:[String]=[]
        let executor=AICommandExecutor(sessionID:UUID(),source:"local fixture",directory:root.path,valid:{true},execute:{command,_ in shell.append(command);return .init(output:"Darwin\n"+root.path,exitCode:0)})
        ai.prepare(source:executor.source,text:"",sessionID:executor.sessionID,question:"Query read status from selected MCP");ai.send(executor:executor)
        for _ in 0..<300 {if ai.pendingApproval != nil || !ai.busy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(ai.pendingApproval?.tool,"mcp_call");XCTAssertTrue(ai.busy)
        _ = NSApplication.shared
        let store = AppStore(fileURL:root.appendingPathComponent("workspace.json"));store.workspace.preferences.language="zh-CN"
        let pane = NSHostingView(rootView:AIAssistantPane(ai:ai,executionOverride:executor,availableHeight:760).environmentObject(store).frame(width:480,height:760))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=pane;window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(150));pane.layoutSubtreeIfNeeded()
        try FileManager.default.createDirectory(atPath:"/tmp/axon-md-ui",withIntermediateDirectories:true)
        let rep=try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in:pane.bounds));pane.cacheDisplay(in:pane.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/axon-md-ui/mcp-approval.png"));window.close()
        ai.approveAction()
        for _ in 0..<300 {if !ai.busy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(ai.busy);XCTAssertTrue(ai.error.isEmpty,ai.error)
        XCTAssertTrue(ai.steps.contains {$0.tool=="mcp_call" && $0.output.contains("agent MCP OK")})
        XCTAssertFalse(shell.contains {$0.contains("MCP") || $0.contains("read_status")})
        ai.mcp.disconnect(server.id)
    }
    func testMCPControlsSelectionKeyboardAndPersistence() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true,forAttribute:NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface"))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("axon-md-controls-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let store=AppStore(fileURL:root.appendingPathComponent("workspace.json"));store.workspace.preferences.language="zh-CN"
        var server=try fixture(root);server.allowedTools=["read_status"]
        store.ai.settings.backend = .claude;store.ai.settings.claude.model="fixture-model";store.ai.settings.mcpServers=[server];store.ai.mcp.credentialReader={_ in ""};await store.ai.mcp.connect(server)
        func shot(_ view:NSView,_ name:String) throws {view.layoutSubtreeIfNeeded();let rep=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/axon-md-ui/\(name).png"))}
        func objects(_ view:NSView)->[NSObject] {
            var result:[NSObject]=[],seen=Set<ObjectIdentifier>()
            func visit(_ o:NSObject) {guard seen.insert(ObjectIdentifier(o)).inserted else{return};result.append(o);if o.responds(to:NSSelectorFromString("accessibilityChildren")) {for child in o.value(forKey:"accessibilityChildren") as? [NSObject] ?? [] {visit(child)}};if let v=o as? NSView {for child in v.subviews {visit(child)}}};visit(view);return result
        }
        func press(_ view:NSView,_ id:String,_ expected:Bool = true) throws {
            let o=try XCTUnwrap(objects(view).first {$0.responds(to:NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey:"accessibilityIdentifier") as? String == id})
            if let button=o as? NSButton {button.performClick(nil);return}
            let sel=NSSelectorFromString("accessibilityPerformPress");typealias Press = @convention(c)(AnyObject,Selector)->Bool;XCTAssertEqual(unsafeBitCast(o.method(for:sel),to:Press.self)(o,sel),expected)
        }
        let fields=NSHostingView(rootView:AIMCPFields(settings:Binding(get:{store.ai.settings},set:{store.ai.settings=$0}),manager:store.ai.mcp).environmentObject(store).padding(20).frame(width:480,height:660).background(Palette.sidebar))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:660),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=fields;window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(150));try shot(fields,"tools-selected")
        try press(fields,"axon-mcp-tool-read_status");XCTAssertEqual(store.ai.settings.mcpServers?.first?.allowedTools,[])
        try await Task.sleep(for:.milliseconds(100));try shot(fields,"tools-unselected")
        try press(fields,"axon-mcp-tool-read_status");XCTAssertEqual(store.ai.settings.mcpServers?.first?.allowedTools,["read_status"])
        try press(fields,"axon-mcp-tool-write_file",false);XCTAssertEqual(store.ai.settings.mcpServers?.first?.allowedTools,["read_status"])
        try store.ai.save(store.ai.settings,key:"");XCTAssertEqual(AIAssistant(fileURL:store.ai.fileURL).settings.mcpServers?.first?.allowedTools,["read_status"])
        window.close()
        var saved:AIMCPServer?
        let editor=NSHostingView(rootView:AIMCPServerSheet(server:server,save:{saved=$0},remove:{}).environmentObject(store))
        let modal=NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:640),styleMask:[.titled],backing:.buffered,defer:false);modal.isReleasedWhenClosed=false;modal.contentView=editor;modal.orderFront(nil)
        try await Task.sleep(for:.milliseconds(100));try press(editor,"axon-mcp-permission");try await Task.sleep(for:.milliseconds(100))
        let menu=try XCTUnwrap(AxonMenuPopover.active);try shot(try XCTUnwrap(menu.popover.contentViewController?.view),"mcp-permission-menu")
        XCTAssertTrue(menu.handleKey(125));XCTAssertTrue(menu.handleKey(36));try await Task.sleep(for:.milliseconds(100));try press(editor,"axon-mcp-save")
        XCTAssertEqual(saved?.permission,.allow);modal.close()
        for width in [1050,1400] {
            store.openPreferences(.ai)
            let host=NSHostingView(rootView:MainView().environmentObject(store));let real=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:900),styleMask:[.titled],backing:.buffered,defer:false);real.isReleasedWhenClosed=false;real.contentView=host;real.orderFront(nil)
            try await Task.sleep(for:.milliseconds(150))
            func views(_ v:NSView)->[NSView] {[v]+v.subviews.flatMap(views)}
            let connect=try XCTUnwrap(views(host).compactMap {$0 as? NSButton}.first {$0.accessibilityIdentifier()=="axon-ai-tool-mcp"});connect.scrollToVisible(connect.bounds.insetBy(dx:0,dy:-500));try await Task.sleep(for:.milliseconds(150));try shot(host,"navigation-\(width)")
            if let scroll = views(host).compactMap({$0 as? NSScrollView}).first(where: {$0.frame.width > 600 && ($0.documentView?.frame.height ?? 0) > $0.frame.height + 500}) {
                scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,scroll.contentView.bounds.minY-900)));scroll.reflectScrolledClipView(scroll.contentView);try await Task.sleep(for:.milliseconds(100));try shot(host,"navigation-mcp-\(width)")
            }
            real.close()
        }
        store.ai.mcp.disconnect(server.id)
    }
    func testMCPTimeoutClosesConnectionWithoutReplaying() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("axon-mcp-timeout-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let server=try fixture(root), script=root.appendingPathComponent("mcp.py")
        var source=try String(contentsOf:script,encoding:.utf8)
        source=source.replacingOccurrences(of:"elif method=='tools/call':",with:"elif method=='tools/call':\n        import time\n        print(json.dumps({'jsonrpc':'2.0','method':'notifications/message','params':{'message':'called once'}}),flush=True)\n        time.sleep(2)")
        try source.write(to:script,atomically:true,encoding:.utf8)
        let client=try AIMCPClient(server,credential:"",seconds:0.5)
        _ = try await client.initialize()
        let call=AIMCPCall(server:server.id,tool:"read_status",arguments:["text":"fixture"])
        do { _ = try await client.call(call);XCTFail("timeout must fail") } catch { XCTAssertEqual((error as? URLError)?.code,.timedOut) }
        do { _ = try await client.call(call);XCTFail("closed connection must not replay") } catch { XCTAssertTrue(error.localizedDescription.contains("closed") || error.localizedDescription.contains("关闭")) }
    }
    func testMCPOnCurrentTerminalKeepsItsOwnToolPermission() async throws {
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("axon-mcp-terminal-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let store=AppStore(fileURL:root.appendingPathComponent("workspace.json"))
        let session=TerminalSession(host:nil,store:store)
        let terminal=SwiftTerm.TerminalView(frame:NSRect(x:0,y:0,width:600,height:400));session.terminal=terminal;session.connected=true;terminal.feed(text:"Darwin\r\n"+root.path+"\r\n")
        var server=try fixture(root);server.allowedTools=["read_status"];server.permission = .allow
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:["server":server.id.uuidString,"tool":"read_status","arguments":["text":"current terminal MCP"]]),as:UTF8.self)
        var round=0
        let ai=AIAssistant(fileURL:root.appendingPathComponent("ai.json"),modelResponder:{_,_,_ in round += 1;return try AIStructuredReply(answer:round==1 ? "Query" : "Done",action:round==1 ? .init(tool:"mcp_call",argument:raw,reason:"Read status",path:nil,find:nil,replacement:nil) : nil).serialized()})
        ai.executionChannel = .currentTerminal;ai.settings.mcpServers=[server];ai.settings.projectInstructionsEnabled=false;ai.settings.skillsEnabled=false
        var policy=ai.settings.policy;policy.approvalMode = .fullAccess;policy.toolPermissions=["commands":.deny,"mcp":.allow];ai.settings.executionPolicy=policy
        ai.mcp.credentialReader={_ in ""};await ai.mcp.connect(server)
        let executor=AICommandExecutor(sessionID:session.id,source:"current terminal fixture",directory:root.path,valid:{session.connected},execute:{_,_ in XCTFail("MCP must not use shell execution");return .init(output:"",exitCode:0)})
        executor.terminalBridge=AITerminalBridge(session:session)
        ai.prepare(source:executor.source,text:"",sessionID:session.id,question:"Read selected MCP status");ai.send(executor:executor)
        for _ in 0..<300 {if !ai.busy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(ai.busy);XCTAssertTrue(ai.error.isEmpty,ai.error);XCTAssertTrue(ai.steps.contains {$0.tool=="mcp_call" && $0.output.contains("current terminal MCP")})
        XCTAssertFalse(ai.steps.contains {$0.tool=="terminal_execute"});ai.mcp.disconnect(server.id)
    }
    func testResourceUIActualRendering() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-md-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json")); ai.settings.backend = .claude; ai.settings.claude.model = "fixture-model"
        ai.settings.usagePricing = .init(backend: .claude, model: "fixture-model", inputUSD: 3, outputUSD: 15, cachedUSD: 0.3, cacheWriteUSD: 3.75)
        let id = ai.usage.begin(ai.settings); ai.usage.report(id, .init(input: 12000, output: 1500, cached: 5000, reasoning: 100)); ai.usage.finish(id, success: true)
        _ = ai.usage.begin(ai.settings)
        var server = try fixture(root); server.allowedTools = ["read_status"]; ai.settings.mcpServers = [server]; ai.mcp.credentialReader = { _ in "" }; await ai.mcp.connect(server)
        let dir = "/tmp/axon-md-ui"; try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func render<V: View>(_ view: V, _ name: String, _ width: Int, _ height: Int) async throws {
            let host = NSHostingView(rootView: view.environmentObject(store).frame(width: CGFloat(width), height: CGFloat(height)))
            let window = NSWindow(contentRect: NSRect(x: 0,y:0,width:width,height:height), styleMask:[.titled], backing:.buffered, defer:false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap); try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath: "\(dir)/\(name).png")); window.close()
        }
        for width in [480, 760] {
            try await render(AIUsageSheet(ai: ai), "usage-\(width)", width, 640)
            try await render(ScrollView { VStack(alignment:.leading,spacing:16) { AIUsagePricingFields(settings: Binding(get:{ai.settings},set:{ai.settings=$0})); AIMCPFields(settings:Binding(get:{ai.settings},set:{ai.settings=$0}),manager:ai.mcp); AIUsageBudgetFields(policy:Binding(get:{ai.settings.policy},set:{ai.settings.executionPolicy=$0})) }.padding(20) }.background(Palette.sidebar), "settings-\(width)", width, 1000)
        }
        try await render(AIMCPServerSheet(server:server,save:{_ in},remove:{}), "server", 580, 680)
        ai.mcp.disconnect(server.id)
        ai.usage = AIUsageLedger(); ai.settings.mcpServers = []
        try await render(AIUsageSheet(ai: ai), "usage-empty", 480, 480)
        try await render(AIMCPFields(settings:Binding(get:{ai.settings},set:{ai.settings=$0}),manager:ai.mcp), "mcp-empty", 480, 300)
        var failure = server; failure.command = "/usr/bin/false"; failure.arguments = []; ai.settings.mcpServers = [failure]
        await ai.mcp.connect(failure)
        try await render(AIMCPFields(settings:Binding(get:{ai.settings},set:{ai.settings=$0}),manager:ai.mcp), "mcp-error", 480, 520)
        let delayed = root.appendingPathComponent("delayed.py")
        try ("import time; time.sleep(1.2)\n" + String(contentsOf: root.appendingPathComponent("mcp.py"),encoding:.utf8)).write(to:delayed,atomically:true,encoding:.utf8)
        server.arguments = [delayed.path]; ai.settings.mcpServers = [server]
        let connection = Task { await ai.mcp.connect(server) }
        try await Task.sleep(for:.milliseconds(50))
        try await render(AIMCPFields(settings:Binding(get:{ai.settings},set:{ai.settings=$0}),manager:ai.mcp), "mcp-loading", 480, 520)
        await connection.value
        try await render(AIMCPFields(settings:Binding(get:{ai.settings},set:{ai.settings=$0}),manager:ai.mcp).disabled(true), "mcp-disabled", 480, 660)
        ai.mcp.disconnect(server.id)
    }
}
