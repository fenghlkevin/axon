import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: FileManagerModel
    @State private var comparison: DirectoryComparisonModel?
    var body: some View {
        VStack(spacing: 0) {
            FileSplitView {
                FilePaneView(pane: model.local, model: model, remote: false, onCompare: compareDirectories)
            } right: {
                ZStack {
                    if model.showingHostPicker || model.remote == nil { SFTPHostPicker(model: model) }
                    else if let pane = model.remote { FilePaneView(pane: pane, model: model, remote: true) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ExternalEditTasksBar(center: store.externalEdits) { model.showExternalEdits = true }
            TransferQueuePanel(queue: model.queue)
        }.background(Palette.background).task(id: store.terminalFileRequest?.id) { await model.open() }
            .sheet(isPresented: $model.showExternalEdits) {
                ExternalEditSheet(center: store.externalEdits) { model.showExternalEdits = false }.environmentObject(store)
            }
            .sheet(item: $comparison) { DirectoryComparisonSheet(model: $0).environmentObject(store) }
    }
    private func compareDirectories() {
        if let target = model.remote {
            comparison = DirectoryComparisonModel(source: model.local, target: target, queue: model.queue, direction: model.rightIsLocal ? "copy" : "upload")
        }
    }
}

/// Every state uses exactly two bounded panes. A native HSplitView can retain
/// different divider constraints when its conditional right child is replaced.
struct FileSplitMetrics {
    let dividerWidth: CGFloat
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    var availableWidth: CGFloat { leftWidth + rightWidth }
    var visibleFraction: CGFloat { availableWidth > 0 ? leftWidth / availableWidth : 0.5 }
    init(width: CGFloat, fraction: CGFloat) {
        let width = max(0, width)
        dividerWidth = min(7, width)
        let available = width - dividerWidth
        let minimum = min(300, available / 2)
        leftWidth = min(max(available * fraction, minimum), available - minimum)
        rightWidth = available - leftWidth
    }
}

struct FileSplitView<Left: View, Right: View>: View {
    let left: Left
    let right: Right
    @State private var fraction: CGFloat = 0.5
    @State private var dragOrigin: CGFloat?
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left(); self.right = right()
    }
    var body: some View {
        GeometryReader { geometry in
            let metrics = FileSplitMetrics(width: geometry.size.width, fraction: fraction)
            HStack(spacing: 0) {
                left.frame(width: metrics.leftWidth, height: geometry.size.height).clipped()
                Rectangle().fill(Palette.background)
                    .overlay { Rectangle().fill(Palette.border).frame(width: 1) }
                    .frame(width: metrics.dividerWidth, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("file-split"))
                        .onChanged { value in
                            guard metrics.availableWidth > 0 else { return }
                            let origin = dragOrigin ?? metrics.leftWidth
                            dragOrigin = origin
                            let requested = (origin + value.translation.width) / metrics.availableWidth
                            fraction = FileSplitMetrics(width: geometry.size.width, fraction: requested).visibleFraction
                        }
                        .onEnded { _ in dragOrigin = nil })
                right.frame(width: metrics.rightWidth, height: geometry.size.height).clipped()
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .coordinateSpace(name: "file-split")
        }.clipped()
    }
}

struct FilePaneToolbarLayout {
    static let headerHeight: CGFloat = 52
    static let filterRowHeight: CGFloat = 40
    let compact: Bool
    let showsInlineFilter: Bool
    let showsFilterRow: Bool
    var height: CGFloat { Self.headerHeight + (showsFilterRow ? Self.filterRowHeight : 0) }
    init(width: CGFloat, showingFilter: Bool, filter: String) {
        compact = width < 520
        let expanded = showingFilter || !filter.isEmpty
        showsInlineFilter = expanded && !compact
        showsFilterRow = expanded && compact
    }
}

struct FilePaneView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var pane: FilePane
    @ObservedObject var model: FileManagerModel
    var remote: Bool
    var onCompare: (() -> Void)? = nil
    @State var editingPath = ""
    @State var editingFile: FileEntry?
    @State private var backupFile: FileEntry?
    @State private var developmentPresented = false
    @State private var showingFilter = false
    @State private var editingLocation = false
    @FocusState private var locationFocused: Bool
    var endpointIsRemote: Bool { remote && !model.rightIsLocal }
    var bookmarkKey: String { endpointIsRemote ? (model.rightHost?.id.uuidString ?? "remote") : "local" }
    var transferTitle: String { model.rightIsLocal ? (remote ? store.text("Copy to left", "复制到左侧") : store.text("Copy to right", "复制到右侧")) : (remote ? store.text("Download selected", "下载所选") : store.text("Upload selected", "上传所选")) }
    var compareTitle: String { model.rightIsLocal ? store.text("Compare left → right and copy", "比较左侧 → 右侧并复制") : store.text("Compare left → right and upload", "比较左侧 → 右侧并上传") }
    var body: some View {
        GeometryReader { geometry in
        let toolbar = FilePaneToolbarLayout(width: geometry.size.width, showingFilter: showingFilter, filter: pane.filter)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if remote {
                    Button { model.showHostPicker() } label: { HStack(spacing: 9) { IconTile(symbol: model.rightIsLocal ? "desktopcomputer" : "folder", color: model.rightIsLocal ? Palette.localTerminal : Palette.sftp, size: 26); Text(model.rightIsLocal ? store.text("Local", "本地") : (model.rightHost?.name ?? store.text("Remote", "远程"))).lineLimit(1).truncationMode(.tail).layoutPriority(-1); Image(systemName: "chevron.down").font(.system(size: 10)) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(StableHostPickerButtonStyle()).focusEffectDisabled().disabled(!model.canSwitchRight).help(store.text("Select host", "选择主机"))
                } else { HStack(spacing: 9) { IconTile(symbol: "terminal", color: Palette.localTerminal, size: 26); Text(store.text("Local", "本地")).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) }
                if toolbar.showsInlineFilter {
                    filterField.frame(width: 160)
                } else {
                    Button { showingFilter = true } label: {
                        if toolbar.compact { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }
                        else { Label(store.text("Filter", "筛选"), systemImage: "magnifyingglass") }
                    }.buttonStyle(FileToolbarButtonStyle()).fixedSize().help(store.text("Filter", "筛选")).accessibilityLabel(store.text("Filter", "筛选"))
                }
                AppActionMenu {
                    if let onCompare { Button(action: onCompare) { Label(compareTitle, systemImage: "arrow.left.arrow.right") }.disabled(!model.canTransfer) }
                    if !endpointIsRemote { Button { developmentPresented = true } label: { Label(store.text("Development tools…", "开发工具…"), systemImage: "chevron.left.forwardslash.chevron.right") }.accessibilityIdentifier("axon-file-development") }
                    Button(action: refreshPane) { Label(store.text("Refresh", "刷新"), systemImage: "arrow.clockwise") }
                    Button { Task { await pane.up() } } label: { Label(store.text("Parent folder", "上级目录"), systemImage: "arrow.up") }
                    Divider()
                    Button { createFile() } label: { Label(store.text("New file", "新建文件"), systemImage: "doc.badge.plus") }
                    Button { createDirectory() } label: { Label(store.text("New folder", "新建目录"), systemImage: "folder.badge.plus") }
                    Divider()
                    Button(store.text("Sort by name", "按名称排序")) { pane.sort = "name" }
                    Button(store.text("Sort by size", "按大小排序")) { pane.sort = "size" }
                    Button(store.text("Sort by modified date", "按修改时间排序")) { pane.sort = "modified" }
                } label: {
                    if toolbar.compact { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    else { Text(store.text("Actions", "操作")).padding(.horizontal, 6).frame(height: 32).contentShape(Rectangle()) }
                }.menuStyle(.borderlessButton).menuIndicator(toolbar.compact ? .hidden : .visible).fixedSize().tint(Palette.text).help(store.text("Actions", "操作")).accessibilityLabel(store.text("Actions", "操作")).accessibilityIdentifier(remote ? "axon-file-actions-right" : "axon-file-actions-local")
                if let onCompare {
                    Button(action: onCompare) { Image(systemName: "arrow.left.arrow.right.square") }
                        .buttonStyle(IconButtonStyle()).disabled(!model.canTransfer).help(compareTitle).accessibilityLabel(compareTitle)
                        .accessibilityIdentifier("axon-compare-directories")
                }
                AppActionMenu { ForEach(store.workspace.bookmarks[bookmarkKey] ?? [], id: \.self) { path in Button(path) { Task { await pane.navigate(path) } } }
                    Button(store.text("Bookmark current folder", "收藏当前目录")) {
                        if !(store.workspace.bookmarks[bookmarkKey] ?? []).contains(pane.path) { store.workspace.bookmarks[bookmarkKey, default: []].append(pane.path); store.save() }
                    }
                    Button(store.text("Remove current bookmark", "取消当前收藏")) { store.workspace.bookmarks[bookmarkKey]?.removeAll { $0 == pane.path }; store.save() }
                } label: { Image(systemName: "bookmark").frame(width: 32, height: 32).contentShape(Rectangle()).foregroundStyle(Palette.muted) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Palette.text)
                Button { pane.showHidden.toggle() } label: { Image(systemName: "eye").foregroundStyle(pane.showHidden ? Palette.accent : Palette.muted) }.buttonStyle(IconButtonStyle()).accessibilityValue(pane.showHidden ? store.text("Shown", "显示") : store.text("Hidden", "隐藏")).help(store.text("Show hidden files", "显示隐藏文件"))
            }.font(.system(size: 14)).foregroundStyle(Palette.text).padding(.horizontal, 16).frame(height: FilePaneToolbarLayout.headerHeight).background(Palette.sidebar)
            if toolbar.showsFilterRow {
                filterField.padding(.horizontal, 12).frame(height: 30).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16).frame(height: FilePaneToolbarLayout.filterRowHeight).background(Palette.sidebar)
            }
            HStack(spacing: 10) {
                Button { Task { await pane.back(-1) } } label: { Image(systemName: "chevron.left") }.disabled(pane.historyIndex <= 0)
                Button { Task { await pane.back(1) } } label: { Image(systemName: "chevron.right") }.disabled(pane.historyIndex >= pane.history.count - 1)
                if editingLocation {
                    TextField("/", text: $editingPath).appInput().focused($locationFocused).onSubmit { editingLocation = false; Task { await pane.navigate(editingPath) } }.onExitCommand { editingPath = pane.path; editingLocation = false }
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 9) {
                            Button("/") { Task { await pane.navigate("/") } }.buttonStyle(AxonSurfaceButtonStyle())
                            ForEach(Array(fileBreadcrumbs(pane.path).enumerated()), id: \.offset) { index, component in
                                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted) }
                                Button { Task { await pane.navigate(component.path) } } label: { HStack(spacing: 6) { Image(systemName: "folder.fill").foregroundStyle(Color(hex: "#65CDF5")); Text(component.name).lineLimit(1) } }.buttonStyle(AxonSurfaceButtonStyle())
                            }
                        }.padding(.vertical, 8)
                    }.scrollIndicators(.hidden)
                    Button { editingPath = pane.path; editingLocation = true; locationFocused = true } label: { Image(systemName: "pencil") }.help(store.text("Edit path", "编辑路径"))
                }
                Button(action: refreshPane) { Image(systemName: "arrow.clockwise") }
            }.font(.system(size: 13)).foregroundStyle(Palette.text).buttonStyle(IconButtonStyle()).padding(.horizontal, 12).frame(height: 46).background(Palette.sidebar)
            if remote && !model.status.isEmpty { Text(model.status).foregroundStyle(.orange).font(.caption).padding(8) }
            FileTableView(entries: pane.visible, path: pane.path, selection: $pane.selected,
                          columnTitles: [store.text("Name", "名称"), store.text("Modified", "修改时间"), store.text("Size", "大小"), store.text("Kind", "类型")],
                          folderTitle: store.text("Folder", "文件夹"), linkTitle: store.text("Link", "链接"), remote: endpointIsRemote,
                          onOpen: openEntry, onParent: { path in Task { await pane.navigate(path) } }, parentTitle: store.text("Parent folder", "上级目录"),
                          onSort: { pane.sort = $0 }, actions: fileActions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if pane.loading { ProgressView().padding(20).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8)).allowsHitTesting(false) } }
            .onDrop(of: [.fileURL, .plainText], isTargeted: nil, perform: receiveDrop)
            HStack { Text("\(pane.visible.count) " + store.text("items", "项")); Spacer(); Text("\(pane.selected.count) " + store.text("selected", "已选")) }.font(.caption).foregroundStyle(.secondary).padding(10)
        }.frame(width: geometry.size.width, height: geometry.size.height).background(Palette.background)
        .modifier(FilePaneErrorOverlay(pane: pane, width: geometry.size.width))
        }.onAppear { editingPath = pane.path }.onChange(of: pane.path) { _, path in editingPath = path }
        .sheet(isPresented: $developmentPresented) { GitWorkspaceSheet(directory: pane.path, registry: store.fileURL.deletingLastPathComponent().appendingPathComponent("git-worktrees.json")) { path in Task { await pane.navigate(path) } }.environmentObject(store) }
        .sheet(item: $backupFile) { entry in FileBackupReviewSheet(backup: entry, backend: pane.backend) { await pane.navigate(pane.path, record: false) }.environmentObject(store) }
        .sheet(item: $editingFile, onDismiss: { pane.busy = false }) { entry in FileEditor(entry: entry, backend: pane.backend, refresh: { await pane.navigate(pane.path, record: false) }).environmentObject(store) }
    }
    var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField(store.text("Filter", "筛选"), text: $pane.filter).textFieldStyle(.plain).frame(maxWidth: .infinity)
            Button { pane.filter = ""; showingFilter = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(AxonSurfaceButtonStyle()).foregroundStyle(Palette.muted).help(store.text("Clear filter", "清除筛选")).accessibilityLabel(store.text("Clear filter", "清除筛选"))
        }.font(.system(size: 14)).foregroundStyle(Palette.text)
    }
    func openEntry(_ entry: FileEntry) {
        if entry.directory && !entry.symlink { Task { await pane.navigate(entry.path) } }
        else if !endpointIsRemote { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
        else { model.transfer(false, entries: [entry]) }
    }
    func fileActions(_ selected: [FileEntry]) -> [FileTableAction] {
        guard let entry = selected.first else {
            var actions = [FileTableAction(title: store.text("Refresh", "刷新"), action: refreshPane),
                           FileTableAction(title: store.text("New file", "新建文件"), action: createFile),
                           FileTableAction(title: store.text("New folder", "新建目录"), action: createDirectory),
                           FileTableAction(title: store.text("Use this directory in terminal", "在终端中使用此目录"), action: { insertDirectory(pane.path) })]
            if let onCompare { actions.append(FileTableAction(title: compareTitle, enabled: model.canTransfer, action: onCompare)) }
            return actions
        }
        var actions = [FileTableAction(title: transferTitle, enabled: model.canTransfer, action: { model.transfer(!remote, entries: selected) })]
        if entry.directory && !entry.symlink {
            actions.append(FileTableAction(title: store.text("Use this directory in terminal", "在终端中使用此目录"), enabled: selected.count == 1, action: { insertDirectory(entry.path) }))
        }
        if !entry.directory && !entry.symlink {
            actions.append(FileTableAction(title: store.text("Follow log", "跟踪日志"), enabled: selected.count == 1,
                action: { store.openLogViewer(pane: pane, entry: entry, host: endpointIsRemote ? model.rightHost : nil) }))
            if (try? FileBackupReview.originalPath(entry)) != nil { actions.append(FileTableAction(title: store.text("Restore backup…", "恢复备份…"), enabled: selected.count == 1, action: { backupFile = entry })) }
            actions.append(FileTableAction(title: store.text("Edit externally…", "使用外部编辑器…"), enabled: selected.count == 1, action: {
                Task { do { try await store.externalEdits.open(entry: entry, pane: pane, host: pane === model.remote && !model.rightIsLocal ? model.rightHost : nil, username: pane === model.remote ? model.rightAuthenticatedUsername : nil); model.showExternalEdits = true } catch { store.error = error.localizedDescription; model.showExternalEdits = true } }
            }))
            actions.append(FileTableAction(title: store.text("Edit text", "编辑文本"), action: { pane.busy = true; editingFile = entry }))
        }
        actions.append(FileTableAction(title: store.text("Rename", "重命名"), enabled: selected.count == 1, action: { rename(entry) }))
        actions.append(FileTableAction(title: store.text("Permissions", "权限"), enabled: selected.count == 1, action: { chmod(entry) }))
        actions.append(FileTableAction(title: store.text("Copy path", "复制路径"), action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.map(\.path).joined(separator: "\n"), forType: .string) }))
        if let onCompare { actions.append(FileTableAction(title: compareTitle, enabled: model.canTransfer, action: onCompare)) }
        actions.append(.divider)
        actions.append(FileTableAction(title: store.text("Delete selected", "删除所选"), action: { delete(selected) }))
        return actions
    }
    func insertDirectory(_ path: String) {
        do { try store.insertChangeDirectory(path: path, host: endpointIsRemote ? model.rightHost : nil) }
        catch { pane.error = error.localizedDescription }
    }
    func prompt(_ title: String, value: String = "") -> String? {
        let alert = AppModalAlert(); alert.messageText = title
        let field = NSTextField(string: value); field.frame = CGRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: store.text("Save", "保存")); alert.addButton(withTitle: store.text("Cancel", "取消"))
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    func action(_ operation: @escaping () async throws -> Void) {
        guard !pane.busy else { return }
        pane.busy = true
        Task { defer { pane.busy = false }; do { try await operation(); await pane.navigate(pane.path, record: false) } catch { pane.error = error.localizedDescription } }
    }
    func refreshPane() {
        Task { if remote && endpointIsRemote { await model.open() } else { await pane.navigate(pane.path, record: false) } }
    }
    func createFile() {
        guard let name = prompt(store.text("New file", "新建文件")) else { return }; let base = pane.path
        action { let path = try remoteJoin(base, name); guard try await fileIfExists(path, backend: pane.backend) == nil else { throw AppFailure.message("File already exists") }; try await pane.backend.write(path, offset: 0, bytes: Data()) }
    }
    func createDirectory() { guard let name = prompt(store.text("New folder", "新建目录")) else { return }; let base = pane.path; action { try await pane.backend.mkdir(remoteJoin(base, name)) } }
    func rename(_ entry: FileEntry) { guard let name = prompt(store.text("Rename", "重命名"), value: entry.name) else { return }; let base = (entry.path as NSString).deletingLastPathComponent; action { let destination = try remoteJoin(base, name); guard destination != entry.path else { return }; guard try await fileIfExists(destination, backend: pane.backend) == nil else { throw AppFailure.message(store.text("Name already exists", "名称已存在")) }; try await pane.backend.rename(entry.path, destination) } }
    func chmod(_ entry: FileEntry) { guard let value = prompt(store.text("Permissions (octal)", "权限（八进制）"), value: String(entry.permissions, radix: 8)), let mode = UInt32(value, radix: 8), mode <= 0o7777 else { return }; action { try await pane.backend.chmod(entry.path, mode) } }
    func delete(_ entries: [FileEntry]) {
        let alert = AppModalAlert(); alert.destructive = true; alert.messageText = store.text("Delete \(entries.count) items?", "删除 \(entries.count) 项？")
        alert.informativeText = endpointIsRemote ? store.text("Remote deletion is permanent.", "远程文件将永久删除。") : store.text("Local files will move to Trash.", "本地文件将移到废纸篓。")
        alert.addButton(withTitle: store.text("Delete", "删除")); alert.addButton(withTitle: store.text("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        action { for entry in entries { try await pane.backend.delete(entry) } }
    }
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let request = model.endpointGeneration
        let target = pane
        let destinationPath = target.path
        let rightSource = model.remote
        let targetIsRemote = endpointIsRemote
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { return }
                    Task { @MainActor in
                        guard model.endpointGeneration == request else { return }
                        do {
                            let source = LocalFiles()
                            let entry = try await source.stat(url.path)
                            guard model.endpointGeneration == request else { return }
                            try model.enqueue([entry], from: source, to: target, destinationPath: destinationPath, direction: targetIsRemote ? "upload" : "copy")
                        } catch { target.error = error.localizedDescription }
                    }
                }
            } else if !remote, let rightSource, !model.rightIsLocal, provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let value = value as? String, value.hasPrefix("tabby-remote:") else { return }
                    let path = String(value.dropFirst("tabby-remote:".count))
                    Task { @MainActor in
                        guard model.endpointGeneration == request,
                              let entry = rightSource.entries.first(where: { $0.path == path }) else { return }
                        do { try model.enqueue([entry], from: rightSource.backend, to: target, destinationPath: destinationPath, direction: "download") }
                        catch { target.error = error.localizedDescription }
                    }
                }
            }
        }
        return accepted
    }

}

