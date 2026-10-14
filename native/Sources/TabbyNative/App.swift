import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main struct TabbyNativeApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject var store = AppStore()
    private var commandStore: AppStore { SceneWindowController.focusedStore ?? store }
    var body: some Scene {
        Window("Axon", id: "main") {
            MainView().environmentObject(store).onAppear { delegate.store = store }.preferredColorScheme(.light).tint(Palette.accent).frame(minWidth: 1050, minHeight: 680).ignoresSafeArea(.container, edges: .top)
                .background(MainWindowLifecycleProbe(controller: delegate.mainWindowController))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 860)
        .commands { AxonCommands(store: store) }
    }
}

struct AxonCommands: Commands {
    @ObservedObject var store: AppStore
    private var commandStore: AppStore { SceneWindowController.focusedStore ?? store }
    var body: some Commands {
            CommandGroup(replacing: .appInfo) {
                Button(commandStore.text("About Axon", "关于 Axon")) { AxonAboutPanel.show() }
            }
            CommandGroup(replacing: .help) {
                Button(commandStore.text("AI assistant manual", "AI 助手使用手册")) { AIManualWindowController.shared.show(store: commandStore) }
            }
            CommandGroup(replacing: .appSettings) {
                Button(commandStore.text("Settings…", "设置…")) { commandStore.openPreferences() }.keyboardShortcut(store.workspace.preferences.shortcut(.settings).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.settings).modifiers)
            }
            CommandMenu(commandStore.text("Terminal", "终端")) {
                Button(commandStore.text("Increase font size", "放大字号")) { commandStore.fontAdjustmentSession?.adjustFontSize(1) }
                    .keyboardShortcut(store.workspace.preferences.shortcut(.fontIncrease).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.fontIncrease).modifiers)
                    .disabled(commandStore.fontAdjustmentSession == nil)
                Button(commandStore.text("Decrease font size", "缩小字号")) { commandStore.fontAdjustmentSession?.adjustFontSize(-1) }
                    .keyboardShortcut(store.workspace.preferences.shortcut(.fontDecrease).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.fontDecrease).modifiers)
                    .disabled(commandStore.fontAdjustmentSession == nil)
                Button(commandStore.text("Reset font size", "恢复默认字号")) { commandStore.fontAdjustmentSession?.setFontSize(nil) }
                    .keyboardShortcut(store.workspace.preferences.shortcut(.fontReset).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.fontReset).modifiers)
                    .disabled(commandStore.fontAdjustmentSession == nil)
            }
            CommandGroup(after: .newItem) {
                Button(commandStore.text("New tab", "新标签")) { commandStore.openLauncher() }.keyboardShortcut(store.workspace.preferences.shortcut(.newTab).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.newTab).modifiers)
                Button(commandStore.text("Search hosts or tabs", "搜索主机或标签")) { commandStore.openLauncher() }.keyboardShortcut(store.workspace.preferences.shortcut(.search).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.search).modifiers)
                Button(commandStore.text("New local terminal", "新建本地终端")) { commandStore.connect() }.keyboardShortcut(store.workspace.preferences.shortcut(.localTerminal).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.localTerminal).modifiers)
                Button(commandStore.text("Split terminal", "终端分屏")) { commandStore.split() }.keyboardShortcut(store.workspace.preferences.shortcut(.split).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.split).modifiers)
                Button(commandStore.text("Close session", "关闭会话")) { if commandStore.sceneWindowID != nil, commandStore.section == "scene" { SceneWindowController.closeFocused() } else if commandStore.section == "scene", let id = commandStore.activeSceneID { commandStore.closeScene(id) } else if commandStore.section == "logviewer", let id = commandStore.activeLogViewer { commandStore.closeLogViewer(id) } else if let id = commandStore.activeSession { commandStore.closeTerminalTab(id) } }.keyboardShortcut(store.workspace.preferences.shortcut(.closeSession).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.closeSession).modifiers)
                Button(commandStore.text("Find in terminal", "搜索终端")) {
                    if let session = commandStore.sessions.first(where: { $0.id == commandStore.activeSession }) {
                        commandStore.showTerminalSection()
                        let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue); session.terminal?.performFindPanelAction(item)
                    }
                }.keyboardShortcut(store.workspace.preferences.shortcut(.find).keyEquivalent, modifiers: store.workspace.preferences.shortcut(.find).modifiers)
                Button(commandStore.text("Import & Export", "导入与导出")) { commandStore.openPreferences(.importHosts) }
            }
        }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let mainWindowController = MainWindowLifecycleController()
    weak var store: AppStore? {
        didSet {
            if launched {
                store?.applyApplicationIconAtLaunch()
                store?.automaticBackup.startAtLaunch()
            }
        }
    }
    private var launched = false
    private lazy var shortcutDispatcher = ApplicationShortcutDispatcher { [weak self] window in
        guard let self else { return nil }
        if window === self.mainWindowController.window { return self.store }
        return SceneWindowController.shortcutStore(for: window)
    }
    func applicationWillTerminate(_ notification: Notification) { SceneWindowController.closeAll(); store?.aiSessions.forEach { $0.cancel() }; store?.automaticBackup.cancel(); store?.batchTasks.cancelAll(); store?.externalEdits.edits.forEach { $0.stop() }; store?.monitoring.stop(); store?.forwardTasks.values.forEach { $0.cancel() }; store?.forwardEngines.values.forEach { $0.stop() }; store?.sceneTasks.values.forEach { $0.cancel() }; store?.logViewers.forEach { $0.close() }; store?.sessions.forEach { $0.disconnect() } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        shortcutDispatcher.start()
        store?.applyApplicationIconAtLaunch()
        store?.automaticBackup.startAtLaunch()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click restores the original view and its unsaved state.
        !mainWindowController.reopen(using: sender)
    }
}

/// Only the workspace window is retained. File panels, credential dialogs and
/// other modal windows keep their own close and cancellation behavior.
final class MainWindowLifecycleController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var previousDelegate: NSWindowDelegate?
    private var fullscreenTransition = false
    private var hideAfterFullscreenExit = false

    @MainActor func attach(to window: NSWindow) {
        guard self.window == nil || self.window === window else { return }
        self.window = window
        window.isReleasedWhenClosed = false
        if window.delegate !== self {
            previousDelegate = window.delegate
            window.delegate = self
        }
    }
    @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if sender.styleMask.contains(.fullScreen) || fullscreenTransition {
            hideAfterFullscreenExit = true
            if !fullscreenTransition { fullscreenTransition = true; sender.toggleFullScreen(nil) }
            return false
        }
        sender.orderOut(nil)
        return false
    }
    @MainActor func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreenTransition = true
        previousDelegate?.windowWillEnterFullScreen?(notification)
    }
    @MainActor func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        previousDelegate?.windowDidEnterFullScreen?(notification)
        if hideAfterFullscreenExit { fullscreenTransition = true; window?.toggleFullScreen(nil) }
    }
    @MainActor func windowWillExitFullScreen(_ notification: Notification) {
        fullscreenTransition = true
        previousDelegate?.windowWillExitFullScreen?(notification)
    }
    @MainActor func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        previousDelegate?.windowDidExitFullScreen?(notification)
        if hideAfterFullscreenExit {
            hideAfterFullscreenExit = false
            window?.orderOut(nil)
        }
    }
    @MainActor func windowDidFailToEnterFullScreen(_ sender: NSWindow) {
        fullscreenTransition = false
        previousDelegate?.windowDidFailToEnterFullScreen?(sender)
        if hideAfterFullscreenExit { hideAfterFullscreenExit = false; sender.orderOut(nil) }
    }
    @MainActor func windowDidFailToExitFullScreen(_ sender: NSWindow) {
        fullscreenTransition = false
        hideAfterFullscreenExit = false
        previousDelegate?.windowDidFailToExitFullScreen?(sender)
        sender.makeKeyAndOrderFront(nil)
    }
    @MainActor @discardableResult func reopen(using application: NSApplication) -> Bool {
        guard let window else { return false }
        hideAfterFullscreenExit = false
        application.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        return true
    }
    // SwiftUI installs a window delegate of its own. Preserve its optional
    // geometry and scene callbacks while intercepting only workspace close.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let previousDelegate, previousDelegate.responds(to: selector) { return previousDelegate }
        return super.forwardingTarget(for: selector)
    }
}

