import Foundation

/// Application-owned submission journal; model summaries never decide replay safety.
struct AITaskRecovery: Codable {
    struct Operation: Codable {
        var id = UUID()
        let tool: String
        let argument: String
        let mutation: Bool
        var state = "uncertain"
        var files: [AIFileCheckpoint]? = nil
        var timelineID: UUID? = nil
        var executionID: UUID?
    }
    var goal: String
    var channel: String
    var operations: [Operation] = []
    var uncertainMutation: Bool { operations.contains { $0.mutation && $0.state == "uncertain" && $0.executionID == nil } }
    var runningID: UUID? { operations.last(where: { $0.state == "running" })?.executionID }
    func blocks(tool: String, argument: String, mutation: Bool) -> Bool {
        guard mutation else { return false }
        return uncertainMutation || operations.contains { $0.mutation && $0.tool == tool && $0.argument == argument && $0.state != "not_applied" }
    }
    var prompt: String {
        "Recovery checkpoint (application-owned):\nOriginal goal: \(goal)\nOriginal execution channel: \(channel)\n"
        + operations.suffix(20).map { "\($0.state): \($0.tool) \(AIContext.sanitize($0.argument)) Execution ID: \($0.executionID?.uuidString ?? "none")" }.joined(separator: "\n")
        + "\nNever replay completed, running, reverted or uncertain mutations. A not_applied file record was freshly byte-verified as absent; a new proposal still requires fresh review and permissions. Recheck frozen checks with fresh observations. If submission outcome is uncertain and no execution ID is available, use read-only inspection and report the blocker; ask the user to resolve the uncertain operation before a new task.\n"
    }
    static func legacy(_ record: AITaskRecord, channel: String) -> Self {
        var recovery = Self(goal: record.workingMemory?.goal ?? record.question, channel: channel)
        for step in (record.turns ?? []).flatMap(\.steps).suffix(256) {
            guard ["command", "terminal_execute", "terminal_send", "terminal_key", "replace_file"].contains(step.tool) else { continue }
            let argument = step.input.isEmpty ? step.command : step.input
            let mutation = step.tool == "replace_file" || !AIVerificationCheck.readOnlyCommand(argument)
            guard mutation || step.executionID != nil else { continue }
            recovery.operations.append(Operation(tool: step.tool, argument: argument, mutation: mutation, state: step.state == "finished" ? "completed" : step.executionID != nil ? "running" : "uncertain", executionID: step.executionID))
        }
        return recovery
    }
    @MainActor mutating func reconcileFiles(executor: AICommandExecutor, policy: AIExecutionPolicy) async throws -> String {
        guard operations.contains(where: { $0.files != nil }), let open = executor.fileBackend else { return "" }
        let backend = try await open()
        do {
            var report: [String] = []
            for index in operations.indices {
                guard let recorded = operations[index].files else { continue }
                // A later application-owned edit supersedes an older completed version.
                let later = Set(operations.dropFirst(index + 1).flatMap { $0.files?.map(\.path) ?? [] })
                let files = operations[index].state == "completed" || operations[index].state == "reverted" ? recorded.filter { !later.contains($0.path) } : recorded
                guard !files.isEmpty else { continue }
                var before = 0, after = 0, conflict = false
                for file in files {
                    try executor.check(); try Task.checkCancellation()
                    let decision = executor.effectivePolicy(policy).decision(target: executor.source, tool: "read_configuration", argument: file.path, automatic: true, hostID: executor.hostID, command: "cat -- " + SnippetParameters.shellArgument(file.path))
                    guard decision == .allow else { conflict = true; report.append(file.path + ": permission needed for recovery inspection"); continue }
                    do {
                        let entry = try await backend.stat(file.path)
                        guard !entry.symlink, !entry.directory, entry.size <= 65536 else { throw AIModelError.invalidReply }
                        let data = try await ExternalEdit.read(entry, from: backend)
                        let hash = AIFileCheckpoint.digest(data)
                        if hash == file.after { after += 1; report.append(file.path + ": expected modification present") }
                        else if hash == file.before { before += 1; report.append(file.path + ": original bytes present") }
                        else { conflict = true; report.append(file.path + ": concurrent/unexpected content; do not overwrite") }
                    } catch is CancellationError { throw CancellationError() }
                    catch { conflict = true; report.append(file.path + ": unavailable; outcome unknown") }
                }
                if !conflict && after == files.count { operations[index].state = "completed" }
                else if !conflict && before == files.count { operations[index].state = operations[index].state == "completed" || operations[index].state == "reverted" ? "reverted" : "not_applied" }
                else { operations[index].state = "uncertain"; operations[index].executionID = nil }
            }
            if let remote = backend as? RemoteFiles { try? await remote.close() }
            try executor.check(); return report.joined(separator: "\n")
        } catch { if let remote = backend as? RemoteFiles { try? await remote.close() }; throw error }
    }
    static func transient(_ error: Error) -> Bool {
        if case AIModelError.incompleteStream = error { return true }
        return AIModelRetry.delay(for: error, attempt: 0) != nil
    }
}
