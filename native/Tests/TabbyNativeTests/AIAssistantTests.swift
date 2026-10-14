import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AIAssistantTests: XCTestCase {
    func testConversationFollowUpAndTargetIsolation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        var prompts: [String] = []
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, publish in
            prompts.append(prompt); let answer = prompts.count == 1 ? "系统盘剩余 22G，数据盘剩余 94G。" : "你刚才问的是磁盘容量，系统盘还有 22G。"; publish(answer); return answer
        })
        let first = UUID(), second = UUID()
        ai.prepare(source: "fixture-one", text: "df output", sessionID: first, question: "看看磁盘容量")
        ai.send(); for _ in 0..<100 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        ai.prepare(source: "fixture-one", text: "fresh context", sessionID: first, question: "那系统盘呢？")
        XCTAssertEqual(ai.answer, "系统盘剩余 22G，数据盘剩余 94G。")
        ai.send(); for _ in 0..<100 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ai.conversation.count, 1); XCTAssertTrue(prompts[1].contains("看看磁盘容量")); XCTAssertTrue(prompts[1].contains("数据盘剩余 94G"))
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0154-ui", withIntermediateDirectories: true)
        for width in [320, 500] {
            let host = NSHostingView(rootView: AIAssistantPane(ai: ai, availableHeight: 760).environmentObject(store).frame(width: CGFloat(width), height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: width,height: 760),styleMask: [.titled],backing: .buffered,defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await settle(host); try snapshot(host, path: "/tmp/axon-0154-ui/conversation-\(width).png")
            window.close()
        }
        ai.prepare(source: "fixture-two", text: "other server", sessionID: second, question: "hello")
        XCTAssertTrue(ai.conversation.isEmpty); XCTAssertTrue(ai.answer.isEmpty)
        ai.send(); for _ in 0..<100 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(prompts[2].contains("数据盘剩余 94G"))
        ai.prepare(source: "fixture-one", text: "refreshed", sessionID: first, question: "继续")
        XCTAssertEqual(ai.conversation.count, 2); XCTAssertEqual(ai.conversation[1].question, "那系统盘呢？")
    }
    func testTaskConversationRetainsActionsAndReplyCopy() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, update in update("系统盘剩余 22G。"); return "系统盘剩余 22G。" })
        let id = UUID(), executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: "/fixture", valid: { true }, execute: { _, update in update("Linux\n/fixture"); return AICommandResult(output: "Linux\n/fixture", exitCode: 0) })
        ai.prepare(source: "fixture", text: "fixture context", sessionID: id, question: "查一下磁盘")
        ai.send(executor: executor); for _ in 0..<100 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        ai.question = "谢谢，解释一下系统盘"; ai.send(); for _ in 0..<100 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ai.conversation.count, 1); XCTAssertEqual(ai.conversation[0].steps.count, 1); XCTAssertTrue(ai.conversation[0].executed); XCTAssertFalse(ai.currentTurnExecuted)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let host = NSHostingView(rootView: AIAssistantPane(ai: ai, availableHeight: 760).environmentObject(store).frame(width: 500, height: 760))
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:500,height:760),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await settle(host)
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0154-ui", withIntermediateDirectories: true)
        try snapshot(host, path: "/tmp/axon-0154-ui/task-conversation.png")
        let copies = accessible(host).filter { read($0, "accessibilityIdentifier") as? String == "axon-ai-copy-answer" }
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first), action = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        XCTAssertTrue(unsafeBitCast(copy.method(for: action), to: Press.self)(copy, action))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "系统盘剩余 22G。")
        NSPasteboard.general.clearContents(); if let previousClipboard { NSPasteboard.general.setString(previousClipboard, forType: .string) }
        window.close()
    }
    func testSentInputClearsAndFailureRestoresWithoutReplacingNewDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, publish in XCTAssertTrue(prompt.contains("original question")); publish("answer"); return "answer" })
        ai.question = "original question"; ai.send(); XCTAssertEqual(ai.question, ""); XCTAssertEqual(ai.submittedQuestion, "original question")
        for _ in 0..<100 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ai.answer, "answer"); XCTAssertEqual(ai.question, "")
        let failed = AIAssistant(fileURL: root.appendingPathComponent("failed.json"), modelResponder: { _, _, _ in throw AppFailure.message("fixture failure") })
        failed.question = "retry me"; failed.send()
        for _ in 0..<100 where failed.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(failed.question, "retry me")
        failed.send(); failed.question = "new draft"
        for _ in 0..<100 where failed.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(failed.question, "new draft")
    }
    func testSavedModelPreferencesSurviveSettingsReentryAndCatalogLoading() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0152-ui", withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        var saved = store.ai.settings; saved.codexModel = "gpt-6.1-sol"; saved.codexReasoningEffort = "high"; saved.codexServiceTier = "default"; try store.ai.save(saved, key: "")
        for width in [1050, 1400] {
            let host = NSHostingView(rootView: ScrollView { AISettingsPane(ai: store.ai).padding(20).frame(maxWidth: 840) }.environmentObject(store).frame(width: CGFloat(width), height: 850)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await settle(host)
            for (identifier, expected) in [("axon-ai-codex-effort", "高"), ("axon-ai-codex-speed", "标准")] {
                let field = try XCTUnwrap(descendants(host).compactMap { $0 as? SelectionFieldButton }.first { $0.accessibilityIdentifier() == identifier })
                XCTAssertEqual(field.title, expected)
            }
            try snapshot(host, path: "/tmp/axon-0152-ui/settings-\(width).png")
            let effort = try XCTUnwrap(descendants(host).compactMap { $0 as? SelectionFieldButton }.first { $0.accessibilityIdentifier() == "axon-ai-codex-effort" })
            XCTAssertTrue(effort.isEnabled)
            if effort.isEnabled {
                effort.performClick(nil); try await settle(host); let popup = try XCTUnwrap(AxonMenuPopover.active)
                let index = try XCTUnwrap(popup.menu.items.firstIndex { $0.title == "中" })
                popup.highlighted = index; XCTAssertTrue(popup.handleKey(36)); try await Task.sleep(for: .milliseconds(450)); try await settle(host)
                XCTAssertEqual(store.ai.settings.codexReasoningEffort, "medium")
                XCTAssertEqual(AIAssistant(fileURL: root.appendingPathComponent("ai-settings.json")).settings.codexReasoningEffort, "medium")
                effort.performClick(nil); try await settle(host); let restore = try XCTUnwrap(AxonMenuPopover.active)
                restore.highlighted = try XCTUnwrap(restore.menu.items.firstIndex { $0.title == "高" }); XCTAssertTrue(restore.handleKey(36)); try await Task.sleep(for: .milliseconds(450)); try await settle(host)
            }
            window.close()
            let loaded = AIAssistant(fileURL: root.appendingPathComponent("ai-settings.json"))
            XCTAssertEqual(loaded.settings.codexModel, saved.codexModel); XCTAssertEqual(loaded.settings.codexReasoningEffort, "high"); XCTAssertEqual(loaded.settings.codexServiceTier, "default")
        }
    }
    func testProviderProtocolsAndUnsafeEndpoints() throws {
        var settings = AISettings(); settings.backend = .claude; settings.claude.model = "fixture-model"
        let request = try AIProtocol.request(settings: settings, key: "fixture-secret", prompt: "question")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNotNil(body["system"]); XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        settings.backend = .chatgpt; settings.chatgpt.model = "fixture"
        let openAI = try AIProtocol.request(settings: settings, key: "fixture", prompt: "question")
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        for endpoint in ["http://example.com/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/test"] {
            settings.chatgpt.endpoint = endpoint
            XCTAssertThrowsError(try AIProtocol.request(settings: settings, key: "fixture", prompt: "question"))
        }
        XCTAssertEqual(try AIProtocol.response(Data(#"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"hello"}]}"#.utf8), backend: .claude), "hello")
        XCTAssertEqual(try AIProtocol.response(Data(#"{"choices":[{"message":{"content":"hello"},"finish_reason":"stop"}]}"#.utf8), backend: .chatgpt), "hello")
        XCTAssertThrowsError(try AIProtocol.response(Data(#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#.utf8), backend: .chatgpt))
    }
    func testRedactionAndCommandExtraction() {
        let text = AIContext.sanitize("password=hello Bearer abcdef token='secret value' https://alice:password@example.org\n-----BEGIN OPENSSH PRIVATE KEY-----\nprivate data")
        for secret in ["hello", "abcdef", "secret value", "alice:password", "private data"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(text.contains("[REDACTED]"))
        XCTAssertEqual(AIProtocol.commands("```bash\nprintf 'ok'\n```\n```json\n{}\n```"), ["printf 'ok'"])
        XCTAssertTrue(AIProtocol.commands("```bash\nprintf '\u{1b}[31m'\n```").isEmpty)
        XCTAssertLessThan(AIContext.sanitize(String(repeating: "x", count: 100000)).count, 24100)
    }
    func testCLILifecycleAndOriginalTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("codex")
        // A fixture exercises the real Process path and stdin, without model calls.
        let script = #"""
        #!/usr/bin/python3
        import sys,json,time
        def emit(value): print(json.dumps(value),flush=True)
        for line in sys.stdin:
            event=json.loads(line)
            if event.get('method')=='initialize': emit({'id':1,'result':{}})
            if event.get('method')=='thread/start': emit({'id':2,'result':{'thread':{'id':'fixture-thread'}}})
            if event.get('method')=='turn/start':
                emit({'id':3,'result':{}})
                emit({'method':'item/agentMessage/delta','params':{'delta':'fixture '}})
                time.sleep(0.6)
                emit({'method':'item/agentMessage/delta','params':{'delta':'answer'}})
                emit({'method':'turn/completed','params':{'turn':{'status':'completed'}}})
        """#
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let ai = AIAssistant(fileURL: root.appendingPathComponent("settings.json")); ai.settings.codexPath = cli.path
        let target = UUID(); ai.prepare(source: "fixture", text: "selected error", sessionID: target, question: "explain")
        ai.send()
        for _ in 0..<100 { if !ai.answer.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ai.busy); XCTAssertEqual(ai.answer, "fixture ")
        XCTAssertNil(ai.answerSessionID)
        for _ in 0..<100 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(ai.answer, "fixture answer"); XCTAssertEqual(ai.answerSessionID, target); XCTAssertTrue(ai.error.isEmpty)
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: cli, atomically: true, encoding: .utf8)
        ai.send(); try await Task.sleep(for: .milliseconds(100)); ai.cancel()
        XCTAssertFalse(ai.busy)
        ai.prepare(source: "new", text: "new", sessionID: nil, question: "new")
        try await Task.sleep(for: .milliseconds(200)); XCTAssertTrue(ai.answer.isEmpty); XCTAssertNil(ai.answerSessionID)
    }
    func testInstalledCodexSmoke() async throws {
        guard ProcessInfo.processInfo.environment["AXON_TEST_CODEX"] == "1" else { throw XCTSkip("Set AXON_TEST_CODEX=1 to call the locally authenticated Codex CLI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var desktopEnvironment = ProcessInfo.processInfo.environment; desktopEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let ai = AIAssistant(fileURL: root.appendingPathComponent("settings.json"), cliEnvironment: desktopEnvironment)
        if let model = (try await CodexModelCatalog.discover(settings: ai.settings, environment: desktopEnvironment)).first { ai.settings.codexModel = model.slug; ai.settings.codexReasoningEffort = model.efforts.first }
        ai.settings.codexServiceTier = "default"
        ai.prepare(source: "Axon smoke test", text: "No host, files or logs supplied.", sessionID: nil, question: "Reply with exactly AXON_AI_OK. Do not use tools.")
        ai.send()
        for _ in 0..<1300 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(ai.busy); XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertTrue(ai.answer.contains("AXON_AI_OK"))
    }
    func testNativeRenderingAndSelection() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: attribute) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let ai = store.ai
        ai.prepare(source: "production-host-with-a-long-name", text: "L1: upstream connection refused\nL2: status=502", sessionID: nil, question: "分析 502 报错，并解释下一步检查")
        ai.answer = "日志 L1 显示上游连接被拒绝。这可能是服务未启动或端口不匹配，请先检查。\n```bash\nss -lntp\n```"
        let directory = "/tmp/axon-ai-ui"; try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [1050, 1400] {
            let host = NSHostingView(rootView: HStack(spacing: 0) { WorkspaceNavigation(settingsPage: .constant(.ai)).frame(width: 190); ScrollView { AISettingsPane(ai: ai).padding(24) }; TerminalToolsPanel(selection: .constant("ai"), isVisible: .constant(true), availableHeight: 730, panelWidth: 460) }.background(Palette.background).environmentObject(store).frame(width: CGFloat(width), height: 730))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 730), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await settle(host); try snapshot(host, path: "\(directory)/ai-\(width).png")
            let tabs = descendants(host).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("axon-terminal-tool-") == true }
            XCTAssertEqual(tabs.count, 6)
            for tab in tabs { XCTAssertGreaterThan(tab.frame.width, 30); XCTAssertEqual(tab.frame.height, 48, accuracy: 1) }
            // Exercise the real custom provider popover.
            if let provider = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "axon-ai-provider" }) {
                provider.scrollToVisible(provider.bounds); try await settle(host); provider.performClick(nil); try await settle(host)
                let popover = try XCTUnwrap(AxonMenuPopover.active)
                try snapshot(try XCTUnwrap(popover.popover.contentViewController?.view), path: "\(directory)/provider-\(width).png")
                XCTAssertEqual(popover.menu.items.filter { $0.state == .on }.count, 1)
                XCTAssertTrue(popover.handleKey(125)); XCTAssertTrue(popover.handleKey(36))
                try await settle(host)
            }
            window.close()
        }
        ai.error = "AI request failed (HTTP 401). / AI 请求失败，请检查接口和密钥。"
        let host = NSHostingView(rootView: ScrollView { AIAssistantPane(ai: ai).padding(16) }.environmentObject(store).frame(width: 660, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 700), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await settle(host); try snapshot(host, path: "\(directory)/analysis-error.png")
        XCTAssertFalse(accessible(host).contains { read($0, "accessibilityIdentifier") as? String == "axon-ai-copy-answer" })
        XCTAssertFalse(accessible(host).contains { read($0, "accessibilityIdentifier") as? String == "axon-ai-edit-command-0" })
        let action = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let disclosure = try XCTUnwrap(accessible(host).first { read($0, "accessibilityRole") as? String == "AXDisclosureTriangle" })
        XCTAssertTrue(unsafeBitCast(disclosure.method(for: action), to: Press.self)(disclosure, action))
        try await settle(host); try snapshot(host, path: "\(directory)/analysis-context.png")
        XCTAssertTrue(accessible(host).contains { read($0, "accessibilityIdentifier") as? String == "axon-ai-context" })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("codex-loading")
        try "#!/bin/sh\nexec /bin/sleep 5\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        ai.settings.codexPath = cli.path
        ai.prepare(source: "loading fixture", text: "error: fixture", sessionID: nil, question: "explain")
        ai.send(); try await settle(host); XCTAssertTrue(ai.busy)
        try snapshot(host, path: "\(directory)/analysis-loading.png")
        ai.cancel(); try await settle(host); XCTAssertFalse(ai.busy)
        try snapshot(host, path: "\(directory)/analysis-empty.png")
        window.close()
    }
    func testActualSettingsWorkspaceAndTranscriptSelection() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: attribute) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-workspace-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"; store.openPreferences(.ai)
        _ = try await CodexModelCatalog.discover(settings: store.ai.settings)
        for width in [1050, 1400] {
            for backend in AIBackend.allCases {
                store.ai.settings = AISettings(); store.ai.settings.backend = backend
                let host = NSHostingView(rootView: MainView().environmentObject(store)); host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                try await settle(host); try snapshot(host, path: "/tmp/axon-ai-ui/settings-\(backend.rawValue)-\(width).png")
                let provider = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "axon-ai-provider" })
                provider.scrollToVisible(provider.bounds); try await settle(host); provider.performClick(nil); try await settle(host)
                let popover = try XCTUnwrap(AxonMenuPopover.active)
                XCTAssertEqual(popover.menu.items.count, 3)
                XCTAssertEqual(popover.menu.items.first { $0.state == .on }?.title, backend.title)
                XCTAssertTrue(popover.handleKey(53))
                if backend == .codex {
                    for identifier in ["axon-ai-codex-model", "axon-ai-codex-effort", "axon-ai-codex-speed"] {
                        let button = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == identifier })
                        button.scrollToVisible(button.bounds); try await settle(host); button.performClick(nil); try await settle(host)
                        let choices = try XCTUnwrap(AxonMenuPopover.active)
                        XCTAssertEqual(choices.menu.items.filter { $0.state == .on }.count, 1)
                        try snapshot(try XCTUnwrap(choices.popover.contentViewController?.view), path: "/tmp/axon-ai-ui/\(identifier)-\(width).png")
                        XCTAssertTrue(choices.handleKey(125)); XCTAssertTrue(choices.handleKey(36)); try await settle(host)
                    }
                    try await Task.sleep(for: .milliseconds(450))
                    XCTAssertEqual(store.ai.settings.codexReasoningEffort, "low")
                    XCTAssertEqual(store.ai.settings.codexServiceTier, "default")
                    let persisted = AIAssistant(fileURL: root.appendingPathComponent("ai-settings.json"))
                    XCTAssertEqual(persisted.settings.codexReasoningEffort, "low")
                    try snapshot(host, path: "/tmp/axon-ai-ui/configured-codex-\(width).png")
                    let modelButton = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "axon-ai-codex-model" })
                    modelButton.scrollToVisible(modelButton.bounds); try await settle(host); modelButton.performClick(nil); try await settle(host)
                    let modelMenu = try XCTUnwrap(AxonMenuPopover.active)
                    XCTAssertTrue(modelMenu.handleKey(126)); XCTAssertTrue(modelMenu.handleKey(36)); try await settle(host)
                    try await Task.sleep(for: .milliseconds(450)); try await settle(host)
                    XCTAssertEqual(store.ai.settings.codexModel, "")
                    XCTAssertNil(store.ai.settings.codexReasoningEffort); XCTAssertNil(store.ai.settings.codexServiceTier)
                }
                window.close()
            }
        }
        let view = AITranscriptTextView(); view.string = "error: connection refused"; view.setSelectedRange(NSRange(location: 7, length: 10))
        var selected = ""; view.analyze = { selected = $0 }; view.analyzeSelectedText(); XCTAssertEqual(selected, "connection")
        XCTAssertEqual(SnippetInput.normalized("ss -lntp\n"), "ss -lntp")
        XCTAssertFalse(try SnippetInput.bytes("ss -lntp", action: .insert, bracketedPaste: false).contains(13))
        XCTAssertThrowsError(try SnippetInput.bytes("one\ntwo", action: .insert, bracketedPaste: false))
    }
    private func read(_ object: NSObject, _ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
    private func accessible(_ view: NSView) -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }; result.append(object)
            for child in read(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
        }
        visit(view); if let window = view.window { visit(window) }; return result
    }
    private func settle(_ view: NSView) async throws { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(250)); view.layoutSubtreeIfNeeded() }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func snapshot(_ view: NSView, path: String) throws { let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), path + " bounds=" + NSStringFromRect(view.bounds)); view.cacheDisplay(in: view.bounds, to: rep); try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path)) }
}
