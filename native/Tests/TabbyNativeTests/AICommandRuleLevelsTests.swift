import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AICommandRuleLevelsTests: XCTestCase {
    func testMergePriorityMigrationPersistenceAndLiveServerRules() throws {
        var system = AIExecutionPolicy(); system.commandBlacklist = "rm .*"; system.commandWhitelist = "printf global"
        var host = TabbyNative.Host(); host.name = "long-production-server-name"; host.address = "fixture.invalid"; host.aiCommandWhitelist = "rm .*\nprintf server"; host.aiCommandBlacklist = "printf global"
        let policy = system.mergingCommandLists(host)
        func decision(_ policy: AIExecutionPolicy, _ command: String) -> AIExecutionPolicy.Decision { policy.decision(target: "fixture", tool: "command", argument: command, automatic: false) }
        XCTAssertEqual(decision(policy, "rm file"), .deny)
        XCTAssertEqual(decision(policy, "printf global"), .deny)
        XCTAssertEqual(decision(policy, "printf server"), .allow)
        XCTAssertEqual(decision(system, "printf server"), .ask)
        var every = policy; every.approvalMode = .everyTime; XCTAssertEqual(decision(every, "printf server"), .ask)
        var full = policy; full.approvalMode = .fullAccess; XCTAssertEqual(decision(full, "rm file"), .deny)
        XCTAssertEqual(try JSONDecoder().decode(TabbyNative.Host.self, from: JSONEncoder().encode(host)), host)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as! [String: Any]; legacy.removeValue(forKey: "aiCommandBlacklist"); legacy.removeValue(forKey: "aiCommandWhitelist")
        let old = try JSONDecoder().decode(TabbyNative.Host.self, from: JSONSerialization.data(withJSONObject: legacy)); XCTAssertNil(old.aiCommandBlacklist); XCTAssertEqual(system.mergingCommandLists(old).commandBlacklist?.trimmingCharacters(in: .whitespacesAndNewlines), "rm .*")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.hosts = [host]; store.save()
        let reopened = AppStore(fileURL: root.appendingPathComponent("workspace.json")); XCTAssertEqual(reopened.workspace.hosts.first?.aiCommandBlacklist, "printf global")
        let session = TerminalSession(host: host, store: store), executor = AICommandExecutor(session: session)
        XCTAssertEqual(decision(executor.effectivePolicy(system), "printf server"), .allow)
        store.workspace.hosts[0].aiCommandBlacklist = "printf server"
        XCTAssertEqual(decision(executor.effectivePolicy(system), "printf server"), .deny)
        host.aiCommandBlacklist = "["; XCTAssertThrowsError(try system.mergingCommandLists(host).validate())
        XCTAssertThrowsError(try store.upsert(host, secret: ""))
    }
    func testServerRulesApplyToInitialAndRequestedCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        var host = TabbyNative.Host(); host.aiCommandBlacklist = "printf blocked"
        var round = 0, commands: [String] = []
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { prompt, _, update in
            round += 1
            let value = round == 1 ? "```axon_action\n{\"tool\":\"command\",\"argument\":\"printf blocked\",\"reason\":\"fixture\"}\n```" : "Blocked by server policy."
            if round == 2 { XCTAssertTrue(prompt.contains("denied")) }; update(value); return round == 1 ? try p0FixtureReply(value, goal: String(prompt.components(separatedBy: "Goal: ").last?.components(separatedBy: "\n").first ?? "")) : value
        })
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: nil, valid: { true }, execute: { command, _ in commands.append(command); return AICommandResult(output: "Linux\n/tmp", exitCode: 0) })
        executor.serverRuleHost = { host }
        ai.question = "fixture"; ai.send(executor: executor)
        for _ in 0..<200 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ai.busy); XCTAssertEqual(commands, ["uname -s; pwd"]); XCTAssertTrue(ai.error.isEmpty, ai.error)
        host.aiCommandBlacklist = nil; round = 0; ai.question = "approval fixture"; ai.send(executor: executor)
        for _ in 0..<200 where ai.pendingApproval == nil && ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(ai.pendingApproval)
        host.aiCommandBlacklist = "printf blocked"; ai.approveAction()
        for _ in 0..<200 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(commands, ["uname -s; pwd", "uname -s; pwd"])
        host.aiCommandBlacklist = "uname .*"; ai.question = "fixture again"; ai.send(executor: executor)
        for _ in 0..<200 where ai.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(commands.count, 2); XCTAssertFalse(ai.error.isEmpty)
    }
    func testHostRuleUIEditingAndDisclosure() async throws {
        _ = NSApplication.shared
        let attr = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"), previous = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: attr); defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attr) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let state = Fixture(); state.host.name = "production-server-with-a-very-long-name"; state.host.address = "fixture.invalid"; state.host.aiCommandBlacklist = "rm .*"; state.host.aiCommandWhitelist = "printf server\nls .*"
        try FileManager.default.createDirectory(atPath: "/tmp/axon-0155-ui", withIntermediateDirectories: true)
        for width in [380, 640] {
            let host = NSHostingView(rootView: RulesFixture(state: state).environmentObject(store).frame(width: CGFloat(width),height: 430))
            let window = NSWindow(contentRect: NSRect(x:0,y:0,width:width,height:430),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded(); try snapshot(host, "/tmp/axon-0155-ui/server-\(width).png")
            let editors = descendants(host).compactMap { $0 as? NSTextView }; XCTAssertEqual(editors.count, 2)
            let editor = try XCTUnwrap(editors.first { $0.string == "rm .*" }); editor.string = "rm .*\nsudo .*"; editor.didChangeText(); try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(state.host.aiCommandBlacklist, "rm .*\nsudo .*")
            state.host.aiCommandBlacklist = "rm .*"; window.close()
        }
        for width in [380, 640] {
            let host = NSHostingView(rootView: HostEditor(host: state.host, isNew: false, done: {}).environmentObject(store).frame(width:CGFloat(width),height:800).foregroundStyle(Palette.text).background(Palette.sidebar).colorScheme(.light))
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:800),styleMask:[.titled],backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
            let disclosure = try XCTUnwrap(accessible(host).first { $0.responds(to:NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey:"accessibilityIdentifier") as? String == "axon-host-ai-rules" })
            let selector = NSSelectorFromString("accessibilityPerformPress"); typealias Press = @convention(c) (AnyObject,Selector)->Bool
            XCTAssertTrue(unsafeBitCast(disclosure.method(for:selector),to:Press.self)(disclosure,selector))
            try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
            if let document = scroll.documentView { document.scroll(NSPoint(x:0,y:document.isFlipped ? document.bounds.height : 0)) }
            try snapshot(host, "/tmp/axon-0155-ui/host-editor-\(width).png"); window.close()
        }
    }
    private final class Fixture: ObservableObject { @Published var host = TabbyNative.Host() }
    private struct RulesFixture: View { @ObservedObject var state: Fixture; var body: some View { AIHostCommandRules(host: $state.host).padding(18).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).foregroundStyle(Palette.text).background(Palette.sidebar).colorScheme(.light) } }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func accessible(_ view: NSView) -> [NSObject] { var result:[NSObject]=[], seen=Set<ObjectIdentifier>(); func visit(_ obj:NSObject) { guard seen.insert(ObjectIdentifier(obj)).inserted else { return }; result.append(obj); if obj.responds(to:NSSelectorFromString("accessibilityChildren")) { for child in obj.value(forKey:"accessibilityChildren") as? [NSObject] ?? [] { visit(child) } }; if let v=obj as? NSView { for child in v.subviews { visit(child) } } };visit(view);return result }
    private func snapshot(_ view:NSView,_ path:String) throws { let rep=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path)) }
}
