import SwiftUI

struct AITaskRecoverySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var ai: AIAssistant
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(store.text("Recovery and completion evidence", "恢复与完成证据"), systemImage: "checkmark.shield").font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }
            Text(store.text("Recorded receipts explain what happened. Saved results are historical; resume rechecks the original target and goal. Unknown command submissions are never automatically replayed.", "执行回执说明实际发生了什么。保存结果是历史证据；继续时重新检查原目标与验收。结果不明的命令不会自动重放。")).font(.caption).foregroundStyle(Palette.muted)
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                ForEach(ai.taskRecords.reversed()) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.question).font(.system(size: 13, weight: .semibold)).lineLimit(3)
                        Text(record.target).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
                        if let recovery = record.recovery {
                            ForEach(recovery.operations.suffix(30), id: \.id) { operation in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(operation.tool + " · " + status(operation.state)).font(.system(size: 12, weight: .semibold))
                                    Text(AIContext.sanitize(operation.argument)).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                                    if let id = operation.executionID { Text(store.text("Execution receipt: ", "执行回执：") + id.uuidString).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled) }
                                    if let files = operation.files { Text(files.map(\.path).joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            if recovery.uncertainMutation { Text(store.text("Uncertain changes block new mutations and final success. Inspect the file timeline or report the blocker; arbitrary Shell side effects need manual inspection.", "不确定修改会阻止新的修改及成功结论。可在文件时间线核对恢复，或报告阻碍；任意 Shell 副作用仍需人工检查。")).font(.caption).foregroundStyle(Palette.danger) }
                        }
                        if let verification = record.verification {
                            Text(verification.pending || verification.inputPending ? store.text("Goal checks pending", "目标验收待完成") : verification.hasChanges ? store.text("Recorded goal checks passed — recheck on resume", "历史目标验收通过，继续时重检") : store.text("No modification checks recorded", "尚无修改验收记录")).font(.system(size: 12, weight: .semibold))
                            ForEach(verification.checks.indices, id: \.self) { index in
                                let check = verification.checks[index]
                                Text((verification.passed.contains(index) ? "✓ " : "○ ") + check.tool + " " + AIContext.sanitize(check.argument) + "\n" + store.text("Expected: ", "预期：") + AIContext.sanitize(check.expectedOutput)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if ai.taskRecords.isEmpty { Text(store.text("No task receipts yet", "尚无任务回执")).foregroundStyle(Palette.muted) }
            } }
        }.padding(20).frame(width: 680, height: 560).background(Palette.background).foregroundStyle(Palette.text)
    }
    private func status(_ value: String) -> String {
        switch value { case "completed": return store.text("Completed receipt", "已完成回执"); case "running": return store.text("Running; poll by ID", "运行中，按回执继续查询"); case "not_applied": return store.text("Original files verified", "已核对未应用"); case "reverted": return store.text("Original version restored", "已恢复原版本"); default: return store.text("Outcome uncertain", "结果不明") }
    }
}
