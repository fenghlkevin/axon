import SwiftUI

struct AIAgentRuntimeField: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: AIAgentRuntime
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.text("Agent execution", "Agent 执行方式")).foregroundStyle(Palette.muted)
            AxonChoiceField(selection: $selection, choices: [
                (.axon, store.text("Axon Agent · original", "Axon Agent · 原有方式")),
                (.codexNative, store.text("Codex Agent · native tools", "Codex Agent · 原生工具"))
            ], placeholder: store.text("Choose Agent", "选择 Agent"), symbol: "brain", identifier: "axon-ai-agent-runtime")
            Text(store.text("Axon Agent keeps the original task protocol. Codex Agent calls each tool directly. Both retain Axon permissions, context, Skills and recovery. Changes apply automatically to the next task; available with Codex CLI.", "Axon Agent 保留原有任务协议；Codex Agent 直接调用独立工具。两种方式均保留 Axon 权限、上下文、Skills 和恢复能力。修改后自动保存，下次任务生效，仅用于 Codex CLI。"))
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 500, alignment: .leading)
    }
}
