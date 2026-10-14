import Foundation
import SwiftUI

struct AIExactPermission: Codable, Equatable {
    var target: String
    var tool: String
    var argument: String
    var hostID: UUID?
    var denied: Bool? = nil
    var global: Bool? = nil
}

struct AIExecutionPolicy: Codable, Equatable {
    var maximumSteps = 60
    var commandSeconds = 120
    var taskMinutes = 30
    var tokenBudget: Int?
    var costBudgetUSD: Double?
    var rules = ""
    var exactAllows: [AIExactPermission]?
    var toolPermissions: [String: AIToolPermission]?
    func toolPermission(_ category: AIToolCategory) -> AIToolPermission { toolPermissions?[category.rawValue] ?? .inherit }
    func toolPermission(for tool: String) -> AIToolPermission { AIToolCategory.category(for: tool).map(toolPermission) ?? .inherit }
    enum Mode: String, Codable, CaseIterable { case everyTime, assisted, fullAccess }
    var approvalMode: Mode?
    var commandWhitelist: String?
    var commandBlacklist: String?
    func mergingCommandLists(_ host: Host?) -> AIExecutionPolicy {
        guard let host else { return self }
        var result = self
        result.commandWhitelist = [commandWhitelist ?? "", host.aiCommandWhitelist ?? ""].joined(separator: "\n")
        result.commandBlacklist = [commandBlacklist ?? "", host.aiCommandBlacklist ?? ""].joined(separator: "\n")
        return result
    }
    var mode: Mode { approvalMode ?? .assisted }
    enum Decision { case allow, ask, deny }
    private func matches(_ pattern: String, _ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
    private func patterns(_ value: String?) -> [String] {
        (value ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
    private func isCommandName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }
    private func listMatches(_ entry: String, _ value: String, denying: Bool) -> Bool {
        guard isCommandName(entry) else { return matches(entry, value) } // Existing regex entries remain valid.
        let escaped = NSRegularExpression.escapedPattern(for: entry)
        if denying {
            // Include sudo, absolute paths and nested/compound shell commands; never substring-match a name.
            let normalized = value.filter { !["\"", "'", "\\"].contains(String($0)) }
            return normalized.range(of: "(?<![A-Za-z0-9_.-])" + escaped + "(?![A-Za-z0-9_.-])", options: .regularExpression) != nil
        }
        // A keyword allow covers one simple command. Compound commands require their own review.
        guard !value.contains(where: { ";|&\n`".contains($0) }), !value.contains("$("), !value.contains(">"), !value.contains("<") else { return false }
        return value.range(of: "^\\s*(?:sudo\\s+)?(?:/[A-Za-z0-9_./-]+/)?" + escaped + "(?:\\s|$)", options: .regularExpression) != nil
    }
    func validate() throws {
        guard (12...200).contains(maximumSteps), (10...1800).contains(commandSeconds), (1...240).contains(taskMinutes) else { throw AppFailure.message("Invalid task limits / 任务限额无效") }
        guard tokenBudget == nil || (100...100_000_000).contains(tokenBudget!), costBudgetUSD == nil || (costBudgetUSD!.isFinite && (0.001...10000).contains(costBudgetUSD!)) else { throw AppFailure.message("Invalid token or cost budget / Token 或费用限额无效") }
        guard (toolPermissions ?? [:]).keys.allSatisfy({ AIToolCategory(rawValue: $0) != nil }) else { throw AppFailure.message("Unknown tool permission / 未知工具权限") }
        for pattern in patterns(commandWhitelist) + patterns(commandBlacklist) {
            guard (try? NSRegularExpression(pattern: "^(?:" + pattern + ")$")) != nil else { throw AppFailure.message("Invalid command list regex / 命令列表正则无效：" + pattern) }
        }
        for rule in exactAllows ?? [] {
            guard !rule.target.isEmpty, !rule.tool.isEmpty else { throw AppFailure.message("Permission target and tool are required / 允许规则的目标和工具不能为空") }
        }
        for line in rules.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, ["allow", "ask", "deny"].contains(fields[0]), !fields[1].isEmpty, !fields[2].isEmpty, !fields[3].isEmpty,
                  (try? NSRegularExpression(pattern: "^(?:" + fields[1] + ")$")) != nil,
                  (try? NSRegularExpression(pattern: "^(?:" + fields[3] + ")$")) != nil else { throw AppFailure.message("Rule format: allow/ask/deny|target regex|tool|argument regex / 规则格式：allow/ask/deny|目标正则|工具|参数正则") }
        }
    }
    func decision(target: String, tool: String, argument: String, automatic: Bool, hostID: UUID? = nil, command: String? = nil) -> Decision {
        let values = [argument, command ?? argument]
        if values.contains(where: AIBuiltInDeny.matches) { return .deny }
        if patterns(commandBlacklist).contains(where: { pattern in values.contains { listMatches(pattern, $0, denying: true) } }) { return .deny }
        if exactAllows?.contains(where: { $0.denied == true && ($0.global == true || ($0.target == target && $0.hostID == hostID)) && ($0.tool == tool || (tool == "terminal_execute" && $0.tool == "terminal_send")) && $0.argument == argument }) == true { return .deny }
        var matched: Decision? = exactAllows?.contains(where: { $0.denied != true && ($0.global == true || ($0.target == target && $0.hostID == hostID)) && ($0.tool == tool || (tool == "terminal_execute" && $0.tool == "terminal_send")) && $0.argument == argument }) == true ? .allow : nil
        for line in rules.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[2] == tool || fields[2] == "*", matches(fields[1], target), matches(fields[3], argument) else { continue }
            if fields[0] == "deny" { return .deny }
            if fields[0] == "ask" { matched = .ask } else if fields[0] == "allow", matched == nil { matched = .allow }
        }
        // Tool prohibitions and explicit asks outrank all remembered grants.
        let permission = toolPermission(for: tool)
        if permission == .deny { return .deny }
        if matched == .ask || permission == .ask || mode == .everyTime { return .ask }
        if matched == .allow || permission == .allow { return .allow }
        if mode == .fullAccess { return .allow }
        if tool == "replace_file" || tool == "replace_files" { return .ask }
        if matched == .allow || patterns(commandWhitelist).contains(where: { pattern in values.contains { listMatches(pattern, $0, denying: false) } }) { return .allow }
        return automatic ? .allow : .ask
    }
}

