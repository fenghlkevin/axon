import Foundation

extension AICommandExecutor {
    var contextEndpoint: String { source + (hostID.map { "|host:" + $0.uuidString } ?? "") }
}

/// Use Git's own tracked/untracked enumeration, including info/exclude and global excludes.
struct AIGitContext {
    let root: String
    private let paths: Set<String>
    private let directories: Set<String>
    init?(root: String) throws {
        func run(_ args: [String]) throws -> (Int32, Data) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", root] + args
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard data.count <= 8 * 1024 * 1024 else { throw AppFailure.message("Git file list is too large / Git 文件列表超过限额") }
            return (process.terminationStatus, data)
        }
        let (status, directory) = try run(["rev-parse", "--show-toplevel"])
        guard status == 0 else { return nil }
        self.root = String(decoding: directory, as: UTF8.self).trimmingCharacters(in: .newlines)
        let (code, data) = try run(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--full-name"])
        guard code == 0 else { throw AppFailure.message("Git exclusions are unavailable / 无法核对 Git 排除规则") }
        let repositoryRoot = self.root
        paths = Set(data.split(separator: 0).map { (repositoryRoot as NSString).appendingPathComponent(String(decoding: $0, as: UTF8.self)) })
        var parents = Set<String>()
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while parent.hasPrefix(self.root), parent != self.root { parents.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        directories = parents
    }
    func excluded(_ path: String) -> Bool { path != root && !paths.contains(path) && !directories.contains(path) }
}

enum AIContextAccess {
    @MainActor static func allowed(_ path: String, root: String, backend: any FileEndpoint, executor: AICommandExecutor, policy: AIExecutionPolicy) async throws -> Bool {
        guard try TerminalDirectoryBridge.normalizedPath(path) == path, try TerminalDirectoryBridge.normalizedPath(root) == root,
              path == root || path.hasPrefix(root + "/"), !AIAutomaticContext.sensitive(path),
              AISkills.permitted(path, tool: "read_file", executor: executor, policy: policy),
              try await AISkills.safe(path, backend: backend),
              let inherited = try await AIProjectIgnore.inherited(root: root, backend: backend, executor: executor, policy: policy) else { return false }
        if backend is LocalFiles, let git = try AIGitContext(root: root), git.excluded(path) { return false }
        let leafDirectory = try await backend.stat(path).directory
        var rules = inherited.rules, directory = root, budget = 65536 - inherited.bytes
        let components = String(path.dropFirst(root.count)).split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            guard !AIAutomaticContext.excludedDirectories.contains(component),
                  AISkills.permitted(directory, tool: "list_directory", executor: executor, policy: policy) else { return false }
            let entries = try await backend.list(directory)
            guard let loaded = try await AIProjectIgnore.load(directory: directory, entries: entries, backend: backend, executor: executor, policy: policy, budget: budget) else { return false }
            budget -= loaded.bytes; rules += loaded.rules
            directory = try remoteJoin(directory, component)
            if AIProjectIgnore.ignored(directory, directory: index < components.count - 1 || leafDirectory, rules: rules) { return false }
        }
        try executor.check(); return true
    }
}
