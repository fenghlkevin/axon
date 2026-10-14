import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class CodexReplyTests: XCTestCase {
    func testFinalSnapshotsAndEmptyMessagesPreservePublicAnswer() throws {
        var stream = CodexAnswerStream()
        try stream.event(["method":"item/agentMessage/delta","params":["delta":"public answer"]])
        try stream.event(["method":"item/completed","params":["item":["type":"agentMessage","text":""]]])
        try stream.event(["method":"turn/completed","params":["turn":["status":"completed","items":[["type":"agentMessage","text":" "]]]]])
        XCTAssertEqual(try stream.result(),"public answer")
        var snapshot = CodexAnswerStream()
        try snapshot.event(["method":"turn/completed","params":["turn":["status":"completed","items":[["type":"reasoning","text":"private reasoning"],["type":"agentMessage","text":"final public answer"]]]]])
        XCTAssertEqual(try snapshot.result(),"final public answer")
        var empty = CodexAnswerStream(); try empty.event(["method":"turn/completed","params":["turn":["status":"completed","items":[]]]]); XCTAssertThrowsError(try empty.result()) { XCTAssertTrue($0 is CodexReplyError) }
        var failed = CodexAnswerStream(); XCTAssertThrowsError(try failed.event(["method":"turn/completed","params":["turn":["status":"failed","error":["message":"model unavailable api_key=secret-fixture"]]]])) { XCTAssertTrue($0.localizedDescription.contains("model unavailable")); XCTAssertFalse($0.localizedDescription.contains("secret-fixture")) }
        var tools = CodexAnswerStream(); XCTAssertThrowsError(try tools.event(["method":"turn/completed","params":["turn":["status":"completed","items":[["type":"commandExecution"]]]]]))
    }
    func testEmptyResponseRetriesOnlyModelRequestAndPersistentFailureRestoresInput() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let store=AppStore(fileURL:root.appendingPathComponent("workspace.json"));store.workspace.preferences.language="zh-CN"
        for mode in ["recover","empty","delta","error"] {
            let script=root.appendingPathComponent(mode), count=root.appendingPathComponent(mode+".count")
            let source=#"""
            #!/usr/bin/python3
            import json,sys,pathlib
            name=pathlib.Path(__file__).name
            counter=pathlib.Path(__file__+'.count')
            def emit(x): print(json.dumps(x),flush=True)
            for line in sys.stdin:
                e=json.loads(line)
                if e.get('method')=='initialize':emit({'id':1,'result':{}})
                elif e.get('method')=='config/read':emit({'id':e['id'],'result':{'config':{'mcp_servers':{'external-fixture':{'enabled':True}}}}})
                elif e.get('method')=='thread/start':emit({'id':e['id'],'result':{'thread':{'id':'fixture'}}})
                elif e.get('method')=='turn/start':
                    n=int(counter.read_text())+1 if counter.exists() else 1
                    counter.write_text(str(n));emit({'id':e['id'],'result':{}})
                    if name=='error':emit({'method':'error','params':{'error':{'message':'fixture service error'},'willRetry':False}});continue
                    items=[]
                    if name=='delta':
                        emit({'method':'item/agentMessage/delta','params':{'delta':'DELTA_OK'}})
                        emit({'method':'item/completed','params':{'item':{'type':'agentMessage','text':''}}})
                    if name=='recover' and n==2:items=[{'type':'agentMessage','text':'SNAPSHOT_OK'}]
                    emit({'method':'turn/completed','params':{'turn':{'status':'completed','items':items}}})
            """#
            try source.write(to:script,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
            let ai=AIAssistant(fileURL:root.appendingPathComponent(mode+".json"));ai.settings.codexPath=script.path
            ai.prepare(source:"local response fixture",text:"Synthetic terminal output only",sessionID:nil,question:"看下谁占用了 8081 端口")
            var commands=0
            let executor=AICommandExecutor(sessionID:UUID(),source:"fixture",directory:nil,valid:{true},execute:{_,_ in commands+=1;return AICommandResult(output:"Linux\n/tmp",exitCode:0)})
            ai.send(executor:executor)
            for _ in 0..<500 where ai.busy {try await Task.sleep(for:.milliseconds(10))}
            XCTAssertFalse(ai.busy);XCTAssertEqual(commands,1,"Empty model retry never reruns target commands")
            XCTAssertEqual(try String(contentsOf:count,encoding:.utf8),["recover","empty"].contains(mode) ? "2":"1")
            if mode=="recover" {XCTAssertEqual(ai.answer,"SNAPSHOT_OK");XCTAssertTrue(ai.error.isEmpty,ai.error)}
            if mode=="delta" {XCTAssertEqual(ai.answer,"DELTA_OK");XCTAssertTrue(ai.error.isEmpty,ai.error)}
            if mode=="empty" {XCTAssertTrue(ai.error.contains("连续两次"));XCTAssertEqual(ai.question,"看下谁占用了 8081 端口")}
            if mode=="error" {XCTAssertFalse(ai.error.isEmpty)}
            if mode=="empty" || mode=="recover" {
                try FileManager.default.createDirectory(atPath:"/tmp/axon-0157-ui",withIntermediateDirectories:true)
                for width in [320,500] {
                    let host=NSHostingView(rootView:AIAssistantPane(ai:ai,availableHeight:760).environmentObject(store).frame(width:CGFloat(width),height:760))
                    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
                    try await Task.sleep(for:.milliseconds(100));host.layoutSubtreeIfNeeded();let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/axon-0157-ui/\(mode)-\(width).png"));window.close()
                }
            }
        }
    }
}
