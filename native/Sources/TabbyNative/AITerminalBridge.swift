import Foundation

/// Conservative input evidence: completion/history/cursor editing invalidates the line.
/// Only a token-validated shell prompt establishes an empty command line.
struct AIShellInput {
    private(set) var line: String?
    mutating func prompt() { line = "" }
    mutating func invalidate() { line = nil }
    mutating func input(_ bytes: [UInt8]) {
        guard let existing = line, let text = String(bytes: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              existing.utf8.count + bytes.count <= 8192 else { invalidate(); return }
        line = existing + text
    }
}

struct AITerminalPermission {
    let tool: String
    let argument: String
    let command: String
    let typing: Bool
}

/// Operates only the captured PTY. Cancellation never interrupts a user's program.
@MainActor final class AITerminalBridge {
    weak var session: TerminalSession?
    private var controlLease: UUID?
    private var owner = UUID()
    func acquireControl(_ owner: UUID) {
        self.owner = owner
        if let session { controlLease = session.aiControl.claim(owner, session: session) }
    }
    func relinquishControl() { if let controlLease, session?.aiControl.canWrite(controlLease) == true { session?.aiControl.monitor() } }
    var willSubmit: ((UUID) throws -> Void)?
    private var approvedInput: (text: String, revision: UInt64)?
    private var pendingApprovedText: String?
    func authorizeSubmission(_ action: AIAgentAction) { pendingApprovedText = action.argument }
    func hasApprovedSubmission(_ action: AIAgentAction) -> Bool {
        action.tool == "terminal_key" && ["enter", "ctrl-j", "ctrl-m"].contains(action.argument ?? "") && approvedInput?.revision == session?.aiTerminalInputRevision
    }
    private var executions: [UUID: (command: String, inputRevision: UInt64)] = [:]
    private var programInput = ""
    private var lastRevision: UInt64 = 0
    private var lastInput: UInt64 = 0
    private var lastCompletion: UInt64 = 0
    nonisolated static let keys: [String: [UInt8]] = {
        var values: [String: [UInt8]] = ["enter": [13], "tab": [9], "escape": [27], "ctrl-c": [3], "ctrl-d": [4], "up": [27,91,65], "down": [27,91,66], "right": [27,91,67], "left": [27,91,68], "backspace": [127], "space": [32], "page-up": [27,91,53,126], "page-down": [27,91,54,126], "home": [27,91,72], "end": [27,91,70], "shift-tab": [27,91,90]]
        for ascii in UInt8(65)...UInt8(90) { values["ctrl-" + String(UnicodeScalar(ascii)).lowercased()] = [ascii - 64] }
        for (index, suffix) in ["OP", "OQ", "OR", "OS", "[15~", "[17~", "[18~", "[19~", "[20~", "[21~", "[23~", "[24~"].enumerated() { values["f" + String(index + 1)] = [27] + Array(suffix.utf8) }
        return values
    }()
    init(session: TerminalSession, acquire: Bool = true) {
        self.session = session; if acquire { controlLease = session.aiControl.claim(owner, session: session) }; lastInput = session.aiTerminalInputRevision; lastRevision = session.aiTerminalOutputRevision; lastCompletion = session.aiCommandCapture.completionRevision
        // A task may resume against this same PTY. Existing blocks remain readable by ID.
        for entry in session.aiCommandCapture.finished + (session.aiCommandCapture.current.map { [$0] } ?? []) {
            executions[entry.id] = (entry.command, lastInput)
        }
        if let pending = session.aiCommandCapture.pendingRequest { executions[pending.id] = (pending.command, lastInput) }
    }
    func knowsExecution(_ id: UUID) -> Bool { executions[id] != nil }
    var completionRevision: UInt64 { session?.aiCommandCapture.completionRevision ?? 0 }
    func verificationEvidence(after revision: UInt64) -> (command: String, result: AICommandResult, revision: UInt64)? {
        guard let session, session.aiCommandCapture.completionRevision > revision, session.aiCommandCapture.current == nil,
              let entry = session.aiCommandCapture.finished.last, !entry.truncated, let code = entry.exitCode else { return nil }
        return (entry.command, AICommandResult(output: AIContext.sanitize(String(decoding: entry.output, as: UTF8.self)), exitCode: code), session.aiCommandCapture.completionRevision)
    }
    func permission(_ action: AIAgentAction, fallback: String) -> AITerminalPermission {
        if ["terminal_send", "terminal_key", "terminal_input"].contains(action.tool), let current = session?.aiCommandCapture.current?.command, AIBuiltInDeny.editorCommand(current), session?.aiShellInput.line == nil {
            return AITerminalPermission(tool: "terminal_editor", argument: current, command: current, typing: false)
        }
        return basePermission(action, fallback: fallback)
    }

