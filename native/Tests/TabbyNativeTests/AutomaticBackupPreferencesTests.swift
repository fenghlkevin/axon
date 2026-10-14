import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AutomaticBackupPreferencesTests: XCTestCase {
    func testAutomaticBackupUsesOnlySharedTopPasswordAndCredentialOption() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility(); defer { restoreAccessibility() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Backup folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        let selection = try AutomaticBackupPersistence.chooseFolder(folder)
        var settings = AutomaticBackupSettings()
        settings.folderBookmark = selection.bookmark; settings.folderPath = selection.path
        try JSONEncoder().encode(settings).write(to: AutomaticBackupPersistence.url(workspaceURL: store.fileURL))
        defer { try? Secrets.save("", id: settings.passwordID) }
        let coordinator = store.automaticBackup
        let hosting = NSHostingView(rootView: ScrollView { CloudBackupPreferencesPane().padding(24) }
            .environmentObject(store).preferredColorScheme(.light))
        let window = show(hosting); defer { window.close() }
        try await settle(hosting)
        try pressToggle("axon-auto-folder-enabled", in: hosting)
        try await settle(hosting)
        let field = try XCTUnwrap(find(NSSecureTextField.self, in: hosting).first { $0.identifier?.rawValue == "axon-cloud-password" })
        XCTAssertNil(find(NSSecureTextField.self, in: hosting).first { $0.identifier?.rawValue == "axon-auto-password" })
        XCTAssertFalse(accessibilityObjects(hosting).contains { read($0, "accessibilityIdentifier") as? String == "axon-auto-include-secrets" })
        XCTAssertFalse(accessibilityObjects(hosting).contains { read($0, "accessibilityIdentifier") as? String == "axon-auto-s3-prefix" })
        let run = try button("axon-auto-run", in: hosting)
        XCTAssertFalse(run.isEnabled)
        let editor = try beginEditing(field, in: window)
        editor.insertText("12345678", replacementRange: editor.selectedRange())
        try await settle(hosting)
        editor.deleteBackward(nil)
        try await settle(hosting)
        editor.insertText("8", replacementRange: editor.selectedRange())
        try await settle(hosting)
        try pressToggle("axon-cloud-include-secrets", in: hosting)
        try await settle(hosting)
        try await settle(hosting)
        XCTAssertTrue(run.isEnabled)
        XCTAssertEqual(field.stringValue, "12345678", "Saving automatic settings must keep the shared top password available")
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID, allowInteraction: false), "12345678")
        XCTAssertTrue(try AutomaticBackupPersistence.load(workspaceURL: store.fileURL).folderEnabled)
        XCTAssertTrue(try AutomaticBackupPersistence.load(workspaceURL: store.fileURL).includeSecrets)
        let metadata = try String(contentsOf: AutomaticBackupPersistence.url(workspaceURL: store.fileURL), encoding: .utf8)
        XCTAssertFalse(metadata.contains("12345678"))

        let newEditor = try beginEditing(field, in: window)
        newEditor.selectAll(nil); newEditor.deleteBackward(nil)
        try await settle(hosting)
        XCTAssertFalse(run.isEnabled)
        XCTAssertFalse(run.accessibilityPerformPress())
        run.performClick(nil)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), "12345678", "Clearing the shared draft must not silently reuse or delete the persisted password")
        newEditor.insertText("changed-password-fixture", replacementRange: newEditor.selectedRange())
        try await settle(hosting)
        XCTAssertTrue(run.isEnabled, "A valid shared password applies automatically")
        try await settle(hosting)
        XCTAssertTrue(run.isEnabled)
        XCTAssertEqual(field.stringValue, "changed-password-fixture")
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), "changed-password-fixture")
        try pressToggle("axon-cloud-include-secrets", in: hosting)
        try await settle(hosting)
        XCTAssertTrue(run.isEnabled)
        try await settle(hosting)
        XCTAssertFalse(try AutomaticBackupPersistence.load(workspaceURL: store.fileURL).includeSecrets)
        XCTAssertTrue(run.isEnabled)
        let finalEditor = try beginEditing(field, in: window)
        finalEditor.selectAll(nil); finalEditor.deleteBackward(nil)
        try await settle(hosting)
        XCTAssertFalse(run.isEnabled)
        try pressToggle("axon-auto-folder-enabled", in: hosting)
        try await settle(hosting)
        XCTAssertFalse(run.isEnabled)
        try await settle(hosting)
        XCTAssertFalse(try AutomaticBackupPersistence.load(workspaceURL: store.fileURL).isEnabled)
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), "")
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty,
                      "Saving a policy must not itself send or create a backup")
    }

    func testCloudPaneLoadsSharedSavedOptionsAndRunNowUsesThemInActualEncryptedFile() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility(); defer { restoreAccessibility() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        var host = TabbyNative.Host()
        host.name = "Shared cloud backup fixture"; host.address = "shared-backup.example.invalid"
        store.workspace.hosts = [host]
        try Secrets.save("host-password-fixture", id: host.id)
        defer { try? Secrets.save("", id: host.id) }
        let selection = try AutomaticBackupPersistence.chooseFolder(folder)
        var settings = AutomaticBackupSettings()
        settings.folderEnabled = true; settings.includeSecrets = true
        settings.folderBookmark = selection.bookmark; settings.folderPath = selection.path
        settings.s3Prefix = "Saved/CustomPrefix"
        let password = "automatic-ui-fixture"
        try AutomaticBackupPersistence.save(settings, password: password, workspaceURL: store.fileURL)
        defer { try? Secrets.save("", id: settings.passwordID) }
        let coordinator = store.automaticBackup
        let hosting = NSHostingView(rootView: ScrollView { CloudBackupPreferencesPane().padding(24) }
            .environmentObject(store).preferredColorScheme(.light))
        let window = show(hosting); defer { window.close() }
        try await settle(hosting)
        let field = try XCTUnwrap(find(NSSecureTextField.self, in: hosting).first { $0.identifier?.rawValue == "axon-cloud-password" })
        XCTAssertEqual(field.stringValue, password)
        let run = try button("axon-auto-run", in: hosting)
        XCTAssertTrue(run.isEnabled)
        run.performClick(nil)
        XCTAssertTrue(coordinator.isRunning)
        await coordinator.waitUntilFinished()
        try await settle(hosting)
        XCTAssertFalse(coordinator.isRunning); XCTAssertTrue(run.isEnabled)
        XCTAssertEqual(coordinator.report.folder?.succeeded, true)
        let output = try XCTUnwrap(coordinator.report.folder?.location)
        XCTAssertEqual(URL(fileURLWithPath: output).lastPathComponent, "Axon-latest.axonbackup")
        let archive = try WorkspaceArchiveCodec.decode(Data(contentsOf: URL(fileURLWithPath: output)), password: password)
        XCTAssertEqual(archive.workspace.preferences.language, "en-US")
        XCTAssertEqual(archive.secrets?[host.id.uuidString]?.secret, "host-password-fixture")
        XCTAssertNotNil(accessibilityObjects(hosting).first { read($0, "accessibilityIdentifier") as? String == "axon-auto-folder-status" })
        XCTAssertTrue(try AutomaticBackupPersistence.loadReport(workspaceURL: store.fileURL).folder?.succeeded == true)
        try pressToggle("axon-cloud-include-secrets", in: hosting)
        try await settle(hosting)
        XCTAssertTrue(run.isEnabled)
        run.performClick(nil)
        await coordinator.waitUntilFinished()
        try await settle(hosting)
        let updated = try WorkspaceArchiveCodec.decode(Data(contentsOf: URL(fileURLWithPath: output)), password: password)
        XCTAssertTrue(updated.secrets?.isEmpty ?? true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Axon-latest.axonbackup"])
        XCTAssertEqual(try AutomaticBackupPersistence.load(workspaceURL: store.fileURL).s3Prefix, "Saved/CustomPrefix",
                       "Removing the editable automatic prefix must preserve the existing target")
        XCTAssertEqual(try Secrets.readChecked(host.id), "host-password-fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "Backup cannot commit user preference drafts")
    }

    func testApplicationLaunchStartsBackupOnceWithStoreAssignedBeforeOrAfterLaunch() async throws {
        _ = NSApplication.shared
        for storeAssignedFirst in [true, false] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let folder = directory.appendingPathComponent("Backups")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
            store.applicationIconController = nil
            var settings = AutomaticBackupSettings()
            settings.folderEnabled = true
            let selection = try AutomaticBackupPersistence.chooseFolder(folder)
            settings.folderBookmark = selection.bookmark; settings.folderPath = selection.path
            try AutomaticBackupPersistence.save(settings, password: "launch-fixture-password", workspaceURL: store.fileURL)
            defer { try? Secrets.save("", id: settings.passwordID) }
            let delegate = ApplicationDelegate()
            if storeAssignedFirst { delegate.store = store }
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            if !storeAssignedFirst { delegate.store = store }
            delegate.store = store
            await store.automaticBackup.waitUntilFinished()
            delegate.store = store
            await store.automaticBackup.waitUntilFinished()
            XCTAssertEqual(store.automaticBackup.report.folder?.succeeded, true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-auto-preferences-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func beginEditing(_ field: NSSecureTextField, in window: NSWindow) throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(field)); field.selectText(nil)
        return try XCTUnwrap(field.currentEditor() as? NSTextView)
    }
    private func button(_ id: String, in root: NSView) throws -> PreferencesRectNativeButton {
        try XCTUnwrap(find(PreferencesRectNativeButton.self, in: root).first { $0.identifier?.rawValue == id })
    }
    private func pressToggle(_ id: String, in root: NSView) throws {
        let toggle = try XCTUnwrap(accessibilityObjects(root).first {
            read($0, "accessibilityIdentifier") as? String == id && read($0, "accessibilityRole") as? String == NSAccessibility.Role.checkBox.rawValue
        })
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(toggle.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(toggle.method(for: selector), to: Press.self)(toggle, selector))
    }
    private func show<V: View>(_ hosting: NSHostingView<V>) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        return window
    }
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) }
    }
    private func read(_ element: NSObject, _ key: String) -> Any? {
        element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
    }
    private func accessibilityObjects(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in read(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root); return result
    }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key)
        NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
}
