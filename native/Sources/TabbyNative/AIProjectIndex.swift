import Foundation
import Combine
import CryptoKit
import NaturalLanguage

/// Local, endpoint-scoped cache. Cached excerpts are never execution or freshness evidence.
@MainActor final class AIProjectIndex: ObservableObject {
    struct Symbol: Codable, Equatable {
        let name: String
        let kind: String
        let line: Int
        let calls: [String]
    }
    struct Document: Codable {
        let path: String
        let digest: String
        let size: UInt64
        let modified: Date
        let chunks: [Chunk]
        let symbols: [Symbol]
        let imports: [String]
        var dependencies: [String]? = nil
    }
    struct Chunk: Codable {
        let line: Int
        let text: String
        let vector: [Double]?
    }
    struct Project: Codable, Identifiable {
        var id: String { Self.key(endpoint, root) }
        let endpoint: String
        let root: String
        var enabled = true
        var updated: Date?
        var state = "pending"
        var note = ""
        var documents: [Document] = []
        static func key(_ endpoint: String, _ root: String) -> String { AIProjectIndex.digest(Data((endpoint + "\u{0}" + root).utf8)) }
    }
    struct Hit: Identifiable {
        var id: String { path + ":" + String(line) }
        let path: String
        let line: Int
        let text: String
        let score: Double
        let semantic: Bool
    }
    @Published private(set) var projects: [Project] = []
    @Published private(set) var syncing = Set<String>()
    private let fileURL: URL
    private static let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    static var semanticAvailable: Bool { embedding != nil }
    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), data.count <= 48 * 1024 * 1024,
           let values = try? JSONDecoder().decode([Project].self, from: data) {
            var ids = Set<String>()
            projects = Array(values.prefix(8)).filter { $0.root != "/" && (try? TerminalDirectoryBridge.normalizedPath($0.root)) == $0.root && !AIAutomaticContext.sensitive($0.root) && ids.insert($0.id).inserted }.map { var p = $0; p.state = "stale"; return p }
        }
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(projects)
        guard data.count <= 48 * 1024 * 1024 else { throw AppFailure.message("Project index is too large / 项目索引超过容量") }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    func add(root: String, endpoint: String) throws {
        guard root != "/", root.hasPrefix("/"), root.utf8.count <= 4096,
              try TerminalDirectoryBridge.normalizedPath(root) == root, !AIAutomaticContext.sensitive(root) else { throw AppFailure.message("Choose a project directory / 请选择项目目录") }
        guard !projects.contains(where: { $0.id == Project.key(endpoint, root) }) else { return }
        guard projects.count < 8 else { throw AppFailure.message("Up to eight project roots / 最多添加 8 个项目目录") }
        projects.append(Project(endpoint: endpoint, root: root)); try save()
    }
    func remove(_ id: String) throws { guard !syncing.contains(id) else { return }; projects.removeAll { $0.id == id }; try save() }
    func enable(_ id: String, _ enabled: Bool) throws {
        guard let i = projects.firstIndex(where: { $0.id == id }), !syncing.contains(id) else { return }
        projects[i].enabled = enabled; try save()
    }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    static func vector(_ text: String) -> [Double]? {
        // Apple's English sentence model provides local natural-language similarity, not a code model.
        embedding?.vector(for: String(text.prefix(1500)))
    }
    static func cosine(_ a: [Double]?, _ b: [Double]?) -> Double {
        guard let a, let b, a.count == b.count, !a.isEmpty else { return 0 }
        let norm = sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return 0 }
        return max(0, zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / norm)
    }
    static func document(path: String, entry: FileEntry, data: Data) -> Document? {
        guard !data.contains(0), let raw = String(data: data, encoding: .utf8) else { return nil }
        let lines = lineSafe(raw)
        var chunks: [Chunk] = []
        for start in stride(from: 0, to: lines.count, by: 32) {
            let value = String(lines[start..<min(start + 40, lines.count)].joined(separator: "\n").prefix(4000))
            chunks.append(Chunk(line: start + 1, text: value, vector: vector(value)))
            if chunks.count >= 8 { break }
        }
        return Document(path: path, digest: digest(data), size: entry.size, modified: entry.modified, chunks: chunks,
                        symbols: AICodeOutline.symbols(raw, path: path), imports: AICodeOutline.imports(raw),
                        dependencies: (path as NSString).lastPathComponent == "pom.xml" ? AIJavaDependencies.maven(Self.lineSafe(raw).joined(separator: "\n")) : nil)
    }
    static func lineSafe(_ raw: String) -> [String] {
        var privateKey = false
        return raw.components(separatedBy: "\n").map { line in
            if line.contains("-----BEGIN ") && line.contains("PRIVATE KEY-----") { privateKey = true }
            if privateKey { if line.contains("-----END ") && line.contains("PRIVATE KEY-----") { privateKey = false }; return "[REDACTED]" }
            return String(AIContext.sanitize(line).prefix(4096)).replacingOccurrences(of: "\n", with: " ")
        }
    }
    /// Rescan metadata and exclusions each sync; hash changed bytes; deleted/excluded files disappear.
    func sync(_ id: String, executor: AICommandExecutor, policy: AIExecutionPolicy, rebuild: Bool = false) async throws {
        guard let project = project(id), project.endpoint == executor.contextEndpoint, !syncing.contains(id), let open = executor.fileBackend else { throw AppFailure.message("Connect the project's original target / 请连接项目原目标") }
        syncing.insert(id); defer { syncing.remove(id) }
        if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].state = "syncing" }
        let backend = try await open()
        do {
            try executor.check()
            guard try await AISkills.safe(project.root, backend: backend), try await backend.stat(project.root).directory,
                  let inherited = try await AIProjectIgnore.inherited(root: project.root, backend: backend, executor: executor, policy: policy) else { throw AppFailure.message("Project exclusions could not be verified / 无法核对项目排除规则") }
            var queue = [(project.root, 0, inherited.rules)], documents: [Document] = [], examined = 0, readBytes = 0, ignoreBytes = inherited.bytes
            var bounded = false, excluded = 0, reused = 0, chunks = 0
            let previous = Dictionary(uniqueKeysWithValues: project.documents.map { ($0.path, $0) })
            let git = backend is LocalFiles ? try AIGitContext(root: project.root) : nil
            while !queue.isEmpty, examined < 20000, documents.count < 5000, chunks < 2000 {
                try Task.checkCancellation(); try executor.check()
                let (directory, depth, inheritedRules) = queue.removeFirst()
                guard AISkills.permitted(directory, tool: "list_directory", executor: executor, policy: policy), try await AISkills.safe(directory, backend: backend) else { bounded = true; continue }
                guard let entries = try? await backend.list(directory), let rules = try await AIProjectIgnore.load(directory: directory, entries: entries, backend: backend, executor: executor, policy: policy, budget: 65536 - ignoreBytes) else { bounded = true; continue }
                ignoreBytes += rules.bytes
                for entry in entries.sorted(by: { $0.name < $1.name }) {
                    try Task.checkCancellation()
                    if examined % 50 == 0 { await Task.yield(); try executor.check() }
                    guard examined < 20000, documents.count < 5000, chunks < 2000 else { bounded = true; break }
                    examined += 1
                    let path = try remoteJoin(directory, entry.name)
                    guard !entry.symlink, !AIAutomaticContext.sensitive(path), !AIAutomaticContext.excludedDirectories.contains(entry.name),
                          !AIProjectIgnore.ignored(path, directory: entry.directory, rules: inheritedRules + rules.rules),
                          git?.excluded(path) != true else { excluded += 1; continue }
                    if entry.directory { if depth < 24 { queue.append((path, depth + 1, inheritedRules + rules.rules)) } else { bounded = true }; continue }
                    guard entry.size <= 262144, AISkills.permitted(path, tool: "read_file", executor: executor, policy: policy), try await AISkills.safe(path, backend: backend) else { excluded += 1; continue }
                    let before = try await backend.stat(path)
                    if !rebuild, let old = previous[path], old.modified == before.modified, old.size == before.size {
                        let accepted = Document(path: old.path, digest: old.digest, size: old.size, modified: old.modified,
                            chunks: Array(old.chunks.prefix(2000 - chunks)), symbols: old.symbols, imports: old.imports, dependencies: old.dependencies)
                        if accepted.chunks.count < old.chunks.count { bounded = true }
                        documents.append(accepted); chunks += accepted.chunks.count; reused += 1; continue
                    }
                    guard readBytes + Int(before.size) <= 32 * 1024 * 1024 else { bounded = true; continue }
                    let bytes = try await backend.read(path, offset: 0, count: Int(before.size) + 1); readBytes += bytes.count
                    let after = try await backend.stat(path)
                    guard !after.symlink, !after.directory, bytes.count == Int(before.size), FileContentDigest.sameMetadata(before, after),
                          AISkills.permitted(path, tool: "read_file", executor: executor, policy: policy),
                          let document = Self.document(path: path, entry: after, data: bytes) else { bounded = true; continue }
                    let accepted = Document(path: document.path, digest: document.digest, size: document.size, modified: document.modified,
                        chunks: Array(document.chunks.prefix(2000 - chunks)), symbols: document.symbols, imports: document.imports, dependencies: document.dependencies)
                    if accepted.chunks.count < document.chunks.count { bounded = true }
                    documents.append(accepted); chunks += accepted.chunks.count
                    await Task.yield()
                    if documents.count >= 5000 || chunks >= 2000 { bounded = true; break }
                }
                if examined % 50 == 0 { await Task.yield() }
            }
            if !queue.isEmpty { bounded = true }
            try executor.check()
            if let i = projects.firstIndex(where: { $0.id == id }) {
                projects[i].documents = documents; projects[i].updated = Date(); projects[i].state = bounded ? "limited" : "synced"
                projects[i].note = "\(documents.count) files · \(reused) unchanged · \(excluded) excluded" + (git == nil ? " · scoped ignore rules" : " · Git tracked + untracked, global excludes")
                try save()
            }
            if let remote = backend as? RemoteFiles { try? await remote.close() }
        } catch {
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].state = "failed"; projects[i].note = AIContext.sanitize(error.localizedDescription); projects[i].documents = [] }
            try? save(); throw error
        }
    }
    func search(query: String, endpoint: String, roots: Set<String>? = nil, limit: Int = 12) -> [Hit] {
        let terms = AIAutomaticContext.searchTerms(query), vector = Self.vector(query)
        var hits: [Hit] = []
        for p in projects where p.enabled && p.endpoint == endpoint && ["synced", "limited"].contains(p.state) && (roots == nil || roots!.contains(p.root)) {
            for d in p.documents {
                for c in d.chunks {
                    let lower = (d.path + "\n" + c.text).lowercased()
                    let lexical = Double(terms.filter { lower.contains($0) }.count)
                    let similarity = Self.cosine(vector, c.vector)
                    // English sentence vectors rank candidate context, not evidence of relevance.
                    guard lexical > 0 || similarity > 0.20 else { continue }
                    hits.append(Hit(path: d.path, line: c.line, text: c.text, score: lexical + similarity * 2, semantic: vector != nil && c.vector != nil))
                }
            }
        }
        return Array(hits.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(min(24, max(1, limit))))
    }
    func freshHits(_ hits: [Hit], executor: AICommandExecutor, policy: AIExecutionPolicy) async throws -> [Hit] {
        guard let open = executor.fileBackend else { return [] }
        let backend = try await open(); var result: [Hit] = [], invalid = Set<String>()
        do {
            for hit in hits {
                try executor.check(); try Task.checkCancellation()
                do {
                guard let p = projects.first(where: { $0.enabled && $0.endpoint == executor.contextEndpoint && $0.documents.contains { $0.path == hit.path } }),
                      let d = p.documents.first(where: { $0.path == hit.path }),
                      try await AIContextAccess.allowed(hit.path, root: p.root, backend: backend, executor: executor, policy: policy) else { invalid.insert(hit.path); continue }
                let before = try await backend.stat(hit.path)
                guard !before.symlink, !before.directory, before.size <= 262144 else { invalid.insert(hit.path); continue }
                let bytes = try await backend.read(hit.path, offset: 0, count: Int(before.size) + 1)
                let after = try await backend.stat(hit.path)
                guard !after.symlink, !after.directory, bytes.count == Int(before.size), FileContentDigest.sameMetadata(before, after), Self.digest(bytes) == d.digest,
                      try await AIContextAccess.allowed(hit.path, root: p.root, backend: backend, executor: executor, policy: policy) else { invalid.insert(hit.path); continue }
                guard let raw = String(data: bytes, encoding: .utf8) else { invalid.insert(hit.path); continue }
                let lines = Self.lineSafe(raw)
                guard hit.line > 0, hit.line <= lines.count else { invalid.insert(hit.path); continue }
                let text = String(lines[(hit.line - 1)..<min(hit.line + 39, lines.count)].joined(separator: "\n").prefix(4000))
                result.append(Hit(path: hit.path, line: hit.line, text: text, score: hit.score, semantic: hit.semantic))
                } catch is CancellationError { throw CancellationError() }
                catch { try executor.check(); invalid.insert(hit.path) }
            }
            for i in projects.indices where projects[i].endpoint == executor.contextEndpoint && projects[i].documents.contains(where: { invalid.contains($0.path) }) {
                projects[i].documents.removeAll { invalid.contains($0.path) }; projects[i].state = "stale"
            }
            if !invalid.isEmpty { try? save() }
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            return result
        } catch { if let remote = backend as? RemoteFiles { try? await remote.close() }; throw error }
    }
}