struct MainWindowLifecycleProbe: NSViewRepresentable {
    let controller: MainWindowLifecycleController
    func makeNSView(context: Context) -> MainWindowLifecycleView {
        let view = MainWindowLifecycleView(); view.controller = controller; return view
    }
    func updateNSView(_ view: MainWindowLifecycleView, context: Context) {
        view.controller = controller
        view.attachWindow()
        // SwiftUI may finish installing its delegate after attaching the view.
        DispatchQueue.main.async { [weak view] in view?.attachWindow() }
    }
}

final class MainWindowLifecycleView: NSView {
    weak var controller: MainWindowLifecycleController?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); attachWindow()
    }
    func attachWindow() {
        guard let window else { return }
        controller?.attach(to: window)
    }
}

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowFullscreen = false
    @State private var inspectorHost: Host?
    @State private var inspectorGroup: HostGroup?
    @State private var selectedHost: UUID?
    @AppStorage("axon.terminalToolsWidth") private var terminalToolsWidth = 320.0
    @State private var terminalToolsVisible = false
    @State private var terminalTool = "ai"
    @State private var monitoringForeground = false
    @State private var newTabHovering = false
    @State private var lastVaultSection = "hosts"
    @State private var gridView = true
    @State private var selectedTag = ""
    @State private var sort = "name"
    @State private var favoritesOnly = false
    @State private var tagsManagementOpen = false
    @State private var sceneLayoutEditing: WorkScene?
    private let vaultSections = ["hosts", "monitoring", "credentials", "forwards", "snippets", "batchTasks", "scenes", "known", "logs", "settings"]
    var vaultSelected: Bool { vaultSections.contains(store.section) }
    var terminalVisible: Bool { store.section == "terminal" || (store.section == "scene" && store.currentScene?.mode == "terminal") }
    var hostCatalog: HostLibraryCatalog { HostLibraryCatalog(hosts: store.workspace.hosts, group: store.group, query: store.search, tag: selectedTag, favoritesOnly: favoritesOnly, sort: sort, workspace: store.workspace) }
    var filteredHosts: [Host] { hostCatalog.visibleHosts }
    var allTags: [String] { store.tags }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                workspaceBar
                Rectangle().fill(terminalVisible ? TerminalChrome.border : Palette.border.opacity(0.6)).frame(height: 1)
                workspaceContent(width: geometry.size.width, height: max(0, geometry.size.height - 53))
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.buttonStyle(ChromeButtonStyle()).foregroundStyle(Palette.text).font(.system(size: 13)).background(Palette.background)
        .background(WindowSurface())
        .background(WindowFullscreenProbe(isFullscreen: $windowFullscreen))
        .background(MonitoringVisibilityProbe { value in monitoringForeground = value })
        .onAppear { returnToHostsIfNeeded(); updateMonitoring() }
        .onDisappear { store.monitoring.stop() }
        .onChange(of: monitoringForeground) { _, _ in updateMonitoring() }
        .onChange(of: terminalToolsVisible) { _, visible in
            if visible, terminalTool == "ai", store.ai.context.sessionID != store.activeSession { store.prepareTerminalAI() }
            updateMonitoring()
        }
        .onChange(of: terminalTool) { _, value in if value == "ai", store.ai.context.sessionID != store.activeSession { store.prepareTerminalAI() }; updateMonitoring() }
        .onChange(of: store.aiTerminalRequest) { _, _ in terminalTool = "ai"; terminalToolsVisible = true }
        .sheet(isPresented: $store.aiAnalysisPresented) { AIAnalysisSheet().environmentObject(store) }
        .onChange(of: store.currentScene?.mode) { _, _ in updateMonitoring() }
        .onChange(of: store.activeSession) { _, id in if terminalToolsVisible && terminalTool == "ai" { store.prepareTerminalAI() }; if let scene = store.openScenes.first(where: { $0.sessionIDs.contains(id ?? UUID()) }) { scene.selectedSessionID = id }; updateMonitoring() }
        .onChange(of: store.sessions.map(\.id)) { _, _ in returnToHostsIfNeeded() }
        .onChange(of: store.workspace.hosts) { _, _ in updateMonitoring() }
        .onChange(of: store.workspace.credentials) { _, _ in updateMonitoring() }
        .onChange(of: store.workspace.groupDefaults) { _, _ in updateMonitoring() }
        .onChange(of: store.group) { _, _ in inspectorHost = nil; inspectorGroup = nil; selectedHost = nil }
        .onChange(of: store.section) { _, section in
            if vaultSections.contains(section) { lastVaultSection = section }
            if section == "launcher" { store.newTabOpen = true }
            returnToHostsIfNeeded()
            updateMonitoring()
        }
        .onChange(of: allTags) { _, tags in if !selectedTag.isEmpty { selectedTag = tags.first { CatalogNames.matches($0, selectedTag) } ?? "" } }
        .sheet(isPresented: $tagsManagementOpen) { TagsManagementView().environmentObject(store) }
        .appAlert(store.text("Error", "错误"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { AppAlertButton(store.text("OK", "确定")) { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func workspaceContent(width: CGFloat, height: CGFloat) -> some View {
        let navigationWidth: CGFloat = vaultSelected ? 185 : 0
        let toolsWidth: CGFloat = terminalVisible && terminalToolsVisible ? TerminalToolsPanel.allocatedWidth(selection: terminalTool, workspace: width - navigationWidth, preferred: terminalToolsWidth) : 0
        let inspectorWidth: CGFloat = store.section == "hosts" && (inspectorHost != nil || inspectorGroup != nil) ? 341 : 0
        let centerWidth = max(0, width - navigationWidth - toolsWidth - inspectorWidth)
        return HStack(spacing: 0) {
            if vaultSelected {
                sidebar.frame(width: 184, height: height)
                Rectangle().fill(Palette.border.opacity(0.65)).frame(width: 1, height: height)
            }
            ZStack {
                VStack(spacing: 0) {
                    if store.section == "scene", let scene = store.currentScene { WorkSceneToolbar(scene: scene, toggleTools: { terminalToolsVisible.toggle() }) }
                    ZStack {
                        sessionArea.opacity(vaultSelected || store.section == "launcher" || store.section == "logviewer" || (store.section == "scene" && store.currentScene?.mode == "logs") ? 0 : 1)
                            .allowsHitTesting(!vaultSelected && store.section != "launcher" && store.section != "logviewer" && !(store.section == "scene" && store.currentScene?.mode == "logs"))
                        if store.section == "logviewer" || (store.section == "scene" && store.currentScene?.mode == "logs") {
                            if let viewer = store.logViewers.first(where: { $0.id == store.activeLogViewer && (store.section != "scene" || store.currentScene?.logIDs.contains($0.id) == true) }) {
                                LogViewerWorkspace(model: viewer).id(viewer.id)
                            } else { ContentUnavailableView(store.text("Open a log file", "打开日志文件"), systemImage: "doc.text.magnifyingglass", description: Text(store.text("Choose a saved log above, or open a file from SFTP.", "选择上方的日志路径，或从 SFTP 文件菜单打开。"))) }
                        }
                    }
                }
                if store.section == "hosts" { hosts }
                if store.section == "monitoring" { MonitoringVaultView(center: store.monitoring) }
                if store.section == "settings" { PreferencesView(selection: $store.settingsPage, showsSidebar: false) }
                if store.section == "known" { KnownHostsView() }
                if store.section == "credentials" { CredentialsView() }
                if store.section == "forwards" { PortForwardsView() }
                if store.section == "logs" { LogsView() }
                if store.section == "scenes" { ScrollView { WorkSceneLibrary(query: "").padding(24) } }
                if store.section == "snippets" { SnippetsView() }
                if store.section == "batchTasks" { BatchTasksView(center: store.batchTasks) }
                if store.section == "launcher" { LauncherView() }
            }.frame(width: centerWidth, height: height).background(Palette.background).clipped()
            if terminalVisible {
                // Keep the drawer at its full width while the surrounding slot
                // slides in and out. Only the workspace allocation animates;
                // the window and the live terminal retain their identities.
                TerminalToolsPanel(selection: $terminalTool, isVisible: $terminalToolsVisible, availableHeight: height, panelWidth: toolsWidth == 0 ? TerminalToolsPanel.allocatedWidth(selection: terminalTool, workspace: width - navigationWidth, preferred: terminalToolsWidth) : toolsWidth)
                    .overlay(alignment: .leading) {
                        TerminalToolsResizeHandle(width: toolsWidth, label: store.text("Drag to resize terminal tools", "拖动调整终端工具宽度")) { value in terminalToolsWidth = Double(TerminalToolsPanel.allocatedWidth(selection: terminalTool, workspace: width - navigationWidth, preferred: value)) }.frame(width: 8)
                    }
                    .frame(width: toolsWidth, height: height, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(terminalToolsVisible)
                    .accessibilityHidden(!terminalToolsVisible)
            }
            if store.section == "hosts", let host = inspectorHost {
                Rectangle().fill(Palette.border).frame(width: 1, height: height)
                HostEditor(host: host, isNew: !store.workspace.hosts.contains(where: { $0.id == host.id })) { inspectorHost = nil; selectedHost = nil }
                    .id(host.id).frame(width: 340, height: height).background(Palette.sidebar)
            } else if store.section == "hosts", let group = inspectorGroup {
                Rectangle().fill(Palette.border).frame(width: 1, height: height)
                GroupEditor(value: group, isNew: !store.groups.contains { CatalogNames.matches($0, group.name) }) { inspectorGroup = nil }
                    .id(group.id).frame(width: 340, height: height).background(Palette.sidebar)
            }
        }.frame(width: width, height: height, alignment: .topLeading).clipped()
            .animation(store.section == "terminal" && !reduceMotion ? .easeInOut(duration: 0.24) : nil, value: terminalToolsVisible)
    }
    var workspaceTabsWidth: CGFloat {
        WorkspaceTabStripSizing.contentWidth(sessionWidths: store.terminalTabs.map {
            store.samePaneGroup(store.activeSession, $0.id) && store.section == "terminal" ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive
        } + store.sceneFileSessions.map { store.section == "sftp" && store.activeSession == $0.id ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive } + (store.sceneWindowID == nil ? store.openScenes : []).map { store.section == "scene" && store.activeSceneID == $0.id ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive } + store.standaloneLogViewers.map { store.section == "logviewer" && store.activeLogViewer == $0.id ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive }, showsNewTab: store.newTabOpen)
    }
    var workspaceScrollTarget: String? {
        if store.section == "launcher" && store.newTabOpen { return "axon-launcher-tab" }
        if store.section == "terminal", let id = store.activeSession { return "axon-session-tab:" + (store.terminalTabs.first { store.samePaneGroup(id, $0.id) }?.id ?? id).uuidString }
        if store.section == "scene", let id = store.activeSceneID { return "axon-scene-tab:" + id.uuidString }
        if store.sceneWindowID != nil, store.section == "sftp", let id = store.activeSession { return "axon-file-tab:" + id.uuidString }
        if store.section == "logviewer", let id = store.activeLogViewer { return "axon-log-tab:" + id.uuidString }
        return nil
    }
    var workspaceBar: some View {
        WorkspaceBarLayout(tabContentWidth: workspaceTabsWidth) {
            HStack(spacing: 0) {
                Button { store.section = lastVaultSection } label: {
                    Label(store.text("Vaults", "主机库"), systemImage: "lock.shield")
                }.buttonStyle(WorkspaceTabStyle(selected: vaultSelected, dark: terminalVisible)).focusEffectDisabled()
                if vaultSelected {
                    AppActionMenu {
                        Button { store.section = lastVaultSection } label: { Label(store.text("Local vault", "本地保险库"), systemImage: "checkmark") }
                    } label: { Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Palette.chromeText).frame(width: 20, height: 34) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(store.text("Select vault", "选择保险库")).accessibilityLabel(store.text("Select vault", "选择保险库"))
                }
            }
            if store.sceneWindowID == nil || store.sceneFileSessions.isEmpty {
                Button { store.section = "sftp" } label: {
                    Label("SFTP", systemImage: "folder.fill").frame(width: store.section == "sftp" ? 108 : 68, alignment: .leading)
                }.buttonStyle(WorkspaceTabStyle(selected: store.section == "sftp", dark: terminalVisible))
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: WorkspaceTabDimensions.spacing) {
                    ForEach(store.sceneFileSessions) { session in
                        WorkAreaTab(title: "SFTP · " + (session.host?.name ?? store.text("Local", "本地")), symbol: "folder.fill", selected: store.section == "sftp" && store.activeSession == session.id, select: { store.activeSession = session.id; store.showFileSection() }, close: {
                            store.currentScene?.definition.directories.removeAll { $0.hostID == session.host?.id }
                            store.objectWillChange.send()
                            if store.section == "sftp" { store.showTerminalSection() }
                        }).id("axon-file-tab:" + session.id.uuidString)
                    }
                    ForEach(store.terminalTabs) { session in
                        SessionTab(session: session) { terminalToolsVisible.toggle() }
                            .id("axon-session-tab:" + session.id.uuidString)
                    }
                    ForEach(store.sceneWindowID == nil ? store.openScenes : []) { scene in
                        WorkAreaTab(title: scene.definition.name, symbol: "rectangle.3.group", selected: store.section == "scene" && store.activeSceneID == scene.id, select: { store.showScene(scene) }, close: { store.closeScene(scene.id) }).id("axon-scene-tab:" + scene.id.uuidString)
                    }
                    ForEach(store.standaloneLogViewers) { viewer in
                        WorkAreaTab(title: viewer.title, symbol: "doc.text", selected: store.section == "logviewer" && store.activeLogViewer == viewer.id, select: { store.activeLogViewer = viewer.id; store.section = "logviewer" }, close: { store.closeLogViewer(viewer.id) }).id("axon-log-tab:" + viewer.id.uuidString)
                    }
                    if store.newTabOpen {
                        HStack(spacing: 8) {
                            Button { store.newTabOpen = false; if store.section == "launcher" { store.section = "hosts" } } label: { Image(systemName: "xmark").frame(width: 16, height: 34) }
                                .buttonStyle(AxonSurfaceButtonStyle()).opacity(newTabHovering || store.section == "launcher" ? 1 : 0).help(store.text("Close new tab", "关闭新标签"))
                                .accessibilityLabel(store.text("Close new tab", "关闭新标签"))
                            Button { store.openLauncher() } label: {
                                Label(store.text("New Tab", "新标签"), systemImage: "plus.app.fill").frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(AxonSurfaceButtonStyle())
                        }.font(.system(size: 13)).padding(.horizontal, 12).frame(width: WorkspaceTabDimensions.newTab, height: 34)
                            .foregroundStyle(store.section == "launcher" ? Palette.chromeText : Color(hex: "#969BB0"))
                            .background(Color(hex: store.section == "launcher" ? "#45475F" : store.section == "terminal" ? "#252738" : "#393C52"))
                            .clipShape(RoundedRectangle(cornerRadius: 10)).onHover { newTabHovering = $0 }.focusEffectDisabled()
                            .id("axon-launcher-tab")
                    }
                    }.fixedSize(horizontal: true, vertical: false)
                }
                .onChange(of: workspaceScrollTarget) { _, target in
                    guard let target else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard workspaceScrollTarget == target else { return }
                        withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(target, anchor: .trailing) }
                    }
                }
                .onChange(of: store.launcherRequest) { _, _ in
                    Task { @MainActor in
                        await Task.yield()
                        if store.newTabOpen && store.section == "launcher" { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("axon-launcher-tab", anchor: .trailing) } }
                    }
                }
            }
            Button { store.newTabOpen = true; store.openLauncher() } label: { Image(systemName: "plus") }.buttonStyle(WorkspaceIconStyle()).help(store.text("New tab", "新标签")).accessibilityLabel(store.text("New tab", "新标签"))
                .onDrop(of: [WorkspaceSessionDrag.type.rawValue], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadDataRepresentation(forTypeIdentifier: WorkspaceSessionDrag.type.rawValue) { data, _ in
                        guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                        Task { @MainActor in store.moveSessionToEnd(id) }
                    }
                    return true
                }
            if store.sceneWindowID != nil {
                Button { sceneLayoutEditing = store.captureScene() } label: { Label(store.text("Save scene", "保存场景"), systemImage: "square.and.pencil") }.buttonStyle(WorkspaceTabStyle(selected: false, dark: terminalVisible)).help(store.text("Save current tabs and layout as a scene", "将当前标签与布局保存为场景"))
            }
            WindowDragHandle().frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52).help(store.text("Drag to move window", "拖动此处移动窗口"))
            if store.section == "terminal" {
                TerminalToolsToggleButton(isVisible: terminalToolsVisible, title: store.text("Terminal tools", "终端工具")) { terminalToolsVisible.toggle() }
                    .frame(width: 28, height: 34)
            }
        }.sheet(item: $sceneLayoutEditing) { WorkSceneEditor(value: $0).environmentObject(store) }
        .padding(.leading, windowFullscreen ? 14 : 84).padding(.trailing, 14).frame(height: 52)
            .background(Palette.chrome)
            .focusEffectDisabled().animation(.easeInOut(duration: 0.16), value: store.section)
    }
    func updateMonitoring() {
        store.monitoring.configure(store: store, terminalStatusVisible: terminalToolsVisible && terminalTool == "status", foreground: monitoringForeground)
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceNavigation(settingsPage: $store.settingsPage)
            Rectangle().fill(Palette.border.opacity(0.6)).frame(height: 1)
            HStack(spacing: 10) {
                if let icon = ApplicationIconAppearance.image(for: store.workspace.preferences.applicationIcon) {
                    Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                } else { IconTile(symbol: "terminal", color: Palette.blue, size: 34) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Axon").font(.system(size: 13, weight: .medium))
                    Text(store.text("Local workspace", "本地工作区")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 12).padding(.horizontal, 4)
        }.padding(.horizontal, 10).background(Palette.sidebar)
    }
    var hosts: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField(store.text("Find a host or ssh user@hostname…", "搜索主机或输入 ssh user@hostname…"), text: $store.search).textFieldStyle(.plain).font(.system(size: 14)).onSubmit(connectFromSearch)
                    if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(AxonSurfaceButtonStyle()).foregroundStyle(Palette.muted) }
                    Button(store.text("CONNECT", "连接"), action: connectFromSearch).buttonStyle(ChromeButtonStyle()).disabled(searchTarget == nil && quickHost == nil)
                }.padding(.horizontal, 14).frame(height: 36).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1))
                GeometryReader { geometry in
                let compact = geometry.size.width < 800
                HStack(spacing: 10) {
                    Button { newHost() } label: { if compact { Image(systemName: "server.rack") } else { Label(store.text("NEW HOST", "新建主机"), systemImage: "server.rack") } }.buttonStyle(ChromeButtonStyle()).help(store.text("New host", "新建主机")).accessibilityLabel(store.text("New host", "新建主机"))
                    Button { store.connect() } label: { if compact { Image(systemName: "terminal") } else { Label(store.text("TERMINAL", "本地终端"), systemImage: "terminal") } }.buttonStyle(ChromeButtonStyle(prominent: true, accentColor: Palette.localTerminal)).help(store.text("Local terminal", "本地终端")).accessibilityLabel(store.text("Local terminal", "本地终端"))
                    Spacer(minLength: 6)
                    HostLibraryLayoutPicker(grid: $gridView, chinese: store.chinese).frame(width: 70, height: 32)
                    AppActionMenu { Button(store.text("All tags", "全部标签")) { selectedTag = "" }; ForEach(allTags, id: \.self) { tag in Button(tag) { selectedTag = tag } }; Divider(); Button(store.text("Manage tags…", "管理标签…")) { tagsManagementOpen = true } } label: { Image(systemName: "tag.fill").foregroundStyle(selectedTag.isEmpty ? Palette.text : Palette.accent); Image(systemName: "chevron.down").font(.system(size: 9)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Palette.text).fixedSize()
                    AppActionMenu { Button(store.text("Name", "名称")) { sort = "name" }; Button(store.text("Address", "地址")) { sort = "address" }; Button(store.text("Favorites first", "收藏优先")) { sort = "favorite" } } label: { Image(systemName: "arrow.up.arrow.down"); Image(systemName: "chevron.down").font(.system(size: 9)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Palette.text).fixedSize()
                    Button { favoritesOnly.toggle() } label: { Image(systemName: favoritesOnly ? "star.fill" : "star").foregroundStyle(favoritesOnly ? Palette.accent : Palette.text) }.buttonStyle(IconButtonStyle()).help(store.text("Favorites", "收藏主机"))
                    Button(action: newGroup) { if compact { Image(systemName: "folder.badge.plus") } else { Label(store.text("New group", "新建分组"), systemImage: "folder.badge.plus") } }.buttonStyle(ChromeButtonStyle()).help(store.text("New group", "新建分组")).accessibilityLabel(store.text("New group", "新建分组")).accessibilityIdentifier("axon-new-group")
                    Button { tagsManagementOpen = true } label: { if compact { Image(systemName: "tag") } else { Label(store.text("Manage tags", "管理标签"), systemImage: "tag") } }.buttonStyle(ChromeButtonStyle()).help(store.text("Manage tags", "管理标签")).accessibilityLabel(store.text("Manage tags", "管理标签"))
                }
                }.frame(height: 34)
            }.padding(12).background(Palette.sidebar)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !store.group.isEmpty || !selectedTag.isEmpty {
                        HStack(spacing: 8) {
                            Button(store.text("All hosts", "全部主机")) { store.group = ""; selectedTag = "" }.buttonStyle(ChromeButtonStyle()).foregroundStyle(Palette.muted)
                            Image(systemName: "chevron.right").font(.system(size: 10))
                            Text(store.group.isEmpty ? selectedTag : store.group)
                            Spacer()
                            if !store.group.isEmpty { Button { editGroup(store.group) } label: { Label(store.text("Edit group", "编辑分组"), systemImage: "pencil") }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-edit-current-group") }
                        }.font(.system(size: 12)).padding(.bottom, 4)
                    }
                    if hostCatalog.isRootBrowse && !store.groups.isEmpty {
                        PaneHeading(title: store.text("Groups", "分组"))
                        LazyVGrid(columns: gridView ? columns : [GridItem(.flexible())], spacing: 12) {
                            ForEach(store.groups, id: \.self) { group in
                                HStack(spacing: 10) {
                                    Button { store.group = group } label: {
                                        HStack(spacing: 12) { IconTile(symbol: "folder.fill", color: Palette.blue); VStack(alignment: .leading, spacing: 6) { Text(group).font(.system(size: 14)).foregroundStyle(Palette.text); Text(String(store.catalogHostCount(group, section: .groups)) + store.text(" hosts", " 台主机")).font(.system(size: 11)).foregroundStyle(Palette.muted) }; Spacer(minLength: 0) }.frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76).contentShape(Rectangle())
                                    }.buttonStyle(AxonSurfaceButtonStyle())
                                    HostCardActionButton(symbol: "pencil", color: NSColor(Palette.muted), label: store.text("Edit group", "编辑分组"), identifier: "axon-group-edit-" + group) { editGroup(group) }.frame(width: 32, height: 32)
                                }.padding(.horizontal, 14).frame(height: 76).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 14)).appContextMenu {
                                    Button(store.text("Edit group", "编辑分组")) { editGroup(group) }
                                    Button(store.text("Delete group", "删除分组（保留主机）")) { deleteGroup(group) }
                                }
                            }
                        }.padding(.bottom, 10)
                    }
                    if !hostCatalog.isRootBrowse || !filteredHosts.isEmpty || store.groups.isEmpty {
                    HStack { PaneHeading(title: hostCatalog.isRootBrowse && !store.groups.isEmpty ? store.text("Ungrouped hosts", "未分组主机") : store.text("Hosts", "主机")); Text(String(filteredHosts.count)).font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer() }
                    LazyVGrid(columns: gridView ? columns : [GridItem(.flexible())], spacing: 12) {
                        ForEach(filteredHosts) { host in
                            HostCard(host: host, selected: selectedHost == host.id, compact: gridView,
                                     select: { selectHost(host) }, connect: { store.connect(host) }, edit: { selectHost(host) },
                                     favorite: { toggleFavorite(host) }, delete: { deleteHost(host) }, showGroup: store.group.isEmpty && !hostCatalog.isRootBrowse, monitor: { store.showMonitoring(host) })
                        }
                    }
                    if filteredHosts.isEmpty {
                        VStack(spacing: 15) {
                            IconTile(symbol: "server.rack", color: Palette.field, size: 58)
                            Text(store.workspace.hosts.isEmpty ? store.text("Your servers, in one place", "在这里管理你的服务器") : store.text("No matching hosts", "没有符合条件的主机")).font(.system(size: 17, weight: .medium))
                            Text(store.workspace.hosts.isEmpty ? store.text("Add your first host or import existing connections.", "添加第一台主机，或导入已有连接。") : store.text("Try another search or clear the filters.", "调整搜索词或清除筛选条件。 ")).font(.system(size: 13)).foregroundStyle(Palette.muted)
                            HStack(spacing: 10) { Button(store.text("New host", "新建主机"), action: newHost).buttonStyle(ChromeButtonStyle(prominent: true)); if store.workspace.hosts.isEmpty { Button(store.text("Import", "导入")) { store.openPreferences(.importHosts) }.buttonStyle(ChromeButtonStyle()) } else { Button(store.text("Clear filters", "清除筛选")) { store.search = ""; selectedTag = ""; favoritesOnly = false }.buttonStyle(ChromeButtonStyle()) } }
                        }.frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    }
                }.padding(22)
            }
        }
    }
    var columns: [GridItem] { [GridItem(.adaptive(minimum: 290, maximum: 560), spacing: 12)] }
    var searchTarget: Host? {
        if let selectedHost, let host = filteredHosts.first(where: { $0.id == selectedHost }) { return host }
        return filteredHosts.count == 1 ? filteredHosts.first : nil
    }
    var quickHost: Host? { parseQuickHost(store.search) }
    func connectFromSearch() { if let host = searchTarget ?? quickHost { store.connect(host) } }
    func newHost() {
        var host = Host(); host.group = store.group
        if store.groupDefaults(named: host.group) != nil { host.groupInheritance = .all }
        inspectorGroup = nil; inspectorHost = host; selectedHost = nil
    }
    func selectHost(_ host: Host) { inspectorGroup = nil; selectedHost = host.id; inspectorHost = host }
    func toggleFavorite(_ host: Host) { if let i = store.workspace.hosts.firstIndex(where: { $0.id == host.id }) { store.workspace.hosts[i].favorite.toggle(); store.save() } }
    func newGroup() {
        inspectorHost = nil; selectedHost = nil; inspectorGroup = HostGroup()
    }
    func editGroup(_ name: String) {
        inspectorHost = nil; selectedHost = nil
        inspectorGroup = store.groupDefaults(named: name) ?? HostGroup(name: name)
    }
    func returnToHostsIfNeeded() {
        if store.section == "terminal", !store.sessions.contains(where: { $0.id == store.activeSession }) {
            if let session = store.sessions.first { store.activeSession = session.id }
            else { store.section = "hosts" }
        }
        if store.section == "launcher", !store.newTabOpen { store.section = "hosts" }
    }
    func deleteGroup(_ group: String) {
        let alert = AppModalAlert(); alert.destructive = true; alert.messageText = store.text("Delete group \(group)?", "删除分组“\(group)”？")
        alert.informativeText = store.text("Hosts will be kept and moved to Ungrouped.", "保留分组内的主机，并将其移至未分组。")
        alert.addButton(withTitle: store.text("Delete group", "删除分组")); alert.addButton(withTitle: store.text("Cancel", "取消"))
        if alert.runModal() == .alertFirstButtonReturn { store.dissolveGroup(group) }
    }
    var sessionArea: some View {
        GeometryReader { geometry in
            let isScene = store.section == "scene"
            let terminalMode = store.section == "terminal" || (isScene && store.currentScene?.mode == "terminal")
            let filesMode = store.section == "sftp" || (isScene && store.currentScene?.mode == "files")
            let pair = terminalMode ? store.visiblePaneIDs : store.activeSession.map { [$0] } ?? []
            let frames = TerminalPaneLayout.frames(count: pair.count, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Palette.chrome
                ForEach(store.sessions) { session in
                    let index = pair.firstIndex(of: session.id) ?? 0
                    let pane = terminalMode && frames.indices.contains(index) ? frames[index] : CGRect(origin: .zero, size: geometry.size)
                    let sceneMember = !isScene || store.currentScene?.sessionIDs.contains(session.id) == true
                    let visible = sceneMember && pair.contains(session.id) && !vaultSelected && store.section != "launcher"
                    SessionWorkspace(session: session, showFiles: filesMode && store.activeSession == session.id, active: visible && terminalMode, focused: store.activeSession == session.id)
                        .frame(width: pane.width, height: pane.height, alignment: .topLeading)
                        .offset(x: pane.minX, y: pane.minY)
                        .opacity(sceneMember && (filesMode ? store.activeSession == session.id : pair.contains(session.id)) ? 1 : 0)
                        .allowsHitTesting(sceneMember && (filesMode ? store.activeSession == session.id : pair.contains(session.id)))
                }

                // Keep the standalone file workspace mounted while opening logs or other tabs.
                // Its StateObject owns the endpoint lease and directory selection.
                if store.sessions.isEmpty {
                    DisconnectedFilesWorkspace(store: store)
                        .opacity(filesMode ? 1 : 0).allowsHitTesting(filesMode)
                }
                if isScene, store.currentScene?.sessionIDs.isEmpty == true { ContentUnavailableView(store.text("Scene sessions have ended", "场景会话已结束"), systemImage: "terminal", description: Text(store.text("Close and reopen this scene to reconnect its saved hosts.", "关闭并重新打开场景，可重新连接已保存的主机。"))) }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading).clipped()
        }
    }
    func deleteHost(_ host: Host) {
        let confirmation = HostDeletionConfirmationWindowController(host: store.resolvedHost(host), chinese: store.chinese)
        guard confirmation.present() else { return }
        do {
            try store.deleteHost(host.id)
            if selectedHost == host.id { selectedHost = nil }
            if inspectorHost?.id == host.id { inspectorHost = nil }
        } catch { store.error = error.localizedDescription }
    }
}

