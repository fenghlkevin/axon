import Foundation
import CryptoKit

struct AIProjectReplacement: Codable {
    let path: String
    let find: String
    let replacement: String
    static func decode(_ argument: String) throws -> [Self] {
        let items = try JSONDecoder().decode([Self].self, from: Data(argument.utf8))
        guard (1...8).contains(items.count), Set(items.map(\.path)).count == items.count,
              items.allSatisfy({ $0.path.hasPrefix("/") && (try? TerminalDirectoryBridge.normalizedPath($0.path)) == $0.path && !$0.find.isEmpty && $0.find != $0.replacement && !$0.find.contains("[REDACTED]") && !$0.replacement.contains("[REDACTED]") }) else { throw AIModelError.invalidReply }
        return items
    }
}

struct AIFileCheckpoint: Codable {
    let path: String
    let before: String
    let after: String
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

@MainActor final class AIProjectEdit {
    let proposals: [AIFileProposal]
    var preview: String { proposals.map { $0.path + "\n" + $0.preview }.joined(separator: "\n\n") }
    var checkpoints: [AIFileCheckpoint] { proposals.map(\.checkpoint).filter { $0.before != $0.after } }
    init(backend: any FileEndpoint, changes: [AIProjectReplacement]) async throws {
        var prepared: [AIFileProposal] = []
        for change in changes {
            prepared.append(try await AIFileProposal(backend: backend, path: change.path, find: change.find, replacement: change.replacement))
        }
        proposals = prepared
    }
    init(proposals: [AIFileProposal]) { self.proposals = proposals }
    func apply(beforeEach: ((String) throws -> Void)? = nil) async throws -> AICommandResult {
        struct Staged { let proposal: AIFileProposal; let temporary: String; let backup: String; var backed = false; var written = false }
        let id = UUID().uuidString
        var stages: [Staged] = []
        do {
            // Prepare and verify every temporary file before any original is renamed.
            for proposal in proposals {
                try Task.checkCancellation(); try beforeEach?(proposal.path); try await proposal.checkOriginal()
                let bytes = try Data(contentsOf: proposal.edit.localURL)
                if bytes == Data(proposal.originalText.utf8) { continue }
                let temporary = proposal.path + ".tabby-" + id, backup = proposal.path + ".backup-" + id
                stages.append(Staged(proposal: proposal, temporary: temporary, backup: backup))
                let metadata = try await proposal.edit.backend.stat(proposal.path)
                try await proposal.edit.backend.write(temporary, offset: 0, bytes: bytes)
                try await proposal.edit.backend.chmod(temporary, metadata.permissions & 0o777)
                let staged = try await proposal.edit.backend.stat(temporary)
                guard try await ExternalEdit.read(staged, from: proposal.edit.backend) == bytes else { throw AppFailure.message("Staging verification failed / 暂存内容校验失败") }
            }
            for proposal in proposals { try await proposal.checkOriginal() }
            for index in stages.indices {
                let stage = stages[index]; try Task.checkCancellation(); try beforeEach?(stage.proposal.path); try await stage.proposal.checkOriginal()
                try await stage.proposal.edit.backend.rename(stage.proposal.path, stage.backup); stages[index].backed = true
                stage.proposal.edit.backupPath = stage.backup
                let backed = try await stage.proposal.edit.backend.stat(stage.backup)
                guard AIFileCheckpoint.digest(try await ExternalEdit.read(backed, from: stage.proposal.edit.backend)) == stage.proposal.checkpoint.before else { throw AppFailure.message("Original changed during commit / 提交期间原文件已改变") }
                try await stage.proposal.edit.backend.rename(stage.temporary, stage.proposal.path); stages[index].written = true
                let current = try await stage.proposal.edit.backend.stat(stage.proposal.path)
                guard AIFileCheckpoint.digest(try await ExternalEdit.read(current, from: stage.proposal.edit.backend)) == stage.proposal.checkpoint.after else { throw AppFailure.message("Written bytes failed verification / 写入内容校验失败") }
            }
            return AICommandResult(output: stages.map { "Applied and byte-verified: " + $0.proposal.path + "\nBackup: " + $0.backup }.joined(separator: "\n") + "\nGroup committed. Service recovery still requires goal checks.", exitCode: 0)
        } catch {
            let cause = error.localizedDescription
            // An unstructured task performs rollback even when the parent was cancelled.
            let recovery = await Task { @MainActor in
                var failures: [String] = []
                for stage in stages.reversed() {
                    do {
                        // A remote rename can succeed before the transport reports failure.
                        // Reconcile our unique backup rather than relying only on return flags.
                        if let backup = try? await stage.proposal.edit.backend.stat(stage.backup) {
                            guard !backup.symlink, !backup.directory else { throw AIModelError.invalidReply }
                            stage.proposal.edit.backupPath = stage.backup
                            if let current = try? await stage.proposal.edit.backend.stat(stage.proposal.path) {
                                guard AIFileCheckpoint.digest(try await ExternalEdit.read(current, from: stage.proposal.edit.backend)) == stage.proposal.checkpoint.after else { throw AppFailure.message("Concurrent edit: original backup preserved; do not overwrite / 并发修改，保留原文备份，不覆盖") }
                                try await stage.proposal.edit.backend.rename(stage.proposal.path, stage.temporary)
                            }
                            try await stage.proposal.edit.backend.rename(stage.backup, stage.proposal.path)
                        }
                        try await stage.proposal.checkOriginal()
                        if let entry = try? await stage.proposal.edit.backend.stat(stage.temporary) { try await stage.proposal.edit.backend.removeStagingFile(entry) }
                    } catch { failures.append(stage.proposal.path + " · Backup: " + stage.backup + " · " + error.localizedDescription) }
                }
                return failures
            }.value
            throw AppFailure.message(cause + (recovery.isEmpty ? "\nGroup failed; originals restored and verified. / 组修改失败，原文件已恢复并校验。" : "\nROLLBACK INCOMPLETE; inspect backups before continuing. / 恢复不完整，继续前请核对备份。\n" + recovery.joined(separator: "\n")))
        }
    }
}
