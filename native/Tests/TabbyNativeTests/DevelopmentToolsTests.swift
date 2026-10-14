import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

private actor DevelopmentFaultFiles: FileEndpoint {
    let files = LocalFiles()
    let failurePath: String
    var failed = false
    var staged = Set<String>()
    let afterRename: Bool
    init(failurePath: String, afterRename: Bool = false) { self.failurePath = failurePath; self.afterRename = afterRename }
    func list(_ path: String) async throws -> [FileEntry] { try await files.list(path) }
    func stat(_ path: String) async throws -> FileEntry { try await files.stat(path) }
    func mkdir(_ path: String) async throws { try await files.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws {
        if from.contains(".tabby-"), to == failurePath, !failed { failed = true; if afterRename { try await files.rename(from, to) }; throw AppFailure.message("injected commit failure") }
        try await files.rename(from, to)
    }
    func delete(_ entry: FileEntry) async throws { try await files.delete(entry) }
    func chmod(_ path: String, _ mode: UInt32) async throws { try await files.chmod(path, mode) }
    func read(_ path: String, offset: UInt64, count: Int) async throws -> Data { try await files.read(path, offset: offset, count: count) }
    func write(_ path: String, offset: UInt64, bytes: Data) async throws { if path.contains(".tabby-") { staged.insert(path) }; try await files.write(path, offset: offset, bytes: bytes) }
    func removeStagingFile(_ entry: FileEntry) async throws { try await files.removeStagingFile(entry) }
}

@MainActor final class DevelopmentToolsTests: XCTestCase {
    private func root() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("axon-dev-test-" + UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
    private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
    func testHunkSelectionManualEditsAndSecretPreview() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let file = dir.appendingPathComponent("settings.txt")
        try write("one\noldA\nkeep\noldB\nend\n", file)
        let proposal = try await AIFileProposal(backend: LocalFiles(), path: file.path, find: "oldA\nkeep\noldB", replacement: "newA\nkeep\nnewB")
        let review = try AIChangeReview(proposals: [proposal]); XCTAssertEqual(review.files[0].hunks.count, 2)
        review.files[0].hunks[0].edited = "humanA"; review.files[0].hunks[1].selected = false; review.files[0].hunks[1].comment = "keep this unchanged"
        XCTAssertTrue(review.feedback.contains(":4")); try review.update([proposal]); XCTAssertEqual(try proposal.reviewedText(), "one\nhumanA\nkeep\noldB\nend\n")
        _ = try await proposal.apply(); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\nhumanA\nkeep\noldB\nend\n")
        XCTAssertEqual(try String(contentsOfFile: proposal.edit.backupPath, encoding: .utf8), "one\noldA\nkeep\noldB\nend\n")
        review.files[0].hunks[0].selected = false; XCTAssertFalse(review.valid)
    }
    func testGroupStagesAllFilesAndRollsBackOnSecondCommit() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try write("old-a", a); try write("old-b", b); let backend = DevelopmentFaultFiles(failurePath: b.path)
        let edit = try await AIProjectEdit(backend: backend, changes: [.init(path: a.path, find: "old-a", replacement: "new-a"), .init(path: b.path, find: "old-b", replacement: "new-b")])
        do { _ = try await edit.apply(); XCTFail("Expected failure") } catch { XCTAssertTrue(error.localizedDescription.contains("originals restored"), error.localizedDescription) }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "old-a"); XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "old-b")
        let stagedCount = await backend.staged.count; XCTAssertEqual(stagedCount, 2); XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".tabby-") || $0.contains(".backup-") })
    }
    func testRollbackPreservesConcurrentEditsAndBackup() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try write("old-a", a); try write("old-b", b)
        let edit = try await AIProjectEdit(backend: LocalFiles(), changes: [.init(path: a.path, find: "old-a", replacement: "new-a"), .init(path: b.path, find: "old-b", replacement: "new-b")])
        var visits = 0
        do { _ = try await edit.apply { path in visits += 1; if path == b.path, visits == 4 { try self.write("human concurrent", a); throw AppFailure.message("permission changed") } }; XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ROLLBACK INCOMPLETE")) }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "human concurrent"); XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "old-b")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("a.backup-") }); XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backup), encoding: .utf8), "old-a")
    }
    func testRollbackReconcilesRenameSucceededThenTransportFailed() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try write("old-a", a); try write("old-b", b); let backend = DevelopmentFaultFiles(failurePath: b.path, afterRename: true)
        let edit = try await AIProjectEdit(backend: backend, changes: [.init(path: a.path, find: "old-a", replacement: "new-a"), .init(path: b.path, find: "old-b", replacement: "new-b")])
        do { _ = try await edit.apply(); XCTFail("Expected failure") } catch { XCTAssertTrue(error.localizedDescription.contains("originals restored"), error.localizedDescription) }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "old-a"); XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "old-b")
    }
    func testCancelledCommitStillRollsBack() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try write("old-a", a); try write("old-b", b)
        let edit = try await AIProjectEdit(backend: LocalFiles(), changes: [.init(path: a.path, find: "old-a", replacement: "new-a"), .init(path: b.path, find: "old-b", replacement: "new-b")])
        let operation = Task { @MainActor in
            var visits = 0
            do { _ = try await edit.apply { _ in visits += 1; if visits == 4 { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() } }; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error.localizedDescription.contains("originals restored"), error.localizedDescription) }
        }
        await operation.value
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "old-a"); XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "old-b")
    }
    func testRevisionFeedbackReturnsToModelWithoutWrites() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let file = dir.appendingPathComponent("settings")
        try write("old", file); var prompts: [String] = []
        let action = AIAgentAction(tool: "replace_file", argument: nil, reason: "edit", path: file.path, find: "old", replacement: "new")
        let ai = AIAssistant(fileURL: dir.appendingPathComponent("ai.json"), modelResponder: { prompt, _, _ in prompts.append(prompt); return try AIStructuredReply(answer: "", action: prompts.count == 1 ? action : .init(tool: "report_blocker", argument: "Review request received", reason: "pause", path: nil, find: nil, replacement: nil), checks: [.init(goal: "change config", tool: "read_file", argument: file.path, expectedOutput: "new")]).serialized() })
        let executor = AICommandExecutor(sessionID: UUID(), source: "fixture", directory: dir.path, valid: { true }, execute: { _, _ in .init(output: "Darwin\n" + dir.path, exitCode: 0) }); executor.fileBackend = { LocalFiles() }
        ai.question = "change config"; ai.send(executor: executor); try await wait { ai.changeReview != nil && ai.pendingApproval != nil }
        ai.reviseReviewedChanges(file.path + ":1: keep old until verified")
        try await wait { !ai.busy }; XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old"); XCTAssertTrue(try XCTUnwrap(prompts.last).contains("keep old until verified")); XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".backup-") })
    }
    func testBackupRestorePreservesSelectedAndCurrentCopies() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let original = dir.appendingPathComponent("config"), backup = dir.appendingPathComponent("config.backup-" + UUID().uuidString)
        try write("new", original); try write("old", backup); let backend = LocalFiles()
        let review = FileBackupReview(backup: try await backend.stat(backup.path), backend: backend); await review.load(); XCTAssertTrue(review.ready, review.error); let restored = await review.restore(); XCTAssertTrue(restored, review.error)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "old"); XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
        let other = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("config.backup-") && $0 != backup.lastPathComponent }); XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(other), encoding: .utf8), "new")
    }
    func testGitPathsStageBranchesAndWorktreeOwnership() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let repo = dir.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws { let result = try await DevelopmentProcess.run("/usr/bin/git", GitWorkspace.options + args, directory: repo.path); XCTAssertEqual(result.exitCode, 0, result.output) }
        try await git(["init", "-b", "main"]); try write("old\n", repo.appendingPathComponent("file with space.txt")); try await git(["add", "--", "."]); try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "initial"]); try await git(["branch", "other"])
        let registry = dir.appendingPathComponent("owned.json"); let workspace = GitWorkspace(directory: repo.path, registry: registry); try await workspace.refresh(); XCTAssertEqual(workspace.branch, "main")
        try write("new\n", repo.appendingPathComponent("file with space.txt")); try await workspace.refresh(); let change = try XCTUnwrap(workspace.changes.first)
        try await workspace.showDiff(change, staged: false); XCTAssertTrue(workspace.diff.contains("+new")); try await workspace.stage(change); XCTAssertEqual(workspace.changes.first?.status, "M ")
        try await workspace.stage(try XCTUnwrap(workspace.changes.first), undo: true); XCTAssertEqual(workspace.changes.first?.status, " M")
        do { try await workspace.switchBranch("other"); XCTFail("Dirty switch allowed") } catch { }
        let checkout = dir.appendingPathComponent("isolated"); try await workspace.createWorktree(path: checkout.path, branch: "codex/test"); let physical = try GitWorkspace.physical(checkout.path); let worktree = try XCTUnwrap(workspace.worktrees.first { $0.path == physical }); XCTAssertTrue(workspace.owns(worktree))
        try write("untracked", checkout.appendingPathComponent("new file")); do { try await workspace.removeWorktree(worktree); XCTFail("Dirty worktree removed") } catch { }
        try FileManager.default.removeItem(at: checkout.appendingPathComponent("new file")); try await workspace.removeWorktree(worktree); XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.path)); XCTAssertTrue(workspace.branches.contains("codex/test"))
        try write("old\n", repo.appendingPathComponent("file with space.txt")); try await workspace.switchBranch("other"); XCTAssertEqual(workspace.branch, "other")
        XCTAssertThrowsError(try GitWorkspace.relative("../outside")); XCTAssertThrowsError(try GitWorkspace.relative(".git/config"))
        let renamed = try GitWorkspace.status("R  new name\0old name\0"); XCTAssertEqual(renamed.first?.oldPath, "old name")
    }
    func testLSPFramingUTF16AndInvalidEdits() throws {
        var decoder = LSPFrameDecoder(); let bytes = try LSPFrameDecoder.encode(["jsonrpc":"2.0", "result":"中文😀", "id":1])
        XCTAssertTrue(try decoder.append(bytes.prefix(12)).isEmpty); XCTAssertEqual(try decoder.append(bytes.dropFirst(12)).first?["result"] as? String, "中文😀")
        let span = EditorLanguageService.Span(start: .init(line: 0, character: 2), end: .init(line: 0, character: 3))
        XCTAssertEqual(try EditorLanguageService.apply([.init(range: span, newText: "Y")], text: "😀x\n"), "😀Y\n")
        XCTAssertThrowsError(try EditorLanguageService.range(.init(start: .init(line: 0, character: 1), end: .init(line: 0, character: 2)), text: "😀x"))
        XCTAssertThrowsError(try EditorLanguageService.apply([.init(range: span, newText: "a"), .init(range: span, newText: "b")], text: "😀x"))
        let second = EditorLanguageService.Span(start: .init(line: 1, character: 0), end: .init(line: 1, character: 1))
        XCTAssertEqual(try EditorLanguageService.apply([.init(range: second, newText: "Y")], text: "a\r\nb"), "a\r\nY"); XCTAssertEqual(try EditorLanguageService.apply([.init(range: second, newText: "Y")], text: "a\rb"), "a\rY")
        var bad = LSPFrameDecoder(); XCTAssertThrowsError(try bad.append(Data("Content-Length: 9000000\r\n\r\n".utf8)))
        XCTAssertTrue(GitDiffReview.reference("@@ -4,2 +8,2 @@\n-old\n+new", line: 2).contains("original line 4")); XCTAssertTrue(GitDiffReview.reference("@@ -4,2 +8,2 @@\n-old\n+new", line: 3).contains("proposed line 8"))
    }
    func testLanguageServerDiagnosticsSymbolsAndFormatting() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let script = dir.appendingPathComponent("server.py"); try write(Self.server, script)
        let service = EditorLanguageService(); defer { service.stop() }
        let text = "😀x\n"; try await service.start(executable: "/usr/bin/python3", arguments: [script.path], path: dir.appendingPathComponent("test.txt").path, text: text, language: "plaintext")
        XCTAssertTrue(service.ready); XCTAssertTrue(service.formatting); XCTAssertEqual(service.symbols.first?.name, "fixtureSymbol"); try await wait { !service.diagnostics.isEmpty }; XCTAssertEqual(service.diagnostics.first?.range.start.character, 0)
        let formatted = try await service.format(text); XCTAssertEqual(formatted, "😀Y\n"); try await service.synchronize("😀z\n"); XCTAssertEqual(service.version, 2); try await service.refreshSymbols(); XCTAssertTrue(service.ready)
    }
    func testInstalledSourceKitLanguageServer() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let found = try await DevelopmentProcess.run("/usr/bin/xcrun", ["--find", "sourcekit-lsp"], directory: dir.path)
        guard found.exitCode == 0 else { throw XCTSkip("No installed SourceKit-LSP") }
        let path = dir.appendingPathComponent("fixture.swift"), text = "func fixtureFunction() -> Int { return 1 }\n"; try write(text, path)
        let service = EditorLanguageService(); defer { service.stop() }
        try await service.start(executable: found.output.trimmingCharacters(in: .newlines), arguments: [], path: path.path, text: text, language: "swift")
        XCTAssertTrue(service.ready); XCTAssertTrue(service.symbols.contains { $0.name.contains("fixtureFunction") }, String(describing: service.symbols))
        if service.formatting { let formatted = try await service.format(text); XCTAssertTrue(formatted.contains("fixtureFunction")) }
    }
    func testLanguageFormattingRejectsStaleResultsAndCancelsOnlyRequest() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let script = dir.appendingPathComponent("server.py")
        let delayed = Self.server.replacingOccurrences(of: "import json,sys", with: "import json,sys,time").replacingOccurrences(of: "elif method=='textDocument/formatting':result=", with: "elif method=='textDocument/formatting':time.sleep(.25);result=")
        try write(delayed, script); let service = EditorLanguageService(); defer { service.stop() }
        try await service.start(executable: "/usr/bin/python3", arguments: [script.path], path: dir.appendingPathComponent("test.txt").path, text: "😀x\n", language: "plaintext")
        let stale = Task { try await service.format("😀x\n") }; try await Task.sleep(for: .milliseconds(80)); try await service.synchronize("😀z\n")
        do { _ = try await stale.value; XCTFail("Stale result applied") } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertTrue(service.ready)
        let cancelled = Task { try await service.format("😀z\n") }; try await Task.sleep(for: .milliseconds(80)); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled result applied") } catch { XCTAssertTrue(error is CancellationError) }
        try await service.refreshSymbols(); XCTAssertTrue(service.ready); XCTAssertFalse(service.symbols.isEmpty)
    }
    func testProposalRejectsMetadataChangeAndProjectSessionsShareOnlySameJournal() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }; let file = dir.appendingPathComponent("config")
        try write("old", file); let backend = LocalFiles(); let proposal = try await AIFileProposal(backend: backend, path: file.path, find: "old", replacement: "new")
        try await backend.chmod(file.path, 0o700)
        do { try await proposal.checkOriginal(); XCTFail("Changed permissions accepted") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
        let settings = dir.appendingPathComponent("ai.json"), a = dir.appendingPathComponent("task-a.json"), b = dir.appendingPathComponent("task-b.json")
        let first = LocalProjectAgentSessions.session(settingsURL: settings, journal: a), other = LocalProjectAgentSessions.session(settingsURL: settings, journal: b)
        XCTAssertTrue(first === LocalProjectAgentSessions.session(settingsURL: settings, journal: a)); XCTAssertFalse(first === other); XCTAssertNotEqual(first.id, other.id)
    }
    private func wait(_ predicate: () -> Bool) async throws { for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTFail("Timed out") }
    static let server = #"""