struct SessionWorkspace: View {
    @ObservedObject private var store: AppStore
    @ObservedObject var session: TerminalSession
    @StateObject var files: FileManagerModel
    var showFiles: Bool
    var active: Bool
    var focused: Bool
    init(session: TerminalSession, showFiles: Bool, active: Bool, focused: Bool) { self.session = session; self.store = session.store; self.showFiles = showFiles; self.active = active; self.focused = focused; _files = StateObject(wrappedValue: FileManagerModel(session: session)) }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if store.paneIDs(containing: session.id).count > 1 && !showFiles {
                        HStack(spacing: 8) {
                            Circle().fill(focused ? Palette.accent : Palette.muted).frame(width: 5, height: 5)
                            Text(session.displayTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer()
                            if session.store.synchronizationReady && session.store.synchronizedTargets.contains(session.id) { Label(session.store.text("Receiving", "同步接收"), systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 10)).foregroundStyle(TerminalChrome.accent) }
                            TerminalFontControls(session: session)
                            Button { session.store.close(session.id) } label: { Image(systemName: "xmark") }.buttonStyle(WorkspaceIconStyle()).help(session.store.text("Close pane", "关闭此分屏")).accessibilityIdentifier("axon-close-pane-" + session.id.uuidString)
                            Button { session.store.separateSession(session.id) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(WorkspaceIconStyle()).help(session.store.text("Separate into tab", "分离为独立标签"))
                        }.padding(.horizontal, 12).frame(height: 32).foregroundStyle(Palette.chromeText).background(Palette.chrome)
                            .onTapGesture { session.store.activeSession = session.id; session.terminal?.window?.makeFirstResponder(session.terminal) }
                    }
                    TerminalSurface(session: session, active: active, focused: focused)
                }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).opacity(showFiles ? 0 : 1).allowsHitTesting(!showFiles)
                if !showFiles && !session.connected && !session.status.isEmpty {
                    HStack(spacing: 10) {
                        Text(session.status).font(.system(size: 12)).lineLimit(2)
                        if session.host != nil { Button { session.reconnect() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(WorkspaceIconStyle()).help(session.store.text("Reconnect", "重新连接")) }
                    }.padding(.horizontal, 12).padding(.vertical, 6).foregroundStyle(Palette.chromeText).background(Palette.chrome).clipShape(RoundedRectangle(cornerRadius: 8)).padding(16)
                }
                if showFiles { FilesView(model: files).environmentObject(session.store) }
            }
        }.background(Color(hex: session.store.workspace.preferences.background)).onChange(of: session.connected) { _, connected in
            if connected && showFiles {
                Task { await files.open() }
            }
        }
        .task(id: showFiles) { if showFiles { session.sceneFiles = files; await files.open() } }
        .task(id: session.store.terminalFileRequest?.id) { if showFiles { await files.openTerminalRequestIfNeeded() } }
        .task(id: session.store.recentFileRequest?.id) {
            if showFiles { await files.openRecentRequestIfNeeded() }
        }
        .onDisappear { if !session.store.sessions.contains(where: { $0.id == session.id }) { files.close() } }
    }
}

