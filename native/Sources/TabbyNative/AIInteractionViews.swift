import SwiftUI

struct AIClarificationView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var ai: AIAssistant
    let question: AIClarification
    var maximumQuestionHeight: CGFloat = 280
    @State private var responses: [Int: String] = [:]
    @State private var selections: [Int: Set<String>] = [:]
    private var answer: String? { question.response(selections: selections, text: responses) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(question.fields.enumerated()), id: \.offset) { index, field in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(field.question, systemImage: "questionmark.bubble").font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            if field.multiple == true { Text(store.text("Select all that apply", "可选择多项")).font(.caption).foregroundStyle(Palette.muted) }
                            ForEach(field.options, id: \.self) { option in
                                let chosen = selections[index, default: []].contains(option)
                                Button {
                                    if field.multiple == true {
                                        if chosen { selections[index, default: []].remove(option) } else { selections[index, default: []].insert(option) }
                                    } else { selections[index] = [option] }
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        AxonSelectionMark(selected: chosen)
                                        Text(option).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(8).background(chosen ? Palette.selected : Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityIdentifier("axon-ai-question-option-\(index)-\(field.options.firstIndex(of: option) ?? 0)").accessibilityValue(chosen ? "selected" : "unselected")
                            }
                            TextField(store.text("Your answer, or additional details", "输入回答或补充说明"), text: Binding(get: { responses[index] ?? "" }, set: { responses[index] = $0 })).appInput().onSubmit { submit() }.accessibilityIdentifier("axon-ai-clarification-input-\(index)")
                        }
                    }
                }
            }.frame(height: maximumQuestionHeight)
            HStack {
                Button(store.text("Skip", "跳过")) { ai.skipQuestion() }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-ai-question-skip")
                Spacer()
                Button(store.text("Answer", "回答")) { submit() }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(answer == nil).accessibilityIdentifier("axon-ai-question-answer")
            }
            Text(store.text("Your answer does not approve commands or file changes.", "回答问题不会批准命令或文件修改。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(12).background(Palette.selected).clipShape(RoundedRectangle(cornerRadius: 8)).id(question.summary)
    }
    private func submit() { if let answer { ai.answerQuestion(answer) } }
}

