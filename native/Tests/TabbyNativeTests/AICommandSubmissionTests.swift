import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AICommandSubmissionTests: XCTestCase {
    func testCompleteCommandEvidenceAndSubmissionAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store)
        let bridge = AITerminalBridge(session: session)
        func action(_ tool: String, _ argument: String) throws -> AIAgentAction {
            try JSONDecoder().decode(AIAgentAction.self, from: JSONSerialization.data(withJSONObject: ["tool":tool,"argument":argument,"reason":"fixture"]))
        }
        let send = try action("terminal_send", "rm ")
        XCTAssertFalse(bridge.permission(send, fallback: "input").typing)
        session.commandHistoryToken = "fixture"; session.commandHistoryReady = true
        XCTAssertTrue(session.receiveCommandHistory("axon-command;wrong;prompt"))
        XCTAssertNil(session.aiShellInput.line)
        XCTAssertTrue(session.receiveCommandHistory("axon-command;fixture;prompt"))
        XCTAssertTrue(bridge.permission(send, fallback: "input").typing)
        session.aiShellInput.input(Array("rm ".utf8)); session.aiShellInput.input(Array("file.txt".utf8))
        var policy = AIExecutionPolicy(); policy.commandBlacklist = "rm .*"; policy.commandWhitelist = ".*"
        for key in ["enter", "ctrl-j", "ctrl-m"] {
            let permission = bridge.permission(try action("terminal_key", key), fallback: key)
            XCTAssertEqual(permission.tool, "terminal_execute"); XCTAssertEqual(permission.argument, "rm file.txt")
            XCTAssertEqual(policy.decision(target:"local",tool:permission.tool,argument:permission.argument,automatic:false,command:permission.command), .deny)
        }
        session.aiShellInput.input([9]); XCTAssertNil(session.aiShellInput.line)
        session.aiShellInput.prompt(); session.aiShellInput.input(Array("ss -lntup 'sport = :8081'".utf8))
        let submit = bridge.permission(try action("terminal_key", "enter"), fallback: "enter")
        policy.commandBlacklist = nil; policy.commandWhitelist = "ss .*"
        XCTAssertEqual(policy.decision(target:"local",tool:submit.tool,argument:submit.argument,automatic:false), .allow)
        policy.approvalMode = .everyTime
        XCTAssertEqual(policy.decision(target:"local",tool:submit.tool,argument:submit.argument,automatic:false), .ask)
        policy.approvalMode = .assisted; policy.commandWhitelist = nil
        policy.exactAllows = [AIExactPermission(target:"local",tool:"terminal_key",argument:"enter")]
        XCTAssertEqual(policy.decision(target:"local",tool:submit.tool,argument:submit.argument,automatic:false), .ask)
        session.aiShellInput.input([27,91,68]); XCTAssertNil(session.aiShellInput.line)
        session.aiShellInput.prompt(); session.aiShellInput.input(Array("écho 中文".utf8)); XCTAssertEqual(session.aiShellInput.line,"écho 中文")
        session.aiShellInput.input([13]); XCTAssertNil(session.aiShellInput.line)
    }
    func testAgentStagesTextThenChecksEnterAndRechecksEdits() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store = AppStore(fileURL:root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host:nil,store:store);session.connected=true
        let terminal = LocalTerminal(frame:NSRect(x:0,y:0,width:600,height:400)); session.terminal=terminal;terminal.ownerSession=session;terminal.terminalDelegate=session
        terminal.startProcess(executable:"/bin/bash",args:["--noprofile","--norc","-i"],environment:["PATH=/usr/bin:/bin","TERM=xterm-256color","PS1=FIXTURE> "],currentDirectory:root.path)
        defer { terminal.terminate() }
        try await Task.sleep(for:.milliseconds(300))
        for mode in ["deny","ask","allow","edited"] {
            session.aiShellInput.prompt()
            var round=0
            let ai=AIAssistant(fileURL:root.appendingPathComponent(mode+".json"),modelResponder:{ _,_,_ in
                round += 1
                if round <= 2 { return try p0FixtureReply("```axon_action\n{\"tool\":\"" + (round == 1 ? "terminal_send" : "terminal_key") + "\",\"argument\":\"" + (round == 1 ? "printf SUBMISSION_FIXTURE" : "enter") + "\",\"reason\":\"fixture\"}\n```", goal: "fixture", tool: "verify_command", argument: "cat /owned/verification", expected: "SUBMISSION_FIXTURE") }
                return "```axon_action\n{\"tool\":\"report_blocker\",\"argument\":\"Fixture shell has no completion hook\",\"reason\":\"fixture\"}\n```"
            })
            var policy=AIExecutionPolicy(); policy.approvalMode = .assisted
            if mode == "ask" || mode == "edited" { policy.rules="ask|.*|terminal_execute|.*" }
            if mode == "deny" { policy.commandBlacklist="printf .*" }
            if mode == "allow" { policy.commandWhitelist="printf .*" }
            ai.settings.executionPolicy=policy; ai.executionChannel = .currentTerminal
            let executor=AICommandExecutor(sessionID:session.id,source:"local fixture",directory:root.path,valid:{session.connected},execute:{_,_ in XCTFail("No independent execution"); return AICommandResult(output:"",exitCode:0) });executor.terminalBridge=AITerminalBridge(session:session)
            ai.prepare(source:executor.source,text:"",sessionID:session.id,question:"fixture");ai.send(executor:executor)
            for _ in 0..<200 { if !ai.busy || ai.pendingApproval != nil { break }; try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertEqual(ai.steps.filter{$0.tool == "terminal_send"}.count,1,"Text insertion never asks at a known shell prompt")
            if mode == "ask" || mode == "edited" {
                XCTAssertEqual(ai.pendingApproval?.tool,"terminal_execute");XCTAssertEqual(ai.pendingApproval?.input,"printf SUBMISSION_FIXTURE")
                if mode == "edited" { session.writeInput(Array(" changed".utf8)); try await Task.sleep(for:.milliseconds(100)) }
                ai.approveAction()
                for _ in 0..<200 { if !ai.busy { break };try await Task.sleep(for:.milliseconds(20)) }
                if mode == "edited" { XCTAssertFalse(ai.error.isEmpty) } else { XCTAssertTrue(ai.error.isEmpty,ai.error) }
            }
            XCTAssertFalse(ai.busy)
            XCTAssertEqual(ai.steps.filter{$0.tool == "terminal_execute" && $0.state == "finished"}.count,mode == "allow" || mode == "ask" ? 1 : 0)
            // Clear the fixture input without executing it before the next case.
            try await session.writeAgentInput([3]);try await Task.sleep(for:.milliseconds(100))
        }
    }
    func testApprovalCommandRenderedAtNarrowAndWideWidths() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let output = URL(fileURLWithPath:"/tmp/axon-0158-ui")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store = AppStore(fileURL:root.appendingPathComponent("workspace.json")); store.workspace.preferences.language="zh-CN"
        store.ai.pendingApproval = AIAgentStep(command:"ss -lntup 'sport = :8081'",reason:"查询占用 8081 端口的进程及 PID",state:"approval",tool:"terminal_execute",input:"ss -lntup 'sport = :8081'")
        for width in [320,500] {
            let host = NSHostingView(rootView:AIAssistantPane(ai:store.ai,terminal:true,availableHeight:900).environmentObject(store).frame(width:CGFloat(width),height:900));host.sizingOptions=[]
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:900),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
            try await Task.sleep(for:.milliseconds(200))
            let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep)
            try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent("approval-\(width).png"))
            window.close()
        }
    }
}
