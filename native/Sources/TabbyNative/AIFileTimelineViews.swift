import SwiftUI

struct AIFileTimelineSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var ai: AIAssistant
    @ObservedObject var timeline: AIFileTimeline
    @StateObject var model: AIFileTimelineReview
    @State private var selected: UUID?
    @State private var paths: Set<String> = []
    init(ai: AIAssistant, executor: AICommandExecutor) {
        self.ai = ai; self.timeline = ai.fileTimeline
        _model = StateObject(wrappedValue: AIFileTimelineReview(timeline: ai.fileTimeline, executor: executor, policy: { ai.settings.policy }))
    }
    private var entry: AIFileTimeline.Entry? { timeline.entries.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(store.text("File change history", "文件变更时间线"), systemImage: "clock.arrow.circlepath").font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() }.disabled(model.busy).accessibilityIdentifier("axon-timeline-close") }
            Text(store.text("Recorded Axon AI edits. Select files or individual hunks, preview Undo or Redo, then apply. Newer edits are protected.", "记录 Axon AI 文件修改。选择文件或差异块，预览撤销／重做后再应用；遇到更新修改会停止。")).font(.caption).foregroundStyle(Palette.muted)
            HStack(alignment: .top, spacing: 12) {
                ScrollView { VStack(spacing: 8) {
                    ForEach(timeline.entries.reversed()) { item in
                        Button { selected = item.id; paths = Set(item.files.map(\.path)); Task { await model.inspect(item) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                Text(item.date.formatted()).font(.caption)
                                Text(item.target).font(.caption).lineLimit(1)
                                Text(String(item.files.count) + store.text(" files · ", " 文件 · ") + state(item.state)).font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(selected == item.id ? Palette.selected : Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(AxonSurfaceButtonStyle()).disabled(model.busy).accessibilityIdentifier("axon-timeline-entry-" + item.id.uuidString)
                    }
                    if timeline.entries.isEmpty { Text(store.text("No recorded file edits yet", "尚无文件修改记录")).font(.caption).foregroundStyle(Palette.muted) }
                } }.frame(width: 235)
                VStack(alignment: .leading, spacing: 10) {
                    if let entry {
                        ScrollView { VStack(alignment: .leading, spacing: 8) {
                            ForEach(entry.files) { file in
                                Toggle(isOn: Binding(get: { paths.contains(file.path) }, set: { if $0 { paths.insert(file.path) } else { paths.remove(file.path) }; model.review = nil })) {
                                    VStack(alignment: .leading, spacing: 3) { Text(file.path).font(.system(size: 12, weight: .semibold)).lineLimit(2); Text(fileState(model.states[file.path])).font(.caption).foregroundStyle(["conflict", "unavailable"].contains(model.states[file.path] ?? "") ? Palette.danger : Palette.muted) }
                                }.toggleStyle(AxonCheckboxStyle()).disabled(model.busy).accessibilityIdentifier("axon-timeline-file-" + file.path)
                            }
                        } }.frame(maxHeight: 140)
                        HStack {
                            Button(store.text("Inspect current files", "核对当前文件")) { Task { await model.inspect(entry) } }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-timeline-inspect")
                            Spacer()
                            Button(store.text("Preview Undo", "预览撤销")) { Task { await model.prepare(entry, after: false, paths: paths) } }.buttonStyle(ChromeButtonStyle()).disabled(paths.isEmpty).accessibilityIdentifier("axon-timeline-undo")
                            Button(store.text("Preview Redo", "预览重做")) { Task { await model.prepare(entry, after: true, paths: paths) } }.buttonStyle(ChromeButtonStyle()).disabled(paths.isEmpty).accessibilityIdentifier("axon-timeline-redo")
                        }.disabled(model.busy)
                        if let review = model.review { TimelineHunks(review: review) }
                        else { ScrollView { Text(store.text("Choose a version to compare with the current files. Unavailable files require reconnecting or checking the retained backups.", "选择版本后与当前文件比较。文件不可用时，请重连或检查保留的备份。")).font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading) }.padding(12).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    } else { Text(store.text("Select a change on the left", "从左侧选择一次修改")).foregroundStyle(Palette.muted); Spacer() }
                }.frame(maxWidth: .infinity)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if !timeline.error.isEmpty { Text(timeline.error).font(.caption).foregroundStyle(Palette.danger) }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(Palette.danger).textSelection(.enabled).lineLimit(3) }
            if !model.message.isEmpty { ScrollView { Text(model.message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 75) }
            Text(store.text("Local private snapshots: up to 64 changes, 8 files per change, 64 KiB per file, 16 MiB total. Shell and external editor changes are not captured. Restoring files does not prove the task succeeded.", "本机私有快照：最多 64 次、每次 8 文件、每文件 64 KiB、总计 16 MiB。不记录 Shell 或外部编辑器修改；恢复文件后仍需目标验收。")).font(.caption).foregroundStyle(Palette.muted)
            HStack { Spacer(); Button(store.text("Apply reviewed restore", "应用已审查的恢复")) { if let entry { Task { guard ai.beginFileRestore() else { return }; defer { ai.endFileRestore() }; await model.apply(origin: entry) { try ai.didRestoreFiles($0, executor: model.executor) } } } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.busy || ai.fileRestoreBusy || model.busy || model.review?.valid != true).accessibilityIdentifier("axon-timeline-apply") }
        }.padding(20).frame(width: 960, height: 680).background(Palette.background).foregroundStyle(Palette.text).task { do { try timeline.reload() } catch { timeline.error = error.localizedDescription } }.onDisappear { Task { await model.closeBackend() } }
    }
    private func state(_ value: String) -> String { value == "applied" ? store.text("Applied", "已应用") : value == "not_applied" ? store.text("Original present", "原版本已核对") : store.text("Needs inspection", "需核对") }
    private func fileState(_ value: String?) -> String {
        switch value { case "before": return store.text("Original version present", "当前为修改前版本"); case "after": return store.text("Modified version present", "当前为修改后版本"); case "recorded": return store.text("Another recorded version present", "当前为另一已记录版本"); case "conflict": return store.text("Newer edits — restore blocked", "存在更新修改，禁止覆盖"); case "unavailable": return store.text("Unavailable — reconnect or inspect backup", "不可用，请重连或核对备份"); default: return store.text("Not inspected", "尚未核对") }
    }
}

private struct TimelineHunks: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var review: AIChangeReview
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 10) {
            ForEach(review.files.indices, id: \.self) { f in
                Text(review.files[f].path).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
                ForEach(review.files[f].hunks.indices, id: \.self) { h in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(store.text("Lines ", "当前行 ") + String(review.files[f].hunks[h].start + 1) + "–" + String(max(review.files[f].hunks[h].start + 1, review.files[f].hunks[h].end)), isOn: $review.files[f].hunks[h].selected).toggleStyle(AxonCheckboxStyle()).accessibilityIdentifier("axon-timeline-hunk-\(f)-\(h)")
                        Text("− " + AIContext.sanitize(review.files[f].hunks[h].before.joined(separator: "\n")) + "\n+ " + AIContext.sanitize(review.files[f].hunks[h].after.joined(separator: "\n"))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        } }
    }
}
