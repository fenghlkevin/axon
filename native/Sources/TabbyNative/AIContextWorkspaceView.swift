import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AIContextAttachmentSummary: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var workspace: AIContextWorkspace
    let open: () -> Void
    private var count: Int { workspace.references.count + workspace.images.count + workspace.urls.count }
    var body: some View {
        if count > 0 {
            Button(action: open) { Label(store.text("\(count) context attachments", "\(count) 个上下文附件"), systemImage: "paperclip").font(.system(size: 11)).foregroundStyle(Palette.accent) }.buttonStyle(.plain).disabled(store.ai.busy).accessibilityIdentifier("axon-context-attachments")
        }
    }
}

struct AIContextWorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: AIContextWorkspace
    @ObservedObject var index: AIProjectIndex
    let executor: AICommandExecutor?
    @State private var root = ""
    @State private var query = ""
    @State private var path = ""
    @State private var start = 1
    @State private var end = 80
    @State private var url = ""
    @State private var error = ""
    @State private var busy = false
    private var projects: [AIProjectIndex.Project] { index.projects.filter { $0.endpoint == executor?.contextEndpoint } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.text("Context & projects", "上下文与项目")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityIdentifier("axon-context-close")
            }
            Text(store.text("Only selected references, images and bounded relevant excerpts are sent. Cached code is checked again before use.", "仅发送选中的引用、图片及有界相关片段；缓存代码在使用前重新核对。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(store.text("Projects on this target", "当前目标的项目")).font(.system(size: 13, weight: .semibold))
                    TextField(store.text("Absolute project directory", "项目绝对目录"), text: $root).appInput().accessibilityIdentifier("axon-context-project-path")
                    Button(store.text("Add project", "添加项目")) {
                        perform { guard let executor else { return }; try index.add(root: root, endpoint: executor.contextEndpoint) }
                    }.buttonStyle(ChromeButtonStyle()).disabled(executor == nil || busy || root.isEmpty).accessibilityIdentifier("axon-context-add-project")
                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Toggle(isOn: Binding(get: { index.project(project.id)?.enabled ?? false }, set: { value in perform { try index.enable(project.id, value) } })) { Text(project.root).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }.toggleStyle(AxonCheckboxStyle())
                                Spacer(minLength: 0)
                            }
                            Text(state(project.state) + " · \(project.documents.count) " + store.text("files", "文件")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            if !project.note.isEmpty { Text(project.note).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
                            HStack {
                                Button(store.text("Sync", "同步")) { sync(project.id, rebuild: false) }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-context-sync")
                                Button(store.text("Rebuild", "重建")) { sync(project.id, rebuild: true) }.buttonStyle(ChromeButtonStyle())
                                Spacer()
                                Button { perform { try index.remove(project.id) } } label: { Image(systemName: "trash") }.buttonStyle(.plain).help(store.text("Remove index", "移除索引"))
                            }.disabled(busy || index.syncing.contains(project.id))
                        }.padding(12).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(store.text("Each worktree is separate. Sync is bounded to 5,000 files, 2,000 excerpts and 32 MiB changed bytes; limited indexes are marked. English sentence embeddings run locally when available; source relationships are candidate references, not type-resolved calls.", "每个 worktree 独立索引。每次最多 5,000 文件、2,000 片段和 32 MiB 变更内容，达到上限会标明。可用时使用本机英文句向量；源码关系是候选引用，不代表类型解析后的调用。"))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text(store.text("@ File, directory, symbol or lines", "@ 文件、目录、符号或行范围")).font(.system(size: 13, weight: .semibold))
                    TextField(store.text("Find a file or symbol", "查找文件或符号"), text: $query).appInput().accessibilityIdentifier("axon-context-search")
                    if !query.isEmpty {
                        ForEach(Array(projects.flatMap { project in project.documents.filter { $0.path.localizedCaseInsensitiveContains(query) || $0.symbols.contains { $0.name.localizedCaseInsensitiveContains(query) } }.prefix(20).map { (project, $0) } }.prefix(30)), id: \.1.path) { project, document in
                            VStack(alignment: .leading, spacing: 5) {
                                Button { add(project, document.path, "file", 1, 80) } label: { Label(document.path, systemImage: "doc.text").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }.buttonStyle(.plain)
                                ForEach(document.symbols.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(8), id: \.line) { symbol in
                                    Button { add(project, document.path, "symbol", symbol.line, symbol.line + 39) } label: { Text("\(symbol.kind) \(symbol.name) · L\(symbol.line)").font(.system(size: 11)).foregroundStyle(Palette.accent) }.buttonStyle(.plain)
                                }
                            }.padding(8).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    TextField(store.text("Absolute file/directory path", "文件／目录绝对路径"), text: $path).appInput()
                    HStack {
                        Stepper(store.text("From \(start)", "起始 \(start)"), value: $start, in: 1...100000).font(.system(size: 11))
                        Stepper(store.text("To \(end)", "结束 \(end)"), value: $end, in: 1...100000).font(.system(size: 11))
                    }
                    HStack {
                        Button(store.text("Add lines", "添加行范围")) { manual("file") }.buttonStyle(ChromeButtonStyle())
                        Button(store.text("Add directory", "添加目录")) { manual("directory") }.buttonStyle(ChromeButtonStyle())
                    }.disabled(executor == nil || path.isEmpty || busy)
                    ForEach(workspace.references) { ref in removable(ref.label) { workspace.references.removeAll { $0.id == ref.id } } }
                    Divider()
                    Button { chooseImages() } label: { Label(store.text("Attach image", "添加图片"), systemImage: "photo") }.buttonStyle(ChromeButtonStyle()).disabled(busy).accessibilityIdentifier("axon-context-image")
                    Text(store.text("Up to four images. Re-encoded PNG without original metadata; sent to the selected model. Image recognition depends on the model.", "最多 4 张，转为不含原始元数据的 PNG；会发送给所选模型，识别能力取决于模型。"))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(workspace.images) { image in removable(image.name) { workspace.images.removeAll { $0.id == image.id } } }
                    Divider()
                    TextField(store.text("Public HTTPS page URL", "公开 HTTPS 网页地址"), text: $url).appInput().accessibilityIdentifier("axon-context-url")
                    Button(store.text("Attach URL", "引用网页")) { perform {
                        let checked = try AIWebContext.validate(url).absoluteString
                        guard workspace.urls.count < 4 else { throw AppFailure.message("Up to four URLs / 最多 4 个网页") }
                        if !workspace.urls.contains(checked) { workspace.urls.append(checked) }; url = ""
                    } }.buttonStyle(ChromeButtonStyle()).disabled(url.isEmpty || busy)
                    ForEach(workspace.urls, id: \.self) { item in removable(item) { workspace.urls.removeAll { $0 == item } } }
                    Text(store.text("Pages are fetched when sending, without login cookies; redirects are revalidated. Agent web_search returns source links; fetch_url reads the source. Pages never grant execution permission.", "发送时获取网页，不使用登录 Cookie，最多 3 次跳转并重新校验公开地址。Agent 可搜索来源链接并读取网页；网页内容不授予执行权限。"))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("axon-context-error") }
        }.padding(16).frame(minWidth: 300, idealWidth: 560, maxWidth: 620, minHeight: 500, idealHeight: 700, maxHeight: 800)
            .foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light)
            .onAppear { root = executor?.terminalBridge?.session?.currentDirectory ?? executor?.directory ?? "" }
    }
    private func removable(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack { Text(text).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true); Spacer(); Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityIdentifier("axon-context-remove-reference") }.padding(8).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func state(_ state: String) -> String { store.text(state, ["pending":"未索引", "synced":"已同步", "limited":"部分索引 · 已达上限", "syncing":"同步中", "failed":"同步失败", "stale":"待重新同步"][state] ?? state) }
    private func perform(_ block: () throws -> Void) { do { try block(); error = "" } catch { self.error = error.localizedDescription } }
    private func add(_ project: AIProjectIndex.Project, _ path: String, _ kind: String, _ start: Int, _ end: Int) { perform { try workspace.add(.init(endpoint: project.endpoint, root: project.root, path: path, kind: kind, start: start, end: end)) } }
    private func manual(_ kind: String) {
        perform {
            guard let executor, let project = projects.filter({ path == $0.root || path.hasPrefix($0.root + "/") }).max(by: { $0.root.count < $1.root.count }) else { throw AppFailure.message("Add the containing project first / 请先添加文件所在项目") }
            try workspace.add(.init(endpoint: executor.contextEndpoint, root: project.root, path: try TerminalDirectoryBridge.normalizedPath(path), kind: kind, start: start, end: end))
        }
    }
    private func sync(_ id: String, rebuild: Bool) {
        guard let executor else { return }; busy = true
        Task { defer { busy = false }; do { try await index.sync(id, executor: executor, policy: store.ai.settings.policy, rebuild: rebuild); error = "" } catch { self.error = error.localizedDescription } }
    }
    private func chooseImages() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.png, .jpeg, .webP]
        if panel.runModal() == .OK { perform { for url in panel.urls { try workspace.addImage(url) } } }
    }
}
