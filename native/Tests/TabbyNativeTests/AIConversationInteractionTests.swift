import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AIConversationInteractionTests: XCTestCase {
    func testComposerReturnShiftReturnAndIME() throws {
        _ = NSApplication.shared
        let editor=AIComposerTextView(frame:NSRect(x:0,y:0,width:400,height:100));var sends=0;editor.onSend={sends += 1};editor.string="hello"
        func key(_ flags:NSEvent.ModifierFlags) -> NSEvent { NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)! }
        editor.keyDown(with:key([]));XCTAssertEqual(sends,1);XCTAssertEqual(editor.string,"hello")
        editor.setSelectedRange(NSRange(location:5,length:0));editor.keyDown(with:key(.shift));XCTAssertEqual(sends,1);XCTAssertEqual(editor.string,"hello\n")
        editor.setMarkedText("中文",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0));editor.keyDown(with:key([]));XCTAssertEqual(sends,1)
    }
    func testContinuousHistoryDeletionAndPersistentDeny() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("ai.json"), ai=AIAssistant(fileURL:file,modelResponder:{_,_,_ in "fixture answer"})
        let id=UUID(), executor=AICommandExecutor(sessionID:id,source:"fixture",directory:"/tmp",valid:{true},execute:{_,_ in AICommandResult(output:"Darwin\n/tmp",exitCode:0)})
        func send(_ question:String) async throws { ai.prepare(source:"fixture",text:"fixture",sessionID:id,question:question);ai.send(executor:executor);for _ in 0..<300 {if !ai.busy{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("timeout") }
        try await send("first");try await send("follow up");XCTAssertEqual(ai.taskRecords.count,1);XCTAssertEqual(ai.taskRecords.first?.messageCount,2)
        ai.newConversation();try await send("new topic");XCTAssertEqual(ai.taskRecords.count,2)
        ai.deleteTask(try XCTUnwrap(ai.taskRecords.first?.id));XCTAssertEqual(ai.taskRecords.count,1)
        XCTAssertEqual(AIAssistant(fileURL:file).taskRecords.count,1);ai.deleteAllTasks();XCTAssertTrue(AIAssistant(fileURL:file).taskRecords.isEmpty)
        var policy=AIExecutionPolicy();policy.approvalMode = .everyTime
        policy.exactAllows=[AIExactPermission(target:"fixture",tool:"terminal_send",argument:"df -h",denied:true)]
        XCTAssertEqual(policy.decision(target:"fixture",tool:"terminal_execute",argument:"df -h",automatic:false),.deny)
        policy.exactAllows?[0].denied=nil;XCTAssertEqual(policy.decision(target:"fixture",tool:"terminal_execute",argument:"df -h",automatic:false),.ask)
        policy.approvalMode = .assisted;XCTAssertEqual(policy.decision(target:"fixture",tool:"terminal_execute",argument:"df -h",automatic:false),.allow)
        policy.commandBlacklist="df .*";XCTAssertEqual(policy.decision(target:"fixture",tool:"terminal_execute",argument:"df -h",automatic:false),.deny)
    }
    func testGlobalExactRuleScopeAndCompatibility() throws {
        let original=UUID(),other=UUID()
        var policy=AIExecutionPolicy();policy.approvalMode = .everyTime
        policy.exactAllows=[AIExactPermission(target:"original",tool:"terminal_send",argument:"pwd && ls -la",hostID:original)]
        XCTAssertEqual(policy.decision(target:"other",tool:"terminal_execute",argument:"pwd && ls -la",automatic:false,hostID:other),.ask)
        policy.exactAllows?[0].global=true
        XCTAssertEqual(policy.decision(target:"other",tool:"terminal_execute",argument:"pwd && ls -la",automatic:false,hostID:other),.ask)
        policy.approvalMode = .assisted
        let saved=try JSONDecoder().decode(AIExecutionPolicy.self,from:JSONEncoder().encode(policy))
        XCTAssertEqual(saved.decision(target:"other",tool:"terminal_execute",argument:"pwd && ls -la",automatic:false,hostID:other),.allow)
        XCTAssertEqual(saved.decision(target:"other",tool:"terminal_execute",argument:"pwd && ls -la /",automatic:false,hostID:other),.ask)
        policy.exactAllows?[0].denied=true
        XCTAssertEqual(policy.decision(target:"other",tool:"terminal_execute",argument:"pwd && ls -la",automatic:false,hostID:other),.deny)
        policy.exactAllows?[0].global=nil
        XCTAssertEqual(policy.decision(target:"other",tool:"terminal_execute",argument:"pwd && ls -la",automatic:false,hostID:other),.ask)
        XCTAssertEqual(policy.exactAllows?.first?.hostID,original)
    }
    func testUnknownShellRefusesApprovedInputWithoutExecuting() async throws {
        _ = NSApplication.shared
        let attribute=NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface");NSApp.accessibilitySetValue(true,forAttribute:attribute)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let store=AppStore(fileURL:root.appendingPathComponent("workspace.json"))
        // Store owns the session lifetime in this fixture.
        let owned=TerminalSession(host:nil,store:store);store.sessions=[owned];owned.connected=true
        let terminal=LocalTerminal(frame:NSRect(x:0,y:0,width:600,height:400));owned.terminal=terminal;terminal.ownerSession=owned;terminal.terminalDelegate=owned
        terminal.startProcess(executable:"/bin/bash",args:["--noprofile","--norc","-i"],environment:["PATH=/usr/bin:/bin","TERM=xterm-256color","PS1=FIXTURE> "],currentDirectory:root.path);defer{terminal.terminate()};try await Task.sleep(for:.milliseconds(200))
        var round=0
        let ai=AIAssistant(fileURL:root.appendingPathComponent("ai.json"),modelResponder:{_,_,_ in round += 1; if round > 2{return "```axon_action\n{\"tool\":\"report_blocker\",\"argument\":\"No hook in fixture shell\",\"reason\":\"fixture\"}\n```"};return try p0FixtureReply("```axon_action\n{\"tool\":\"" + (round == 1 ? "terminal_send" : "terminal_key") + "\",\"argument\":\"" + (round == 1 ? "printf approved_pair" : "enter") + "\",\"reason\":\"fixture\"}\n```", goal: "test") })
        ai.executionChannel = .currentTerminal
        let executor=AICommandExecutor(sessionID:owned.id,source:"fixture",directory:"/tmp",valid:{owned.connected},execute:{_,_ in XCTFail("independent");return AICommandResult(output:"",exitCode:0)});executor.terminalBridge=AITerminalBridge(session:owned)
        ai.prepare(source:"fixture",text:"",sessionID:owned.id,question:"test");ai.send(executor:executor)
        for _ in 0..<200 {if ai.pendingApproval != nil{break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(ai.pendingTool,"terminal_send");ai.approveAction()
        for _ in 0..<300 {if !ai.busy || ai.pendingApproval != nil{break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertNil(ai.pendingApproval);XCTAssertFalse(ai.busy);XCTAssertTrue(ai.error.contains("Terminal state unknown"),ai.error);XCTAssertEqual(ai.steps.last?.tool,"terminal_send")
    }
    func testCompactComposerAndTogglePreviewRendered() async throws {
        _ = NSApplication.shared
        let attribute=NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface");NSApp.accessibilitySetValue(true,forAttribute:attribute)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=AppStore(fileURL:root.appendingPathComponent("workspace.json"));store.workspace.preferences.language="zh-CN"
        let session=TerminalSession(host:nil,store:store);session.connected=true;store.sessions=[session];store.activeSession=session.id
        store.ai=AIAssistant(fileURL:root.appendingPathComponent("ai.json"),modelResponder:{_,_,_ in "当前目录包含以下文件，您可以继续询问文件的用途。\n\n```sh\npwd && ls -la\n```"})
        store.ai.prepare(source:"fixture",text:"preview fixture",sessionID:session.id,question:"请查看当前目录有哪些文件");store.ai.send()
        for _ in 0..<200 { if !store.ai.busy { break }; try await Task.sleep(for:.milliseconds(10)) }
        store.ai.question="输入一段消息"

        try FileManager.default.createDirectory(atPath:"/tmp/axon-0166-ui",withIntermediateDirectories:true)
        for width in [320,600] {
            if width == 600 {
                store.ai.prepare(source:"fixture",text:"preview fixture",sessionID:session.id,question:"请查看当前目录有哪些文件");store.ai.send()
                for _ in 0..<200 { if !store.ai.busy { break }; try await Task.sleep(for:.milliseconds(10)) }
                store.ai.question="输入一段消息"
            }
            let host=NSHostingView(rootView:AIAssistantPane(ai:store.ai,terminal:true,availableHeight:760).environmentObject(store).frame(width:CGFloat(width),height:760));host.sizingOptions=[]
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
            try await Task.sleep(for:.milliseconds(150));try snapshot(host,"/tmp/axon-0166-ui/compact-\(width).png")
            let editor=try XCTUnwrap(find(AIComposerTextView.self,host).first);XCTAssertGreaterThan(editor.bounds.width,100)
            try press(host,"axon-ai-preview");try await Task.sleep(for:.milliseconds(150));try snapshot(host,"/tmp/axon-0166-ui/preview-open-\(width).png")
            try press(host,"axon-ai-preview");try await Task.sleep(for:.milliseconds(150));try snapshot(host,"/tmp/axon-0166-ui/preview-closed-\(width).png")
            window.close()
        }
        let host=NSHostingView(rootView:AIAnalysisSheet().environmentObject(store));host.sizingOptions=[]
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:900),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(150));try snapshot(host,"/tmp/axon-0166-ui/expanded.png");window.close()
    }
    func testHistoryDeleteButtonsAndPermanentPermissionMenuUI() async throws {
        _ = NSApplication.shared
        let attribute=NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface");NSApp.accessibilitySetValue(true,forAttribute:attribute)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=AppStore(fileURL:root.appendingPathComponent("workspace.json"));store.workspace.preferences.language="zh-CN"
        let session=TerminalSession(host:nil,store:store);session.connected=true;store.sessions=[session];store.activeSession=session.id
        var round=0
        let ai=AIAssistant(fileURL:root.appendingPathComponent("ai.json"),modelResponder:{_,_,_ in
            round += 1
            if round == 3 { return try p0FixtureReply("```axon_action\n{\"tool\":\"command\",\"argument\":\"cat /owned/fixture\",\"reason\":\"fixture\"}\n```", goal: "permission fixture") }
            return "fixture answer"
        });store.ai=ai
        let executor=AICommandExecutor(sessionID:session.id,source:"Local macOS / 本机 macOS",directory:"/tmp",valid:{true},execute:{_,_ in AICommandResult(output:"Darwin\n/tmp",exitCode:0)})
        for title in ["first conversation","second conversation"] {
            ai.newConversation();ai.prepare(source:session.displayTitle,text:"fixture",sessionID:session.id,question:title);ai.send(executor:executor)
            for _ in 0..<200 {if !ai.busy{break};try await Task.sleep(for:.milliseconds(10))}
        }
        let host=NSHostingView(rootView:AIAssistantPane(ai:ai,terminal:true,availableHeight:760).environmentObject(store).frame(width:600,height:760));host.sizingOptions=[]
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil);defer{window.close()}
        try await Task.sleep(for:.milliseconds(150));try press(host,"axon-ai-task-history");try await Task.sleep(for:.milliseconds(200))
        let sheet=try XCTUnwrap(window.sheets.first), content=try XCTUnwrap(sheet.contentView)
        try snapshot(content,"/tmp/axon-0166-ui/task-history.png");try press(content,"axon-ai-delete-task");try await Task.sleep(for:.milliseconds(100));XCTAssertEqual(ai.taskRecords.count,1)
        try press(content,"axon-ai-delete-all-tasks");try await Task.sleep(for:.milliseconds(100));XCTAssertTrue(ai.taskRecords.isEmpty)
        try press(content,"axon-ai-close-history");try await Task.sleep(for:.milliseconds(100))
        ai.prepare(source:session.displayTitle,text:"fixture",sessionID:session.id,question:"permission fixture");ai.send(executor:executor)
        for _ in 0..<200 {if ai.pendingApproval != nil{break};try await Task.sleep(for:.milliseconds(10))}
        try await Task.sleep(for:.milliseconds(100));try press(host,"axon-ai-approval-scope");try await Task.sleep(for:.milliseconds(100))
        let menu=try XCTUnwrap(AxonMenuPopover.active)
        XCTAssertTrue(menu.menu.items.contains{$0.title=="一直允许此操作"});XCTAssertTrue(menu.menu.items.contains{$0.title=="一直不允许此操作"})
        try snapshot(try XCTUnwrap(menu.popover.contentViewController?.view),"/tmp/axon-0166-ui/permanent-permission-menu.png")
        menu.highlighted=2;XCTAssertTrue(menu.handleKey(36));try await Task.sleep(for:.milliseconds(100));try press(host,"axon-ai-approve")
        for _ in 0..<100 {if !ai.busy{break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(ai.settings.policy.exactAllows?.first?.denied,true);XCTAssertEqual(AIAssistant(fileURL:root.appendingPathComponent("ai.json")).settings.policy.exactAllows?.first?.denied,true)
    }
    private func read(_ object:NSObject,_ key:String)->Any?{object.responds(to:NSSelectorFromString(key)) ? object.value(forKey:key) : nil}
    private func accessible(_ view:NSView)->[NSObject]{var result:[NSObject]=[],seen=Set<ObjectIdentifier>();func visit(_ object:NSObject){guard seen.insert(ObjectIdentifier(object)).inserted else{return};result.append(object);for child in read(object,"accessibilityChildren") as? [NSObject] ?? []{visit(child)};if let native=object as? NSView{for child in native.subviews{visit(child)}}};visit(view);return result}
    private func press(_ view:NSView,_ id:String)throws{let object=try XCTUnwrap(accessible(view).first{read($0,"accessibilityIdentifier") as? String == id});if let button=object as? NSButton{button.performClick(nil);return};let selector=NSSelectorFromString("accessibilityPerformPress");typealias Press = @convention(c)(AnyObject,Selector)->Bool;XCTAssertTrue(unsafeBitCast(object.method(for:selector),to:Press.self)(object,selector))}
    private func find<T:NSView>(_ type:T.Type,_ view:NSView)->[T]{(view as? T).map{[$0]} ?? [] + view.subviews.flatMap{find(type,$0)}}
    func testAnalysisCloseIconRendered() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let host = NSHostingView(rootView: AIAnalysisSheet().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0166-ui", withIntermediateDirectories: true)
        try snapshot(host, "/tmp/axon-0166-ui/analysis-close.png"); window.close()
    }
    func testChatConversationPersistsRestoresAndContinuesAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ai.json"), session = UUID()
        let responder: (String, String, @escaping (String) -> Void) async throws -> String = { _, _, _ in "answer" }
        let ai = AIAssistant(fileURL: path, modelResponder: responder)
        ai.prepare(source: "fixture", text: "context", sessionID: session, question: "")
        for question in ["first", "second"] {
            ai.question = question; ai.send()
            for _ in 0..<200 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(ai.taskRecords.count, 1)
        XCTAssertEqual(ai.taskRecords[0].turns?.map(\.question), ["first", "second"])
        ai.newConversation(); XCTAssertTrue(ai.conversation.isEmpty)
        let restored = AIAssistant(fileURL: path, modelResponder: responder)
        restored.prepare(source: "fixture", text: "fresh", sessionID: UUID(), question: "")
        restored.restoreTask(try XCTUnwrap(restored.taskRecords.first))
        XCTAssertEqual(restored.conversation.map(\.question), ["first"])
        XCTAssertEqual(restored.submittedQuestion, "second"); XCTAssertTrue(restored.question.isEmpty)
        restored.question = "third"; restored.send()
        for _ in 0..<200 { if !restored.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(restored.taskRecords.count, 1)
        XCTAssertEqual(restored.taskRecords[0].turns?.map(\.question), ["first", "second", "third"])
    }
    func testUnifiedTaskReplyWithManyStepsRenderedAndToggled() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.connected = true; store.sessions = [session]; store.activeSession = session.id
        var round = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _,_,_ in
            round += 1
            if round <= 14 { return "```axon_action\n{\"tool\":\"verify_command\",\"argument\":\"cat /owned/fixture-" + String(round) + "\",\"reason\":\"检查文件内容及执行结果，第 " + String(round) + " 步\"}\n```" }
            return "已在 nohup.out 末尾追加一行 test ai init，并核验文件内容，原有内容保留。"
        })
        var policy = AIExecutionPolicy(); policy.approvalMode = .fullAccess; ai.settings.executionPolicy = policy; store.ai = ai
        let executor = AICommandExecutor(sessionID: session.id, source: "root@fixture:22", directory: "/root", valid: { true }, execute: { command,_ in AICommandResult(output: command.contains("uname") ? "Linux\n/root" : "fixture verified", exitCode: 0) })
        ai.prepare(source: executor.source, text: "fixture", sessionID: session.id, question: "帮我打开 nohup.out，补充一行 test ai init"); ai.send(executor: executor)
        for _ in 0..<300 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertEqual(ai.steps.count, 15)
        ai.steps[3] = AIAgentStep(command: "sleep 3; printf ready", reason: "等待当前命令完成，按执行编号读取结果", state: "running", tool: "terminal_execute", input: "sleep 3; printf ready")
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0171-ui", withIntermediateDirectories: true)
        for width in [320, 600] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, terminal: true, availableHeight: 900).environmentObject(store).frame(width: CGFloat(width), height: 900)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150)); try snapshot(host, "/tmp/axon-0171-ui/unified-\(width).png")
            try press(host, "axon-ai-reply-actions"); try await Task.sleep(for: .milliseconds(150)); try snapshot(host, "/tmp/axon-0171-ui/actions-open-\(width).png")
            try press(host, "axon-ai-reply-actions"); try await Task.sleep(for: .milliseconds(150)); try snapshot(host, "/tmp/axon-0171-ui/actions-closed-\(width).png")
            window.close()
        }
    }
    private func snapshot(_ view:NSView,_ path:String)throws{let rep=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))}
}
