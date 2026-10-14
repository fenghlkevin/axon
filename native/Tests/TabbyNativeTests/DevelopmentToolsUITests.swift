import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

@MainActor final class DevelopmentToolsUITests: XCTestCase {
    private func fixture() throws -> URL {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        try FileManager.default.createDirectory(atPath: "/tmp/axon-ed-ui", withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ed-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func window(_ view: AnyView, _ width: Int, _ height: Int) -> NSWindow {
        let host = NSHostingView(rootView: view.preferredColorScheme(.light)); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); return window
    }
    private func objects(_ view: NSView) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject) { guard seen.insert(ObjectIdentifier(object)).inserted else { return }; result.append(object); if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { children.forEach(visit) }; if let v = object as? NSView { v.subviews.forEach(visit) } }
        visit(view); return result
    }
    private func control(_ view: NSView, _ id: String) throws -> NSObject { try XCTUnwrap(objects(view).first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id }, id) }
    private func press(_ object: NSObject) throws {
        if let b = object as? NSButton { b.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress"); XCTAssertTrue(object.responds(to: selector)); typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
    private func press(_ view: NSView, _ id: String) throws { try press(control(view, id)) }
    private func snapshot(_ view: NSView, _ name: String) throws { view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap); try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-ed-ui/" + name + ".png")) }
    private func wait(_ predicate: () -> Bool) async throws { for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTFail("Timed out") }
    func testActualApprovalUsesHumanContentAndRechecksGoal() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }; let file = root.appendingPathComponent("settings.txt")
        try Data("one\noldA\nkeep\noldB\nend\n".utf8).write(to: file)
        let goal = "Set the first value to humanA and keep the second oldB"; var rounds = 0
        let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"), modelResponder: { _, _, _ in
            rounds += 1
            let action: AIAgentAction? = rounds == 1 ? .init(tool: "replace_file", argument: nil, reason: "edit", path: file.path, find: "oldA\nkeep\noldB", replacement: "newA\nkeep\nnewB") : rounds == 2 ? .init(tool: "read_file", argument: file.path, reason: "verify actual human content", path: nil, find: nil, replacement: nil) : nil
            return try AIStructuredReply(answer: rounds == 3 ? "Verified requested values" : "", action: action, checks: rounds == 1 ? [.init(goal: goal, tool: "read_file", argument: file.path, expectedOutput: "humanA\nkeep\noldB")] : nil).serialized()
        })
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: root.path, valid: { true }, execute: { command, _ in .init(output: command.contains("uname") ? "Darwin\n" + root.path : try String(contentsOf: file, encoding: .utf8), exitCode: 0) }); executor.fileBackend = { LocalFiles() }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        ai.question = goal; ai.send(executor: executor); try await wait { ai.pendingApproval != nil && ai.changeReview != nil }; let review = try XCTUnwrap(ai.changeReview)
        let w = window(AnyView(AIChangeReviewSheet(ai: ai, review: review, close: {}).environmentObject(store)), 740, 650); defer { w.close(); ai.cancel() }
        try await Task.sleep(for: .milliseconds(150)); try press(w.contentView!, "axon-diff-hunk-0-1")
        let editor = try XCTUnwrap(objects(w.contentView!).compactMap { $0 as? NSTextView }.first { $0.string == "newA" }); editor.string = "humanA"; editor.didChangeText()
        try await wait { review.files[0].hunks[0].edited == "humanA" }; try snapshot(w.contentView!, "review-ready-to-apply"); try press(w.contentView!, "axon-ai-apply-diff"); try await wait { !ai.busy }
        XCTAssertTrue(ai.error.isEmpty, ai.error); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\nhumanA\nkeep\noldB\nend\n"); let verification = try XCTUnwrap(ai.taskRecords.first?.verification); XCTAssertFalse(verification.pending); XCTAssertEqual(verification.passed, [0]); XCTAssertEqual(rounds, 3)
        XCTAssertEqual(ai.taskRecords.first?.recovery?.operations.first(where: { $0.tool == "replace_file" })?.files?.first?.after, AIFileCheckpoint.digest(Data("one\nhumanA\nkeep\noldB\nend\n".utf8)))
    }
    func testActualReviewSelectionAndEditorFormatSave() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let path = root.appendingPathComponent("config-with-long-name.txt"); try Data("first\noldA\nkeep\noldB\nend\n".utf8).write(to: path)
        let proposal = try await AIFileProposal(backend: LocalFiles(), path: path.path, find: "oldA\nkeep\noldB", replacement: "newA\nkeep\nnewB")
        let review = try AIChangeReview(proposals: [proposal]); let ai = AIAssistant(fileURL: root.appendingPathComponent("ai.json"))
        var closed = false; let w = window(AnyView(AIChangeReviewSheet(ai: ai, review: review) { closed = true }.environmentObject(store)), 740, 650); defer { w.close() }
        try await Task.sleep(for: .milliseconds(200)); try snapshot(w.contentView!, "review-selected")
        try press(w.contentView!, "axon-diff-hunk-0-1"); try await Task.sleep(for: .milliseconds(100)); XCTAssertFalse(review.files[0].hunks[1].selected)
        review.files[0].hunks[0].edited = "human edited"; review.files[0].hunks[0].comment = "检查这些行并保留兼容行为"; review.request = "先检查实际文件，再修订"; try await Task.sleep(for: .milliseconds(100)); try snapshot(w.contentView!, "review-comments")
        let apply = try control(w.contentView!, "axon-ai-apply-diff"); if apply.responds(to: NSSelectorFromString("accessibilityEnabled")) { XCTAssertEqual(apply.value(forKey: "accessibilityEnabled") as? Bool, false) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), proposal.originalText); XCTAssertFalse(closed)
        let script = root.appendingPathComponent("server.py"); try Data(DevelopmentToolsTests.server.utf8).write(to: script)
        let document = root.appendingPathComponent("unicode.txt"); try Data("😀x\n".utf8).write(to: document)
        let suite = "axon-ed-test-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/python3", forKey: "axon.editor.languageServer"); defaults.set("[\"" + script.path + "\"]", forKey: "axon.editor.languageServerArguments")
        let service = EditorLanguageService(); var saved = false
        let editor = window(AnyView(FileEditor(entry: try await LocalFiles().stat(document.path), backend: LocalFiles(), refresh: { saved = true }, languageDefaults: defaults, service: service).environmentObject(store)), 960, 700); defer { editor.close(); service.stop() }
        try await Task.sleep(for: .milliseconds(250)); try snapshot(editor.contentView!, "editor-disconnected"); try press(editor.contentView!, "axon-editor-language-connect"); try await wait { service.ready && !service.symbols.isEmpty }; try await Task.sleep(for: .milliseconds(100)); try snapshot(editor.contentView!, "editor-language")
        try press(editor.contentView!, "axon-editor-format"); try await Task.sleep(for: .milliseconds(250)); XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "😀x\n"); try snapshot(editor.contentView!, "editor-formatted-draft")
        try press(editor.contentView!, "axon-file-editor-save"); try await wait { saved }; XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "😀Y\n")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("unicode.txt.backup-") })
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "😀x\n")
        let restore = window(AnyView(FileBackupReviewSheet(backup: try await LocalFiles().stat(backup.path), backend: LocalFiles(), refresh: {}).environmentObject(store)), 680, 520); defer { restore.close() }
        try await Task.sleep(for: .milliseconds(250)); try snapshot(restore.contentView!, "backup-restore")
    }
    func testMainFileWorkspaceKeepsNavigationAtBothWidths() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("representative content".utf8).write(to: root.appendingPathComponent("config.txt"))
        let store = AppStore(fileURL: root.appendingPathComponent("state/workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); session.terminal = TerminalView(frame: .zero); session.connected = true
        store.sessions = [session]; store.activeSession = session.id; store.section = "sftp"
        store.terminalFileRequest = TerminalFileRequest(sessionID: session.id, host: nil, path: root.path, isSelection: false, generation: session.generation)
        let w = window(AnyView(MainView().environmentObject(store)), 1050, 900); defer { w.close() }
        for width in [1050, 1400] {
            w.setContentSize(NSSize(width: width, height: 900))
            try await Task.sleep(for: .milliseconds(350)); XCTAssertEqual(session.sceneFiles?.local.path, root.path); try snapshot(w.contentView!, "main-files-\(width)")
            XCTAssertEqual(store.sessions.first?.id, session.id); XCTAssertEqual(store.activeSession, session.id); XCTAssertEqual(store.section, "sftp")
        }
        store.monitoring.stop()
    }

    func testActualGitActionsMenusWorktreesAndFilePaneWidths() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }; let repo = root.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws { let result = try await DevelopmentProcess.run("/usr/bin/git", GitWorkspace.options + args, directory: repo.path); XCTAssertEqual(result.exitCode, 0, result.output) }
        try await git(["init", "-b", "main"]); let file = repo.appendingPathComponent("a-long-configuration-filename.txt"); try Data("old\n".utf8).write(to: file); try await git(["add", "."]); try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"]); try await git(["branch", "a-very-long-branch-name-used-for-layout-verification"]); try Data("new\n".utf8).write(to: file)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let registry = root.appendingPathComponent("worktrees.json"), workspace = GitWorkspace(directory: repo.path, registry: registry)
        let w = window(AnyView(GitWorkspaceSheet(directory: repo.path, registry: registry, workspace: workspace, openDirectory: { _ in }).environmentObject(store)), 960, 680); defer { w.close() }
        try await wait { !workspace.root.isEmpty && !workspace.busy }; try await Task.sleep(for: .milliseconds(100)); try press(w.contentView!, "axon-git-diff"); try await wait { !workspace.busy && workspace.diff.contains("+new") }; try snapshot(w.contentView!, "git-diff")
        try press(w.contentView!, "axon-git-line-7"); let field = try XCTUnwrap(objects(w.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "审查意见" }); field.stringValue = "请检查新增值是否兼容"; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field)); try await Task.sleep(for: .milliseconds(120)); try press(w.contentView!, "axon-git-add-comment"); try await Task.sleep(for: .milliseconds(120)); try snapshot(w.contentView!, "git-comment"); try press(w.contentView!, "axon-git-agent"); try await Task.sleep(for: .milliseconds(180)); let agentSheet = try XCTUnwrap(w.sheets.first); try snapshot(agentSheet.contentView!, "git-comment-agent"); XCTAssertTrue(objects(agentSheet.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string.contains("请检查新增值是否兼容") }); try press(agentSheet.contentView!, "axon-project-close"); try await wait { w.sheets.isEmpty }
        try press(w.contentView!, "axon-git-stage"); try await wait { !workspace.busy && workspace.changes.first?.status == "M " }; try snapshot(w.contentView!, "git-staged"); try press(w.contentView!, "axon-git-unstage"); try await wait { !workspace.busy && workspace.changes.first?.status == " M" }
        try press(w.contentView!, "axon-git-branch"); try await Task.sleep(for: .milliseconds(100)); if let popover = AxonMenuPopover.active { try snapshot(try XCTUnwrap(popover.popover.contentViewController?.view), "git-branch-menu"); _ = popover.handleKey(125); _ = popover.handleKey(36) }; try await Task.sleep(for: .milliseconds(100))
        let checkout = root.appendingPathComponent("isolated"); try await workspace.createWorktree(path: checkout.path, branch: "codex/ui"); try press(w.contentView!, "axon-git-view"); try await Task.sleep(for: .milliseconds(100)); if let popover = AxonMenuPopover.active { _ = popover.handleKey(125); _ = popover.handleKey(36) }; try await Task.sleep(for: .milliseconds(150)); try snapshot(w.contentView!, "worktrees")
        let project = LocalProjectAgentSheet(directory: checkout.path, settingsURL: store.ai.fileURL, feedback: "a-long-configuration-filename.txt:1: review this change")
        let projectWindow = window(AnyView(project.environmentObject(store)), 740, 740); defer { projectWindow.close() }; try await Task.sleep(for: .milliseconds(150)); try snapshot(projectWindow.contentView!, "independent-project-task")
        XCTAssertEqual(project.executor.directory, checkout.path); XCTAssertNoThrow(try project.executor.check())
        let otherProject = LocalProjectAgentSheet(directory: repo.path, settingsURL: store.ai.fileURL)
        XCTAssertNotEqual(project.executor.sessionID, otherProject.executor.sessionID)
        let actualDirectory = try await project.executor.execute("pwd", update: { _ in }); XCTAssertEqual(try GitWorkspace.physical(actualDirectory.output.trimmingCharacters(in: .newlines)), try GitWorkspace.physical(checkout.path))
        try press(projectWindow.contentView!, "axon-ai-settings"); try await Task.sleep(for: .milliseconds(200)); let settingsSheet = try XCTUnwrap(projectWindow.sheets.first); try snapshot(settingsSheet.contentView!, "project-ai-settings"); try press(settingsSheet.contentView!, "axon-project-settings-close"); try await wait { projectWindow.sheets.isEmpty }
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store)); _ = await model.local.navigate(repo.path); await model.selectLocal(path: checkout.path)
        for width in [1050, 1400] {
            let files = window(AnyView(FilesView(model: model).environmentObject(store)), width, 760); try await Task.sleep(for: .milliseconds(180)); try snapshot(files.contentView!, "files-\(width)")
            if width == 1050 {
                try press(files.contentView!, "axon-file-actions-local"); try await Task.sleep(for: .milliseconds(150))
                if let menu = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && objects($0.contentView!).contains(where: { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == "axon-file-development" }) }) { try snapshot(menu.contentView!, "file-actions-menu"); try press(menu.contentView!, "axon-file-development") }
                try await wait { !files.sheets.isEmpty }; let sheet = try XCTUnwrap(files.sheets.first); try await Task.sleep(for: .milliseconds(650)); try snapshot(sheet.contentView!, "file-development-route")
            }
            files.close()
        }
    }
}
