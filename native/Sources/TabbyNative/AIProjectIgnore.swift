import Foundation
import Darwin
import CryptoKit

/// Scoped ignore rules for file retrieval. Sensitive/generated directories remain non-negotiable.
enum AIProjectIgnore {
    static let names = [".gitignore", ".axonignore", ".warpindexingignore", ".cursorignore", ".cursorindexingignore", ".codeiumignore"]
    struct Rule {
        let scope: String
        let pattern: [String]
        let anchored: Bool
        let directoryOnly: Bool
        let include: Bool
        init?(_ raw: String, scope: String) {
            var value = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            while value.hasSuffix(" ") {
                let preceding = value.dropLast().reversed().prefix { $0 == "\\" }.count
                if preceding % 2 == 1 { break }
                value.removeLast()
            }
            guard !value.isEmpty, !value.hasPrefix("#"), value.utf8.count <= 1024 else { return nil }
            include = value.hasPrefix("!")
            if include { value.removeFirst() }
            directoryOnly = value.hasSuffix("/")
            if directoryOnly { value.removeLast() }
            anchored = value.hasPrefix("/") || value.contains("/")
            if value.hasPrefix("/") { value.removeFirst() }
            guard !value.isEmpty else { return nil }
            self.scope = scope
            pattern = value.components(separatedBy: "/")
        }
        func matches(_ path: String, directory: Bool) -> Bool {
            guard !directoryOnly || directory else { return false }
            let prefix = scope == "/" ? "/" : scope + "/"
            guard path.hasPrefix(prefix) else { return false }
            let components = String(path.dropFirst(prefix.count)).components(separatedBy: "/")
            guard components.count <= 128 else { return true }
            if !anchored, let pattern = pattern.first {
                return components.contains { fnmatch(pattern, $0, FNM_PATHNAME) == 0 }
            }
            var memo: [String: Bool] = [:]
            func match(_ p: Int, _ c: Int) -> Bool {
                let key = "\(p):\(c)"; if let result = memo[key] { return result }
                let result: Bool
                if p == pattern.count { result = c == components.count }
                else if pattern[p] == "**" {
                    // abc/** ignores entries inside abc, not abc itself (which can contain negated rules).
                    if p == pattern.count - 1 { result = c < components.count }
                    else { result = match(p + 1, c) || (c < components.count && match(p, c + 1)) }
                } else { result = c < components.count && fnmatch(pattern[p], components[c], FNM_PATHNAME) == 0 && match(p + 1, c + 1) }
                memo[key] = result; return result
            }
            return match(0, 0)
        }
    }
    static func ignored(_ path: String, directory: Bool, rules: [Rule]) -> Bool {
        var excluded = false
        for rule in rules where rule.matches(path, directory: directory) { excluded = !rule.include }
        return excluded
    }
    struct Loaded { let rules: [Rule]; let fingerprint: String; let bytes: Int }
    /// Parent rules apply when the selected search directory is inside a recognized repository.
    @MainActor static func inherited(root: String, backend: any FileEndpoint, executor: AICommandExecutor,
                                     policy: AIExecutionPolicy) async throws -> Loaded? {
        var chain: [(String, [FileEntry])] = [], current = root, found = false
        for _ in 0..<8 {
            try executor.check()
            if current == "/" { break }
            guard AISkills.permitted(current, tool: "list_directory", executor: executor, policy: policy),
                  try await AISkills.safe(current, backend: backend) else { return nil }
            let entries = try await backend.list(current)
            chain.append((current, entries))
            if entries.contains(where: { $0.name == ".git" && !$0.symlink }) { found = true; break }
            current = (current as NSString).deletingLastPathComponent
        }
        guard found else { return Loaded(rules: [], fingerprint: "", bytes: 0) }
        var rules: [Rule] = [], manifest = "", bytes = 0
        for (directory, entries) in chain.reversed() where directory != root {
            if ignored(directory, directory: true, rules: rules) { return nil }
            guard let loaded = try await load(directory: directory, entries: entries, backend: backend, executor: executor, policy: policy, budget: 65536 - bytes) else { return nil }
            rules += loaded.rules; manifest += loaded.fingerprint; bytes += loaded.bytes
        }
        guard !ignored(root, directory: true, rules: rules) else { return nil }
        return Loaded(rules: rules, fingerprint: manifest, bytes: bytes)
    }
    /// If an existing ignore file cannot be safely read, skip that subtree instead of guessing its exclusions.
    @MainActor static func load(directory: String, entries: [FileEntry], backend: any FileEndpoint,
                                executor: AICommandExecutor, policy: AIExecutionPolicy, budget: Int) async throws -> Loaded? {
        var rules: [Rule] = [], bytes = 0, manifest = ""
        for name in names {
            guard let listed = entries.first(where: { $0.name == name }) else { continue }
            let path = try remoteJoin(directory, name)
            try executor.check()
            guard !listed.directory, !listed.symlink, listed.size <= 8192,
                  listed.size <= max(0, budget - bytes), AISkills.permitted(path, tool: "read_file", executor: executor, policy: policy),
                  try await AISkills.safe(path, backend: backend) else { return nil }
            let before = try await backend.stat(path)
            guard !before.symlink, !before.directory, before.size <= 8192, before.size <= max(0, budget - bytes) else { return nil }
            let data = try await backend.read(path, offset: 0, count: Int(before.size) + 1)
            let after = try await backend.stat(path)
            try executor.check()
            guard data.count == Int(before.size), !data.contains(0), let text = String(data: data, encoding: .utf8),
                  !after.symlink, FileContentDigest.sameMetadata(before, after),
                  try await AISkills.safe(path, backend: backend),
                  AISkills.permitted(path, tool: "read_file", executor: executor, policy: policy) else { return nil }
            rules += text.components(separatedBy: "\n").compactMap { Rule($0, scope: directory) }
            bytes += data.count
            manifest += path + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\n"
        }
        return Loaded(rules: rules, fingerprint: manifest, bytes: bytes)
    }
}
