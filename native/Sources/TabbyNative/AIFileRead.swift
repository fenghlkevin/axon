import Foundation

extension AICommandExecutor {
    /// File inspection uses the pinned endpoint, without starting a second shell.
    func readFileAction(_ action: AIAgentAction, currentTerminal: Bool, policy: AIExecutionPolicy = AIExecutionPolicy()) async throws -> AICommandResult {
        try check()
        guard let open = fileBackend, let raw = action.argument, !raw.isEmpty else { throw AppFailure.message("File operations unavailable / 文件操作不可用") }
        let path: String
        if raw.hasPrefix("/") { path = try TerminalDirectoryBridge.normalizedPath(raw) }
        else {
            guard let base = currentTerminal ? terminalBridge?.session?.currentDirectory : directory else { throw AppFailure.message("Current directory unknown; use an absolute path. / 当前目录未知，请使用绝对路径。") }
            path = try TerminalDirectoryBridge.normalizedPath((base as NSString).appendingPathComponent(raw))
        }
        let backend = try await open()
        do {
            guard try await AIContextAccess.allowed(path, root: (path as NSString).deletingLastPathComponent, backend: backend, executor: self, policy: policy) else { throw AppFailure.message("File is excluded by project rules / 文件被项目规则排除") }
            let output: String
            if action.tool == "list_directory" {
                let entries = try await backend.list(path)
                output = (entries.isEmpty ? "[Directory is empty]\n" : "") + entries.prefix(500).map { ($0.directory ? "directory " : "file ") + $0.name }.joined(separator: "\n") + (entries.count > 500 ? "\n[List truncated]" : "")
            } else {
                let entry = try await backend.stat(path)
                guard !entry.directory, !entry.symlink else { throw AppFailure.message("Read a plain file, not a directory or symlink. / 请读取普通文件，不能读取目录或符号链接。") }
                let bytes = try await backend.read(path, offset: 0, count: 65537)
                let after = try await backend.stat(path)
                guard !after.symlink, FileContentDigest.sameMetadata(entry, after) else { throw AppFailure.message("File changed during read / 读取期间文件已变化") }
                guard !bytes.contains(0), let text = String(data: bytes.prefix(65536), encoding: .utf8) else { throw AppFailure.message("File is not UTF-8 text / 文件不是 UTF-8 文本") }
                let lines = text.components(separatedBy: "\n")
                let truncated = bytes.count > 65536 || (action.tool == "read_file" && lines.count > 120)
                output = (action.tool == "read_file" ? lines.prefix(120).joined(separator: "\n") : text) + (truncated ? "\n[File truncated; omitted content is unknown]" : "")
            }
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            try check()
            return AICommandResult(output: AIContext.sanitize(output), exitCode: 0)
        } catch {
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            throw error
        }
    }
}
