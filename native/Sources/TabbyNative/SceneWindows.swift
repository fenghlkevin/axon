import AppKit
import SwiftUI
import Combine

/// Only changed fields are committed, so independent window snapshots cannot erase sibling changes.
enum SceneWorkspaceMerge {
    static func apply(base: Workspace, edited: Workspace, current: Workspace) throws -> Workspace {
        let encoder = JSONEncoder()
        func object(_ value: Workspace) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        let merged = merge(try object(base), try object(edited), try object(current))
        return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: merged))
    }
    private static func same(_ a: Any, _ b: Any) -> Bool { (a as? NSObject)?.isEqual(b) == true }
    private static func merge(_ base: Any, _ edited: Any, _ current: Any) -> Any {
        if same(base, edited) { return current }
        if let old = base as? [String: Any], let new = edited as? [String: Any] {
            var result = current as? [String: Any] ?? [:]
            for key in Set(old.keys).union(new.keys) {
                guard let incoming = new[key] else { result.removeValue(forKey: key); continue }
                if let previous = old[key] { result[key] = merge(previous, incoming, result[key] ?? previous) }
                else { result[key] = incoming }
            }
            return result
        }
        if let old = base as? [Any], let new = edited as? [Any], let live = current as? [Any] {
            func id(_ item: Any) -> String? { (item as? [String: Any])?["id"] as? String }
            if (old + new + live).allSatisfy({ id($0) != nil }) {
                let oldIDs = Set(old.compactMap(id)), newIDs = Set(new.compactMap(id))
                var result = live.filter { !oldIDs.subtracting(newIDs).contains(id($0)!) }
                for item in new {
                    let key = id(item)!
                    if let previous = old.first(where: { id($0) == key }) {
                        if let index = result.firstIndex(where: { id($0) == key }) { result[index] = merge(previous, item, result[index]) }
                        else if !same(previous, item) { result.append(item) }
                    } else if !result.contains(where: { id($0) == key }) { result.append(item) }
                }
                if old.compactMap(id) != new.compactMap(id) {
                    let order = new.compactMap(id)
                    result.sort { (order.firstIndex(of: id($0)!) ?? Int.max) < (order.firstIndex(of: id($1)!) ?? Int.max) }
                }
                return result
            }
            var result = live.filter { item in !old.contains(where: { same($0, item) }) || new.contains(where: { same($0, item) }) }
            for item in new where !old.contains(where: { same($0, item) }) && !result.contains(where: { same($0, item) }) { result.append(item) }
            return result
        }
        return edited
    }
}

@MainActor final class SceneWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [String: SceneWindowController] = [:]
    static func shortcutStore(for window: NSWindow) -> AppStore? { windows.values.first { $0.window === window }?.store }
    static var focusedStore: AppStore? { windows.values.first { $0.window === NSApp.keyWindow || $0.window === NSApp.keyWindow?.sheetParent || $0.window === NSApp.mainWindow }?.store }
    let store: AppStore
    private weak var parentStore: AppStore?
    private var baseline: Workspace
    private let sceneID: UUID
    private let registryKey: String
    private var changes: AnyCancellable?
    private var cleaned = false
    private var openingTabs: Task<Void, Never>?

    @discardableResult static func open(_ definition: WorkScene, owner: AppStore) throws -> SceneWindowController {
        let owner = owner.sceneWindowOwner ?? owner
        let key = String(describing: ObjectIdentifier(owner)) + definition.id.uuidString
        if let existing = windows[key] { if existing.store.openScenes.isEmpty { _ = try existing.store.openScene(definition) }; existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return existing }
        let controller = try SceneWindowController(definition: definition, owner: owner, key: key)
        windows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }
    static func activateAIWindow(for store: AppStore) {
        if let controller = windows.values.first(where: { $0.store === store }) { controller.window?.makeKeyAndOrderFront(nil) }
        else { NSApp.windows.first(where: { $0.title == "Axon" })?.makeKeyAndOrderFront(nil) }
    }
    static func closeFocused() { windows.values.first { $0.store === focusedStore }?.close() }
    static func closeAll() { for controller in Array(windows.values) { controller.close() } }
    private init(definition: WorkScene, owner: AppStore, key: String) throws {
        self.parentStore = owner; baseline = owner.workspace; sceneID = definition.id; registryKey = key
        store = AppStore(fileURL: owner.fileURL, aiNamespace: definition.id); store.workspace = owner.workspace; store.sceneWindowID = definition.id; store.sceneWindowOwner = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.isMovableByWindowBackground = false
        window.title = definition.name + " · Axon"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1050, height: 680); window.isReleasedWhenClosed = false; window.delegate = self
        store.sharedWorkspaceCommit = { [weak self] edited in
            guard let self, let owner = self.parentStore else { return false }
            let previous = owner.workspace
            do { owner.workspace = try SceneWorkspaceMerge.apply(base: self.baseline, edited: edited, current: previous) }
            catch { self.store.error = error.localizedDescription; return false }
            guard owner.save() else { owner.workspace = previous; self.store.error = owner.error; return false }
            self.baseline = owner.workspace; self.store.workspace = owner.workspace
            return true
        }
        changes = owner.$workspace.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, let owner = self.parentStore else { return }
            self.baseline = owner.workspace; self.store.workspace = owner.workspace
        }
        let runtime = try store.openScene(definition)
        store.showScene(runtime)
        window.contentView = NSHostingView(rootView: MainView().environmentObject(store).preferredColorScheme(.light).tint(Palette.accent).ignoresSafeArea(.container, edges: .top))
        window.center()
        openingTabs = Task { [weak self] in
            guard let self else { return }
            await Task.yield()
            for _ in 0..<600 {
                if Task.isCancelled { return }
                if self.store.sessions.allSatisfy({ $0.connected || (!$0.connectionInProgress && !$0.status.isEmpty) }) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }

            for location in definition.logFiles { self.store.openSceneLog(location) }
            self.store.showTerminalSection()
        }
    }
    required init?(coder: NSCoder) { fatalError("Unsupported") }
    func windowWillClose(_ notification: Notification) {
        guard !cleaned else { return }; cleaned = true
        openingTabs?.cancel(); changes?.cancel(); store.aiSessions.forEach { $0.cancel() }; store.closeScene(sceneID); store.batchTasks.cancelAll(); store.externalEdits.edits.forEach { $0.stop() }; store.monitoring.stop(); store.automaticBackup.cancel()
        for id in Array(store.forwardTasks.keys) { store.stopForward(id) }
        for session in Array(store.sessions) { store.close(session.id) }
        for log in Array(store.logViewers) { store.closeLogViewer(log.id) }
        Self.windows.removeValue(forKey: registryKey)
    }
}