struct HostEditor: View {
    @EnvironmentObject var store: AppStore
    @State var host: Host
    var isNew: Bool
    var done: () -> Void
    @State private var secret = ""
    @State private var privateKeyText = ""
    @State private var tagDraft = ""
    @State private var savedTags = ""
    @State private var savedGroup = ""
    @State private var savedGroupDefaults: HostGroup?
    @State private var secretLoaded = false
    @State private var portValid = true
    @State private var credentialLoadError = ""
    @State private var credentialLoadAttempt = 0
    @State private var independentCredential: IndependentHostCredentialDraft?
    @State private var editingCredential: VaultCredential?
    @State private var error = ""
    private var selectedCredential: VaultCredential? { store.workspace.credentials.first { $0.id == host.credentialID } }
    private var groupDefaults: HostGroup? { store.groupDefaults(named: host.group) }
    private var effectiveHost: Host { store.resolvedHost(host) }
    private var inheritsAuthentication: Bool { groupDefaults != nil && host.groupInheritance?.authentication == true }
    private var credentialLoadID: String { "\(host.id)-\(host.credentialID?.uuidString ?? "independent")-\(inheritsAuthentication)-\(credentialLoadAttempt)" }
    private var formValidationError: String? {
        do { _ = try ConnectionValidation.host(effectiveHost, workspace: store.workspace, chinese: store.chinese); try AIExecutionPolicy().mergingCommandLists(host).validate(); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(isNew ? store.text("New host", "新建主机") : store.text("Host details", "主机详情")).font(.system(size: 15, weight: .medium)); Spacer(); DismissIconButton(title: store.text("Close details", "关闭详情"), action: done) }.padding(.horizontal, 18).frame(height: 52)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) { IconTile(symbol: "server.rack", size: 48); VStack(alignment: .leading, spacing: 6) { Text(host.name.isEmpty ? store.text("Unnamed host", "未命名主机") : host.name).font(.system(size: 14, weight: .medium)).lineLimit(1); Text(store.text("Local vault", "本地保险库")).font(.system(size: 11)).foregroundStyle(Palette.muted) } }
                    if !isNew { Button { store.showMonitoring(host) } label: { Label(store.text("View status", "查看状态"), systemImage: "waveform.path.ecg") }.buttonStyle(ChromeButtonStyle()) }
                    sectionTitle(store.text("ADDRESS", "地址"))
                    TextField(store.text("Hostname or IP address", "主机名或 IP 地址"), text: $host.address).appInput()
                    sectionTitle(store.text("GENERAL", "常规"))
                    field(store.text("Label", "名称")) { TextField(store.text("Host label", "主机名称"), text: $host.name).appInput() }
                    field(store.text("Group", "分组")) {
                        GroupPicker(selection: Binding(get: { host.group }, set: chooseGroup), groups: store.groups, chinese: store.chinese).frame(height: 38).disabled(!secretLoaded)
                        if let groupDefaults {
                            Text(store.text("Connection settings can follow \(groupDefaults.name). Turn off “Use group” to set an individual value.", "可复用“\(groupDefaults.name)”的连接设置，关闭“使用分组”即可单独设置。"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    field(store.text("Tags", "标签")) { TagsEditor(tags: $host.tags, pending: $tagDraft, suggestions: store.tags, chinese: store.chinese) }
                    Divider().overlay(Palette.border)
                    HStack { sectionTitle("SSH"); Spacer(); Text(store.text("Enabled", "已启用")).font(.system(size: 11)).foregroundStyle(Palette.accent) }
                    Toggle(store.text("Persistent session (tmux)", "持久会话（tmux）"), isOn: Binding(get: { host.persistentSession ?? false }, set: { host.persistentSession = $0 })).toggleStyle(AxonCheckboxStyle())
                    if host.persistentSession == true {
                        TextField(store.text("Session name · optional", "会话名称 · 可选"), text: Binding(get: { host.persistentSessionName ?? "" }, set: { host.persistentSessionName = $0 })).appInput()
                        Text(store.text("Requires tmux 3.3+ and Bash. Closing a tab keeps remote tasks running.", "需要 tmux 3.3+ 和 Bash；关闭标签后远端任务继续运行。")).font(.caption).foregroundStyle(Palette.muted)
                    }
                    inheritedField(store.text("Port", "端口"), keyPath: \.port) {
                        if groupDefaults != nil && host.groupInheritance?.port == true {
                            Text(String(effectiveHost.port)).frame(maxWidth: .infinity, alignment: .leading).appInput().foregroundStyle(Palette.muted)
                        } else { PortInput(value: $host.port, valid: $portValid, placeholder: "22", label: store.text("SSH port", "SSH 端口")) }
                    }
                    inheritedField(store.text("Username", "用户名"), keyPath: \.username) {
                        if groupDefaults != nil && host.groupInheritance?.username == true || (!inheritsAuthentication && host.credentialID != nil) {
                            Text(effectiveHost.username).frame(maxWidth: .infinity, alignment: .leading).appInput().foregroundStyle(Palette.muted)
                        } else { TextField(store.text("Username", "用户名"), text: $host.username).appInput().disabled(!inheritsAuthentication && host.credentialID != nil) }
                        if !inheritsAuthentication && host.credentialID != nil {
                            Text(store.text("This shared credential owns the username. Use group authentication or an individual login to override it.", "用户名由所选共享凭据提供。可改为分组认证或单独登录后设置。"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    inheritedField(store.text("Login credentials", "登录凭据"), keyPath: \.authentication) {
                    if inheritsAuthentication {
                        HStack(spacing: 10) { Image(systemName: effectiveHost.auth == "key" ? "key.fill" : "lock.fill"); Text(effectiveHost.auth == "key" ? store.text("Group private key", "使用分组私钥") : store.text("Group password", "使用分组密码")); Spacer() }
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).appInput()
                        Text(store.text("The group's current authentication is used on connection. No need to enter it again.", "连接时使用分组当前的认证设置，无需再次填写。"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    } else {
                        CredentialPicker(selectedID: Binding(get: { host.credentialID }, set: { chooseCredential($0) }),
                                         credentials: store.workspace.credentials, chinese: store.chinese,
                                         enabled: secretLoaded, onNew: {}, allowsCreation: false)
                            .frame(maxWidth: .infinity).frame(height: CredentialPickerButton.fieldHeight)
                        if let credential = selectedCredential {
                            Text(store.text("This host uses the shared username and authentication below. Edit the shared credential to change them, or choose “Set up for this host”.", "此主机使用共享的用户名和认证方式。可编辑共享凭据，或选择“仅用于此主机”单独设置。"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Button(store.text("Edit shared credential", "编辑共享凭据")) { editingCredential = credential }.buttonStyle(ChromeButtonStyle())
                        } else {
                            Text(store.text("The username and password or key below are used only by this host. Manage shared credentials in the credential vault.", "下方用户名和密码或私钥仅用于此主机，共享凭据可在凭据库中管理。"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    }
                    if !inheritsAuthentication {
                    field(store.text("Authentication", "认证")) {
                        AxonChoiceField(selection: $host.auth, choices: [("password", store.text("Password", "密码")), ("key", store.text("Private key", "私钥")), ("agent", store.text("Local SSH Agent", "本机 SSH Agent"))], placeholder: store.text("Authentication", "认证"), symbol: "key", identifier: "axon-host-authentication").disabled(!secretLoaded || host.credentialID != nil)
                            .onChange(of: host.auth) { _, value in if value == "key", host.keySource == nil, host.keyPath.isEmpty { host.keySource = "text" } }
                        if !credentialLoadError.isEmpty {
                            Text(credentialLoadError).font(.system(size: 11)).foregroundStyle(.red)
                            if !secretLoaded { Button(store.text("Retry reading credentials", "重新读取凭据")) { credentialLoadAttempt += 1 }.buttonStyle(ChromeButtonStyle()) }
                        } else if !secretLoaded {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(store.text("Reading saved credentials…", "正在读取已保存的凭据…")) }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    if host.auth == "key" {
                        field(store.text("Private key", "私钥")) {
                            if host.credentialID == nil { PrivateKeyInput(source: $host.keySource, path: $host.keyPath, text: $privateKeyText).disabled(!secretLoaded) }
                            else { Text(host.keySource == "text" ? store.text("Text key from shared identity", "使用共享身份中的文本私钥") : host.keyPath).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        }
                    }
                    if host.auth == "agent" {
                        SSHAgentHostFields(host: $host)
                    } else {
                    field(host.auth == "key" ? store.text("Passphrase", "私钥口令") : store.text("Password", "密码")) { PreferencesSecureField(title: store.text("Optional", "可稍后输入"), text: $secret, identifier: "axon-host-secret", chinese: store.chinese).appInput().disabled(!secretLoaded || host.credentialID != nil) }
                    Text(host.credentialID == nil ? store.text("Credentials are saved in macOS Keychain.", "凭据保存在 macOS 钥匙串中。 ") : store.text("Shared secrets are saved in macOS Keychain. Future connections use the shared credential's current values.", "共享凭据保存在 macOS 钥匙串中，后续连接使用它的最新设置。 ")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    }
                    Divider().overlay(Palette.border)
                    sectionTitle(store.text("ADVANCED", "高级"))
                    SSHCompatibilityFields(host: $host)
                    SSHDiagnosticsControl(host: effectiveHost)
                    DisclosureGroup(store.text("AI command permissions", "AI 命令权限")) { AIHostCommandRules(host: $host).padding(.top, 8) }.font(.system(size: 12)).accessibilityIdentifier("axon-host-ai-rules")
                    inheritedField(store.text("Jump host", "跳板机"), keyPath: \.jumpHost) {
                        if groupDefaults != nil && host.groupInheritance?.jumpHost == true {
                            Text(effectiveHost.jumpHostID.flatMap { id in store.workspace.hosts.first { $0.id == id } }.map { $0.name.isEmpty ? $0.address : $0.name } ?? store.text("None · direct connection", "无 · 直接连接")).frame(maxWidth: .infinity, alignment: .leading).appInput().foregroundStyle(Palette.muted)
                        } else {
                            JumpHostPicker(selection: $host.jumpHostID, host: effectiveHost, hosts: store.workspace.hosts.map(store.resolvedHost), chinese: store.chinese).frame(height: 38)
                        }
                    }
                }.padding(18)
            }
            if !error.isEmpty || (formValidationError != nil && (!isNew || !host.address.isEmpty)) {
                Text(error.isEmpty ? (formValidationError ?? "") : error).font(.system(size: 11)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 10) {
                Button(store.text("Save", "保存")) { save(connect: false) }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.return, modifiers: .command)
                Button { save(connect: true) } label: { Label(store.text("Connect", "连接"), systemImage: "terminal") }.buttonStyle(ChromeButtonStyle(prominent: true))
            }.frame(maxWidth: .infinity).padding(16).disabled(!secretLoaded || (!portValid && host.groupInheritance?.port != true) || formValidationError != nil)
        }.onAppear { savedTags = host.tags; savedGroup = host.group; savedGroupDefaults = groupDefaults }
        .onChange(of: store.workspace.groupDefaults) { _, _ in
            if let current = groupDefaults { savedGroupDefaults = current }
        }
        .onChange(of: store.workspace.hosts) { _, hosts in
            guard let saved = hosts.first(where: { $0.id == host.id }) else { return }
            if saved.tags != savedTags {
                let oldTags = TagTokens.parse(savedTags)
                let newTags = TagTokens.parse(saved.tags)
                let removed = oldTags.filter { !CatalogNames.contains(newTags, $0) }
                let added = newTags.filter { !CatalogNames.contains(oldTags, $0) }
                host.tags = TagTokens.serialized(TagTokens.parse(host.tags).filter { !CatalogNames.contains(removed, $0) }.map { tag in newTags.first { CatalogNames.matches($0, tag) } ?? tag } + added)
                savedTags = saved.tags
            }
            if saved.group != savedGroup {
                if CatalogNames.matches(host.group, savedGroup) {
                    if saved.group.isEmpty, let defaults = savedGroupDefaults, host.groupInheritance?.hasAny == true {
                        let inheritedAuthentication = host.groupInheritance?.authentication == true
                        var previous = store.workspace; previous.groupDefaults = [defaults]
                        host = GroupDefaults.resolved(host, workspace: previous)
                        if inheritedAuthentication {
                            // Store deletion copied inherited secrets to the host.
                            // Refresh that copy before a subsequent editor save.
                            independentCredential = nil; credentialLoadAttempt += 1
                        }
                    }
                    host.group = saved.group
                }
                savedGroup = saved.group
                savedGroupDefaults = groupDefaults
            }
        }
        .sheet(item: $editingCredential) { value in
            CredentialEditor(value: value, onSaved: { saved in
                chooseCredential(saved.id)
                applySharedCredential(saved)
            }).environmentObject(store)
        }.task(id: credentialLoadID) {
            secretLoaded = false
            credentialLoadError = ""
            let selectedID = host.credentialID
            let id = host.id
            if inheritsAuthentication { secretLoaded = true; return }
            if let selectedID {
                guard let credential = store.workspace.credentials.first(where: { $0.id == selectedID }) else {
                    credentialLoadError = store.text("The shared credential is unavailable. Choose a different credential.", "共享凭据已不存在，请选择其他凭据。")
                    secretLoaded = true
                    return
                }
                applySharedCredential(credential)
                secret = ""; privateKeyText = ""; secretLoaded = true
                return
            }
            if let draft = independentCredential {
                draft.apply(to: &host)
                secret = draft.secret; privateKeyText = draft.privateKey; secretLoaded = true
                return
            }
            if isNew { secretLoaded = true; return }
            do {
                let saved = try await Task.detached { try Secrets.readCredential(id) }.value
                guard !Task.isCancelled, host.credentialID == selectedID else { return }
                secret = saved.secret; privateKeyText = saved.privateKey; secretLoaded = true
            } catch {
                guard !Task.isCancelled, host.credentialID == selectedID else { return }
                credentialLoadError = error.localizedDescription
            }
        }
    }
    func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted) }
    func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted); content() } }
    func inheritedField<Content: View>(_ title: String, keyPath: WritableKeyPath<HostGroupInheritance, Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                if groupDefaults != nil {
                    GroupSettingToggle(isOn: Binding(get: { host.groupInheritance?[keyPath: keyPath] ?? false }, set: { value in setInheritance(value, keyPath: keyPath) }), title: store.text("Use group", "使用分组"), label: title + store.text(": Use group", "：使用分组"), identifier: "axon-group-inherit-" + inheritanceName(keyPath)).frame(width: 96, height: 22)
                        .disabled(!secretLoaded || (keyPath == \.username && !inheritsAuthentication && host.credentialID != nil))
                }
            }
            content()
        }
    }
    private func inheritanceName(_ keyPath: WritableKeyPath<HostGroupInheritance, Bool>) -> String {
        if keyPath == \.port { return "port" }
        if keyPath == \.username { return "username" }
        if keyPath == \.authentication { return "authentication" }
        return "jump"
    }
    private func setInheritance(_ enabled: Bool, keyPath: WritableKeyPath<HostGroupInheritance, Bool>) {
        if keyPath == \.authentication {
            if enabled, !inheritsAuthentication, secretLoaded, host.credentialID == nil {
                independentCredential = IndependentHostCredentialDraft(host: host, secret: secret, privateKey: privateKeyText)
            } else if !enabled, inheritsAuthentication, independentCredential == nil, host.credentialID == nil {
                detachGroupAuthentication { applyInheritance(false, keyPath: keyPath) }
                return
            }
        }
        applyInheritance(enabled, keyPath: keyPath)
    }
    private func applyInheritance(_ enabled: Bool, keyPath: WritableKeyPath<HostGroupInheritance, Bool>) {
        var flags = host.groupInheritance ?? HostGroupInheritance(port: false, username: false, authentication: false, jumpHost: false)
        flags[keyPath: keyPath] = enabled
        if keyPath == \.authentication, !enabled, host.credentialID != nil { flags.username = false }
        host.groupInheritance = flags
    }
    private func detachGroupAuthentication(after: @escaping () -> Void) {
        let original = host
        let resolved = effectiveHost
        let secretID = store.groupSecretID(for: original)
        secretLoaded = false; credentialLoadError = ""
        Task { @MainActor in
            do {
                let material = try await Task.detached { try Secrets.readCredential(secretID) }.value
                guard host.id == original.id, CatalogNames.matches(host.group, original.group), host.groupInheritance?.authentication == true else { return }
                independentCredential = IndependentHostCredentialDraft(host: resolved, secret: material.secret, privateKey: material.privateKey)
                secret = material.secret; privateKeyText = material.privateKey
                secretLoaded = true; after()
            } catch {
                credentialLoadError = error.localizedDescription
                self.error = error.localizedDescription; secretLoaded = true
            }
        }
    }
    private func chooseGroup(_ name: String) {
        guard !CatalogNames.matches(host.group, name) else { return }
        if groupDefaults != nil, host.groupInheritance?.hasAny == true, store.groupDefaults(named: name) == nil {
            let resolved = effectiveHost
            if inheritsAuthentication {
                detachGroupAuthentication {
                    host = resolved; host.group = name; host.groupInheritance = nil
                    savedGroupDefaults = nil
                }
            } else {
                host = resolved; host.group = name; host.groupInheritance = nil; savedGroupDefaults = nil
            }
        } else {
            if store.groupDefaults(named: name) != nil, !inheritsAuthentication, host.credentialID == nil, secretLoaded {
                independentCredential = IndependentHostCredentialDraft(host: host, secret: secret, privateKey: privateKeyText)
            }
            host.group = name; host.groupInheritance = store.groupDefaults(named: name) == nil ? nil : .all
            savedGroupDefaults = groupDefaults
        }
    }
    private func applySharedCredential(_ value: VaultCredential) {
        host.username = value.username; host.auth = value.auth; host.keyPath = value.keyPath; host.keySource = value.keySource
    }
    private func chooseCredential(_ id: UUID?) {
        guard host.credentialID != id else { return }
        if host.credentialID == nil, secretLoaded {
            independentCredential = IndependentHostCredentialDraft(host: host, secret: secret, privateKey: privateKeyText)
        } else if id == nil, independentCredential == nil {
            // A host that started with a shared identity has no editable secret
            // loaded. Detaching starts an explicit empty credential draft.
            independentCredential = IndependentHostCredentialDraft(host: host, secret: "", privateKey: "")
        }
        host.credentialID = id
        if id != nil, host.groupInheritance != nil { host.groupInheritance?.username = false }
        secretLoaded = false; error = ""
    }
    func save(connect: Bool) {
        guard secretLoaded, portValid || (groupDefaults != nil && host.groupInheritance?.port == true) else { error = store.text("Enter a port from 1 to 65535 and wait for credentials to load.", "请输入 1–65535 的端口，并等待凭据读取完成。"); return }
        host.tags = TagTokens.committing(host.tags, draft: tagDraft); tagDraft = ""
        if let original = store.workspace.hosts.first(where: { $0.id == host.id }) { host.favorite = original.favorite }
        do { try store.upsert(host, secret: secret, privateKey: privateKeyText); if connect, let saved = store.workspace.hosts.first(where: { $0.id == host.id }) { store.connect(saved) }; done() } catch { self.error = error.localizedDescription }
    }
}

struct SessionTab: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var session: TerminalSession
    var showTools: () -> Void
    var selected: Bool { store.samePaneGroup(store.activeSession, session.id) && store.section == "terminal" }
    var index: Int? { store.sessions.firstIndex(where: { $0.id == session.id }) }
    var body: some View {
        NativeSessionTab(id: session.id, title: store.paneIDs(containing: session.id).compactMap { key in store.sessions.first { $0.id == key }?.displayTitle }.joined(separator: " | "), selected: selected, connected: session.connected,
                         dark: store.section == "terminal", chinese: store.chinese, remote: session.host != nil,
                         canMoveLeft: (index ?? 0) > 0, canMoveRight: (index ?? store.sessions.count) < store.sessions.count - 1,
                         onAction: performAction, canDropSession: { id in store.sessions.contains { $0.id == id } },
                         onDropSession: { id, placement in
            switch placement {
            case .before: store.moveSession(id, before: session.id)
            case .after: store.moveSession(id, after: session.id)
            case .split: store.pairSessions(id, with: session.id)
            }
        }).frame(width: selected ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive, height: 34)
            .focusEffectDisabled()
    }
    func performAction(_ action: SessionTabAction) {
        switch action {
        case .select: store.activeSession = session.id; store.section = "terminal"
        case .close: store.closeTerminalTab(session.id)
        case .separate: store.separateSession(session.id)
        case .tools: showTools()
        case .duplicate: store.connect(session.host)
        case .split: store.activeSession = session.id; store.split()
        case .reconnect: session.reconnect()
        case .moveLeft: store.moveSession(session.id, by: -1)
        case .moveRight: store.moveSession(session.id, by: 1)
        case .moveFirst: store.moveSessionToBeginning(session.id)
        case .moveLast: store.moveSessionToEnd(session.id)
        case .closeOthers: let keep = store.paneIDs(containing: session.id); for id in store.standaloneSessions.map(\.id) where !keep.contains(id) { store.close(id) }
        }
    }
}

@MainActor enum AxonAboutPanel {
    static func centeredFrame(size: NSSize, parent: NSRect, visible: NSRect) -> NSRect {
        NSRect(x: max(visible.minX, min(parent.midX - size.width / 2, visible.maxX - size.width)),
               y: max(visible.minY, min(parent.midY - size.height / 2, visible.maxY - size.height)),
               width: size.width, height: size.height)
    }
    private static weak var panel: NSWindow?
    @discardableResult static func show(relativeTo parent: NSWindow? = nil) -> NSWindow? {
        let parent = parent ?? NSApp.keyWindow ?? NSApp.mainWindow
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(nil)
        let presented = panel ?? NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel }
        guard let presented else { return nil }
        panel = presented
        if let parent, parent !== presented, let screen = parent.screen {
            presented.setFrame(centeredFrame(size: presented.frame.size, parent: parent.frame, visible: screen.visibleFrame), display: true)
        } else if parent !== presented { presented.center() }
        return presented
    }
}