import json,sys
inp=sys.stdin.buffer;out=sys.stdout.buffer
span={"start":{"line":0,"character":0},"end":{"line":0,"character":2}}
def send(value):
    data=json.dumps(value,ensure_ascii=False).encode();out.write(('Content-Length: %d\r\n\r\n'%len(data)).encode()+data);out.flush()
while True:
    line=inp.readline()
    if not line:break
    length=int(line.split(b':')[1]);
    while inp.readline().strip():pass
    msg=json.loads(inp.read(length));method=msg.get('method');params=msg.get('params',{})
    if method=='initialize':result={'capabilities':{'textDocumentSync':2,'documentSymbolProvider':True,'documentFormattingProvider':True}}
    elif method=='textDocument/documentSymbol':result=[{'name':'fixtureSymbol','kind':12,'range':span,'selectionRange':span}]
    elif method=='textDocument/formatting':result=[{'range':{'start':{'line':0,'character':2},'end':{'line':0,'character':3}},'newText':'Y'}]
    elif method in ['textDocument/didOpen','textDocument/didChange']:
        doc=params['textDocument'];send({'jsonrpc':'2.0','method':'textDocument/publishDiagnostics','params':{'uri':doc['uri'],'version':doc['version'],'diagnostics':[{'range':span,'severity':2,'message':'fixture warning'}]}});continue
    else:continue
    send({'jsonrpc':'2.0','id':msg['id'],'result':result})
"""#
}
