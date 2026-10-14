import SwiftUI
import AppKit

struct FileEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let entry: FileEntry
    let backend: any FileEndpoint
    let refresh: () async -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var originalBytes = Data()
    @State private var selection: TextSelection?
    @StateObject private var languageService = EditorLanguageService()
    @AppStorage("axon.editor.languageServer") private var languageServer = ""
    @AppStorage("axon.editor.languageServerArguments") private var languageArguments = "[]"
    @State private var languageBusy = false
    @State private var languageTask: Task<Void, Never>?
    @State private var loading = true
    @State private var saving = false
    @State private var error = ""
    init(entry: FileEntry, backend: any FileEndpoint, refresh: @escaping () async -> Void, languageDefaults: UserDefaults = .standard, service: EditorLanguageService? = nil) {
        self.entry = entry; self.backend = backend; self.refresh = refresh
        _languageServer = AppStorage(wrappedValue: "", "axon.editor.languageServer", store: languageDefaults)
        _languageArguments = AppStorage(wrappedValue: "[]", "axon.editor.languageServerArguments", store: languageDefaults)
        _languageService = StateObject(wrappedValue: service ?? EditorLanguageService())
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack { Label(entry.name, systemImage: "doc.text").font(.headline); Spacer(); Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if backend is LocalFiles { VStack(alignment: .leading, spacing: 4) {
                HStack { Text(store.text("Installed local language server (optional)", "本机语言服务（可选，需已安装）")).font(.caption).foregroundStyle(Palette.muted); Spacer(); Text(store.text("Arguments: JSON string array", "参数：JSON 字符串数组")).font(.caption).foregroundStyle(Palette.muted) }
                HStack {
                TextField(store.text("Installed language server executable", "已安装的语言服务可执行文件"), text: $languageServer).appInput().disabled(languageService.ready)
                Button(store.text("Choose", "选择")) { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK { languageServer = panel.url?.path ?? "" } }.buttonStyle(ChromeButtonStyle()).disabled(languageService.ready)
                TextField(store.text("Arguments (JSON array)", "参数（JSON 数组）"), text: $languageArguments).appInput().frame(width: 170).disabled(languageService.ready)
                Button(languageService.ready ? store.text("Disconnect", "断开") : store.text("Connect", "连接")) { if languageService.ready { languageService.stop() } else { connectLanguage() } }.buttonStyle(ChromeButtonStyle()).disabled(loading || languageBusy || languageServer.isEmpty).accessibilityIdentifier("axon-editor-language-connect")
            } } }
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $text, selection: $selection).scrollContentBackground(.hidden).background(Palette.card).font(.system(size: 14, design: .monospaced)).disabled(loading || saving).accessibilityIdentifier("axon-file-editor-text")
                if languageService.ready {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(store.text("Language service", "语言服务")).font(.caption); Spacer(); Button(store.text("Refresh", "刷新")) { refreshLanguage() }.buttonStyle(ChromeButtonStyle()).disabled(languageBusy) }
                        Button(store.text("Format draft", "格式化草稿")) { Task { languageBusy = true; defer { languageBusy = false }; do { let old = text; let value = try await languageService.format(old); guard text == old else { throw AppFailure.message("Document changed; formatting discarded / 文档已变化，已丢弃格式化结果") }; text = value } catch { self.error = error.localizedDescription } } }.buttonStyle(ChromeButtonStyle()).disabled(!languageService.formatting || languageBusy || saving).accessibilityIdentifier("axon-editor-format")
                        ScrollView { VStack(alignment: .leading, spacing: 8) {
                            Text(store.text("Diagnostics", "诊断")).font(.system(size: 12, weight: .semibold))
                            if languageService.diagnostics.isEmpty { Text(store.text("No diagnostics received", "尚无诊断消息")).font(.caption).foregroundStyle(Palette.muted) }
                            ForEach(languageService.diagnostics) { diagnostic in Button { select(diagnostic.range) } label: { HStack(alignment: .top) { Text(diagnostic.severity == 1 ? store.text("Error", "错误") : diagnostic.severity == 2 ? store.text("Warning", "警告") : store.text("Info", "信息")).foregroundStyle(diagnostic.severity == 1 ? Palette.danger : Palette.muted); Text("\(diagnostic.range.start.line + 1): " + diagnostic.message).foregroundStyle(Palette.text) }.font(.caption).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(AxonSurfaceButtonStyle()) }
                            Text(store.text("Symbols", "符号")).font(.system(size: 12, weight: .semibold))
                            ForEach(languageService.symbols) { symbol in Button { select(symbol.range) } label: { Text(symbol.name).font(.caption).padding(.leading, CGFloat(symbol.depth * 8)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(AxonSurfaceButtonStyle()) }
                        } }
                    }.padding(10).frame(width: 230).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            if !languageService.error.isEmpty { Text(languageService.error).font(.caption).foregroundStyle(Palette.danger) }
            Text(store.text("Optional installed local LSP server. Formatting changes only the draft; Save checks the original file and keeps a backup.", "可选接入已安装的本机 LSP 服务。格式化仅改草稿；保存检查原文件并保留备份。")).font(.caption).foregroundStyle(Palette.muted)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Palette.danger) }
            HStack {
                if loading || saving { ProgressView().controlSize(.small) }
                Text(store.text("UTF-8 text · 2 MB maximum", "UTF-8 文本 · 最大 2 MB")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle()).disabled(saving)
                Button(store.text("Save", "保存")) { Task { await save() } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(loading || saving || text == original).accessibilityIdentifier("axon-file-editor-save")
            }
        }.padding(20).background(Palette.sidebar).foregroundStyle(Palette.text).frame(width: 960, height: 700).task { await load() }.onChange(of: text) { _, _ in refreshLanguage() }.onDisappear { languageTask?.cancel(); languageService.stop() }
    }
    private func select(_ range: EditorLanguageService.Span) { do { selection = TextSelection(range: try EditorLanguageService.range(range, text: text)) } catch { self.error = store.text("Position is stale; refresh the document", "位置已过期，请刷新文档") } }
    private func connectLanguage() {
        guard backend is LocalFiles else { return }
        languageTask?.cancel()
        languageTask = Task { languageBusy = true; defer { languageBusy = false }; do {
            let arguments = try JSONDecoder().decode([String].self, from: Data(languageArguments.utf8))
            let ext = (entry.path as NSString).pathExtension.lowercased(); let language = ["swift":"swift", "py":"python", "js":"javascript", "ts":"typescript", "java":"java", "c":"c", "cpp":"cpp", "h":"c", "rs":"rust", "go":"go", "json":"json"][ext] ?? (ext.isEmpty ? "plaintext" : ext)
            try await languageService.start(executable: languageServer, arguments: arguments, path: entry.path, text: text, language: language)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } } }
    }
    private func refreshLanguage() {
        guard languageService.ready else { return }
        languageTask?.cancel()
        languageTask = Task { do { try await Task.sleep(for: .milliseconds(400)); try await languageService.synchronize(text); try await languageService.refreshSymbols() } catch { if !Task.isCancelled { self.error = error.localizedDescription } } }
    }
    func load() async {
        defer { loading = false }
        do {
            guard !entry.directory, !entry.symlink, entry.size <= 2 * 1024 * 1024 else { throw AppFailure.message(store.text("Choose a UTF-8 text file smaller than 2 MB", "请选择小于 2 MB 的 UTF-8 文本文件")) }
            var data = Data(); var offset: UInt64 = 0
            while offset < entry.size {
                let bytes = try await backend.read(entry.path, offset: offset, count: 256 * 1024)
                guard !bytes.isEmpty else { throw AppFailure.message("File changed while reading") }
                data.append(bytes); offset += UInt64(bytes.count)
                guard data.count <= 2 * 1024 * 1024 else { throw AppFailure.message("File too large") }
            }
            guard let content = String(data: data, encoding: .utf8), !content.contains("\0") else { throw AppFailure.message(store.text("Binary files cannot be edited", "无法编辑二进制文件")) }
            text = content; original = content; originalBytes = data
        } catch { self.error = error.localizedDescription }
    }
    func save() async {
        saving = true; defer { saving = false }
        let temp = entry.path + ".tabby-" + UUID().uuidString
        let backup = entry.path + ".backup-" + UUID().uuidString
        do {
            let current = try await backend.stat(entry.path)
            guard !current.symlink, !current.directory, current.size == entry.size, abs(current.modified.timeIntervalSince(entry.modified)) < 1 else { throw AppFailure.message(store.text("File changed. Reopen it before saving.", "文件已改变，请重新打开后保存。")) }
            guard try await ExternalEdit.read(current, from: backend) == originalBytes else { throw AppFailure.message("File contents changed; reopen before saving / 文件内容已改变，请重新打开后保存") }
            let data = Data(text.utf8)
            guard data.count <= 2 * 1024 * 1024 else { throw AppFailure.message("File too large") }
            if data.isEmpty { try await backend.write(temp, offset: 0, bytes: data) }
            var offset = 0
            while offset < data.count {
                let end = min(offset + 256 * 1024, data.count)
                try await backend.write(temp, offset: UInt64(offset), bytes: data.subdata(in: offset..<end)); offset = end
            }
            try await backend.chmod(temp, entry.permissions & 0o777)
            let staging = try await backend.stat(temp)
            guard try await ExternalEdit.read(staging, from: backend) == data else { throw AppFailure.message("Staged content verification failed / 暂存内容校验失败") }
            let final = try await backend.stat(entry.path)
            guard FileContentDigest.sameMetadata(current, final), try await ExternalEdit.read(final, from: backend) == originalBytes else { throw AppFailure.message("File changed before commit / 提交前文件已变化") }
            try await backend.rename(entry.path, backup)
            do { try await backend.rename(temp, entry.path) }
            catch { try? await backend.rename(backup, entry.path); throw error }
            let written = try await backend.stat(entry.path)
            guard try await ExternalEdit.read(written, from: backend) == data else { throw AppFailure.message("Written content verification failed. Backup: " + backup) }
            // Keep the backup beside the edited file so changes can be recovered.
            await refresh(); dismiss()
        } catch {
            if let partial = try? await backend.stat(temp) { try? await backend.removeStagingFile(partial) }
            self.error = error.localizedDescription
        }
    }
}
