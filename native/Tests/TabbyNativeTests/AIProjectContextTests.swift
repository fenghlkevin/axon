import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class AIProjectContextTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axon-project-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func executor(_ directory: URL, source: String = "fixture") -> AICommandExecutor {
        let value = AICommandExecutor(sessionID: UUID(), source: source, directory: directory.path, valid: { true }, execute: { _, _ in XCTFail("Context must not execute Shell commands"); return .init(output: "", exitCode: 1) })
        value.fileBackend = { LocalFiles() }; return value
    }
    private func write(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    func testIndexIncrementalDeletionFreshnessAndEndpointIsolation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("service.swift")
        try write("// Cache persistence and authentication\nfunc authenticate() { validate() }\nfunc validate() {}", file)
        let index = AIProjectIndex(fileURL: root.appendingPathComponent("index.json")), ex = executor(source)
        try index.add(root: source.path, endpoint: ex.source)
        let id = index.projects[0].id
        try await index.sync(id, executor: ex, policy: AIExecutionPolicy())
        let hits = index.search(query: "authenticate", endpoint: "fixture")
        XCTAssertFalse(hits.isEmpty); XCTAssertTrue(index.search(query: "authenticate", endpoint: "other").isEmpty)
        XCTAssertEqual(index.projects[0].documents[0].symbols.first?.name, "authenticate")
        try await index.sync(id, executor: ex, policy: AIExecutionPolicy())
        XCTAssertTrue(index.projects[0].note.contains("1 unchanged"))
        try write("// totally replaced\nfunc changed() {}", file)
        let stale = try await index.freshHits(hits, executor: ex, policy: AIExecutionPolicy())
        XCTAssertTrue(stale.isEmpty)
        try await index.sync(id, executor: ex, policy: AIExecutionPolicy())
        XCTAssertEqual(index.projects[0].documents[0].symbols.first?.name, "changed")
        try FileManager.default.removeItem(at: file)
        try await index.sync(id, executor: ex, policy: AIExecutionPolicy())
        XCTAssertTrue(index.projects[0].documents.isEmpty)
        let restored = AIProjectIndex(fileURL: root.appendingPathComponent("index.json"))
        XCTAssertEqual(restored.projects[0].state, "stale")
        try index.enable(id, false); XCTAssertTrue(index.search(query: "changed", endpoint: "fixture").isEmpty)
        try index.remove(id); XCTAssertTrue(index.projects.isEmpty)
    }
    func testIgnoredExplicitReferencesAndSensitiveFilesNeverEnterContext() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("excluded.txt\n", source.appendingPathComponent(".gitignore"))
        try write("DO NOT SEND", source.appendingPathComponent("excluded.txt"))
        try write("password = 'PRIVATE'\nfunc publicAPI() {}", source.appendingPathComponent("app.swift"))
        try write("secret", source.appendingPathComponent(".env"))
        let workspace = AIContextWorkspace(fileURL: root.appendingPathComponent("index.json")), ex = executor(source)
        try workspace.index.add(root: source.path, endpoint: ex.source)
        let ref = AIContextWorkspace.Reference(endpoint: "fixture", root: source.path, path: source.appendingPathComponent("excluded.txt").path, kind: "file", start: 1, end: 3)
        do { _ = try await workspace.collect(references: [ref], urls: [], query: "publicAPI", executor: ex, policy: AIExecutionPolicy()); XCTFail("Ignored file was sent") } catch {}
        try await workspace.index.sync(workspace.index.projects[0].id, executor: ex, policy: AIExecutionPolicy())
        XCTAssertFalse(workspace.index.projects[0].documents.contains { $0.path.hasSuffix("excluded.txt") || $0.path.hasSuffix(".env") })
        let data = try String(contentsOf: root.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("PRIVATE")); XCTAssertFalse(data.contains("DO NOT SEND"))
    }
    func testReferenceLinesAndSymbolsAreActuallyDeliveredAndChatDoesNotExecute() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("app.swift"); try write("// unused\nfunc greet() {}\n// line three", file)
        var observed = ""
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in observed = prompt; return "greet 位于第二行" })
        ai.prepare(source: "fixture", text: "", sessionID: nil, question: "解释 greet")
        try ai.contextWorkspace.index.add(root: source.path, endpoint: "fixture")
        try ai.contextWorkspace.add(.init(endpoint: "fixture", root: source.path, path: file.path, kind: "symbol", start: 2, end: 2))
        ai.send(contextExecutor: executor(source))
        for _ in 0..<200 where ai.busy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error)
        XCTAssertTrue(observed.contains("L2: func greet() {}")); XCTAssertFalse(ai.currentTurnExecuted)
        XCTAssertTrue(ai.contextWorkspace.sentSources.contains { $0.contains("app.swift:2") })
        ai.newConversation(); XCTAssertTrue(ai.contextWorkspace.references.isEmpty)
    }
    func testProgramContextToolUsesFreshIndexAndReportsCandidateRelations() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("import Foundation\nfunc greet() { render() }\nfunc render() {}", source.appendingPathComponent("app.swift"))
        let workspace = AIContextWorkspace(fileURL: root.appendingPathComponent("index.json")), ex = executor(source)
        try workspace.index.add(root: source.path, endpoint: ex.source)
        let argument = String(decoding: try JSONSerialization.data(withJSONObject: ["path": source.path, "query": "render", "kind": "relations"]), as: UTF8.self)
        let action = AIAgentAction(tool: "project_context", argument: argument, reason: "Find callers", path: nil, find: nil, replacement: nil)
        _ = try action.command(os: "Linux")
        let result = try await workspace.execute(action, executor: ex, policy: AIExecutionPolicy())
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.output.contains("greet")); XCTAssertTrue(result.output.contains("NOT type-resolved"))
        XCTAssertTrue(AINativeAgentTools.recognizes("axon_project_context")); XCTAssertTrue(AINativeAgentTools.recognizes("axon_fetch_url"))
    }
    func testImageTransportAndNoTextOnlyFallback() throws {
        let image = AIImageContext(name: "diagram", data: Data([1,2,3]))
        for backend in [AIBackend.chatgpt, .claude] {
            var settings = AISettings(); settings.backend = backend
            if backend == .claude { settings.claude.model = "vision" } else { settings.chatgpt.model = "vision" }
            let request = try AIProtocol.request(settings: settings, key: "fixture", prompt: "Explain picture", images: [image])
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = object["messages"] as! [[String: Any]], blocks = messages.last!["content"] as! [[String: Any]]
            XCTAssertEqual(blocks.count, 2); XCTAssertEqual(blocks[1]["type"] as? String, backend == .claude ? "image" : "image_url")
        }
    }
    func testWebInputSafetyAndHTMLExtraction() throws {
        for bad in ["http://example.com", "https://localhost", "https://user:pass@example.com", "https://host.local", "https://example.com:8000"] { XCTAssertThrowsError(try AIWebContext.validate(bad)) }
        for ip in ["127.0.0.1", "10.1.2.3", "172.16.1.1", "192.168.1.2", "169.254.169.254", "::1", "::ffff:127.0.0.1", "fc00::1"] { XCTAssertFalse(AIWebContext.publicAddress(ip), ip) }
        XCTAssertTrue(AIWebContext.publicAddress("8.8.8.8"))
        XCTAssertEqual(AIWebContext.plain("<script>bad()</script><p>A &amp; B</p>"), "A & B")
        XCTAssertThrowsError(try AIProjectContextRequest.decode("{\"path\":\"/a\",\"query\":\"x\",\"kind\":\"execute\"}"))
        XCTAssertEqual(AIWebContext.references(in: "看 https://example.com/guide，解释一下"), ["https://example.com/guide"])
        XCTAssertTrue(AIWebContext.references(in: "https://example.com/?api_key=PRIVATE").isEmpty)
    }
    func testLocalSemanticRetrievalWithoutKeywordOverlap() async throws {
        guard AIProjectIndex.semanticAvailable else { throw XCTSkip("System English sentence embedding unavailable") }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("Persist records to disk and reload them on restart. Keep saved data between sessions.", source.appendingPathComponent("persistence.txt"))
        let index = AIProjectIndex(fileURL: root.appendingPathComponent("index.json")), ex = executor(source)
        try index.add(root: source.path, endpoint: "fixture"); try await index.sync(index.projects[0].id, executor: ex, policy: AIExecutionPolicy())
        let hits = index.search(query: "durable storage", endpoint: "fixture")
        XCTAssertTrue(hits.contains { $0.path.hasSuffix("persistence.txt") && $0.semantic })
    }
    func testJavaSpringOutlineDoesNotTreatCommentsStringsOrNeighborBodiesAsCalls() {
        let source = """
        @RequestMapping("/api")
        public class Controller {
            // void pretend() { erase(); }
            @GetMapping("/users")
            public java.util.List<User> users() {
                String example = "danger()";
                return service.loadUsers();
            }
            public void refresh() { service.reload(); }
        }
        """
        let symbols = AIJavaOutline.symbols(source)
        let users = symbols.first { $0.name == "users" }
        XCTAssertEqual(users?.line, 5)
        XCTAssertEqual(users?.calls, ["loadUsers"])
        XCTAssertFalse(symbols.contains { $0.name == "pretend" })
        XCTAssertEqual(symbols.first { $0.name == "refresh" }?.calls, ["reload"])
        XCTAssertEqual(AIJavaOutline.springRoutes(source), ["line 1: RequestMapping \"/api\"", "line 4: GetMapping \"/users\""])
    }
    func testMavenDeclarationsRemainUnresolvedAndExternalEntitiesAreRejected() {
        let pom = "<project><dependencies><dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency></dependencies></project>"
        XCTAssertEqual(AIJavaDependencies.maven(pom), ["org.springframework.boot:spring-boot-starter-web:inherited/unresolved scope=compile"])
        XCTAssertTrue(AIJavaDependencies.maven("<!DOCTYPE project SYSTEM 'file:///etc/passwd'>" + pom).isEmpty)
    }
    func testGitInfoExcludeAndChangedExclusionsInvalidateCache() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["init", "-q", source.path]; try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
        try write("private.log\n", source.appendingPathComponent(".git/info/exclude"))
        try write("excluded log", source.appendingPathComponent("private.log"))
        let file = source.appendingPathComponent("code.swift"); try write("func publicCode() {}", file)
        let index = AIProjectIndex(fileURL: root.appendingPathComponent("index.json")), ex = executor(source)
        try index.add(root: source.path, endpoint: "fixture"); try await index.sync(index.projects[0].id, executor: ex, policy: AIExecutionPolicy())
        XCTAssertFalse(index.projects[0].documents.contains { $0.path.hasSuffix("private.log") })
        let hits = index.search(query: "publicCode", endpoint: "fixture")
        try write("private.log\ncode.swift\n", source.appendingPathComponent(".git/info/exclude"))
        let fresh = try await index.freshHits(hits, executor: ex, policy: AIExecutionPolicy())
        XCTAssertFalse(fresh.contains { $0.path == file.path })
    }
    func testLiveCodexImageContext() async throws {
        guard ProcessInfo.processInfo.environment["AXON_TEST_CODEX"] == "1" else { throw XCTSkip("Opt-in authenticated image model request") }
        _ = NSApplication.shared
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0,y: 0,width: 240,height: 100).fill()
        ("4827" as NSString).draw(at: NSPoint(x: 25,y: 25), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let file = root.appendingPathComponent("digits.png"); try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"))
        let models = try await CodexModelCatalog.discover(settings: ai.settings)
        let model = try XCTUnwrap(models.first { $0.efforts.contains("low") }); ai.settings.codexModel = model.slug; ai.settings.codexReasoningEffort = "low"
        ai.prepare(source: "image fixture", text: "", sessionID: nil, question: "图片中的四位数字是什么？只回答图片上的数字。"); try ai.contextWorkspace.addImage(file); ai.send()
        for _ in 0..<1800 where ai.busy { try await Task.sleep(for: .milliseconds(100)) }
        defer { ai.cancel() }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertTrue(ai.answer.contains("4827"), ai.answer)
    }
    func testRedactionPreservesSourceLines() {
        let lines = AIProjectIndex.lineSafe("a\n-----BEGIN PRIVATE KEY-----\nSECRET\n-----END PRIVATE KEY-----\nfunc five() {}")
        XCTAssertEqual(lines.count, 5); XCTAssertEqual(lines[4], "func five() {}"); XCTAssertFalse(lines.joined().contains("SECRET"))
    }
    func testContextPanelNativeNarrowWideAndReferenceRemoval() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")), ex = executor(root)
        let workspace = AIContextWorkspace(fileURL: root.appendingPathComponent("index.json"))
        try workspace.index.add(root: root.path, endpoint: "fixture")
        try workspace.add(.init(endpoint: "fixture", root: root.path, path: root.appendingPathComponent("very-long-project-file-name.swift").path, kind: "file", start: 1, end: 20))
        let output = URL(fileURLWithPath: "/tmp/axon-0200-ui"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width: CGFloat in [320,600] {
            let view = NSHostingView(rootView: AIContextWorkspaceView(workspace: workspace, index: workspace.index, executor: ex).environmentObject(store).frame(width: width, height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("context-\(Int(width)).png"))
            func scrolls(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrolls) }
            if let scroll = scrolls(view).first, let document = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded()
                let lower = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: lower)
                try lower.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("context-bottom-\(Int(width)).png"))
            }
            if width == 600 { try press(view, "axon-context-remove-reference"); XCTAssertTrue(workspace.references.isEmpty) }
            window.close()
        }
    }
    private func press(_ view: NSView, _ id: String) throws {
        var objects: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; objects.append(object)
            for child in read(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(view)
        let candidates = objects.filter { read($0, "accessibilityIdentifier") as? String == id }
        let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c)(AnyObject, Selector) -> Bool
        for object in candidates {
            if let button = object as? NSButton { button.performClick(nil); return }
            if object.responds(to: selector), unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector) { return }
        }
        XCTFail("Cannot press " + id)
    }
    func testActualNativeSyncButtonAndImageDecoding() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("func visibleSymbol() {}", source.appendingPathComponent("app.swift"))
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")), ex = executor(source)
        let workspace = AIContextWorkspace(fileURL: root.appendingPathComponent("index.json")); try workspace.index.add(root: source.path, endpoint: "fixture")
        let view = NSHostingView(rootView: AIContextWorkspaceView(workspace: workspace, index: workspace.index, executor: ex).environmentObject(store).frame(width: 600, height: 760))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 600,height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); try press(view, "axon-context-sync")
        for _ in 0..<100 where workspace.index.projects[0].updated == nil { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(workspace.index.projects[0].documents.count, 1)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let file = root.appendingPathComponent("image.png"); try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        try workspace.addImage(file); XCTAssertEqual(workspace.images.count, 1)
        XCTAssertTrue(workspace.images[0].url.hasPrefix("data:image/png;base64,"))
    }
    func testLiveWebFetchAndSearch() async throws {
        guard ProcessInfo.processInfo.environment["AXON_TEST_WEB"] == "1" else { throw XCTSkip("Opt-in public network read") }
        let page = try await AIWebContext.fetch("https://www.swift.org/documentation/")
        XCTAssertTrue(page.text.lowercased().contains("swift"), String(page.text.prefix(800))); XCTAssertTrue(page.url.contains("swift.org"))
        let result = try await AIWebContext.search("Swift programming language documentation site:swift.org")
        XCTAssertTrue(result.contains("https://"))
    }
}
