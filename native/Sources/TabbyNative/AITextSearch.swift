import Foundation
import CryptoKit

struct AITextSearchRequest: Decodable {
    let path: String
    let query: String
    let caseSensitive: Bool?
    let limit: Int?
    let cursor: String?
    static func decode(_ value: String) throws -> Self {
        let data = Data(value.utf8)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(["path", "query"]).isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: Set(["path", "query", "caseSensitive", "limit", "cursor"])) else { throw AIModelError.invalidReply }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.path.hasPrefix("/"), request.path.utf8.count <= 4096,
              try TerminalDirectoryBridge.normalizedPath(request.path) == request.path,
              !request.query.isEmpty, request.query.utf8.count <= 512,
              ![request.path, request.query].contains(where: { $0.contains("[REDACTED]") || $0.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) }),
              (1...100).contains(request.limit ?? 50), (request.cursor?.utf8.count ?? 0) <= 2048 else { throw AIModelError.invalidReply }
        return request
    }
}

/// Literal search on the pinned file connection. Cursors describe a position, never authority or a path to read.
enum AITextSearch {
    private struct Cursor: Codable { let binding: String; let manifest: String; let file: Int; let line: Int }
    private struct Scope { var files: [FileEntry] = []; var manifest = ""; var excluded = 0; var bounded = false }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func readableName(_ name: String) -> Bool { !name.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } }
    @MainActor private static func scope(_ root: String, backend: any FileEndpoint, executor: AICommandExecutor, policy: AIExecutionPolicy) async throws -> Scope {
        var result = Scope()
        guard let inherited = try await AIProjectIgnore.inherited(root: root, backend: backend, executor: executor, policy: policy) else { result.excluded = 1; return result }
        result.manifest = inherited.fingerprint
        let git = backend is LocalFiles ? try AIGitContext(root: root) : nil
        var queue: [(String, Int, [AIProjectIgnore.Rule])] = [(root, 0, inherited.rules)]
        var examined = 0, directories = 0, ignoreBudget = 65536 - inherited.bytes
        while !queue.isEmpty, examined < 1000, directories < 80 {
            try executor.check(); try Task.checkCancellation()
            let (directory, depth, inherited) = queue.removeFirst(); directories += 1
            guard AISkills.permitted(directory, tool: "list_directory", executor: executor, policy: policy),
                  try await AISkills.safe(directory, backend: backend) else { result.excluded += 1; continue }
            let entries: [FileEntry]
            do { entries = try await backend.list(directory) }
            catch { try executor.check(); result.excluded += 1; continue }
            let loaded: AIProjectIgnore.Loaded?
            do { loaded = try await AIProjectIgnore.load(directory: directory, entries: entries, backend: backend, executor: executor, policy: policy, budget: ignoreBudget) }
            catch { try executor.check(); result.excluded += 1; continue }
            guard let loaded else { result.excluded += 1; continue }
            ignoreBudget -= loaded.bytes; result.manifest += loaded.fingerprint
            let rules = inherited + loaded.rules
            if entries.count > 1000 - examined { result.bounded = true }
            for listed in entries.sorted(by: { $0.name < $1.name }).prefix(1000 - examined) {
                examined += 1
                guard readableName(listed.name), let path = try? remoteJoin(directory, listed.name) else { result.excluded += 1; continue }
                let permitted = AISkills.permitted(path, tool: listed.directory ? "list_directory" : "read_file", executor: executor, policy: policy)
                let excluded = listed.symlink || AIAutomaticContext.sensitive(path) || AIAutomaticContext.excludedDirectories.contains(listed.name)
                    || AIProjectIgnore.ignored(path, directory: listed.directory, rules: rules) || git?.excluded(path) == true || !permitted
                result.manifest += path + ":\(listed.size):\(listed.modified.timeIntervalSince1970):\(listed.directory):\(excluded)\n"
                if excluded { result.excluded += 1; continue }
                if listed.directory {
                    if depth < 8 { queue.append((path, depth + 1, rules)) }
                    else { result.bounded = true }
                } else if listed.size <= 1048576, result.files.count < 400 {
                    var entry = listed; entry.path = path; result.files.append(entry)
                } else { result.excluded += 1; result.bounded = true }
            }
        }
        if !queue.isEmpty { result.bounded = true }
        result.files.sort { $0.path < $1.path }
        result.manifest = digest(result.manifest)
        return result
    }
    private static func excerpt(_ line: String, match: Range<String.Index>) -> String {
        let offset = line.distance(from: line.startIndex, to: match.lowerBound)
        let start = max(0, offset - 60)
        let index = line.index(line.startIndex, offsetBy: start)
        let text = String(line[index...].prefix(220))
        return (start > 0 ? "…" : "") + AIContext.sanitize(text) + (line.distance(from: index, to: line.endIndex) > 220 ? "…" : "")
    }
    @MainActor static func run(_ request: AITextSearchRequest, backend: any FileEndpoint,
                              executor: AICommandExecutor, policy: AIExecutionPolicy) async throws -> AICommandResult {
        guard !AIAutomaticContext.sensitive(request.path), try await AISkills.safe(request.path, backend: backend),
              try await backend.stat(request.path).directory else { throw AppFailure.message("Choose a plain project directory / 请选择普通项目目录") }
        let selected = try await scope(request.path, backend: backend, executor: executor, policy: policy)
        let binding = digest(executor.source + executor.sessionID.uuidString + request.path + "\u{0}" + request.query + "\u{0}" + String(request.caseSensitive ?? true))
        var fileIndex = 0, lineIndex = 0
        if let raw = request.cursor {
            guard let data = Data(base64Encoded: raw), let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
                  cursor.binding == binding, cursor.manifest == selected.manifest,
                  cursor.file >= 0, cursor.file < selected.files.count, cursor.line >= 0, cursor.line <= 1048576 else {
                throw AppFailure.message("Search scope changed or cursor does not match. Restart without cursor. / 搜索范围已变化或分页不匹配，请移除 cursor 重新搜索。")
            }
            fileIndex = cursor.file; lineIndex = cursor.line
        }
        var matches: [String] = [], inspected = 0, remainingBytes = 2097152, outputBytes = 0, skipped = 0
        let options: String.CompareOptions = request.caseSensitive == false ? [.literal, .caseInsensitive] : [.literal]
        while fileIndex < selected.files.count {
            try executor.check(); try Task.checkCancellation()
            let entry = selected.files[fileIndex]
            if Int(entry.size) > remainingBytes { break }
            guard AISkills.permitted(entry.path, tool: "read_file", executor: executor, policy: policy),
                  try await AISkills.safe(entry.path, backend: backend) else { throw AppFailure.message("Search permissions or file path changed; restart the search / 搜索权限或文件路径已变化，请重新搜索") }
            let before = try await backend.stat(entry.path)
            guard !before.symlink, !before.directory, before.size <= 1048576, FileContentDigest.sameMetadata(entry, before) else { throw AppFailure.message("File changed during search; restart / 搜索期间文件变化，请重新搜索") }
            let data = try await backend.read(entry.path, offset: 0, count: Int(before.size) + 1)
            let after = try await backend.stat(entry.path)
            try executor.check()
            guard data.count == Int(before.size), !after.symlink, FileContentDigest.sameMetadata(before, after),
                  AISkills.permitted(entry.path, tool: "read_file", executor: executor, policy: policy),
                  try await AISkills.safe(entry.path, backend: backend) else { throw AppFailure.message("File or permission changed during search; restart / 搜索期间文件或权限变化，请重新搜索") }
            remainingBytes -= data.count; inspected += 1
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { skipped += 1; fileIndex += 1; lineIndex = 0; continue }
            let lines = text.components(separatedBy: "\n")
            guard lineIndex <= lines.count else { throw AIModelError.invalidReply }
            while lineIndex < lines.count {
                if lineIndex % 128 == 0 { try executor.check(); try Task.checkCancellation() }
                let line = lines[lineIndex]
                if let hit = line.range(of: request.query, options: options) {
                    let value = entry.path + ":\(lineIndex + 1): " + excerpt(line, match: hit)
                    if matches.count >= (request.limit ?? 50) || outputBytes + value.utf8.count > 12000 { break }
                    matches.append(value); outputBytes += value.utf8.count + 1
                }
                lineIndex += 1
            }
            if lineIndex < lines.count { break }
            fileIndex += 1; lineIndex = 0
        }
        let fresh = try await scope(request.path, backend: backend, executor: executor, policy: policy)
        guard fresh.manifest == selected.manifest else { throw AppFailure.message("Search scope changed during this page; restart without cursor / 本页搜索期间范围已变化，请移除 cursor 重新搜索") }
        let next: String?
        if fileIndex < selected.files.count { next = try JSONEncoder().encode(Cursor(binding: binding, manifest: selected.manifest, file: fileIndex, line: lineIndex)).base64EncodedString() }
        else { next = nil }
        let header = "Literal text search (one result per matching line, one-based line numbers).\nNext cursor: " + (next ?? "none")
            + "\nPage matches: \(matches.count); inspected files: \(inspected); excluded entries: \(selected.excluded); non-text skipped: \(skipped).\n"
            + (selected.bounded ? "Scope limits reached. Narrow the directory; unscanned entries are unknown.\n" : "")
            + "Not proof of absence or task completion: ignored, sensitive, denied and non-text files are excluded; each page is a fresh bounded inspection.\n"
        return .init(output: header + (matches.isEmpty ? "No matches in this inspected page." : matches.joined(separator: "\n")), exitCode: 0)
    }
}
