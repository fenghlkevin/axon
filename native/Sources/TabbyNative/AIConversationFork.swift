import SwiftUI

struct AIConversationForkSheet: View {
    @ObservedObject var ai: AIAssistant
    let entry: AITaskRecord
    let completed: () -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    private var turns: [AIAssistant.ConversationTurn] { entry.turns ?? [] }
    private var count: Int { Int(selected) ?? turns.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.text("Fork conversation", "分叉会话")).font(.system(size: 18, weight: .semibold))
                Spacer()
                DismissIconButton(title: store.text("Close", "关闭")) { dismiss() }
            }
            Text(store.text("Choose the last turn to include. Later messages remain in the original conversation.", "选择保留到哪一轮，之后的消息只留在原会话中。"))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            AxonChoiceField(selection: $selected, choices: turns.indices.map { (String($0 + 1), store.text("Turn \($0 + 1): ", "第 \($0 + 1) 轮：") + String(turns[$0].question.prefix(60))) }, placeholder: store.text("Include through", "保留到"), symbol: "arrow.triangle.branch", identifier: "axon-ai-fork-turn")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(turns.prefix(count).enumerated()), id: \.offset) { index, turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). " + turn.question).font(.system(size: 12, weight: .semibold)).lineLimit(3)
                            Text(turn.answer.isEmpty ? turn.error : turn.answer).font(.system(size: 12)).lineLimit(4).foregroundStyle(Palette.muted)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text(store.text("Creates independent history on the original target. Commands are not replayed. Previous approvals and checks do not carry over.", "在原目标上建立独立历史；不重放命令，不继承审批与验收结果。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack { Spacer(); Button(store.text("Create branch", "创建分支")) {
                if ai.forkConversation(entry, through: count) { dismiss(); completed() }
            }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.busy || turns.isEmpty).accessibilityIdentifier("axon-ai-create-fork") }
            if !ai.error.isEmpty { Text(ai.error).font(.system(size: 11)).foregroundStyle(.red) }
        }.padding(20).frame(width: 480, height: 480).foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light)
            .onAppear { selected = String(turns.count) }
    }
}
