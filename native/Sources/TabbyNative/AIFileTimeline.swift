import Foundation
import SwiftUI

/// Private application-owned snapshots. They never become model context or permissions.
@MainActor final class AIFileTimeline: ObservableObject {
    struct Snapshot: Codable, Identifiable {
        var id: String { path }
        let path: String
        let before: Data
        let after: Data
        let permissions: UInt32
    }
    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let target: String
        let hostID: UUID?
        let directory: String?
        let taskID: UUID?
        let title: String
        let files: [Snapshot]
        var state: String
        var origin: UUID?
    }
    @Published private(set) var entries: [Entry] = []
    @Published var error = ""
    let url: URL
    static let maximumBytes = 16 * 1024 * 1024
    init(url: URL) { self.url = url; do { try reload() } catch { self.error = error.localizedDescription } }
    func reload() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { entries = []; return }
        let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        guard directory[.type] as? FileAttributeType == .typeDirectory else { throw AIModelError.invalidReply }
        let attr = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attr[.type] as? FileAttributeType == .typeRegular, (attr[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumBytes else { throw AIModelError.invalidReply }
        let decoded = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        guard decoded.count <= 64, Set(decoded.map(\.id)).count == decoded.count, decoded.allSatisfy({ (1...8).contains($0.files.count) && Set($0.files.map(\.path)).count == $0.files.count && $0.files.allSatisfy({ Self.valid($0) }) }) else { throw AIModelError.invalidReply }
        entries = decoded; error = ""
    }
    private static func valid(_ file: Snapshot) -> Bool {
        file.path.utf8.count <= 4096 && file.path.hasPrefix("/") && (try? TerminalDirectoryBridge.normalizedPath(file.path)) == file.path && [file.before, file.after].allSatisfy { $0.count <= 65536 && !$0.contains(0) && String(data: $0, encoding: .utf8) != nil }
    }
    private func persist(_ updated: [Entry]) throws {
        var retained = updated
        var data = try JSONEncoder().encode(retained)
        while retained.count > 64 || data.count > Self.maximumBytes {
            guard let index = retained.firstIndex(where: { ["applied", "not_applied"].contains($0.state) }) else { throw AppFailure.message("Resolve pending file changes before adding history / 请先处理待恢复修改，时间线已达限额") }
            retained.remove(at: index); data = try JSONEncoder().encode(retained)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        guard directory[.type] as? FileAttributeType == .typeDirectory else { throw AIModelError.invalidReply }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        entries = retained
    }
    @discardableResult func begin(proposals: [AIFileProposal], executor: AICommandExecutor, taskID: UUID?, title: String, origin: UUID? = nil) throws -> UUID {
        try reload()
        let files = try proposals.map { Snapshot(path: $0.path, before: Data($0.originalText.utf8), after: Data(try $0.reviewedText().utf8), permissions: $0.originalEntry.permissions) }.filter { $0.before != $0.after }
        guard !files.isEmpty, files.allSatisfy({ Self.valid($0) }) else { throw AIModelError.invalidReply }
        let entry = Entry(id: UUID(), date: Date(), target: executor.source, hostID: executor.hostID, directory: executor.directory, taskID: taskID, title: String(AIContext.sanitize(title).prefix(1000)), files: files, state: "pending", origin: origin)
        try persist(entries + [entry]); return entry.id
    }
    func finish(_ id: UUID, state: String) throws {
        try reload(); var updated = entries
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw AIModelError.invalidReply }
        updated[index].state = state; try persist(updated)
    }
    func matches(_ entry: Entry, _ executor: AICommandExecutor) -> Bool { entry.target == executor.source && entry.hostID == executor.hostID && entry.directory == executor.directory }
    func knownVersion(_ bytes: Data, path: String, entry: Entry) -> Bool {
        entries.filter { $0.target == entry.target && $0.hostID == entry.hostID && $0.directory == entry.directory }.flatMap(\.files).contains { $0.path == path && ($0.before == bytes || $0.after == bytes) }
    }
    static func permission(path: String, executor: AICommandExecutor, policy: AIExecutionPolicy, write: Bool) throws {
        try executor.check()
        let decision = executor.effectivePolicy(policy).decision(target: executor.source, tool: write ? "replace_file" : "read_configuration", argument: path, automatic: !write, hostID: executor.hostID, command: write ? "Restore reviewed file " + path : "cat -- " + SnippetParameters.shellArgument(path))
        guard write ? decision != .deny : decision == .allow else { throw AppFailure.message("Permission needed for this file / 当前文件权限不允许此操作：" + path) }
    }
    func inspect(_ entry: Entry, executor: AICommandExecutor, policy: AIExecutionPolicy) async throws -> [String: String] {
        guard matches(entry, executor), let open = executor.fileBackend else { throw AppFailure.message("Connect the original target and directory / 请连接原目标并打开原目录") }
        let backend = try await open()
        do {
            var result: [String: String] = [:]
            for file in entry.files {
                try Self.permission(path: file.path, executor: executor, policy: policy, write: false)
                do {
                    let stat = try await backend.stat(file.path)
                    guard stat.size <= 65536, !stat.symlink, !stat.directory else { throw AIModelError.invalidReply }
                    let bytes = try await ExternalEdit.read(stat, from: backend)
                    result[file.path] = bytes == file.before ? "before" : bytes == file.after ? "after" : knownVersion(bytes, path: file.path, entry: entry) ? "recorded" : "conflict"
                } catch is CancellationError { throw CancellationError() }
                catch { result[file.path] = "unavailable" }
            }
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            try executor.check()
            if result.values.allSatisfy({ $0 == "before" }) { try finish(entry.id, state: "not_applied") }
            else if result.values.allSatisfy({ $0 == "after" }) { try finish(entry.id, state: "applied") }
            return result
        } catch { if let remote = backend as? RemoteFiles { try? await remote.close() }; throw error }
    }
}

