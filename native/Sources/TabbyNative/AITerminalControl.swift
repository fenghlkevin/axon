import Foundation
import Combine

/// Input leases belong to one captured terminal. Program ownership is distinct from who is typing.
@MainActor final class AITerminalControl: ObservableObject {
    enum Mode: String { case idle, agent, human, monitoring }
    struct Program: Identifiable {
        let id: UUID
        let owner: UUID
        let command: String
        let startedByAgent: Bool
        let started = Date()
        var directory: String?
        var state = "starting"
        var exitCode: Int?
        var output = ""
        var inputRevision: UInt64
        var active: Bool { ["starting", "running", "background", "human"].contains(state) }
    }
    @Published private(set) var mode: Mode = .idle
    @Published private(set) var programs: [Program] = []
    private(set) var owner: UUID?
    private var lease: UUID?
    func claim(_ owner: UUID, session: TerminalSession) -> UUID {
        self.owner = owner; let token = UUID(); lease = token; mode = .agent
        if let entry = session.aiCommandCapture.current, !programs.contains(where: { $0.id == entry.id }) {
            register(entry.id, owner: owner, command: entry.command, revision: session.aiTerminalInputRevision, directory: session.currentDirectory, startedByAgent: false)
        }
        for i in programs.indices where programs[i].owner == owner && programs[i].id == session.aiCommandCapture.current?.id {
            programs[i].inputRevision = session.aiTerminalInputRevision; programs[i].state = "running"
        }
        return token
    }
    func canWrite(_ token: UUID) -> Bool { lease == token && mode == .agent }
    func validate(_ token: UUID) throws {
        guard canWrite(token) else { throw AppFailure.message("Terminal is under human control; explicitly hand it back before continuing. / 终端已由人工接管，请明确交回 AI 后再继续。") }
    }
    func monitor() {
        lease = nil; mode = .monitoring
        for i in programs.indices where programs[i].active { programs[i].state = "background" }
    }
    func takeover() {
        lease = nil; mode = .human
        for i in programs.indices where programs[i].active { programs[i].state = "human" }
    }
    func disconnected() {
        lease = nil; mode = .idle; owner = nil
        for i in programs.indices where programs[i].active { programs[i].state = "disconnected" }
    }
    func register(_ id: UUID, owner: UUID, command: String, revision: UInt64, directory: String?, startedByAgent: Bool = true) {
        guard !programs.contains(where: { $0.id == id }) else { return }
        if programs.count >= 64 { programs.removeAll { !$0.active } }
        programs.append(Program(id: id, owner: owner, command: AIContext.sanitize(command), startedByAgent: startedByAgent, directory: directory, inputRevision: revision))
    }
    func refresh(_ session: TerminalSession) {
        for i in programs.indices {
            if let entry = session.aiCommandCapture.entry(programs[i].id) {
                programs[i].directory = entry.directory ?? programs[i].directory
                programs[i].output = AIContext.sanitize(String(decoding: entry.output.suffix(12000), as: UTF8.self))
                if let code = entry.exitCode { programs[i].exitCode = code; programs[i].state = "completed" }
                else if entry.superseded { programs[i].state = "unknown" }
                else if programs[i].state == "starting" { programs[i].state = "running" }
            } else if !session.connected { programs[i].state = "disconnected" }
        }
    }
    func submittedInput(_ revision: UInt64, session: TerminalSession) {
        for i in programs.indices where programs[i].id == session.aiCommandCapture.current?.id { programs[i].inputRevision = revision }
    }
    func detach(_ id: UUID, token: UUID, session: TerminalSession) throws {
        try validate(token); refresh(session)
        guard let i = programs.firstIndex(where: { $0.id == id && $0.owner == owner && $0.active }),
              session.aiCommandCapture.current?.id == id else { throw AppFailure.message("Only the current running program can be left running / 只能保留当前正在运行的程序") }
        programs[i].state = "background"; mode = .monitoring; lease = nil
    }
    func canInterrupt(_ id: UUID, session: TerminalSession) -> Bool {
        guard session.connected, let program = programs.first(where: { $0.id == id }), program.startedByAgent, program.active,
              program.inputRevision == session.aiTerminalInputRevision, session.aiCommandCapture.current?.id == id,
              mode != .human else { return false }
        return true
    }
    /// Ctrl-C is sent only to the still-matching foreground command. No guessed PID or remote kill.
    func interrupt(_ id: UUID, session: TerminalSession) async throws {
        refresh(session)
        guard canInterrupt(id, session: session), let program = programs.first(where: { $0.id == id }) else {
            throw AppFailure.message("Program ownership or terminal input changed; interruption refused / 程序归属或终端输入已变化，已拒绝中断")
        }
        let revision = session.aiTerminalInputRevision
        let token = claim(program.owner, session: session)
        try await session.writeAgentInput([3], expectedRevision: revision, controlLease: token, expectedExecutionID: id)
        submittedInput(session.aiTerminalInputRevision, session: session)
        // Request is not proof of exit. Keep monitoring the real completion marker.
        if canWrite(token) { mode = .monitoring; lease = nil }; refresh(session)
    }
}
