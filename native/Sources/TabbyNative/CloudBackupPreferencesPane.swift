import Foundation
import AppKit
import SwiftUI

struct CloudConnectionSettings: Codable, Equatable {
    var id = UUID()
    var s3 = S3BackupConfiguration()
    var createNewFile = false
    init(id: UUID = UUID(), s3: S3BackupConfiguration = S3BackupConfiguration(), createNewFile: Bool = false) { self.id = id; self.s3 = s3; self.createNewFile = createNewFile }
    enum CodingKeys: String, CodingKey { case id, s3, createNewFile }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        s3 = try values.decode(S3BackupConfiguration.self, forKey: .s3)
        createNewFile = try values.decodeIfPresent(Bool.self, forKey: .createNewFile) ?? false
    }
}

enum CloudConnectionPersistence {
    static func url(workspaceURL: URL) -> URL { workspaceURL.deletingLastPathComponent().appendingPathComponent("cloud-backup.json") }
    static func load(workspaceURL: URL) throws -> CloudConnectionSettings {
        let file = url(workspaceURL: workspaceURL)
        guard FileManager.default.fileExists(atPath: file.path) else { return CloudConnectionSettings() }
        return try JSONDecoder().decode(CloudConnectionSettings.self, from: WorkspaceTransfer.read(file))
    }
    static func saveMetadata(_ settings: CloudConnectionSettings, workspaceURL: URL) throws {
        let file = url(workspaceURL: workspaceURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func save(_ settings: CloudConnectionSettings, secret: String, workspaceURL: URL) throws {
        let old = try Secrets.readCredential(settings.id)
        let file = url(workspaceURL: workspaceURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Secrets.saveCredential(Secrets.Value(secret: secret), id: settings.id)
        do { try saveMetadata(settings, workspaceURL: workspaceURL) }
        catch { try? Secrets.saveCredential(old, id: settings.id); throw error }
    }
}

struct CloudBackupPreferencesPane: View {
    @EnvironmentObject var store: AppStore
    @State private var settings = CloudConnectionSettings()
    @State private var secret = ""
    @State private var password = ""
    @State private var includeSecrets = false
    @State private var loaded = false
    @State private var credentialReadable = true
    @State private var busy = false
    @State private var settingsReadable = false
    @State private var persistedSettings = CloudConnectionSettings()
    @State private var persistedSecret = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var catalog: [BackupCatalogEntry] = []
    @State private var catalogShown = false
    @State private var catalogFolder: URL?
    @State private var catalogConfiguration: S3BackupConfiguration?
    @State private var catalogSecret = ""
    @State private var catalogSource = ""
    @State private var selectedBackup: BackupCatalogEntry?
    @State private var operation: Task<Void, Never>?
    @State private var message = ""
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BackupCard(title: store.text("Encrypted backup", "加密备份"), symbol: "lock.shield") {
                PreferencesSecureField(title: store.text("Backup password (at least 8 characters)", "备份密码（至少 8 位）"), text: $password, identifier: "axon-cloud-password", chinese: store.chinese).appInput()
                Toggle(store.text("Create a new file for every backup", "每次备份生成新文件"), isOn: $settings.createNewFile).toggleStyle(AxonCheckboxStyle()).accessibilityIdentifier("axon-cloud-new-file")
                Text(store.text("Applies to manual and automatic backups. New files include a timestamp and unique ID; older backups are retained.", "同时用于手动和自动备份；新文件名包含时间和唯一标识，保留历史备份。关闭时自动备份更新固定的最新文件。" )).font(.caption).foregroundStyle(Palette.muted)
                Toggle(store.text("Include passwords and pasted private keys", "携带密码与粘贴的私钥"), isOn: $includeSecrets).toggleStyle(AxonCheckboxStyle())
                    .accessibilityIdentifier("axon-cloud-include-secrets")
                Text(store.text("Manual and automatic backups share this password and credential option. Backups are encrypted locally; the password is never sent to storage. Enabling automatic backup remembers it in this Mac's Keychain. Restore asks for the original backup password separately. Private-key files, logs and recent history are excluded.", "手动与自动备份共用这里的密码和携带凭据选项。备份先在本机加密，密码不发送给存储服务；启用自动备份且配置有效后，会记在本机钥匙串中。恢复时单独输入原备份密码。私钥文件不复制，日志和最近记录不备份。" )).foregroundStyle(Palette.muted)
                if busy { ProgressView().controlSize(.small) }
                if !message.isEmpty { Text(message).foregroundStyle(failed ? .red : Palette.blue).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("axon-cloud-result") }
            }
            .disabled(busy)
            BackupCard(title: "iCloud Drive", symbol: "icloud") {
                Text(store.text("Save to iCloud Drive without an Apple developer membership; macOS handles file syncing. Use the buttons for manual backup, or enable a startup backup below. Backups do not merge workspaces automatically.", "保存到 iCloud Drive 无需 Apple 开发者会员，文件同步由 macOS 完成。这里可以手动备份，也可在下方开启启动后自动备份。备份不会自动合并工作区。" )).foregroundStyle(Palette.muted)
                HStack(spacing: 10) {
                    action(store.text("Save to folder…", "保存到文件夹…"), "axon-cloud-folder-save", enabled: password.count >= 8 && !busy, run: saveFolder)
                    action(store.text("Choose backup…", "选择备份恢复…"), "axon-cloud-folder-restore", enabled: !busy, run: restoreFolder)
                }
                Text(store.text("Enable iCloud Drive in macOS first. You may also choose a local, Dropbox or other synced folder. Native CloudKit integration requires an Apple Developer Program membership.", "请先在 macOS 中启用 iCloud Drive；也可选择本地或其他网盘同步文件夹。原生 CloudKit 接入需要 Apple Developer Program 会员。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            BackupCard(title: store.text("S3-compatible storage", "S3 兼容存储"), symbol: "externaldrive.badge.icloud") {
                Text(store.text("AWS S3, Qiniu S3 API or another provider with SigV4 and conditional PUT support. Create a private bucket and use its S3 endpoint.", "可使用 AWS S3、七牛 S3 API 或支持 SigV4 与条件 PUT 的服务。请创建私有存储空间并填写其 S3 Endpoint。" )).foregroundStyle(Palette.muted)
                HStack(spacing: 10) {
                    action(store.text("Qiniu East China", "七牛华东预设"), "axon-cloud-qiniu", enabled: !busy) {
                        settings.s3.endpoint = "https://s3.cn-east-1.qiniucs.com"; settings.s3.region = "cn-east-1"
                    }
                    action(store.text("New backup key", "生成新备份路径"), "axon-cloud-new-key", enabled: !busy) { settings.s3.objectKey = "Axon/" + BackupPresentation.filename() }
                }
                field("Endpoint", $settings.s3.endpoint, "https://s3.cn-east-1.qiniucs.com")
                field(store.text("Region", "区域"), $settings.s3.region, "cn-east-1")
                field(store.text("Bucket", "存储空间"), $settings.s3.bucket, store.text("S3 bucket name", "S3 空间名"))
                field(store.text("Object key", "备份路径"), $settings.s3.objectKey, "Axon/backup.axonbackup")
                field("Access Key ID", $settings.s3.accessKeyID, "AK")
                HStack(spacing: 12) { Text("Secret Access Key").foregroundStyle(Palette.muted).frame(width: 125, alignment: .leading); PreferencesSecureField(title: "SK", text: $secret, identifier: "axon-cloud-secret", chinese: store.chinese).appInput() }
                HStack(spacing: 10) {
                    action(store.text("Upload backup", "上传备份"), "axon-cloud-upload", prominent: true, enabled: !busy && credentialReadable && password.count >= 8 && !secret.isEmpty, run: upload)
                    action(store.text("List backups…", "查看备份列表…"), "axon-cloud-download", enabled: !busy && credentialReadable && !secret.isEmpty, run: download)
                }
                if !credentialReadable { action(store.text("Retry Keychain", "重试读取钥匙串"), "axon-cloud-retry", run: load) }
                Text(store.text("Connection changes are saved automatically; Secret Access Key stays in macOS Keychain. Restore lists backups in this bucket, then downloads only the selected backup. Listing requires bucket list permission.", "连接字段修改后自动保存；SK 仅存入 macOS 钥匙串。恢复先展示空间中的备份列表，仅下载所选备份；需拥有列举空间对象的权限。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.disabled(busy)
            AutomaticBackupPreferencesPane(coordinator: store.automaticBackup, password: $password, includeSecrets: $includeSecrets, createNewFile: settings.createNewFile).disabled(busy)
        }.onAppear { if !loaded { load(); loadBackupOptions(); loaded = true } }
            .onChange(of: settings) { _, _ in scheduleSave() }
            .onChange(of: secret) { _, _ in scheduleSave() }
            .onDisappear { saveTask?.cancel(); persistDraft(); operation?.cancel() }
            .sheet(isPresented: $catalogShown, onDismiss: restoreSelection) {
                BackupCatalogView(entries: catalog, source: catalogSource, restore: { selectedBackup = $0; catalogShown = false }, cancel: { selectedBackup = nil; catalogShown = false }).environmentObject(store)
            }
    }
    private func field(_ title: String, _ value: Binding<String>, _ placeholder: String) -> some View {
        HStack(spacing: 12) { Text(title).foregroundStyle(Palette.muted).frame(width: 125, alignment: .leading); TextField(placeholder, text: value).appInput().accessibilityIdentifier("axon-cloud-field-" + title) }
    }
    private func action(_ title: String, _ id: String, prominent: Bool = false, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        PreferencesActionButton(title: title, identifier: id, prominent: prominent, enabled: enabled, action: run).frame(maxWidth: .infinity).frame(height: 38).disabled(!enabled)
    }
    private func load() {
        do {
            let saved = try CloudConnectionPersistence.load(workspaceURL: store.fileURL)
            settings = saved; persistedSettings = saved; settingsReadable = true
            secret = try Secrets.readChecked(saved.id); persistedSecret = secret; credentialReadable = true
        } catch { credentialReadable = false; show(error) }
    }
    private func loadBackupOptions() {
        do {
            let saved = try AutomaticBackupPersistence.load(workspaceURL: store.fileURL)
            includeSecrets = saved.includeSecrets
            if saved.isEnabled { password = try Secrets.readChecked(saved.passwordID, allowInteraction: false) }
        } catch { show(error) }
    }
    private func saveConnection() {
        do {
            _ = try settings.s3.objectURL()
            if secret.isEmpty { try CloudConnectionPersistence.saveMetadata(settings, workspaceURL: store.fileURL) }
            else { try CloudConnectionPersistence.save(settings, secret: secret, workspaceURL: store.fileURL) }
            success(store.text("Connection saved; Secret Access Key is in Keychain.", "连接配置已保存，SK 已存入钥匙串。"))
        } catch { show(error) }
    }
    private func scheduleSave() {
        guard loaded, settingsReadable else { return }
        saveTask?.cancel()
        do {
            if settings != persistedSettings { try CloudConnectionPersistence.saveMetadata(settings, workspaceURL: store.fileURL); persistedSettings = settings }
        } catch { show(error) }
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); persistDraft() } catch {}
        }
    }
    private func persistDraft() {
        guard loaded, settingsReadable else { return }
        do {
            if settings != persistedSettings { try CloudConnectionPersistence.saveMetadata(settings, workspaceURL: store.fileURL); persistedSettings = settings }
            if credentialReadable && !secret.isEmpty && secret != persistedSecret {
                try CloudConnectionPersistence.save(settings, secret: secret, workspaceURL: store.fileURL); persistedSecret = secret
            }
        } catch { show(error) }
    }
    private func saveFolder() {
        guard password.count >= 8 && !busy else { return }
        let url: URL
        if settings.createNewFile {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            url = folder.appendingPathComponent(BackupNaming.filename())
        } else {
            let panel = NSSavePanel(); panel.nameFieldStringValue = AutomaticBackupPersistence.filename()
            guard panel.runModal() == .OK, let file = panel.url else { return }; url = file
        }
        do { try AutomaticBackupPersistence.writeBackup(store.archiveData(password: password, includeSecrets: includeSecrets), to: url, overwrite: !settings.createNewFile); success(store.text("Encrypted backup saved: ", "加密备份已保存：") + url.lastPathComponent) }
        catch { show(error) }
    }
    private func restoreFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = store.text("List backups", "展示备份列表")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { catalog = try BackupNaming.localEntries(folder); catalogFolder = folder; catalogConfiguration = nil; catalogSource = folder.path; selectedBackup = nil; catalogShown = true }
        catch { show(error) }
    }
    private func restoreSelection() {
        guard let entry = selectedBackup else { return }; selectedBackup = nil
        if let folder = catalogFolder {
            do { try restore(WorkspaceTransfer.read(folder.appendingPathComponent(entry.key))) } catch { show(error) }
        } else if var configuration = catalogConfiguration {
            configuration.objectKey = entry.key
            let client = S3BackupClient(configuration: configuration, secretAccessKey: catalogSecret)
            busy = true
            operation = Task { @MainActor in
                defer { busy = false; operation = nil }
                do { let data = try await client.download(); try Task.checkCancellation(); try restore(data) } catch { show(error) }
            }
        }
    }
    private func upload() {
        guard password.count >= 8 && !busy && credentialReadable && !secret.isEmpty else { return }
        do {
            let data = try store.archiveData(password: password, includeSecrets: includeSecrets)
            var configuration = settings.s3
            if settings.createNewFile { configuration.objectKey = BackupNaming.key(from: configuration.objectKey) }
            let client = S3BackupClient(configuration: configuration, secretAccessKey: secret)
            busy = true; message = ""
            operation = Task { @MainActor in
                defer { busy = false; operation = nil }
                do { try await client.upload(data); success(store.text("Encrypted backup uploaded to \(configuration.objectKey)", "加密备份已上传到 \(configuration.objectKey)")) }
                catch { show(error) }
            }
        } catch { show(error) }
    }
    private func download() {
        let configuration = settings.s3, savedSecret = secret
        let client = S3BackupClient(configuration: configuration, secretAccessKey: savedSecret)
        busy = true; message = ""
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do {
                catalog = try await client.listBackups(); try Task.checkCancellation()
                catalogFolder = nil; catalogConfiguration = configuration; catalogSecret = savedSecret
                catalogSource = configuration.bucket; selectedBackup = nil; catalogShown = true
            } catch { show(error) }
        }
    }
    private func restore(_ data: Data) throws {
        guard WorkspaceArchiveCodec.isEncrypted(data) else { throw AppFailure.message(store.text("Cloud restore requires an encrypted Axon backup. Use Import & Export for plain local backups.", "云恢复需要加密的 Axon 备份；普通本地备份请从“导入与导出”恢复。")) }
        guard let archive = try BackupPresentation.decodeForRestore(data, chinese: store.chinese) else { return }
        guard BackupPresentation.confirmRestore(archive, store: store) else { return }
        try store.restoreArchive(archive); success(store.text("Workspace restored; original local configuration was backed up.", "工作区已恢复，原本地配置已备份。"))
    }
    private func success(_ text: String) { message = text; failed = false }
    private func show(_ error: Error) { message = error.localizedDescription; failed = true }
}
