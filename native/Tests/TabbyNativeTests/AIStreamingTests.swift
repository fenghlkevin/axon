import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

@MainActor final class AIStreamingTests: XCTestCase {
    func testSSEAccumulatesBothProvidersAndRequiresCompletion() throws {
        var chat = AIStreamEvents()
        try chat.line(#"data: {"choices":[{"delta":{"content":"你好"}}]}"#, backend: .chatgpt); try chat.line("", backend: .chatgpt)
        XCTAssertEqual(chat.text, "你好"); XCTAssertThrowsError(try chat.result())
        try chat.line(#"data: {"choices":[{"delta":{"content":"，世界"}}]}"#, backend: .chatgpt); try chat.line("", backend: .chatgpt)
        try chat.line(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, backend: .chatgpt); try chat.line("", backend: .chatgpt)
        try chat.line("data: [DONE]", backend: .chatgpt); try chat.line("", backend: .chatgpt)
        XCTAssertEqual(try chat.result(), "你好，世界")
        var claude = AIStreamEvents()
        try claude.line(#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private"}}"#, backend: .claude); try claude.line("", backend: .claude)
        XCTAssertTrue(claude.text.isEmpty)
        try claude.line(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}"#, backend: .claude); try claude.line("", backend: .claude)
        try claude.line(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, backend: .claude); try claude.line("", backend: .claude)
        try claude.line(#"data: {"type":"message_stop"}"#, backend: .claude); try claude.line("", backend: .claude)
        XCTAssertEqual(try claude.result(), "你好")
        var failed = AIStreamEvents(); try failed.line(#"data: {"error":{"message":"failed"}}"#, backend: .chatgpt)
        XCTAssertThrowsError(try failed.line("", backend: .chatgpt))
        var codex = CodexAnswerStream()
        try codex.event(["method":"item/agentMessage/delta", "params":["delta":"first"]]); XCTAssertEqual(codex.text, "first"); XCTAssertFalse(codex.completed)
        XCTAssertThrowsError(try codex.event(["method":"item/started", "params":["item":["type":"commandExecution"]]]))
    }
    func testAPIStreamsOverHTTPBeforeCompletion() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-http-stream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server.py")
        try #"""
        import http.server,time,json
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length',0)))
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
                def send(event):
                    self.wfile.write(('data: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode('utf-8')); self.wfile.flush()
                if self.path=='/claude':
                    send({'type':'message_start','message':{'usage':{'input_tokens':100,'output_tokens':0,'cache_read_input_tokens':20}}})
                    send({'type':'content_block_delta','delta':{'type':'text_delta','text':'你好'}})
                    time.sleep(1.5)
                    send({'type':'content_block_delta','delta':{'type':'text_delta','text':'，世界'}})
                    send({'type':'message_delta','delta':{'stop_reason':'end_turn'},'usage':{'output_tokens':10}})
                    send({'type':'message_stop'})
                else:
                    send({'choices':[{'delta':{'content':'你好'}}]})
                    time.sleep(1.5)
                    send({'choices':[{'delta':{'content':'，世界'},'finish_reason':'stop'}]})
                    send({'choices':[],'usage':{'prompt_tokens':120,'completion_tokens':10}})
                    self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        server=http.server.HTTPServer(('127.0.0.1',0),Handler)
        from pathlib import Path
        Path(__file__).with_suffix(".port").write_text(str(server.server_port)); server.serve_forever()
        """#.write(to: script, atomically: true, encoding: .utf8)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [script.path]; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        let portFile = script.deletingPathExtension().appendingPathExtension("port")
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: portFile.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(Int(try String(contentsOf: portFile, encoding: .utf8)))
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        try FileManager.default.createDirectory(atPath: "/tmp/axon-ai-wide-ui", withIntermediateDirectories: true)
        for backend in [AIBackend.claude, .chatgpt] {
            let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), apiKeyReader: { _ in "local-fixture-key" })
            ai.settings.backend = backend
            let provider = AIProviderSettings(endpoint: "http://127.0.0.1:\(port)/\(backend.rawValue)", model: "fixture")
            if backend == .claude { ai.settings.claude = provider } else { ai.settings.chatgpt = provider }
            ai.prepare(source: "HTTP streaming fixture", text: "No host data", sessionID: nil, question: "解释当前输出")
            ai.send()
            for _ in 0..<100 { if !ai.answer.isEmpty || !ai.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(ai.busy, ai.error); XCTAssertEqual(ai.answer, "你好")
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, availableHeight: 640).environmentObject(store).frame(width: 760,height: 640))
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:640),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try snapshot(host,path:"/tmp/axon-ai-wide-ui/stream-\(backend.rawValue).png")
            for _ in 0..<150 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(ai.busy); XCTAssertEqual(ai.answer, "你好，世界", ai.error); XCTAssertTrue(ai.error.isEmpty); XCTAssertEqual(ai.usage.tokens.total,130); XCTAssertEqual(ai.usage.unknown,0)
            window.close()
        }
    }
    func testCurrentTerminalContextAndWideWorkspace() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-workspace-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)); session.terminal = view
        store.sessions = [session]; store.activeSession = session.id
        view.feed(text: (1...180).map { "line \($0)" }.joined(separator: "\r\n") + "\r\nERROR upstream connection refused\r\napi_key=private-fixture\r\n")
        try await Task.sleep(for: .milliseconds(100))
        store.ai.question = "服务停止了吗"; store.prepareTerminalAI()
        XCTAssertEqual(store.ai.question, "服务停止了吗")
        XCTAssertEqual(store.ai.context.sessionID, session.id)
        XCTAssertTrue(store.ai.context.text.contains("ERROR upstream connection refused"))
        XCTAssertFalse(store.ai.context.text.contains("private-fixture"))
        XCTAssertFalse(store.ai.context.text.contains("L1: line 1\n"))
        store.ai.answer = "上游连接被拒绝，请检查监听端口。\n```bash\nss -lntp\n```"; store.ai.answerSessionID = session.id
        view.feed(text: "\r\nLISTEN 0 128 127.0.0.1:8080\r\n")
        store.prepareTerminalAI(); XCTAssertTrue(store.ai.context.text.contains("127.0.0.1:8080")); XCTAssertTrue(store.ai.context.text.contains("Previous assistant hypothesis"))
        view.selectAll(); store.prepareTerminalAI(selectionOnly: true); XCTAssertTrue(store.ai.context.text.contains("Selected output")); view.selectNone()
        let directory = "/tmp/axon-ai-wide-ui"; try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [1050, 1400] {
            let panelWidth = TerminalToolsPanel.allocatedWidth(selection: "ai", workspace: CGFloat(width))
            XCTAssertEqual(panelWidth, TerminalToolsPanel.width); XCTAssertGreaterThan(CGFloat(width) - panelWidth, 450)
            store.ai.answer = String(repeating: "当前输出提示上游拒绝连接，应结合进程与端口判断。\n", count: 10) + "\n```bash\nss -lntp\n```"
            let host = NSHostingView(rootView: HStack(spacing: 0) { PreviewTerminal(view: view); TerminalToolsPanel(selection: .constant("ai"), isVisible: .constant(true), availableHeight: 760, panelWidth: panelWidth) }.environmentObject(store).frame(width: CGFloat(width), height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded(); try snapshot(host, path: "\(directory)/workspace-\(width).png")
            let expand = try XCTUnwrap(accessible(host).first { read($0, "accessibilityIdentifier") as? String == "axon-ai-expand" })
            let press = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let preview = try XCTUnwrap(accessible(host).first { read($0, "accessibilityIdentifier") as? String == "axon-ai-preview" })
            let previousAnswer = store.ai.answer
            XCTAssertTrue(unsafeBitCast(preview.method(for: press), to: Press.self)(preview, press))
            XCTAssertEqual(store.ai.answer, previousAnswer)
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); try snapshot(host, path: "\(directory)/preview-\(width).png")
            XCTAssertTrue(unsafeBitCast(expand.method(for: press), to: Press.self)(expand, press)); XCTAssertTrue(store.aiAnalysisPresented)
            window.close()
        }
        let host = NSHostingView(rootView: AIAnalysisSheet().environmentObject(store)); let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 980,height: 700),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded(); try snapshot(host,path: "\(directory)/expanded.png"); window.close()
    }
    private struct PreviewTerminal: NSViewRepresentable {
        let view: TerminalView
        func makeNSView(context: Context) -> TerminalView { view }
        func updateNSView(_ nsView: TerminalView, context: Context) {}
    }
    private func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
    private func accessible(_ view: NSView) -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) { guard seen.insert(ObjectIdentifier(object)).inserted else { return }; result.append(object); for child in read(object,"accessibilityChildren") as? [NSObject] ?? [] { visit(child) } }
        visit(view); return result
    }
    private func snapshot(_ view: NSView, path: String) throws { let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in:view.bounds,to:rep); try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path)) }
}
