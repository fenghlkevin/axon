import Foundation
import Darwin
import SwiftUI

/// Executes argv directly; never interpolates Git paths into a shell.
enum DevelopmentProcess {
    static func run(_ executable: String, _ arguments: [String], directory: String, seconds: Double = 20) async throws -> AICommandResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axon-development-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output"); FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LANG", "LC_CTYPE", "TMPDIR"].contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        try process.run(); defer { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            try Task.checkCancellation()
            let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= 2 * 1024 * 1024, Date() < deadline else { throw AppFailure.message("Tool timed out or output exceeded 2 MB / 工具超时或输出超过 2 MB") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation(); let bytes = try Data(contentsOf: output); guard bytes.count <= 2 * 1024 * 1024 else { throw AIModelError.invalidReply }
        return .init(output: String(decoding: bytes, as: UTF8.self), exitCode: Int(process.terminationStatus))
    }
}

@MainActor final class GitWorkspace: ObservableObject {
    struct Change: Identifiable, Equatable { var id: String { path }; var path: String; var oldPath: String?; var status: String }
    struct Worktree: Identifiable, Equatable { var id: String { path }; var path: String; var branch: String; var locked: Bool }
    @Published private(set) var root = ""
    @Published private(set) var branch = ""
    @Published private(set) var branches: [String] = []
    @Published private(set) var changes: [Change] = []
    @Published private(set) var worktrees: [Worktree] = []
    @Published var diff = ""
    @Published var busy = false
    @Published var error = ""
    let directory: String
    private let registry: URL
    private var owned: [String: String] = [:] // checkout -> original repository's common directory
    private var common = ""
    init(directory: String, registry: URL) { self.directory = directory; self.registry = registry; if let data = try? Data(contentsOf: registry), data.count <= 65536, let values = try? JSONDecoder().decode([String: String].self, from: data) { owned = values } }
    static let options = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.pager=cat", "-c", "submodule.recurse=false"]
    func git(_ arguments: [String], at directory: String? = nil) async throws -> String {
        let result = try await DevelopmentProcess.run("/usr/bin/git", Self.options + arguments, directory: directory ?? (root.isEmpty ? self.directory : root))
        guard result.exitCode == 0 else { throw AppFailure.message(AIContext.sanitize(result.output)) }; return result.output
    }
    static func status(_ output: String) throws -> [Change] {
        let fields = output.components(separatedBy: "\0"); var result: [Change] = []; var i = 0
        while i < fields.count, !fields[i].isEmpty {
            let field = fields[i]; guard field.count >= 4 else { throw AIModelError.invalidReply }
            let status = String(field.prefix(2)), path = String(field.dropFirst(3)); try relative(path)
            var old: String?; i += 1
            if status.contains("R") || status.contains("C") { guard i < fields.count, !fields[i].isEmpty else { throw AIModelError.invalidReply }; old = fields[i]; try relative(old!); i += 1 }
            result.append(.init(path: path, oldPath: old, status: status)); guard result.count <= 2000 else { throw AppFailure.message("Too many Git changes / Git 修改过多，请缩小范围") }
        }
        return result
    }
    static func relative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.components(separatedBy: "/").contains(where: { ["..", ".git", "."].contains($0) }) else { throw AIModelError.invalidReply }
    }
    static func physical(_ path: String) throws -> String {
        guard let pointer = realpath(path, nil) else { throw AppFailure.message("Directory is unavailable / 目录不可用") }
        defer { free(pointer) }; return String(cString: pointer)
    }
    func refresh() async throws {
        if FileManager.default.fileExists(atPath: registry.path) {
            let data = try Data(contentsOf: registry); guard data.count <= 65536 else { throw AIModelError.invalidReply }; owned = try JSONDecoder().decode([String: String].self, from: data)
        }
        root = try await git(["rev-parse", "--show-toplevel"], at: directory).trimmingCharacters(in: .newlines)
        common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .newlines)
        branch = (try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"]).trimmingCharacters(in: .newlines)) ?? "detached"
        changes = try Self.status(try await git(["status", "--porcelain=v1", "-z", "--untracked-files=normal"]))
        branches = try await git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"]).split(separator: "\n").map(String.init)
        let data = try await git(["worktree", "list", "--porcelain", "-z"])
        worktrees = data.components(separatedBy: "\0\0").compactMap { block in
            let lines = block.components(separatedBy: "\0"); guard let path = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
            return .init(path: String(path.dropFirst(9)), branch: String(lines.first(where: { $0.hasPrefix("branch ") })?.dropFirst(7) ?? "detached"), locked: lines.contains { $0.hasPrefix("locked") || $0.hasPrefix("prunable") })
        }
    }
    func showDiff(_ change: Change, staged: Bool) async throws {
        guard changes.contains(change) else { throw AIModelError.invalidReply }
        if change.status == "??" {
            let path = (root as NSString).appendingPathComponent(change.path); let backend = LocalFiles(); let entry = try await backend.stat(path)
            guard !entry.symlink, !entry.directory, entry.size <= 65536 else { throw AppFailure.message("Choose a small plain text file / 请选择较小的普通文本文件") }
            let bytes = try await backend.read(path, offset: 0, count: 65537); guard bytes.count <= 65536, !bytes.contains(0), let value = String(data: bytes, encoding: .utf8) else { throw AIModelError.invalidReply }; diff = "+++ " + change.path + "\n" + AIContext.sanitize(value)
        } else { diff = AIContext.sanitize(try await git(["diff", "--no-ext-diff", "--no-textconv"] + (staged ? ["--cached"] : []) + ["--", change.path] + (change.oldPath.map { [$0] } ?? []))) }
    }
    func stage(_ change: Change, undo: Bool = false) async throws {
        try await refresh(); guard changes.contains(change) else { throw AppFailure.message("Git changed; refresh and select again / Git 已变化，请重新选择") }
        _ = try await git((undo ? ["reset", "--"] : ["add", "--"]) + [change.path] + (change.oldPath.map { [$0] } ?? [])); try await refresh()
    }
    func switchBranch(_ name: String) async throws {
        try await refresh(); guard changes.isEmpty, branches.contains(name), !name.hasPrefix("-") else { throw AppFailure.message("Switch only from a clean checkout to an existing branch / 请先处理当前修改，再切换已有分支") }
        _ = try await git(["switch", "--no-recurse-submodules", "--no-overwrite-ignore", name]); try await refresh()
    }
    func createWorktree(path: String, branch: String) async throws {
        try await refresh(); let normalized = try TerminalDirectoryBridge.normalizedPath(path)
        let destination = URL(fileURLWithPath: path)
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else { throw AppFailure.message("Choose an existing parent directory / 请选择已有的父目录") }
        let checkout = (try Self.physical(destination.deletingLastPathComponent().path) as NSString).appendingPathComponent(destination.lastPathComponent)
        guard normalized == path, !FileManager.default.fileExists(atPath: checkout), !branch.hasPrefix("-"), !branch.contains("\n"), owned.count < 100 else { throw AIModelError.invalidReply }
        _ = try await git(["check-ref-format", "--branch", branch])
        // Persist intent before creating, so an interrupted creation remains manageable.
        do { try persist(updating: checkout, value: common); _ = try await git(["worktree", "add", "-b", branch, checkout, "HEAD"]); try await refresh() }
        catch { if !FileManager.default.fileExists(atPath: checkout) { try? persist(removing: checkout) }; throw error }
    }
    func owns(_ worktree: Worktree) -> Bool { owned[worktree.path] == common && worktree.path != root && !worktree.locked }
    func removeWorktree(_ worktree: Worktree) async throws {
        try await refresh(); guard worktrees.contains(worktree), owns(worktree), try Self.status(try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"], at: worktree.path)).isEmpty else { throw AppFailure.message("Only an Axon-created clean checkout without ignored files can be removed / 只能移除 Axon 创建且无修改、无忽略文件的工作树") }
        _ = try await git(["worktree", "remove", "--", worktree.path]); try persist(removing: worktree.path); try await refresh()
    }
    private func persist(updating: String? = nil, value: String? = nil, removing: String? = nil) throws {
        var values: [String: String] = [:]
        if FileManager.default.fileExists(atPath: registry.path) {
            let data = try Data(contentsOf: registry); guard data.count <= 65536 else { throw AIModelError.invalidReply }; values = try JSONDecoder().decode([String: String].self, from: data)
        }
        if let updating, let value { values[updating] = value }; if let removing { values.removeValue(forKey: removing) }
        guard values.count <= 100 else { throw AIModelError.invalidReply }
        try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try JSONEncoder().encode(values).write(to: registry, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path); owned = values
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = ""
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