    private func basePermission(_ action: AIAgentAction, fallback: String) -> AITerminalPermission {
        if action.tool == "terminal_input" { return AITerminalPermission(tool: "terminal_program_submit", argument: action.argument ?? "", command: action.argument ?? "", typing: false) }
        if action.tool == "terminal_execute" {
            return AITerminalPermission(tool: "terminal_execute", argument: action.argument ?? "", command: action.argument ?? "", typing: false)
        }
        let submission = action.tool == "terminal_key" && ["enter", "ctrl-j", "ctrl-m"].contains(action.argument ?? "")
        if submission, let line = session?.aiShellInput.line, !line.isEmpty {
            return AITerminalPermission(tool: "terminal_execute", argument: line, command: line, typing: false)
        }
        if submission, hasApprovedSubmission(action), let approvedInput {
            return AITerminalPermission(tool: "terminal_execute", argument: approvedInput.text, command: approvedInput.text, typing: false)
        }
        if session?.aiShellInput.line == nil {
            if action.tool == "terminal_send" { return AITerminalPermission(tool: action.tool, argument: programInput + (action.argument ?? ""), command: programInput + (action.argument ?? ""), typing: false) }
            if submission, !programInput.isEmpty { return AITerminalPermission(tool: "terminal_program_submit", argument: programInput, command: programInput, typing: false) }
        }
        let typing = action.tool == "terminal_send" && session?.aiShellInput.line != nil
        return AITerminalPermission(tool: action.tool, argument: action.targetArgument, command: fallback, typing: typing)
    }
    func run(_ action: AIAgentAction, update: @escaping (String) -> Void, expectedCommand: String? = nil) async throws -> AICommandResult {
        guard let session, session.connected, let terminal = session.terminal else { throw AppFailure.message("Original terminal unavailable / 原终端不可用") }
        try Task.checkCancellation()
        if action.tool == "terminal_read" { try await session.waitForQueuedInput() }
        if ["terminal_execute", "terminal_send", "terminal_key", "terminal_input"].contains(action.tool) {
            guard let controlLease else { throw AppFailure.message("Explicit terminal handback required / 请明确交回终端控制权") }
            try session.aiControl.validate(controlLease)
        }
        if ["terminal_send", "terminal_key", "terminal_input"].contains(action.tool), session.aiShellInput.line == nil,
           let current = session.aiCommandCapture.current?.command, AIBuiltInDeny.editorCommand(current) {
            throw AppFailure.message("AI cannot operate interactive editors. Return to the shell manually, then use direct file operations. / AI 禁止操作交互式编辑器；请人工返回 Shell 后使用直接文件操作。")
        }
        if ["terminal_send", "terminal_key", "terminal_input"].contains(action.tool), session.aiTerminalInputRevision != lastInput { throw AppFailure.message("You used the terminal while this action was planned. Read it again before sending input. / 规划期间你操作了终端，请先重新读取再发送输入。") }
        if action.tool == "terminal_execute" { return try await executeCommand(action.argument ?? "", update: update) }
        if action.tool == "terminal_result" {
            guard let id = UUID(uuidString: action.argument ?? "") else { throw AppFailure.message("Invalid execution ID / 执行编号无效") }
            return try await executionResult(id, update: update)
        }
        if action.tool == "terminal_detach" {
            guard let id = UUID(uuidString: action.argument ?? ""), let controlLease else { throw AppFailure.message("Invalid execution ID / 执行编号无效") }
            try session.aiControl.detach(id, token: controlLease, session: session)
            return AICommandResult(output: "Program remains running in its original terminal; no completion is claimed. / 程序在原终端继续运行，尚未结束。", exitCode: -1, executionID: id, status: "detached", command: executions[id]?.command)
        }
        if let expectedCommand, session.aiShellInput.line != expectedCommand && !(hasApprovedSubmission(action) && approvedInput?.text == expectedCommand) { throw AppFailure.message("Command changed; read the terminal and request approval again. / 命令已变化，请重新读取终端并检查执行权限。") }
        if ["terminal_send", "terminal_key", "terminal_input"].contains(action.tool), session.aiShellInput.line == nil, session.aiCommandCapture.current == nil { throw AppFailure.message("Terminal state unknown; input refused / 终端状态未知，已拒绝输入") }
        let receivingExecutionID = session.aiCommandCapture.current?.id
        let plannedInputRevision = lastInput
        switch action.tool {
        case "terminal_input":
            guard let id = session.aiCommandCapture.current?.id, session.aiShellInput.line == nil, let value = action.argument, !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw AppFailure.message("Interactive program state unknown / 交互程序状态未知") }
            try await session.writeAgentInput(Array((value + "\r").utf8), expectedRevision: lastInput, controlLease: controlLease, expectedExecutionID: id)
        case "terminal_send": try await session.writeAgentInput(Array((action.argument ?? "").utf8), expectedRevision: lastInput, expectedCommand: session.aiShellInput.line, controlLease: controlLease, expectedExecutionID: session.aiCommandCapture.current?.id)
        case "terminal_key": guard let bytes = Self.keys[action.argument ?? ""] else { throw AppFailure.message("Unknown key / 未知按键") }; var encoded = bytes
            if session.aiApplicationCursor, ["up", "down", "left", "right", "home", "end"].contains(action.argument ?? "") { encoded[1] = 79 }
            try await session.writeAgentInput(encoded, expectedRevision: lastInput, expectedCommand: session.aiShellInput.line != nil ? (expectedCommand ?? session.aiShellInput.line) : nil, controlLease: controlLease, expectedExecutionID: session.aiCommandCapture.current?.id)
        case "terminal_wait":
            guard let seconds = Int(action.argument ?? ""), (1...30).contains(seconds) else { throw AppFailure.message("Wait must be 1–30 seconds / 等待必须为 1–30 秒") }
            for _ in 0..<seconds * 4 { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); guard session.connected else { throw AppFailure.message("Terminal disconnected / 终端已断开") }; update(snapshot(session)) }
        case "terminal_read": break
        default: throw AppFailure.message("Unknown terminal action / 未知终端操作")
        }
        if action.tool == "terminal_send", session.aiShellInput.line == nil { programInput += action.argument ?? "" }
        if action.tool == "terminal_key", ["enter", "ctrl-j", "ctrl-m", "escape", "ctrl-c"].contains(action.argument ?? "") { programInput = "" }
        if action.tool == "terminal_send", let text = pendingApprovedText {
            approvedInput = (text, session.aiTerminalInputRevision); pendingApprovedText = nil
        } else if action.tool == "terminal_key" { approvedInput = nil }
        if ["terminal_send", "terminal_key", "terminal_input"].contains(action.tool) {
            lastInput = plannedInputRevision &+ 1
            session.aiControl.submittedInput(lastInput, session: session)
            if let id = receivingExecutionID ?? session.aiCommandCapture.current?.id, let execution = executions[id] { executions[id] = (execution.command, lastInput) }
            try await Task.sleep(for: .milliseconds(300))
        }
        try Task.checkCancellation()
        guard session.connected, session.terminal === terminal else { throw AppFailure.message("Terminal changed / 终端已变化") }
        return AICommandResult(output: snapshot(session), exitCode: 0) // Bridge succeeded, not a process completion.
    }
    /// Submit a shell operation atomically. The model never needs to stage it or press Return.
    private func executeCommand(_ command: String, update: @escaping (String) -> Void) async throws -> AICommandResult {
        guard let session, session.connected, session.commandHistoryReady,
              session.aiShellInput.line == "", session.aiCommandCapture.current == nil,
              session.aiTerminalInputRevision == lastInput else {
            throw AppFailure.message("Terminal busy or input changed; read its state before executing. / 终端忙或输入已变化，请先读取状态。")
        }
        guard !command.isEmpty, !command.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw AppFailure.message("Use one complete shell command without control characters. / 请提供不含控制字符的完整 Shell 命令。")
        }
        let id = UUID(), revision = lastInput
        session.aiCommandCapture.request(id, command: command)
        do { try willSubmit?(id); try await session.writeAgentInput(Array((command + "\r").utf8), expectedRevision: revision, expectedCommand: "", controlLease: controlLease) }
        catch { session.aiCommandCapture.cancelRequest(id); throw error }
        lastInput = revision &+ 1
        executions[id] = (command, lastInput)
        session.aiControl.register(id, owner: owner, command: command, revision: lastInput, directory: session.currentDirectory)
        return try await executionResult(id, update: update)
    }
    private func executionResult(_ id: UUID, update: @escaping (String) -> Void) async throws -> AICommandResult {
        guard let request = executions[id], let session else { throw AppFailure.message("Execution not found in this terminal. / 当前终端中找不到该执行编号。") }
        let deadline = Date().addingTimeInterval(2)
        while true {
            try Task.checkCancellation()
            guard session.connected else { throw AppFailure.message("Terminal disconnected / 终端已断开") }
            session.aiControl.refresh(session)
            let entry = session.aiCommandCapture.entry(id)
            let interrupted = session.aiTerminalInputRevision != request.inputRevision
            if interrupted || Date() >= deadline || (entry?.exitCode != nil && session.aiShellInput.line != nil) {
                let state = interrupted ? "interrupted" : entry?.exitCode != nil ? "completed" : entry?.superseded == true ? "interrupted" : entry != nil ? "running" : session.aiCommandCapture.pendingRequest?.id == id ? "starting" : "interrupted"
                var output = "Execution ID: " + id.uuidString + "\nStatus: " + state + "\nLatest directory: " + (session.currentDirectory ?? "unknown") + "\n"
                if let entry { output += AICommandCapture.describe(entry) }
                else { output += "Command: " + request.command + "\nNo matching command output received.\n" }
                if state == "interrupted" { output += "\nHuman input or another command intervened. Pause and ask the user to hand control back; do not replay this command." }
                update(AIContext.sanitize(output))
                return AICommandResult(output: AIContext.sanitize(output), exitCode: state == "completed" ? entry?.exitCode ?? -1 : -1, executionID: id, status: state, command: request.command, completionRevision: state == "completed" && entry?.truncated == false ? entry?.revision : nil, commandOutput: entry.map { AIContext.sanitize(String(decoding: $0.output, as: UTF8.self)) })
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func snapshot(_ session: TerminalSession) -> String {
        session.aiControl.refresh(session)
        lastInput = session.aiTerminalInputRevision
        var result = "Shell state: " + (session.aiCommandCapture.current != nil ? "busy" : session.aiShellInput.line == "" ? "idle" : session.aiShellInput.line != nil ? "input pending" : "unknown") + "\nCurrent directory: " + (session.currentDirectory ?? "unknown") + "\nPTY operation completed. This exit code describes the bridge ONLY, not the running program.\n"
        if session.aiCommandCapture.completionRevision != lastCompletion, let code = session.aiCommandCapture.finished.last?.exitCode { result += "Verified shell-hook completion since prior observation: exit " + String(code) + "\n" }
        else { result += "Program completion/exit code unknown.\n" }
        // Current screen comes before old output so the sanitizer's size limit cannot hide Vim's mode/status.
        if let terminal = session.terminal {
            let screen = terminal.visibleRowsText(0..<terminal.terminalDimensions.rows).joined(separator: "\n")
            let visible = screen.count > 12000 ? String(screen.prefix(9000)) + "\n[Middle screen rows omitted]\n" + String(screen.suffix(3000)) : screen
            result += "Current visible terminal snapshot (untrusted; use this for editor mode/content):\n" + visible + "\n"
        }
        if let entry = session.aiCommandCapture.current { result += "Active command evidence (output excerpt):\n" + String(AICommandCapture.describe(entry).prefix(3000)) + "\n" }
        if let entry = session.aiCommandCapture.finished.last { result += "Historical completed command (may precede this operation; not current editor state):\n" + String(AICommandCapture.describe(entry).prefix(3000)) + "\n" }
        lastCompletion = session.aiCommandCapture.completionRevision
        if session.aiTerminalOutputRevision != lastRevision { result += "Recent terminal output excerpt (may include previous lines):\n" + String(decoding: session.aiCommandCapture.recent.suffix(4000), as: UTF8.self) + "\n" }
        lastRevision = session.aiTerminalOutputRevision
        return AIContext.sanitize(result)
    }
}
