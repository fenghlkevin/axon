import Foundation
import SwiftUI

@MainActor final class AIChangeReview: ObservableObject {
    struct Hunk: Identifiable {
        var id = UUID()
        var start: Int
        var end: Int
        var before: [String]
        var after: [String]
        var selected = true
        var edited: String?
        var comment = ""
        var text: String { edited ?? after.joined(separator: "\n") }
    }
    struct File: Identifiable {
        var id: String { path }
        var path: String
        var original: [String]
        var hunks: [Hunk]
        func content() -> String {
            var lines = original
            for hunk in hunks.reversed() where hunk.selected {
                let replacement = hunk.edited.map { $0.isEmpty ? [] : $0.components(separatedBy: "\n") } ?? hunk.after
                lines.replaceSubrange(hunk.start..<hunk.end, with: replacement)
            }
            return lines.joined(separator: "\n")
        }
    }
    @Published var files: [File]
    @Published var request = ""
    init(proposals: [AIFileProposal]) throws {
        files = try proposals.map { proposal in
            let a = proposal.originalText.components(separatedBy: "\n"), b = try proposal.reviewedText().components(separatedBy: "\n")
            var hunks: [Hunk] = []
            if max(a.count, b.count) > 1000 { hunks = [.init(start: 0, end: a.count, before: a, after: b)] }
            else {
                var removed = Set<Int>(), inserted = Set<Int>()
                for change in b.difference(from: a) { switch change { case .remove(let offset, _, _): removed.insert(offset); case .insert(let offset, _, _): inserted.insert(offset) } }
                var i = 0, j = 0
                while i < a.count || j < b.count {
                    if removed.contains(i) || inserted.contains(j) {
                        let start = i, right = j
                        while i < a.count && removed.contains(i) { i += 1 }
                        while j < b.count && inserted.contains(j) { j += 1 }
                        hunks.append(.init(start: start, end: i, before: Array(a[start..<i]), after: Array(b[right..<j])))
                    } else { i += 1; j += 1 }
                }
            }
            return File(path: proposal.path, original: a, hunks: hunks)
        }
    }
    var valid: Bool { files.contains { $0.content() != $0.original.joined(separator: "\n") } && files.allSatisfy { let value = $0.content(); return value.utf8.count <= 65536 && !value.contains("\0") && !value.contains("[REDACTED]") } }
    var feedback: String {
        let comments = files.flatMap { file in file.hunks.filter { !$0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { file.path + ":" + String($0.start + 1) + "–" + String(max($0.start + 1, $0.end)) + ": " + $0.comment } }
        return ([request] + comments).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func update(_ proposals: [AIFileProposal]) throws {
        guard valid else { throw AppFailure.message("Select at least one valid change / 请至少选择一项有效修改") }
        for proposal in proposals { if let file = files.first(where: { $0.path == proposal.path }) { try proposal.updateReviewedContent(file.content()) } }
    }
}

struct AIChangeReviewSheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var ai: AIAssistant
    @ObservedObject var review: AIChangeReview
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Review file changes", "审查文件修改")).font(.headline); Spacer(); DismissIconButton(title: store.text("Back", "返回"), action: close) }
            Text(ai.executionSource).font(.caption).foregroundStyle(Palette.muted)
            ScrollView {
                ForEach(review.files.indices, id: \.self) { fileIndex in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(review.files[fileIndex].path).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                        ForEach(review.files[fileIndex].hunks.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(store.text("Lines ", "原文行 ") + String(review.files[fileIndex].hunks[index].start + 1) + "–" + String(max(review.files[fileIndex].hunks[index].start + 1, review.files[fileIndex].hunks[index].end)), isOn: $review.files[fileIndex].hunks[index].selected).toggleStyle(AxonCheckboxStyle()).accessibilityIdentifier("axon-diff-hunk-\(fileIndex)-\(index)")
                                Text("− " + AIContext.sanitize(review.files[fileIndex].hunks[index].before.joined(separator: "\n"))).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                                Text(store.text("Replacement (editable)", "替换内容（可手改）")).font(.caption).foregroundStyle(Palette.muted)
                                TextEditor(text: Binding(get: { AIContext.sanitize(review.files[fileIndex].hunks[index].text) }, set: { review.files[fileIndex].hunks[index].edited = $0 })).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).frame(height: 90).padding(8).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8)).disabled(!review.files[fileIndex].hunks[index].selected || AIContext.sanitize(review.files[fileIndex].hunks[index].text) != review.files[fileIndex].hunks[index].text)
                                if AIContext.sanitize(review.files[fileIndex].hunks[index].text) != review.files[fileIndex].hunks[index].text { Text(store.text("Sensitive content is masked; manual editing is disabled for this change.", "敏感内容已遮盖，此差异暂不可手改。")).font(.caption).foregroundStyle(Palette.muted) }
                                TextField(store.text("Comment on these lines", "这些行的审查意见"), text: $review.files[fileIndex].hunks[index].comment).appInput()
                            }.padding(10).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(.bottom, 10)
                }
            }
            TextField(store.text("Revision request", "统一修订要求"), text: $review.request).appInput()
            Text(store.text("Unselected changes are skipped. Comments return to AI without applying files. Backups and goal checks remain required.", "未选差异不写入。意见集中返回 AI，此时不修改文件；备份与目标验收仍保留。")).font(.caption).foregroundStyle(Palette.muted)
            HStack { Button(store.text("Request revision", "要求 AI 修订")) { ai.reviseReviewedChanges(review.feedback); close() }.buttonStyle(ChromeButtonStyle()).disabled(review.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || review.feedback.utf8.count > 8000).accessibilityIdentifier("axon-diff-revise"); Spacer(); Button(store.text("Apply and verify", "应用并验证")) { ai.approveAction(); close() }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.pendingApproval == nil || !review.valid).accessibilityIdentifier("axon-ai-apply-diff") }
        }.padding(20).frame(width: 740, height: 650).background(Palette.background).foregroundStyle(Palette.text)
    }
}