struct SFTPHostPicker: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: FileManagerModel
    @State private var search = ""
    @State private var group = ""
    @FocusState private var searchFocused: Bool
    var hosts: [Host] { store.workspace.hosts.filter { (group.isEmpty || $0.group == group) && (search.isEmpty || "\($0.name) \($0.address) \($0.group) \($0.tags)".localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        if model.opening {
            VStack(spacing: 18) {
                IconTile(symbol: "server.rack", color: Palette.sftp, size: 48)
                Text(model.rightHost.map { $0.name.isEmpty ? $0.address : $0.name } ?? store.text("Remote host", "远程主机"))
                    .font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
                if let host = model.rightHost {
                    Text(RecentTargets.effectiveUsername(host, workspace: store.workspace) + "@" + host.address)
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                ProgressView().controlSize(.small)
                Text(store.text("Connecting to SFTP…", "正在连接 SFTP…")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.sidebar)
        } else {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SFTPHostPickerBackButton(title: store.text("Select host", "选择主机"),
                                         label: store.text("Back to files", "返回文件列表")) {
                    if model.remote != nil { model.dismissHostPicker() }
                    else { Task { await model.selectLocal(path: model.local.path) } }
                }.frame(width: 150, height: 40).disabled(!model.canSwitchRight)
                Spacer()
                Button { Task { await model.selectLocal() } } label: { Label(store.text("Local", "本地"), systemImage: "terminal") }.buttonStyle(ChromeButtonStyle(prominent: true, accentColor: Palette.localTerminal)).disabled(!model.canSwitchRight)
            }.padding(.horizontal, 16).frame(height: 60)
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill")
                Text(store.text("Local vault", "本地主机库")).font(.system(size: 13, weight: .semibold))
                Spacer()
                AxonChoiceField(selection: $group, choices: [("", store.text("All groups", "全部分组"))] + store.groups.map { ($0, $0) }, placeholder: store.text("All groups", "全部分组"), symbol: "folder", identifier: "axon-sftp-host-group").frame(width: 180)
            }.padding(.horizontal, 22).padding(.bottom, 16)
            VaultSearchField(placeholder: store.text("Search hosts or tags", "搜索主机或标签"), text: $search).focused($searchFocused).padding(.horizontal, 20).padding(.bottom, 16)
            if !model.status.isEmpty { Text(model.status).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 22).padding(.bottom, 12) }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(hosts) { host in
                        Button { Task { await model.selectHost(host) } } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: "server.rack", color: Palette.blue, size: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.name.isEmpty ? host.address : host.name).font(.system(size: 13)).lineLimit(1)
                                    Text("\(host.username)@\(host.address)").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                }
                                Spacer()
                                if store.sessions.contains(where: { $0.host?.id == host.id && $0.client?.isConnected == true }) || (model.rightHost?.id == host.id && model.remote != nil && !model.rightIsLocal) {
                                    Text(store.text("Connected", "已连接")).font(.caption).foregroundStyle(Palette.accent)
                                }
                            }.padding(12).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                        }.buttonStyle(StableHostPickerButtonStyle()).focusEffectDisabled().disabled(!model.canSwitchRight)
                    }
                    if hosts.isEmpty { Text(store.text("No hosts found", "没有找到主机")).foregroundStyle(Palette.muted).padding(30) }
                }.padding(.horizontal, 20)
            }
        }.foregroundStyle(Palette.text).background(Palette.sidebar).onAppear { searchFocused = true }
        }
    }
}

struct DisconnectedFilesWorkspace: View {
    @StateObject private var model: FileManagerModel
    init(store: AppStore) { _model = StateObject(wrappedValue: FileManagerModel(session: TerminalSession(host: nil, store: store))) }
    var body: some View { FilesView(model: model).onDisappear { model.close() } }
}

struct ExternalEditTasksBar: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var center: ExternalEditCenter
    let open: () -> Void
    var body: some View {
        if !center.edits.isEmpty {
            HStack {
                Label(store.text("External editing", "外部编辑任务"), systemImage: "square.and.pencil")
                Text("\(center.edits.count)").foregroundStyle(Palette.muted)
                Spacer()
                Button(store.text("Review and upload…", "查看与回传…"), action: open).buttonStyle(ChromeButtonStyle())
            }.padding(12).background(Palette.card)
        }
    }
}