struct AIPromptQueueView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var ai: AIAssistant
    @State private var editing: AIQueuedPrompt?
    @State private var draft = ""
    var body: some View {
        DisclosureGroup(store.text("Queued messages · \(ai.queuedPrompts.count)", "排队消息 · \(ai.queuedPrompts.count)")) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(ai.queuedPrompts.enumerated()), id: \.element.id) { index, prompt in
                        HStack(spacing: 4) {
                            Text(prompt.text).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Button { ai.moveQueued(prompt.id, offset: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(IconButtonStyle()).disabled(index == 0).help(store.text("Move up", "上移"))
                            Button { ai.moveQueued(prompt.id, offset: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(IconButtonStyle()).disabled(index == ai.queuedPrompts.count - 1).help(store.text("Move down", "下移"))
                            Button { draft = prompt.text; editing = prompt } label: { Image(systemName: "pencil") }.buttonStyle(IconButtonStyle()).help(store.text("Edit", "编辑"))
                            Button { ai.removeQueued(prompt.id) } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(store.text("Remove", "移除"))
                        }.padding(6).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: 120)
            if !ai.busy {
                Button(store.text("Continue queue", "继续队列")) { ai.resumeQueue() }.buttonStyle(ChromeButtonStyle()).disabled(!ai.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("axon-ai-queue-resume")
            }
            Text(store.text("Runs in order after completion. Stops on failure, refusal or cancellation. Not saved after quitting.", "完成后按顺序执行；失败、拒绝或停止时暂停。退出应用后不保留队列。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.font(.system(size: 11)).accessibilityIdentifier("axon-ai-prompt-queue")
            .sheet(item: $editing) { prompt in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(store.text("Edit queued message", "编辑排队消息")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { editing = nil } }
                    AIComposer(text: $draft, send: { if ai.editQueued(prompt.id, text: draft) { editing = nil } }).frame(height: 120).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack { Spacer(); Button(store.text("Save", "保存")) { if ai.editQueued(prompt.id, text: draft) { editing = nil } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.utf8.count > 24000) }
                }.padding(20).frame(width: 440).foregroundStyle(Palette.text).background(Palette.background)
            }
    }
}

struct AIPlanSheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var ai: AIAssistant
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AIAgentPlan(title: "", items: [])
    @State private var revision = ""
    @State private var mode = "edit"
    @State private var selected = Set<String>()
    @State private var message = ""
    private var comparison: AIAgentPlan { let index = Int(revision) ?? 0; return index > 0 && ai.plans.indices.contains(index - 1) ? ai.plans[index - 1] : AIAgentPlan(title: "", items: []) }
    private var valid: Bool { guard let data = try? JSONEncoder().encode(draft) else { return false }; return (try? AIAgentPlan.decode(String(decoding: data, as: UTF8.self))) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Plan & tasks", "计划与待办")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }
            HStack {
                AxonChoiceField(selection: $mode, choices: [("edit", store.text("Edit & select stages", "编辑与选择阶段")), ("diff", store.text("Compare versions", "比较版本")), ("todo", store.text("Task list", "待办列表"))], placeholder: store.text("View", "视图"), symbol: "list.bullet", identifier: "axon-ai-plan-mode")
                AxonChoiceField(selection: $revision, choices: ai.plans.indices.reversed().map { (String($0), store.text("Revision \($0 + 1)", "版本 \($0 + 1)")) }, placeholder: store.text("Revision", "版本"), symbol: "clock", identifier: "axon-ai-plan-revision").frame(width: 160)
            }
            if mode == "edit" { TextField(store.text("Plan title *", "计划标题 *"), text: $draft.title).appInput() }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if mode == "todo" {
                        if ai.todos.isEmpty { Text(store.text("Task memory creates todos as work remains.", "AI 工作记忆中的剩余事项会自动生成待办。")).font(.caption).foregroundStyle(Palette.muted) }
                        ForEach(ai.todos) { item in
                            HStack {
                                Text(item.title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                                AxonChoiceField(selection: Binding(get: { item.status }, set: { ai.updateTodo(item.id, status: $0) }), choices: statusChoices, placeholder: store.text("Status", "状态"), symbol: "checklist", identifier: "axon-ai-todo-status").frame(width: 140).disabled(ai.busy && !ai.canSteer)
                            }.padding(10).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else if mode == "diff" {
                        Text(store.text("Compared with the previous revision", "与前一版本比较")).font(.caption).foregroundStyle(Palette.muted)
                        if draft.title != comparison.title { Text(comparison.title + " → " + draft.title).font(.system(size: 12, weight: .medium)) }
                        if draft.differences(from: comparison).isEmpty { Text(store.text("No step changes", "步骤没有变化")).foregroundStyle(Palette.muted) }
                        ForEach(draft.differences(from: comparison)) { difference in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(difference.id).font(.caption).foregroundStyle(Palette.muted)
                                if let old = difference.before { Text("− " + old.title + " · " + statusTitle(old.status)).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                                if let new = difference.after { Text("+ " + new.title + " · " + statusTitle(new.status)).font(.system(size: 12)) }
                                Text(store.text("Dependencies", "依赖") + ": " + (difference.before?.dependencies ?? []).joined(separator: ", ") + " → " + (difference.after?.dependencies ?? []).joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                Text(store.text("Position", "顺序") + ": " + (comparison.items.firstIndex(where: { $0.id == difference.id }).map { String($0 + 1) } ?? "—") + " → " + (draft.items.firstIndex(where: { $0.id == difference.id }).map { String($0 + 1) } ?? "—")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Button { if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) } } label: { HStack { AxonSelectionMark(selected: selected.contains(item.id)); Text(store.text("Stage \(index + 1)", "阶段 \(index + 1)")) }.padding(.horizontal, 8).frame(minHeight: 34) }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityValue(selected.contains(item.id) ? "1" : "0").disabled(ai.busy).accessibilityIdentifier("axon-ai-plan-select-" + item.id)
                                    Text(item.id).font(.system(size: 10)).foregroundStyle(Palette.muted); Spacer()
                                    Button { draft.items.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.buttonStyle(IconButtonStyle()).disabled(index == 0)
                                    Button { draft.items.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(IconButtonStyle()).disabled(index == draft.items.count - 1)
                                    Button { draft.items.removeAll { $0.id == item.id }; selected.remove(item.id) } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle())
                                }
                                TextField(store.text("Step *", "步骤 *"), text: Binding(get: { draft.items.first { $0.id == item.id }?.title ?? "" }, set: { text in if let i = draft.items.firstIndex(where: { $0.id == item.id }) { draft.items[i].title = text } })).appInput()
                                HStack {
                                    AxonChoiceField(selection: Binding(get: { draft.items.first { $0.id == item.id }?.status ?? "pending" }, set: { value in if let i = draft.items.firstIndex(where: { $0.id == item.id }) { draft.items[i].status = value } }), choices: statusChoices, placeholder: store.text("Status", "状态"), symbol: "checklist", identifier: "axon-ai-plan-step-status").frame(width: 145)
                                    TextField(store.text("Dependency IDs, comma separated", "依赖阶段 ID，以逗号分隔"), text: Binding(get: { draft.items.first { $0.id == item.id }?.dependencies?.joined(separator: ",") ?? "" }, set: { value in if let i = draft.items.firstIndex(where: { $0.id == item.id }) { draft.items[i].dependencies = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } })).appInput()
                                }
                            }.padding(10).background(selected.contains(item.id) ? Palette.selected : Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button(store.text("Add step", "添加步骤")) { draft.items.append(.init(id: UUID().uuidString, title: "", status: "pending")) }.buttonStyle(ChromeButtonStyle()).disabled(draft.items.count >= 20).accessibilityIdentifier("axon-ai-plan-add")
                    }
                }
            }
            Text(store.text("Statuses are task reports, not proof. Selecting stages preserves the original goal and checks. Dependencies must finish first.", "状态是任务记录，不能替代验收。选择阶段保留原目标与验收条件；必须先完成依赖。")).font(.caption).foregroundStyle(Palette.muted)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Palette.muted) }
            HStack {
                if ai.busy && ai.planExecution != nil { Button(store.text("Pause stages", "暂停阶段")) { ai.pausePlan() }.buttonStyle(ChromeButtonStyle()) }
                if !ai.busy && ai.planExecution != nil { Button(store.text("Clear selection", "清除阶段选择")) { ai.clearPlanSelection(); selected = [] }.buttonStyle(ChromeButtonStyle()) }
                Spacer()
                Button(store.text("Save revision", "保存版本")) { if ai.revisePlan(draft) { message = store.text("Saved", "已保存") } else { message = store.text("Plan conflicts with the current selected stages.", "计划与当前所选阶段冲突。") } }.buttonStyle(ChromeButtonStyle()).disabled(!valid || ai.busy && !ai.canSteer).accessibilityIdentifier("axon-ai-plan-save")
                Button(store.text("Select stages", "选择阶段")) { if ai.revisePlan(draft) && ai.selectPlanStages(draft.items.filter { selected.contains($0.id) }.map(\.id)) { dismiss() } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.busy || !valid || selected.isEmpty).accessibilityIdentifier("axon-ai-plan-apply-stages")
            }
        }.padding(20).frame(width: 660, height: 600).foregroundStyle(Palette.text).background(Palette.background)
        .onAppear { revision = String(max(0, ai.plans.count - 1)); draft = ai.plans.last ?? draft; selected = Set(ai.planExecution?.selected ?? []) }
        .onChange(of: revision) { _, value in if let index = Int(value), ai.plans.indices.contains(index) { draft = ai.plans[index] } }
    }
    private var statusChoices: [(String, String)] { ["pending", "running", "completed", "cancelled"].map { ($0, statusTitle($0)) } }
    private func statusTitle(_ status: String) -> String { store.text(status.capitalized, ["pending":"待执行", "running":"进行中", "completed":"已完成", "cancelled":"已取消"][status] ?? status) }
}
