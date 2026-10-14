import Foundation

struct AIProjectReadRequest: Decodable {
    let path: String
    let query: String?
    let startLine: Int?
    let endLine: Int?
    static func decode(_ value: String, search: Bool) throws -> Self {
        let data = Data(value.utf8)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == (search ? Set(["path", "query"]) : Set(["path", "startLine", "endLine"])) else { throw AIModelError.invalidReply }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.path.hasPrefix("/"), request.path.utf8.count <= 4096,
              !request.path.contains("[REDACTED]"), !request.path.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw AIModelError.invalidReply }
        guard try TerminalDirectoryBridge.normalizedPath(request.path) == request.path else { throw AIModelError.invalidReply }
        if search {
            guard let query = request.query, query.count >= 3, query.utf8.count <= 512,
                  request.startLine == nil, request.endLine == nil,
                  !query.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw AIModelError.invalidReply }
        } else {
            guard request.query == nil, let start = request.startLine, let end = request.endLine,
                  start >= 1, end >= start, end - start < 200, end <= 100000 else { throw AIModelError.invalidReply }
        }
        return request
    }
}

extension AICommandExecutor {
    func readProjectAction(_ action: AIAgentAction, policy: AIExecutionPolicy) async throws -> AICommandResult {
        let search = ["search_files", "search_text"].contains(action.tool)
        let textRequest = action.tool == "search_text" ? try AITextSearchRequest.decode(action.argument ?? "") : nil
        let request = try textRequest.map { AIProjectReadRequest(path: $0.path, query: $0.query, startLine: nil, endLine: nil) } ?? AIProjectReadRequest.decode(action.argument ?? "", search: search)
        let path = try TerminalDirectoryBridge.normalizedPath(request.path)
        let ownCommand = try action.command(os: "Linux").text
        guard effectivePolicy(policy).decision(target: source, tool: action.tool, argument: action.targetArgument, automatic: true, hostID: hostID, command: ownCommand) != .deny else { return .init(output: "Project read denied / 项目读取被禁止", exitCode: 1) }
        guard let open = fileBackend else { return .init(output: "Pinned file endpoint unavailable / 当前文件连接不可用", exitCode: 1) }
        let backend = try await open()
        do {
            try check()
            guard !AIAutomaticContext.sensitive(path), effectivePolicy(policy).decision(target: source, tool: search ? "list_directory" : "read_file", argument: path, automatic: true, hostID: hostID, command: path) != .deny else { throw AppFailure.message("File access denied / 文件访问被禁止") }
            guard try await AISkills.safe(path, backend: backend) else { throw AppFailure.message("Symbolic links are not followed / 不跟随符号链接") }
            let output: String
            if let textRequest {
                output = try await AITextSearch.run(textRequest, backend: backend, executor: self, policy: policy).output
            } else if search {
                guard try await backend.stat(path).directory else { throw AIModelError.invalidReply }
                let items = try await AIAutomaticContext.discover(goal: request.query!, root: path, backend: backend, executor: self, policy: policy)
                output = "Bounded lexical retrieval; results are relevant excerpts, NOT exhaustive matches. No result does not prove absence. Use read_file_range for additional lines.\n" + items.map { "File: " + $0.path + "\n" + $0.text }.joined(separator: "\n\n")
            } else {
                guard try await AIContextAccess.allowed(path, root: (path as NSString).deletingLastPathComponent, backend: backend, executor: self, policy: policy) else { throw AppFailure.message("File is excluded by project rules / 文件被项目规则排除") }
                let before = try await backend.stat(path)
                guard !before.directory, !before.symlink, before.size <= 1048576 else { throw AppFailure.message("Read a plain UTF-8 file up to 1 MiB / 仅支持读取不超过 1 MiB 的普通文本文件") }
                let bytes = try await backend.read(path, offset: 0, count: Int(before.size) + 1)
                guard bytes.count == Int(before.size), !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { throw AppFailure.message("File changed or is not UTF-8 text / 文件已变化或不是 UTF-8 文本") }
                let after = try await backend.stat(path)
                guard !after.symlink, FileContentDigest.sameMetadata(before, after) else { throw AppFailure.message("File changed during read / 读取期间文件已变化") }
                let lines = text.components(separatedBy: "\n")
                let start = request.startLine!, end = min(request.endLine!, lines.count)
                if start > lines.count { output = "[Requested line is beyond end of file; total lines: \(lines.count)]" }
                else {
                    var selected: [String] = [], size = 0
                    for index in (start - 1)..<end {
                        let line = "\(index + 1): " + lines[index]
                        if size + line.utf8.count > 32768 { selected.append("[Output limit reached; omitted lines are unknown]"); break }
                        selected.append(line); size += line.utf8.count + 1
                    }
                    output = "File: \(path); total lines: \(lines.count)\n" + selected.joined(separator: "\n")
                }
            }
            try check()
            guard effectivePolicy(policy).decision(target: source, tool: action.tool, argument: action.targetArgument, automatic: true, hostID: hostID, command: ownCommand) != .deny else { throw AppFailure.message("Project read denied by updated rules / 项目读取被新规则禁止") }
            guard effectivePolicy(policy).decision(target: source, tool: search ? "list_directory" : "read_file", argument: path, automatic: true, hostID: hostID, command: path) != .deny else { throw AppFailure.message("File access denied / 文件访问被禁止") }
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            return .init(output: AIContext.sanitize(output), exitCode: 0)
        } catch {
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            try check()
            return .init(output: AIContext.sanitize(error.localizedDescription), exitCode: 1)
        }
    }
}
