import SwiftUI

@MainActor final class FileBackupReview: ObservableObject {
    @Published var preview = ""
    @Published var error = ""
    @Published var busy = false
    @Published var ready = false
    private var edit: ExternalEdit?
    private var staging: URL?
    let backup: FileEntry
    let backend: any FileEndpoint
    init(backup: FileEntry, backend: any FileEndpoint) { self.backup = backup; self.backend = backend }
    static func originalPath(_ entry: FileEntry) throws -> String {
        guard !entry.symlink, !entry.directory, let marker = entry.path.range(of: ".backup-", options: .backwards), UUID(uuidString: String(entry.path[marker.upperBound...])) != nil else { throw AppFailure.message("Select an Axon backup file / 请选择 Axon 备份文件") }; return String(entry.path[..<marker.lowerBound])
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let original = try Self.originalPath(backup), target = try await backend.stat(original)
            let currentBackup = try await backend.stat(backup.path)
            guard FileContentDigest.sameMetadata(backup, currentBackup), backup.size <= 2 * 1024 * 1024, target.size <= 2 * 1024 * 1024 else { throw AppFailure.message("Backup changed or exceeds 2 MB / 备份已变化或超过 2 MB") }
            let bytes = try await ExternalEdit.read(currentBackup, from: backend)
            guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { throw AIModelError.invalidReply }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axon-restore-" + UUID().uuidString); staging = folder
            let edit = try await ExternalEdit.prepare(entry: target, backend: backend, directory: folder)
            let previous = try String(contentsOf: edit.localURL, encoding: .utf8)
            try bytes.write(to: edit.localURL, options: .atomic); edit.checkChanges(); self.edit = edit
            preview = EditDifferencePreview.make(old: previous, new: text); ready = edit.changed
        } catch { self.error = error.localizedDescription }
    }
    func restore() async -> Bool {
        guard ready, !busy, let edit else { return false }; busy = true; defer { busy = false }
        do { try await edit.upload(); let current = try await backend.stat(edit.remotePath); guard try await ExternalEdit.read(current, from: backend) == Data(contentsOf: edit.localURL) else { throw AppFailure.message("Restore byte verification failed / 恢复内容校验失败") }; ready = false; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    deinit { if let staging { try? FileManager.default.removeItem(at: staging) } }
}

struct FileBackupReviewSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject var review: FileBackupReview
    let refresh: () async -> Void
    init(backup: FileEntry, backend: any FileEndpoint, refresh: @escaping () async -> Void) { _review = StateObject(wrappedValue: FileBackupReview(backup: backup, backend: backend)); self.refresh = refresh }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Restore backup", "恢复备份")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() }.disabled(review.busy) }
            Text(review.backup.path).font(.caption).textSelection(.enabled)
            if review.busy { ProgressView().controlSize(.small) }
            ScrollView { Text(review.preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(12).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
            if !review.error.isEmpty { Text(review.error).font(.caption).foregroundStyle(Palette.danger) }
            Text(store.text("Checks the current original and creates a new backup before restoring. The selected backup is preserved. Plain UTF-8 files up to 2 MB.", "恢复前检查当前文件并另存一份新备份，所选备份保留。仅支持最大 2 MB 的普通 UTF-8 文件。")).font(.caption).foregroundStyle(Palette.muted)
            HStack { Spacer(); Button(store.text("Restore and verify", "恢复并校验")) { Task { if await review.restore() { await refresh(); dismiss() } } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!review.ready || review.busy).accessibilityIdentifier("axon-file-restore-backup") }
        }.padding(20).frame(width: 680, height: 520).background(Palette.background).foregroundStyle(Palette.text).task { await review.load() }
    }
}