struct AITaskRecord: Codable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let hostID: UUID?
    let target: String
    let question: String
    var transcript: String
    var summary: String
    var state: String
    var updated: Date
    var messageCount: Int? = nil
    var turns: [AIAssistant.ConversationTurn]? = nil
    var executed: Bool? = nil
    var workingMemory: AITaskMemory? = nil
    var verification: AIVerificationState? = nil
    var recovery: AITaskRecovery? = nil
    var plans: [AIAgentPlan]? = nil
    var planExecution: AIPlanExecution? = nil
    var todos: [AITodoItem]? = nil
    var parentConversationID: UUID? = nil
    var forkTurnCount: Int? = nil
    var usage: AIUsageLedger? = nil
}

@MainActor final class AIFileProposal {
    let edit: ExternalEdit
    let root: URL
    private(set) var preview: String
    let path: String
    let originalEntry: FileEntry
    private(set) var checkpoint: AIFileCheckpoint
    private(set) var originalText = ""
    init(backend: any FileEndpoint, path: String, find: String, replacement: String, wholeFile: Bool = false) async throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }), (wholeFile || !find.isEmpty), find != replacement, !find.contains("[REDACTED]"), !replacement.contains("[REDACTED]"), !replacement.contains("\0"), find.utf8.count <= (wholeFile ? 65536 : 16000), replacement.utf8.count <= (wholeFile ? 65536 : 16000) else { throw AppFailure.message("Use an absolute path and an exact nonempty replacement; redacted values cannot be written. / 请使用绝对路径和明确替换内容，不能写入脱敏占位符。") }
        let entry = try await backend.stat(path)
        originalEntry = entry
        guard entry.size <= 64 * 1024 else { throw AppFailure.message("Configuration edit limit is 64 KB / 配置修改限额为 64 KB") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-edit-" + UUID().uuidString)
        edit = try await ExternalEdit.prepare(entry: entry, backend: backend, directory: root)
        self.path = path
        do {
            let data = try Data(contentsOf: edit.localURL)
            guard let old = String(data: data, encoding: .utf8), (wholeFile ? old == find : old.components(separatedBy: find).count == 2) else { throw AppFailure.message("The exact text must occur once; read the configuration again. / 待替换内容必须精确匹配一次，请重新读取配置。") }
            originalText = old
            let new = wholeFile ? replacement : old.replacingOccurrences(of: find, with: replacement)
            guard new.utf8.count <= 64 * 1024 else { throw AppFailure.message("Configuration exceeds 64 KB / 配置超过 64 KB") }
            checkpoint = AIFileCheckpoint(path: path, before: AIFileCheckpoint.digest(data), after: AIFileCheckpoint.digest(Data(new.utf8)))
            preview = "− Exact original text / 原文：\n" + AIContext.sanitize(find) + "\n\n+ Replacement / 替换为：\n" + AIContext.sanitize(replacement)
            try Data(new.utf8).write(to: edit.localURL, options: .atomic)
            edit.checkChanges()
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func reviewedText() throws -> String { try String(contentsOf: edit.localURL, encoding: .utf8) }
    func updateReviewedContent(_ text: String) throws {
        guard text.utf8.count <= 65536, !text.contains("\0"), !text.contains("[REDACTED]") else { throw AIModelError.invalidReply }
        try Data(text.utf8).write(to: edit.localURL, options: .atomic)
        checkpoint = AIFileCheckpoint(path: path, before: checkpoint.before, after: AIFileCheckpoint.digest(Data(text.utf8)))
        preview = AIContext.sanitize(EditDifferencePreview.make(old: originalText, new: text))
        edit.checkChanges()
    }
    func checkOriginal() async throws {
        let entry = try await edit.backend.stat(path)
        guard !entry.symlink, !entry.directory, entry.size <= 65536, FileContentDigest.sameMetadata(originalEntry, entry), originalEntry.permissions == entry.permissions,
              AIFileCheckpoint.digest(try await ExternalEdit.read(entry, from: edit.backend)) == checkpoint.before else {
            throw AppFailure.message("File changed after review / 审阅后文件已改变：" + path)
        }
    }
    func apply() async throws -> AICommandResult {
        try Task.checkCancellation()
        try await edit.upload() // Conflict check, original backup, mode preservation and rollback.
        let entry = try await edit.backend.stat(path)
        let actual = try await ExternalEdit.read(entry, from: edit.backend)
        guard actual == (try Data(contentsOf: edit.localURL)) else { throw AppFailure.message("File verification failed / 文件校验失败") }
        return AICommandResult(output: "Applied and byte-verified: " + path + "\nBackup: " + edit.backupPath + "\nService recovery has NOT yet been verified; perform health checks.", exitCode: 0)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

struct AITaskPolicyFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var policy: AIExecutionPolicy
    @State private var editingRule: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.text("Task execution", "任务执行")).font(.system(size: 14, weight: .semibold))
            AxonChoiceField(selection: Binding(get: { policy.mode }, set: { policy.approvalMode = $0 }), choices: AIExecutionPolicy.Mode.allCases.map { ($0, modeTitle($0)) }, placeholder: store.text("Approval mode", "批准模式"), symbol: "hand.raised", identifier: "axon-ai-approval-mode").frame(maxWidth: 360)
            Text(modeDescription).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(store.text("System command rules · all targets", "系统级命令规则 · 适用于所有目标")).font(.system(size: 12, weight: .semibold))
            Label(store.text("Critical operations remain prohibited: physical deletion, data destruction, disk formatting/partition changes, raw block-device writes, shutdown/reboot and AI use of interactive editors (Vim/Nano/Emacs). Other commands follow the selected permission mode and system/server rules. Blacklists and deny rules take priority. Scripts are inspected before execution.", "关键操作禁止执行：物理删除、销毁数据、磁盘格式化／分区变更、块设备写入、关机重启及 AI 操作交互式编辑器（Vim/Nano/Emacs）。其他命令遵循所选权限模式及系统／服务器规则，黑名单与 deny 规则优先。脚本执行前检查内容。"), systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(Palette.muted)
            AICommandListFields(whitelist: Binding(get: { policy.commandWhitelist ?? "" }, set: { policy.commandWhitelist = $0 }), blacklist: Binding(get: { policy.commandBlacklist ?? "" }, set: { policy.commandBlacklist = $0 }), identifier: "axon-ai-command")
            Text(store.text("One command name per line, e.g. rm or printf. Names cover command arguments, sudo and absolute paths. Existing regex entries remain supported. System rules apply to every target; server rules are in host details. Both blacklists win over allow rules. Every-time approval ignores allow rules. Explicit advanced ask rules still require approval in full access.", "每行一个命令名，例如 rm 或 printf，覆盖不同参数、sudo 和绝对路径。兼容已有正则规则。系统级规则作用于全部目标；服务器级规则在主机详情中配置。两级黑名单均优先于白名单。每次批准不自动放行允许规则；完整权限仍遵守高级 ask 规则。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
            AIToolPermissionFields(policy: $policy)
            Stepper(store.text("Maximum steps: ", "最多步骤：") + String(policy.maximumSteps), value: $policy.maximumSteps, in: 12...200)
            Stepper(store.text("Command timeout: ", "命令超时：") + String(policy.commandSeconds) + "s", value: $policy.commandSeconds, in: 10...1800, step: 10)
            Stepper(store.text("Task budget: ", "任务时长：") + String(policy.taskMinutes) + store.text(" min", " 分钟"), value: $policy.taskMinutes, in: 1...240)
            AIUsageBudgetFields(policy: $policy)
            if let exact = policy.exactAllows, !exact.isEmpty {
                Text(store.text("Remembered exact permissions: ", "已记住的精确权限规则：") + String(exact.count)).foregroundStyle(Palette.muted)
                ForEach(Array(exact.enumerated()), id: \.offset) { index, rule in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) { Text(rule.global == true ? store.text("All servers · exact command", "全部服务器 · 精确命令") : rule.target).font(.system(size: 11)); Text((rule.denied == true ? store.text("Deny · ", "禁止 · ") : store.text("Allow · ", "允许 · ")) + rule.tool + " " + rule.argument).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled) }
                        Spacer()
                        PreferencesActionButton(title: store.text("Edit", "编辑"), identifier: "axon-ai-edit-rule-" + String(index)) { editingRule = editingRule == index ? nil : index }.frame(width: 54, height: 30)
                        PreferencesActionButton(title: store.text("Remove", "删除"), identifier: "axon-ai-remove-rule-" + String(index), destructive: true) { policy.exactAllows?.remove(at: index); editingRule = nil }.frame(width: 54, height: 30)

                    }.accessibilityElement(children: .contain).padding(8).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    if editingRule == index {
                        VStack(alignment: .leading, spacing: 6) {
                            AxonChoiceField(selection: Binding(get: { policy.exactAllows?[index].global == true }, set: { value in guard policy.exactAllows?.indices.contains(index) == true else { return }; policy.exactAllows?[index].global = value ? true : nil }), choices: [(false, store.text("Original server", "原服务器")), (true, store.text("All servers", "全部服务器"))], placeholder: store.text("Scope", "作用范围"), symbol: "globe", identifier: "axon-ai-rule-scope").frame(maxWidth: 300)
                            Text(store.text("The command still matches exactly. Blacklists take priority.", "命令仍精确匹配，黑名单优先。切回原服务器会保留主机绑定。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Text(store.text("Target (original host binding retained)", "目标（保留原主机绑定）")).foregroundStyle(Palette.muted)
                            TextField("Target", text: ruleBinding(index, \.target)).appInput().accessibilityIdentifier("axon-ai-rule-target")
                            Toggle(store.text("Deny this exact operation", "禁止此精确操作"), isOn: Binding(get: { policy.exactAllows?[index].denied == true }, set: { policy.exactAllows?[index].denied = $0 ? true : nil })).toggleStyle(AxonCheckboxStyle())
                            Text(store.text("Tool", "工具")).foregroundStyle(Palette.muted)
                            TextField("command / terminal_send / …", text: ruleBinding(index, \.tool)).appInput().accessibilityIdentifier("axon-ai-rule-tool")
                            Text(store.text("Exact argument", "精确参数")).foregroundStyle(Palette.muted)
                            TextField("Argument", text: ruleBinding(index, \.argument)).appInput().accessibilityIdentifier("axon-ai-rule-argument")
                            Button(store.text("Done editing", "完成编辑")) { editingRule = nil }.buttonStyle(ChromeButtonStyle())
                        }
                    }
                }
            }
            Text(store.text("Advanced permission rules", "高级权限规则")).foregroundStyle(Palette.muted)
            TextEditor(text: $policy.rules).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).frame(height: 100).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("axon-ai-permission-rules")
            Text(store.text("One rule per line: allow/ask/deny|target regex|tool|argument regex. Both regexes match the entire value; deny takes priority. Example: allow|local fixture|command|printf test. Approval follows the selected mode; assisted file edits require diff approval. Rules apply only to Axon's execution bridge.", "每行：allow/ask/deny|目标正则|工具|参数正则。正则匹配完整内容，deny 优先。例：allow|local fixture|command|printf test。按所选模式批准；帮我批准模式下配置修改需确认差异。规则仅作用于 Axon 执行通道。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.font(.system(size: 12)).padding(18).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func modeTitle(_ mode: AIExecutionPolicy.Mode) -> String {
        switch mode {
        case .everyTime: return store.text("Approve every time", "每次批准")
        case .assisted: return store.text("Help me approve", "帮我批准")
        case .fullAccess: return store.text("Full access", "完整权限")
        }
    }
    private var modeDescription: String {
        switch policy.mode {
        case .everyTime: return store.text("Ask before each operation, including read-only commands.", "每个操作都先请求批准，包括只读命令。")
        case .assisted: return store.text("Automatically approve built-in read-only checks and allow rules; ask for other operations.", "自动批准内置只读检查和允许规则，其他操作请求批准。")
        case .fullAccess: return store.text("Automatically execute commands, terminal interactions and file changes on the current target. Blacklist and explicit ask rules remain effective.", "在当前目标自动执行命令、终端交互和文件修改；黑名单与明确要求确认的规则仍生效。")
        }
    }
    private func commandList(_ title: String, binding: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(Palette.muted)
            TextEditor(text: binding).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).frame(height: 64).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier(identifier)
        }
    }
    private func ruleBinding(_ index: Int, _ key: WritableKeyPath<AIExactPermission, String>) -> Binding<String> {
        Binding(get: { guard let rules = policy.exactAllows, rules.indices.contains(index) else { return "" }; return rules[index][keyPath: key] }, set: { value in guard policy.exactAllows?.indices.contains(index) == true else { return }; policy.exactAllows?[index][keyPath: key] = value })
    }

}

struct AICommandListFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var whitelist: String
    @Binding var blacklist: String
    var identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            list(store.text("Blacklist · always deny", "黑名单 · 始终禁止"), value: $blacklist, suffix: "blacklist")
            list(store.text("Whitelist · automatically allow in assisted mode", "白名单 · 帮我批准时自动允许"), value: $whitelist, suffix: "whitelist")
            Text(store.text("One command name per line, e.g. rm. Blacklists also inspect compound commands; keyword whitelists allow simple commands only. Existing regex entries remain supported. Blank inherits system rules. Either blacklist wins; whitelists combine. Every-time approval still asks.", "每行一个命令名，例如 rm。黑名单也检查复合命令；命令名白名单仅自动允许单条简单命令。兼容已有正则规则。服务器级留空沿用系统规则。任一级黑名单命中即禁止，白名单合并；每次批准仍需确认。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
    private func list(_ title: String, value: Binding<String>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextEditor(text: value).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).frame(height: 64).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier(identifier + "-" + suffix)
        }
    }
}

struct AIHostCommandRules: View {
    @EnvironmentObject var store: AppStore
    @Binding var host: Host
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(store.text("AI server command rules", "AI 服务器级命令规则"), systemImage: "checkmark.shield").font(.system(size: 13, weight: .semibold))
            Text(store.text("Applies only to this saved server. System rules remain active.", "仅适用于这台已保存的服务器，系统级规则仍然生效。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            AICommandListFields(whitelist: Binding(get: { host.aiCommandWhitelist ?? "" }, set: { host.aiCommandWhitelist = $0 }), blacklist: Binding(get: { host.aiCommandBlacklist ?? "" }, set: { host.aiCommandBlacklist = $0 }), identifier: "axon-host-ai-command")
        }
    }
}
