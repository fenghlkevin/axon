import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class CommandOriginTests: XCTestCase {
    func testHookAttributionMixedInputAndLegacyUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")), history = CommandHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store); session.commandHistoryStore = history; session.commandHistoryToken = "fixture"; session.commandHistoryReady = true; session.commandHistoryRecording = true
        let log = try store.sessionLogs.begin(session: session); session.transcriptID = log
        func command(_ value: String) { let report = "axon-command;fixture;" + Data(value.utf8).base64EncodedString(); session.captureOutput(Array(("\u{1b}]7;" + report + "\u{7}").utf8)); XCTAssertTrue(session.receiveCommandHistory(report)) }
        session.recordInputOrigin(.ai); command("df -h")
        session.recordInputOrigin(.human); command("pwd")
        session.recordInputOrigin(.ai); session.recordInputOrigin(.human); command("free -h")
        command("whoami")
        XCTAssertEqual(history.entries.map { $0.origin ?? .unknown }, [.unknown,.mixed,.human,.ai])
        let output = String(decoding: try store.sessionLogs.content(log), as: UTF8.self)
        XCTAssertTrue(output.contains("AI + 人工")); XCTAssertTrue(output.contains("终端输入")); XCTAssertTrue(output.contains("人工"))
        store.sessionLogs.stop(log)
        let reloaded = SessionLogStore(root: store.sessionLogs.root); XCTAssertEqual(reloaded.records.first?.markers.map { $0.origin ?? .unknown }, [.ai,.human,.mixed,.unknown])
        let entry = ExecutedCommand(hostID: nil, hostName: "fixture", sessionID: session.id, command: "old command")
        XCTAssertNil(try JSONDecoder().decode(ExecutedCommand.self, from: JSONEncoder().encode(entry)).origin)
        var tracker = CommandOriginTracker(); tracker.input(.ai); tracker.input(.human); XCTAssertEqual(tracker.consume(), .mixed); XCTAssertEqual(tracker.consume(), .unknown)
    }
    func testAnnotationsPreserveHookOffsetsAndDoNotRecordInputSecrets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")), session = TerminalSession(host: nil, store: store)
        let id = try store.sessionLogs.begin(session: session); session.transcriptID = id
        store.sessionLogs.append(Array("before\n".utf8), id: id); session.recordInputOrigin(.human)
        let chinese = Array("中文".utf8)
        store.sessionLogs.append(Array(chinese.prefix(1)), id:id); session.recordInputOrigin(.ai)
        store.sessionLogs.append(Array(chinese.dropFirst(1)), id:id)
        XCTAssertTrue(String(decoding:try store.sessionLogs.content(id),as:UTF8.self).contains("中文"))
        let before = try store.sessionLogs.content(id).count
        let report = "axon-command;fixture;" + Data("pwd".utf8).base64EncodedString()
        store.sessionLogs.append(Array(("\u{1b}]7;" + report + "\u{7}/tmp\n").utf8), id: id)
        let entry = ExecutedCommand(hostID:nil,hostName:"fixture",sessionID:session.id,command:"pwd",origin:.human)
        store.sessionLogs.marker(entry,report:report,id:id)
        XCTAssertEqual(store.sessionLogs.records.first?.markers.first?.offset, before)
        store.sessionLogs.stop(id)
    }
    func testIndependentAuditAndLogUI() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL:root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let history = CommandHistoryStore(fileURL:root.appendingPathComponent("history.json")), session = TerminalSession(host:nil,store:store); session.commandHistoryStore = history; session.commandHistoryRecording = true
        let id = try store.sessionLogs.begin(session:session); session.transcriptID = id
        let executor = AICommandExecutor(session:session)
        executor.auditOperation?("df -h",nil); executor.auditOperation?("df -h",AICommandResult(output:"/dev/system 400G 22G\n",exitCode:0))
        XCTAssertEqual(history.entries.first?.origin,.ai); XCTAssertEqual(history.entries.first?.exitCode,0)
        session.recordInputOrigin(.human)
        let human = ExecutedCommand(hostID:nil,hostName:"人工操作",sessionID:session.id,command:"pwd",origin:.human); history.append(human); store.sessionLogs.marker(human,report:"",id:id); store.sessionLogs.append(Array("/root\n".utf8),id:id)
        session.recordInputOrigin(.ai); session.recordInputOrigin(.human)
        let mixed = ExecutedCommand(hostID:nil,hostName:"共同操作",sessionID:session.id,command:"free -h",origin:.mixed); history.append(mixed); store.sessionLogs.marker(mixed,report:"",id:id)
        let exported = String(decoding:try store.sessionLogs.content(id),as:UTF8.self); XCTAssertTrue(exported.contains("AI · independent")); XCTAssertTrue(exported.contains("22G")); XCTAssertTrue(exported.contains("AI + 人工"))
        store.sessionLogs.stop(id); store.sessionLogs.selectedID = id
        try FileManager.default.createDirectory(atPath:"/tmp/axon-0156-ui",withIntermediateDirectories:true)
        for width in [1050,1400] {
            let host = NSHostingView(rootView:SessionLogsView(logs:store.sessionLogs).padding(20).environmentObject(store).frame(width:CGFloat(width),height:760).background(Palette.background))
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:760),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
            try await Task.sleep(for:.milliseconds(250));host.layoutSubtreeIfNeeded();try snapshot(host,"/tmp/axon-0156-ui/logs-\(width).png")
            let choice = try XCTUnwrap(descendants(host).compactMap { $0 as? SelectionFieldButton }.first { $0.accessibilityIdentifier() == "axon-transcript-command" })
            choice.performClick(nil); try await Task.sleep(for:.milliseconds(100)); let popup = try XCTUnwrap(AxonMenuPopover.active)
            XCTAssertTrue(popup.menu.items.contains { $0.title.contains("[AI]") }); XCTAssertTrue(popup.menu.items.contains { $0.title.contains("[人工]") }); XCTAssertTrue(popup.menu.items.contains { $0.title.contains("[AI + 人工]") })
            try snapshot(try XCTUnwrap(popup.popover.contentViewController?.view),"/tmp/axon-0156-ui/command-origins-\(width).png")
            popup.highlighted = 1; XCTAssertTrue(popup.handleKey(36)); window.close()
        }
        let host = NSHostingView(rootView:OperationHistoryView(history:history, server:"local").padding(20).environmentObject(store).frame(width:1050,height:760).background(Palette.background))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(200));host.layoutSubtreeIfNeeded();try snapshot(host,"/tmp/axon-0156-ui/history.png");window.close()
    }
    func testHistorySourceFilterAndColoredBadgesUI() async throws {
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store=AppStore(fileURL:root.appendingPathComponent("workspace.json"));store.workspace.preferences.language="zh-CN"
        let history=CommandHistoryStore(fileURL:root.appendingPathComponent("history.json"))
        for origin in CommandOrigin.allCases { history.append(ExecutedCommand(hostID:nil,hostName:"测试服务器",sessionID:UUID(),command:"printf source_" + origin.rawValue,origin:origin)) }
        try FileManager.default.createDirectory(atPath:"/tmp/axon-0160-ui",withIntermediateDirectories:true)
        for width in [1050,1400] {
            let host=NSHostingView(rootView:OperationHistoryView(history:history,server:"local").environmentObject(store).frame(width:CGFloat(width),height:760).background(Palette.background));host.sizingOptions=[]
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
            try await Task.sleep(for:.milliseconds(200));try snapshot(host,"/tmp/axon-0160-ui/history-all-\(width).png")
            let choice=try XCTUnwrap(descendants(host).compactMap{$0 as? SelectionFieldButton}.first{$0.accessibilityIdentifier()=="axon-history-origin-filter"})
            choice.performClick(nil);try await Task.sleep(for:.milliseconds(100));let popup=try XCTUnwrap(AxonMenuPopover.active)
            XCTAssertEqual(popup.menu.items.map(\.title), ["全部来源", "AI", "人工"]);try snapshot(try XCTUnwrap(popup.popover.contentViewController?.view),"/tmp/axon-0160-ui/source-menu-\(width).png")
            popup.highlighted=1;XCTAssertTrue(popup.handleKey(36));try await Task.sleep(for:.milliseconds(150));XCTAssertEqual(choice.title,"AI")
            try snapshot(host,"/tmp/axon-0160-ui/history-ai-\(width).png")
            // The chosen origin remains active when the backing history updates.
            history.append(ExecutedCommand(hostID:nil,hostName:"测试服务器",sessionID:UUID(),command:"printf another_human",origin:.human))
            try await Task.sleep(for:.milliseconds(100));XCTAssertEqual(choice.title,"AI")
            window.close()
        }
    }
    private func descendants(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(descendants) }
    private func snapshot(_ view:NSView,_ path:String) throws {let rep=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))}
}
