import XCTest
import SwiftTerm
import Combine
import AppKit
import SwiftUI
@testable import TabbyNative

final class CommandHistoryTests: XCTestCase {
    func testBootstrapStatementsStayBelowCanonicalPTYLineLimit() {
        let script = CommandHistoryProtocol.script(token: UUID().uuidString)
        XCTAssertTrue(script.components(separatedBy: "\n").allSatisfy { $0.utf8.count < 1000 })
    }
    func testProtocolRequiresSessionTokenAndPreservesEditedMultilineCommand() {
        let command = "printf '%s\\n' '中文'\nls -la"
        let payload = "axon-command;current;" + Data(command.utf8).base64EncodedString()
        XCTAssertEqual(CommandHistoryProtocol.decode(payload, token: "current"), command)
        XCTAssertNil(CommandHistoryProtocol.decode(payload, token: "other"))
        XCTAssertNil(CommandHistoryProtocol.decode("axon-command;current;invalid!", token: "current"))
        XCTAssertNil(CommandHistoryProtocol.decode("axon-command;current;" + Data(repeating: 65, count: 8193).base64EncodedString(), token: "current"))
    }
    func testSecretCommandsAndIntegrationAreExcluded() {
        for value in ["curl --password secret", "export API_TOKEN=abc", "curl -H 'Authorization: Bearer abc'", "sshpass -p password ssh host", "_axon_history_prompt", "printf 'axon-command;token;ready'", "pwd\u{1b}"] { XCTAssertFalse(CommandHistoryProtocol.allowed(value), value) }
        for value in ["ls -la", "sudo systemctl status nginx", "printf '%s' 中文", "cat a\ncat b"] { XCTAssertTrue(CommandHistoryProtocol.allowed(value), value) }
    }
    func testCompoundBootstrapIsExcludedButUserReferencesArePreserved() throws {
        let lines = CommandHistoryProtocol.script(token: "fixture").components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("if [ -n \"${ZSH_VERSION-}\"") })
        let compound = lines.dropFirst(start).joined(separator: "; ")
        XCTAssertTrue(compound.hasPrefix("if ["))
        XCTAssertTrue(CommandHistoryProtocol.isInternalIntegration(compound))
        XCTAssertFalse(CommandHistoryProtocol.allowed(compound))
        for command in ["grep _axon_history_emit ~/.zshrc", "printf '%s' _axon_history_finish", "if [ -n \"${ZSH_VERSION-}\" ]; then echo zsh; fi"] {
            XCTAssertFalse(CommandHistoryProtocol.isInternalIntegration(command))
            XCTAssertTrue(CommandHistoryProtocol.allowed(command))
        }
    }
    @MainActor func testLegacyBootstrapIsCleanedAndUserMetadataPersistsAndRenders() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("commands.json")
        let lines = CommandHistoryProtocol.script(token: "fixture").components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("if [ -n \"${ZSH_VERSION-}\"") })
        let compound = lines.dropFirst(start).joined(separator: "; ")
        let internalEntry = ExecutedCommand(hostID: nil, hostName: "Local", sessionID: UUID(), command: compound)
        let user = ExecutedCommand(hostID: nil, hostName: "Local", sessionID: UUID(), command: "ls -la", directory: "/root", exitCode: 0, duration: 2)
        try JSONEncoder().encode([internalEntry, user]).write(to: url)
        let history = CommandHistoryStore(fileURL: url)
        XCTAssertEqual(history.entries, [user]); XCTAssertEqual(CommandHistoryStore(fileURL: url).entries, [user])
        history.append(internalEntry); XCTAssertEqual(history.entries, [user])
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        for width: CGFloat in [1050, 1400] {
            let hosting = NSHostingView(rootView: OperationHistoryView(history: history, server: "local").environmentObject(store).font(.system(size: 13)).foregroundStyle(Palette.text).background(Palette.background).preferredColorScheme(.light)); hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
            if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
                let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("history-user-only-\(Int(width)).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    @MainActor func testPersistenceBoundAndClearWithPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let entries = (0..<1000).map { ExecutedCommand(hostID: nil, hostName: "Local", sessionID: UUID(), command: "echo \($0)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url)
        let history = CommandHistoryStore(fileURL: url)
        history.append(ExecutedCommand(hostID: nil, hostName: "Local", sessionID: UUID(), command: "pwd"))
        XCTAssertEqual(history.entries.count, 1000); XCTAssertEqual(history.entries.first?.command, "pwd")
        let restored = CommandHistoryStore(fileURL: url)
        XCTAssertEqual(restored.entries, history.entries)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        history.clear(); XCTAssertTrue(CommandHistoryStore(fileURL: url).entries.isEmpty)
    }
    @MainActor func testSessionHandshakePauseAndStaleReportsDoNotRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let history = CommandHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store); session.commandHistoryStore = history
        session.commandHistoryToken = "active"
        let payload = "axon-command;active;" + Data("pwd".utf8).base64EncodedString()
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(session.receiveCommandHistory("axon-command;active;ready"))
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertEqual(history.entries.count, 1)
        session.commandHistoryRecording = false
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertEqual(history.entries.count, 1)
        session.commandHistoryRecording = true; session.disconnect()
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertEqual(history.entries.count, 1)
        XCTAssertFalse(session.receiveCommandHistory("file://localhost/tmp"))
    }
    @MainActor func testActualTerminalReportRecordsAndKeepsDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let history = CommandHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store)
        session.commandHistoryStore = history; session.commandHistoryToken = "active"
        let terminal = TerminalView(frame: .zero); terminal.terminalDelegate = session
        session.terminal = terminal; session.connected = true
        let recorded = expectation(description: "Executed command reported by SwiftTerm")
        let observer = history.$entries.filter { !$0.isEmpty }.prefix(1).sink { entries in
            XCTAssertEqual(entries.first?.command, "ls -la"); recorded.fulfill()
        }
        let payload = Data("ls -la".utf8).base64EncodedString()
        terminal.feed(text: "\u{1b}]7;axon-command;active;ready\u{7}\u{1b}]7;axon-command;active;" + payload + "\u{7}")
        await fulfillment(of: [recorded], timeout: 2)
        XCTAssertNil(session.currentDirectory)
        terminal.feed(text: "\u{1b}]7;axon-command;active;meta;" + Data("/tmp/owned".utf8).base64EncodedString() + "\u{7}")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.currentDirectory, "/tmp/owned")
        terminal.feed(text: "\u{1b}]7;axon-command;wrong;meta;" + Data("/tmp/wrong".utf8).base64EncodedString() + "\u{7}")
        terminal.feed(text: "\u{1b}]7;axon-command;active;meta;" + Data("relative".utf8).base64EncodedString() + "\u{7}")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.currentDirectory, "/tmp/owned")
        observer.cancel()
    }
    @MainActor func testOpeningLocalTerminalAutomaticallyRecordsCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/bash"
        store.workspace.preferences.localLoginShell = false
        let history = CommandHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store)
        session.commandHistoryStore = history
        defer { session.disconnect() }
        let ready = expectation(description: "Automatic shell integration")
        let observer = session.$commandHistoryReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        let terminal = session.makeView()
        terminal.feed(text: "AXON_LOGIN_BANNER\r\n")
        await fulfillment(of: [ready], timeout: 5)
        observer.cancel()
        let recorded = expectation(description: "Command recorded without manual setup")
        let commands = history.$entries.filter { $0.contains { $0.command == "printf AXON_AUTO_HISTORY_TEST" } }.prefix(1).sink { _ in recorded.fulfill() }
        terminal.send(data: Array("printf AXON_AUTO_HISTORY_TEST\r".utf8)[...])
        await fulfillment(of: [recorded], timeout: 5)
        commands.cancel()
        XCTAssertFalse(session.commandHistoryBootstrapScreen)
        let visible = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertTrue(visible.contains("AXON_LOGIN_BANNER"))
        XCTAssertEqual(terminal.alphaValue, 1)
        XCTAssertFalse(visible.contains("_axon_history_emit"))
        XCTAssertFalse(visible.contains("_axon_history_prompt()"))
        XCTAssertTrue(visible.contains("AXON_AUTO_HISTORY_TEST"))
        XCTAssertFalse(history.entries.contains { $0.command.contains("axon-command;") })
    }
    @MainActor func testBashTabCompletionDoesNotRecordPreviousAliasOrLoseTail() async throws {
        _ = NSApplication.shared
        var shells = ["/bin/bash"]
        if let bash = ProcessInfo.processInfo.environment["AXON_TEST_BASH5"] { shells.append(bash) }
        for shell in shells {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let application = root.appendingPathComponent("application")
            try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
            try Data("AXON_LOCAL_TAIL_FIXTURE\n".utf8).write(to: application.appendingPathComponent("af-console.log"))
            defer { try? FileManager.default.removeItem(at: root) }
            let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
            store.workspace.preferences.localShell = shell
            store.workspace.preferences.localLoginShell = false
            let history = CommandHistoryStore(fileURL: root.appendingPathComponent("history.json"))
            let session = TerminalSession(host: nil, store: store); session.commandHistoryStore = history
            defer { session.disconnect() }
            let terminal = session.makeView()
            func waitFor(_ predicate: () -> Bool) async throws {
                for _ in 0..<100 {
                    if predicate() { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTFail("Timed out in \(shell)")
                throw NSError(domain: "AxonHistoryFixture", code: 1)
            }
            func send(_ text: String) { terminal.send(data: Array(text.utf8)[...]) }
            func execute(_ command: String) async throws {
                let revision = session.aiCommandCapture.completionRevision
                send(command + "\r")
                try await waitFor { session.aiCommandCapture.completionRevision > revision }
            }
            try await waitFor { session.commandHistoryReady }
            // Programmable completion follows the same Readline path used by
            // server bash-completion, without depending on installed profiles.
            try await execute("cd '\(root.path)'; alias ll='ls -alF'; _fixture_complete() { COMPREPLY=($(compgen -f -- \"${COMP_WORDS[COMP_CWORD]}\")); }; complete -F _fixture_complete cd tail")
            try await execute("ll")
            let beforeDirectoryCompletion = history.entries.count
            send("cd appl\t")
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(history.entries.count, beforeDirectoryCompletion, "Tab must not execute the previous alias")
            let revision = session.aiCommandCapture.completionRevision
            send("\r")
            try await waitFor { session.aiCommandCapture.completionRevision > revision }
            XCTAssertTrue(history.entries.first?.command.hasPrefix("cd application") == true)
            try await execute("ll")
            let beforeTailCompletion = history.entries.count
            send("tail -100f af-cons\t")
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(history.entries.count, beforeTailCompletion)
            send("\r")
            try await waitFor { history.entries.first?.command.hasPrefix("tail -100f af-console.log") == true }
            XCTAssertEqual(history.entries.count, beforeTailCompletion + 1)
            XCTAssertNil(history.entries.first?.exitCode, "A running tail must already appear in history")
            try await waitFor { session.aiCommandCapture.current?.output.range(of: Data("AXON_LOCAL_TAIL_FIXTURE".utf8)) != nil }
            send("\u{3}")
            try await waitFor { history.entries.first?.exitCode == 130 }
            let tail = try XCTUnwrap(session.aiCommandCapture.finished.last)
            XCTAssertTrue(tail.command.hasPrefix("tail -100f af-console.log"))
            XCTAssertEqual(tail.exitCode, 130)
            XCTAssertFalse(history.entries.contains { $0.command == "ls -alF" })
            if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
                store.workspace.preferences.language = "zh-CN"
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for width: CGFloat in [1050, 1400] {
                    let hosting = NSHostingView(rootView: OperationHistoryView(history: history, server: "local")
                        .environmentObject(store).font(.system(size: 13)).foregroundStyle(Palette.text)
                        .background(Palette.background).preferredColorScheme(.light))
                    hosting.sizingOptions = []
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let mode = shell == "/bin/bash" ? "bash3" : "bash5"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("history-tab-tail-\(mode)-\(Int(width)).png"))
                }
            }
            try await execute("printf AFTER_TAIL")
            XCTAssertEqual(history.entries.first?.command, "printf AFTER_TAIL")
        }
    }
    @MainActor func testBootstrapKeepsTerminalVisibleBehindFrozenNormalScreen() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store)
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        session.terminal = terminal
        let window = NSWindow(contentRect: terminal.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        defer { window.close() }
        try terminal.setUseMetal(false)
        TerminalAppearance.apply(store.workspace.preferences, to: terminal)
        terminal.feed(text: "LOGIN_STAYS_VISIBLE\r\n[root@fixture ~]# ")
        try await Task.sleep(for: .milliseconds(50))
        session.beginCommandHistoryBootstrapScreen()
        let cover = try XCTUnwrap(session.commandHistoryBootstrapCover as? CommandHistoryFrozenSurface)
        XCTAssertNotNil(cover.image)
        XCTAssertTrue(cover.superview === terminal)
        XCTAssertEqual(terminal.alphaValue, 1)
        XCTAssertFalse(terminal.isHidden)
        XCTAssertNil(cover.hitTest(.zero))
        terminal.feed(text: "INITIALIZATION_ONLY")
        session.endCommandHistoryBootstrapScreen()
        terminal.feed(text: "[root@fixture ~]# ")
        XCTAssertEqual(terminal.alphaValue, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(cover.superview)
        let normal = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertTrue(normal.contains("LOGIN_STAYS_VISIBLE"))
        XCTAssertFalse(normal.contains("INITIALIZATION_ONLY"))
        XCTAssertEqual(normal.components(separatedBy: "[root@fixture ~]#").count - 1, 1)
    }
    func testBashSubshellCreationAndFollowingVerificationDoNotShiftOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.sh").path
        let commands = ["(set -C; printf '%s\\n' '#!/bin/sh' \"echo 'hello world'\" > " + file + ")", "cat " + file, "sh " + file, "cat " + file, "cat " + file]
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["--noprofile", "--norc", "-i"]
        var environment = ProcessInfo.processInfo.environment
        environment["HISTFILE"] = "/dev/null"; environment["TERM"] = "dumb"; environment["PS1"] = ""; environment["HISTCONTROL"] = "ignoreboth"
        process.environment = environment
        let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data((CommandHistoryProtocol.script(token: "fixture") + "\n" + commands.joined(separator: "\n") + "\n\nexit\n").utf8)); try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        var capture = AICommandCapture(); capture.receive(Array(bytes), token: "fixture")
        XCTAssertEqual(capture.finished.map(\.command), commands)
        XCTAssertEqual(capture.completionRevision, UInt64(commands.count))
        for entry in capture.finished { XCTAssertEqual(entry.exitCode, 0) }
        XCTAssertTrue(capture.finished.last?.output.range(of: Data("#!/bin/sh".utf8)) != nil)
        XCTAssertTrue(capture.finished.last?.output.range(of: Data("echo 'hello world'".utf8)) != nil)
    }
    func testBashExistingPromptAndFailedCommandsKeepExitAndOutputBoundaries() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["--noprofile", "--norc", "-i"]
        var environment = ProcessInfo.processInfo.environment
        environment["HISTFILE"] = "/dev/null"; environment["TERM"] = "dumb"; environment["PS1"] = "$(printf PROMPT_ONLY)> "
        environment["PROMPT_COMMAND"] = "printf 'USER_PROMPT_STATUS=%s\\n' \"$?\""
        process.environment = environment
        let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data((CommandHistoryProtocol.script(token: "fixture") + "\nfalse\nprintf 'OWNED_OK\\n'\n\nexit\n").utf8)); try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        var capture = AICommandCapture(); capture.receive(Array(bytes), token: "fixture")
        XCTAssertEqual(capture.finished.map(\.command), ["false", "printf 'OWNED_OK\\n'"])
        XCTAssertEqual(capture.finished.map(\.exitCode), [1, 0])
        XCTAssertEqual(capture.completionRevision, 2)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("USER_PROMPT_STATUS=1"))
        XCTAssertFalse(String(decoding: capture.finished.last!.output, as: UTF8.self).contains("USER_PROMPT_STATUS="))
    }
    func testActualBashAndZshHooksCaptureShellCommands() throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = shell.hasSuffix("bash") ? ["--noprofile", "--norc", "-i"] : ["-f", "-i"]
            var environment = ProcessInfo.processInfo.environment; environment["HISTFILE"] = "/dev/null"; environment["TERM"] = "dumb"; environment["PS1"] = ""; process.environment = environment
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            let commands = CommandHistoryProtocol.script(token: "test-token") + "\nprintf '%s' AXON_HISTORY_TEST\nexit\n"
            input.fileHandleForWriting.write(Data(commands.utf8)); try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, shell)
            XCTAssertTrue(text.contains("\u{1b}]7;axon-command;test-token;ready\u{7}"), shell)
            let reports = text.components(separatedBy: "\u{1b}]7;").dropFirst().compactMap { $0.components(separatedBy: "\u{7}").first }.compactMap { CommandHistoryProtocol.decode($0, token: "test-token") }
            XCTAssertTrue(reports.contains { $0.contains("printf '%s' AXON_HISTORY_TEST") }, shell + " reports=" + reports.joined(separator: ","))
        }
    }
}
