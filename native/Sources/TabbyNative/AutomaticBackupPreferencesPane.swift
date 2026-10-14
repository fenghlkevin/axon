import AppKit
import SwiftUI

struct AutomaticBackupPreferencesPane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var coordinator: AutomaticBackupCoordinator
    @Binding var password: String
    @Binding var includeSecrets: Bool
    var createNewFile = false
    @State private var settings = AutomaticBackupSettings()
    @State private var saved = AutomaticBackupSettings()
    @State private var savedPassword = ""
    @State private var loaded = false
    @State private var readable = false
    @State private var message = ""
    @State private var failed = false

    private var canSave: Bool {
        readable && !coordinator.isRunning && (!settings.isEnabled || password.count >= 8)
    }
    private var canRun: Bool {
        readable && saved.isEnabled && settings == saved && password.count >= 8 && password == savedPassword
            && includeSecrets == saved.includeSecrets && !coordinator.isRunning
    }
    var body: some View {
        BackupCard(title: store.text("Automatic backup", "自动备份"), symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.text("Create an encrypted backup in the background once after each app launch. Configure either or both destinations. The new-file option above retains each run; otherwise Axon-latest.axonbackup is updated.", "每次启动 Axon 后，在后台备份一次。两个目标可单独或同时启用；上方开启“每次备份生成新文件”可保留每次备份；关闭时更新 Axon-latest.axonbackup。" )).foregroundStyle(Palette.muted)
                Toggle(store.text("Back up to iCloud / synced folder on startup", "启动后自动备份到 iCloud / 同步文件夹"), isOn: $settings.folderEnabled).toggleStyle(AxonCheckboxStyle())
                    .accessibilityIdentifier("axon-auto-folder-enabled")
                if settings.folderEnabled {
                    HStack(spacing: 12) {
                        Text(settings.folderPath.isEmpty ? store.text("No backup folder selected", "尚未选择备份文件夹") : settings.folderPath)
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("axon-auto-folder-path")
                        Spacer(minLength: 0)
                        action(store.text("Choose folder…", "选择文件夹…"), "axon-auto-folder-choose", enabled: readable, run: chooseFolder)
                    }
                }
                Toggle(store.text("Upload to S3 on startup", "启动后自动上传到 S3"), isOn: $settings.s3Enabled).toggleStyle(AxonCheckboxStyle())
                    .accessibilityIdentifier("axon-auto-s3-enabled")
                if settings.s3Enabled {
                    Text(store.text("Automatic S3 object: ", "S3 自动备份对象：") + settings.s3Prefix + "/" + (createNewFile ? store.text("Axon-<timestamp>-<id>.axonbackup", "Axon-<时间>-<标识>.axonbackup") : AutomaticBackupPersistence.filename()))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("axon-auto-s3-object")
                }
                Text(store.text("Uses the password and credential option above. Changes apply automatically; disabling both removes the remembered password.", "共用上方的密码和携带凭据选项。有效配置自动保存；关闭两个目标会移除记住的密码。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
                if settings.isEnabled && !canSave && !coordinator.isRunning {
                    Text(store.text("Enter at least 8 characters in the backup password above to enable automatic backup.", "启用自动备份需在上方填写至少 8 位备份密码。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 10) {
                    action(store.text("Back up now", "立即备份"), "axon-auto-run", enabled: canRun) {
                        guard canRun else { return }
                        coordinator.runNow()
                    }
                    if !readable {
                        action(store.text("Retry settings", "重新读取设置"), "axon-auto-retry", run: load)
                    }
                }
                if !message.isEmpty {
                    Text(message).foregroundStyle(failed ? .red : Palette.blue).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("axon-auto-settings-result")
                }
            }.disabled(coordinator.isRunning)
            if coordinator.isRunning {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(store.text("Backing up…", "正在自动备份…"))
                    action(store.text("Cancel backup", "取消备份"), "axon-auto-cancel", run: coordinator.cancel)
                }
            }
            if let message = coordinator.report.generalMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("axon-auto-status")
            }
            if let folder = coordinator.report.folder { status(folder, title: store.text("iCloud / folder", "iCloud / 文件夹"), id: "axon-auto-folder-status") }
            if let s3 = coordinator.report.s3 { status(s3, title: "S3", id: "axon-auto-s3-status") }
            if coordinator.report.lastAttemptAt == nil {
                Text(store.text("No automatic backup has run yet. Use Back up now to verify the destinations.", "尚未执行自动备份。可点击“立即备份”检查目标。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Text(store.text("Folder backup completion means the file was saved locally; macOS handles iCloud upload. Offline or unavailable destinations are reported here, and are tried again at the next launch or with Back up now.", "文件夹备份完成表示文件已在本机保存，iCloud 上传由 macOS 处理。网络或文件夹不可用时，会在这里显示失败，下次启动或点击“立即备份”会再次尝试。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.onAppear { if !loaded { load(); loaded = true } }
            .onChange(of: settings) { _, _ in autoSave() }
            .onChange(of: password) { _, _ in autoSave() }
            .onChange(of: includeSecrets) { _, _ in autoSave() }
            .onChange(of: coordinator.isRunning) { _, running in if !running { autoSave() } }

    }

    private func status(_ value: AutomaticBackupTargetStatus, title: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title + " · " + value.completedAt.formatted(date: .numeric, time: .standard))
                .font(.system(size: 12, weight: .semibold))
            Text(value.message).foregroundStyle(value.succeeded ? Palette.blue : .red)
            if !value.location.isEmpty { Text(value.location).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }
    private func action(_ title: String, _ identifier: String, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        PreferencesActionButton(title: title, identifier: identifier, enabled: enabled, action: run).frame(width: 144, height: 38)
    }
    private func load() {
        do {
            settings = try AutomaticBackupPersistence.load(workspaceURL: store.fileURL)
            saved = settings; readable = true; savedPassword = ""; message = ""; failed = false
            do {
                if settings.isEnabled { savedPassword = try Secrets.readChecked(settings.passwordID, allowInteraction: false) }
            }
            catch {
                message = store.text("The saved password is temporarily unavailable. Unlock Keychain, then reopen this page or enter the backup password above to apply changes.", "暂时无法读取已保存的密码。解锁钥匙串后重新打开此页面，或在上方填写备份密码以自动应用。")
                failed = true
            }
        } catch { readable = false; show(error) }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = store.text("Select backup folder", "选择备份文件夹")
        let cloud = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: cloud.path) { panel.directoryURL = cloud }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let selection = try AutomaticBackupPersistence.chooseFolder(url)
            settings.folderBookmark = selection.bookmark; settings.folderPath = selection.path
            message = ""; failed = false
        } catch { show(error) }
    }
    private func autoSave() {
        guard loaded, readable else { return }
        var updated = settings; updated.includeSecrets = includeSecrets
        guard updated != saved || (updated.isEnabled && password != savedPassword) else { return }
        save()
    }
    private func save() {
        guard canSave else { return }
        do {
            var updated = settings
            updated.includeSecrets = includeSecrets
            let cleanupMessage = try AutomaticBackupPersistence.save(updated, password: password, workspaceURL: store.fileURL)
            settings = updated; saved = updated; savedPassword = updated.isEnabled ? password : ""; failed = false
            message = cleanupMessage ?? store.text("Automatic backup settings saved. Enabled destinations will run at the next launch, or use Back up now.", "自动备份设置已保存。启用的目标会在下次启动后备份，也可点击“立即备份”。")
        } catch { show(error) }
    }
    private func show(_ error: Error) { message = error.localizedDescription; failed = true }
}