@MainActor final class AIFileTimelineReview: ObservableObject {
    @Published var review: AIChangeReview?
    @Published var states: [String: String] = [:]
    @Published var error = ""
    @Published var busy = false
    @Published var message = ""
    private var proposals: [AIFileProposal] = []
    private var backend: (any FileEndpoint)?
    let timeline: AIFileTimeline
    let executor: AICommandExecutor
    let policy: () -> AIExecutionPolicy
    init(timeline: AIFileTimeline, executor: AICommandExecutor, policy: @escaping () -> AIExecutionPolicy) { self.timeline = timeline; self.executor = executor; self.policy = policy }
    func inspect(_ entry: AIFileTimeline.Entry) async {
        guard !busy else { return }; busy = true; defer { busy = false }; error = ""; message = ""; review = nil; proposals = []
        await closeBackend()
        do { states = try await timeline.inspect(entry, executor: executor, policy: policy()) }
        catch { self.error = error.localizedDescription; states = [:] }
    }
    func prepare(_ entry: AIFileTimeline.Entry, after: Bool, paths: Set<String>) async {
        guard !busy else { return }; busy = true; defer { busy = false }; review = nil; error = ""; message = ""; proposals = []
        await closeBackend()
        do {
            try timeline.reload()
            guard timeline.matches(entry, executor), timeline.entries.contains(where: { $0.id == entry.id }), !paths.isEmpty, paths.isSubset(of: Set(entry.files.map(\.path))), let open = executor.fileBackend else { throw AIModelError.invalidReply }
            backend = try await open()
            for file in entry.files where paths.contains(file.path) {
                try AIFileTimeline.permission(path: file.path, executor: executor, policy: policy(), write: false)
                try AIFileTimeline.permission(path: file.path, executor: executor, policy: policy(), write: true)
                let stat = try await backend!.stat(file.path)
                guard stat.size <= 65536, !stat.symlink, !stat.directory, stat.permissions == file.permissions || stat.permissions == file.permissions & 0o777 else { throw AIModelError.invalidReply }
                let current = try await ExternalEdit.read(stat, from: backend!)
                guard timeline.knownVersion(current, path: file.path, entry: entry) else { throw AppFailure.message("File has newer edits; reopen and compare / 文件存在更新修改，请重新打开比较：" + file.path) }
                let desired = after ? file.after : file.before
                if current != desired { proposals.append(try await AIFileProposal(backend: backend!, path: file.path, find: String(decoding: current, as: UTF8.self), replacement: String(decoding: desired, as: UTF8.self), wholeFile: true)) }
            }
            guard !proposals.isEmpty else { message = "Files already match this version / 文件已是所选版本"; await closeBackend(); return }
            review = try AIChangeReview(proposals: proposals)
        } catch { self.error = error.localizedDescription; await closeBackend() }
    }
    func apply(origin: AIFileTimeline.Entry, completed: ([String]) throws -> Void) async {
        guard !busy, let review, review.valid else { return }; busy = true; defer { busy = false }; error = ""
        do {
            try review.update(proposals)
            for p in proposals { try AIFileTimeline.permission(path: p.path, executor: executor, policy: policy(), write: true); try await p.checkOriginal() }
            let id = try timeline.begin(proposals: proposals, executor: executor, taskID: origin.taskID, title: "Restore / 恢复 · " + origin.title, origin: origin.id)
            do {
                let result = try await AIProjectEdit(proposals: proposals).apply { path in try AIFileTimeline.permission(path: path, executor: self.executor, policy: self.policy(), write: true) }
                try timeline.finish(id, state: "applied")
                states = [:]
                for file in origin.files {
                    if let proposal = proposals.first(where: { $0.path == file.path }) {
                        let current = Data(try proposal.reviewedText().utf8)
                        states[file.path] = current == file.before ? "before" : current == file.after ? "after" : "recorded"
                    }
                }
                try completed(proposals.map(\.path)); message = "Restored and byte-verified; task goal needs fresh checks / 已恢复并校验字节，任务目标需重新验收\n" + AIContext.sanitize(result.output)
                self.review = nil
            } catch { try? timeline.finish(id, state: "pending"); throw error }
        } catch { self.error = AIContext.sanitize(error.localizedDescription) }
        if !error.isEmpty { self.review = nil }
        await closeBackend()
    }
    func closeBackend() async { if let remote = backend as? RemoteFiles { try? await remote.close() }; backend = nil }
}