/// Source-level outline and candidate call sites, deliberately not a type-resolved call graph.
enum AICodeOutline {
    static func matches(_ pattern: String, _ text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }; let value = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).prefix(300).map { value.substring(with: $0.range(at: group)) }
    }
    static func imports(_ text: String) -> [String] {
        Array(Set(matches(#"(?m)^\s*(?:import|from|use|#include)\s+[<\"']?([\w./:-]+)"#, text) + matches(#"(?:from\s+|require\s*\()['\"]([^'\"]+)"#, text))).sorted()
    }
    static func symbols(_ text: String, path: String) -> [AIProjectIndex.Symbol] {
        if path.hasSuffix(".java") { return AIJavaOutline.symbols(text) }
        let lines = text.components(separatedBy: "\n")
        let pattern = #"\b(func|def|function|class|struct|enum|interface|actor|protocol|fn)\s+([A-Za-z_$][\w$]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [AIProjectIndex.Symbol] = []
        for (index, line) in lines.enumerated() {
            let value = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: value.length)), !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            let name = value.substring(with: match.range(at: 2)), body = lines[index..<min(index + 40, lines.count)].joined(separator: "\n")
            let calls = Array(Set(matches(#"\b([A-Za-z_$][\w$]*)\s*\("#, body)).subtracting([name, "if", "for", "while", "switch", "catch"])).sorted()
            result.append(.init(name: name, kind: value.substring(with: match.range(at: 1)), line: index + 1, calls: Array(calls.prefix(40))))
            if result.count >= 200 { break }
        }
        return result
    }
}
