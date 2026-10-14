import Foundation

struct AIVerificationCheck: Codable, Equatable {
    var goal: String
    var tool: String
    var argument: String
    var expectedOutput: String
    static let readTools = ["read_file", "read_configuration", "http_health", "tcp_probe", "service_status", "inspect_port", "inspect_process", "docker_inspect", "verify_command", "program_result"]
    func validate(goal original: String) throws {
        guard Self.sameGoal(goal, original) else { throw AIModelError.invalidTaskReply("checks.goal must match the application-pinned Goal. Copy it verbatim; do not summarize it or omit requirements.") }
        guard Self.readTools.contains(tool), !argument.isEmpty, argument.utf8.count <= 1024,
              expectedOutput.trimmingCharacters(in: .whitespacesAndNewlines).count >= (tool == "program_result" ? 1 : 3), expectedOutput.count <= 512,
              !expectedOutput.contains("[REDACTED]"), !argument.contains("[REDACTED]") else { throw AIModelError.invalidReply }
        if tool == "program_result" {
            guard !argument.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }), !AIBuiltInDeny.matches(argument) else { throw AIModelError.invalidReply }
            return // Receipt-only: never launches or repeats this command.
        }
        let action = AIAgentAction(tool: tool, argument: argument, reason: "Verify the original goal", path: nil, find: nil, replacement: nil)
        do { _ = try action.command(os: "Linux") } catch { throw AIModelError.invalidReply }
        if tool == "verify_command", !Self.readOnlyCommand(argument) { throw AIModelError.invalidTaskReply("verify_command must be a single read-only inspection command. Do not run the script in a check. Use cat <script path> with its expected contents as the check; run the script separately as an operational action and inspect its actual output.") }
    }
    static func sameGoal(_ lhs: String, _ rhs: String) -> Bool {
        // Whitespace formatting is not a different task; every non-whitespace character remains fixed.
        lhs.filter { !$0.isWhitespace } == rhs.filter { !$0.isWhitespace }
    }
    static func readOnlyCommand(_ command: String) -> Bool {
        guard !command.contains(where: { ";|&\n`><$".contains($0) }), !command.contains("\\"),
              let segments = try? AIExecutableInspection.segments(command), segments.count == 1,
              let words = segments.first, let first = words.first else { return false }
        let name = URL(fileURLWithPath: first).lastPathComponent
        guard first == name || ["/bin", "/usr/bin", "/sbin", "/usr/sbin"].contains(URL(fileURLWithPath: first).deletingLastPathComponent().path) else { return false }
        switch name {
        case "cat", "head", "tail", "grep", "rg", "stat", "ls", "ps", "pgrep", "lsof", "ss", "dig", "pwd", "uname", "id", "whoami", "df", "du":
            return !words.contains(where: { ["--pre", "--pre-glob"].contains($0) || $0.hasPrefix("--pre=") })
        case "systemctl": return words.dropFirst().first == "status" || words.dropFirst().first == "is-active"
        case "docker": return ["inspect", "ps", "logs"].contains(words.dropFirst().first ?? "")
        default: return false
        }
    }
    func accepts(_ result: AICommandResult) -> Bool {
        guard result.exitCode == 0, !result.output.isEmpty, result.output.contains(expectedOutput) else { return false }
        if tool == "program_result" {
            let expected = expectedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.output.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == expected }
        }
        if tool == "http_health" {
            // Use curl’s final status trailer; proxy CONNECT headers are not endpoint evidence.
            guard result.output.range(of: #"\nAXON_HTTP_STATUS:2\d\d\s*$"#, options: .regularExpression) != nil else { return false }
        }
        return true
    }
}

/// Checks are fixed before changes, and every change invalidates earlier successes.
struct AIVerificationState: Codable, Equatable {
    var checks: [AIVerificationCheck] = []
    var passed: [Int] = []
    var pending = false
    var hasChanges = false
    var inputPending = false
    var mutationRevision: UInt64 = 0
    var terminalCommandRevision: UInt64 = 0
    mutating func configure(_ proposed: [AIVerificationCheck], goal: String) throws {
        guard !hasChanges, !proposed.isEmpty, proposed.count <= 8 else { throw AIModelError.invalidReply }
        for check in proposed { try check.validate(goal: goal) }
        checks = proposed.map { var check = $0; check.goal = goal; return check }; passed = []
    }
    mutating func changed(terminalRevision: UInt64 = 0) {
        pending = true; hasChanges = true; passed = []; mutationRevision = terminalRevision; terminalCommandRevision = terminalRevision
    }
    mutating func observe(tool: String, argument: String, result: AICommandResult) {
        guard hasChanges, !checks.isEmpty else { return }
        for (index, check) in checks.enumerated() where check.tool == tool && check.argument == argument {
            passed.removeAll { $0 == index }
            if check.accepts(result) { passed.append(index) }
        }
        pending = passed.count != checks.count
    }
    var prompt: String {
        let rows = checks.map { ["goal": $0.goal, "tool": $0.tool, "argument": $0.argument, "expectedOutput": $0.expectedOutput] }
        let encoded = (try? JSONSerialization.data(withJSONObject: rows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return "Application verification state: \(pending || inputPending ? "PENDING — final completion prohibited" : "no pending mutation")\nTerminal input awaiting submission: \(inputPending)\nFrozen goal checks: \(encoded)\nPassed check indexes: \(passed.sorted())\n"
    }
}
