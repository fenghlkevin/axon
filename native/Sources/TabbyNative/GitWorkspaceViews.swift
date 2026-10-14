import SwiftUI
import AppKit

struct GitWorkspaceSheet: View {
    @EnvironmentObject var store: AppStore
    @StateObject var workspace: GitWorkspace
    let openDirectory: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var view = "changes"
    @State private var selectedBranch = ""
    @State private var newBranch = "codex/"
    @State private var newPath = ""
    @State private var project: ProjectTarget?
    @State private var selectedPath = ""
    @State private var selectedLine = 1
    @State private var comment = ""
    @State private var comments: [String] = []
    struct ProjectTarget: Identifiable { var id: String { path }; let path: String }
    init(directory: String, registry: URL, workspace: GitWorkspace? = nil, openDirectory: @escaping (String) -> Void) { _workspace = StateObject(wrappedValue: workspace ?? GitWorkspace(directory: directory, registry: registry)); self.openDirectory = openDirectory }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(store.text("Local development tools", "本地开发工具"), systemImage: "chevron.left.forwardslash.chevron.right").font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }
            Text(workspace.root.isEmpty ? workspace.directory : workspace.root).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
            HStack {
                AxonChoiceField(selection: $view, choices: [("changes", store.text("Git changes", "Git 修改")), ("worktrees", store.text("Worktrees", "工作树"))], placeholder: store.text("View", "视图"), symbol: "arrow.triangle.branch", identifier: "axon-git-view").frame(width: 220)
                AxonChoiceField(selection: $selectedBranch, choices: workspace.branches.map { ($0, $0) }, placeholder: workspace.branch, symbol: "arrow.triangle.branch", identifier: "axon-git-branch").frame(width: 220)
                Button(store.text("Switch", "切换")) { workspace.perform { try await workspace.switchBranch(selectedBranch) } }.buttonStyle(ChromeButtonStyle()).disabled(workspace.busy || !workspace.changes.isEmpty || selectedBranch == workspace.branch || !workspace.branches.contains(selectedBranch))
                Spacer(); Button { workspace.perform { try await workspace.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(IconButtonStyle()).disabled(workspace.busy).accessibilityIdentifier("axon-git-refresh")
            }
            if workspace.busy { ProgressView().controlSize(.small) }
            if !workspace.error.isEmpty { Text(workspace.error).font(.caption).foregroundStyle(Palette.danger).textSelection(.enabled) }
            if view == "changes" {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if workspace.changes.isEmpty { Text(store.text("Working tree is clean", "工作树没有修改")).font(.caption).foregroundStyle(Palette.muted) }
                            ForEach(workspace.changes) { change in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(change.status + "  " + change.path).font(.system(size: 11, design: .monospaced)).lineLimit(3)
                                    HStack { Button(store.text("Diff", "差异")) { selectedPath = change.path; workspace.perform { try await workspace.showDiff(change, staged: false) } }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-git-diff"); Button(store.text("Index", "暂存差异")) { selectedPath = change.path; workspace.perform { try await workspace.showDiff(change, staged: true) } }.buttonStyle(ChromeButtonStyle()) }
                                    HStack { Button(store.text("Stage", "暂存")) { workspace.perform { try await workspace.stage(change) } }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-git-stage"); Button(store.text("Unstage", "取消暂存")) { workspace.perform { try await workspace.stage(change, undo: true) } }.buttonStyle(ChromeButtonStyle()).disabled(change.status.first == " " || change.status == "??").accessibilityIdentifier("axon-git-unstage") }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.frame(width: 280).disabled(workspace.busy)
                    VStack(alignment: .leading, spacing: 8) {
                        diffView
                        HStack { Text(store.text("Diff line", "差异行号")).font(.caption); TextField("1", value: $selectedLine, format: .number).appInput().frame(width: 65); TextField(store.text("Review comment", "审查意见"), text: $comment).appInput().accessibilityIdentifier("axon-git-comment"); Button(store.text("Add", "添加")) { comments.append(selectedPath + " · " + GitDiffReview.reference(workspace.diff, line: selectedLine) + "\n" + comment); comment = "" }.buttonStyle(ChromeButtonStyle()).disabled(selectedPath.isEmpty || selectedLine < 1 || selectedLine > min(2000, workspace.diff.components(separatedBy: "\n").count) || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || comment.utf8.count > 2000 || comments.count >= 20 || workspace.busy).accessibilityIdentifier("axon-git-add-comment") }
                        if !comments.isEmpty { ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(comments.indices, id: \.self) { index in HStack(alignment: .top) { Text(comments[index]).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Button { comments.remove(at: index) } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(store.text("Remove comment", "删除意见")) } } } }.frame(maxHeight: 110) }
                    }
                }
            } else {
                HStack { TextField(store.text("New branch", "新分支"), text: $newBranch).appInput(); TextField(store.text("Absolute checkout directory", "工作树绝对目录"), text: $newPath).appInput(); Button(store.text("Create", "创建")) { workspace.perform { try await workspace.createWorktree(path: newPath, branch: newBranch) } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(workspace.busy || newPath.isEmpty || newBranch == "codex/").accessibilityIdentifier("axon-git-create-worktree") }
                ScrollView { VStack(spacing: 8) { ForEach(workspace.worktrees) { worktree in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(worktree.branch).font(.system(size: 12, weight: .semibold)); Text(worktree.path).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
                        HStack { Button(store.text("Open folder", "打开目录")) { openDirectory(worktree.path); dismiss() }.buttonStyle(ChromeButtonStyle()); Button(store.text("Independent task", "独立项目任务")) { project = .init(path: worktree.path) }.buttonStyle(ChromeButtonStyle()); Spacer(); Button(store.text("Remove clean checkout", "移除干净工作树")) { workspace.perform { try await workspace.removeWorktree(worktree) } }.buttonStyle(ChromeButtonStyle()).disabled(!workspace.owns(worktree) || workspace.busy) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                } } }
            }
            Text(store.text("Local repositories only. Switching requires a clean checkout. Removing is limited to Axon-created clean worktrees without ignored files; branches remain. Independent tasks use separate directories and history, with existing AI permissions.", "仅支持本机仓库。切换分支需无修改；仅移除 Axon 创建且无修改、无忽略文件的工作树，保留分支。独立任务使用各自目录和历史，遵循既有 AI 权限。")).font(.caption).foregroundStyle(Palette.muted)
            HStack { Spacer(); Button(store.text("Review with AI", "交给 AI 审查")) { project = .init(path: workspace.root) }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(workspace.root.isEmpty || workspace.busy || comments.joined(separator: "\n").utf8.count > 8000).accessibilityIdentifier("axon-git-agent") }
        }.padding(20).frame(width: 960, height: 680).foregroundStyle(Palette.text).background(Palette.background)
        .task { workspace.perform { try await workspace.refresh() } }.onChange(of: workspace.branch) { _, branch in selectedBranch = branch }
        .sheet(item: $project) { target in LocalProjectAgentSheet(directory: target.path, settingsURL: store.ai.fileURL, feedback: comments.joined(separator: "\n")).environmentObject(store) }
    }
    private var diffView: some View {
        ScrollView {
            if workspace.diff.isEmpty { Text(store.text("Select a file to review", "选择文件查看差异")).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
            else { LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(workspace.diff.components(separatedBy: "\n").prefix(2000).enumerated()), id: \.offset) { offset, line in
                    HStack(alignment: .top, spacing: 8) {
                        Button { selectedLine = offset + 1 } label: { Text(String(offset + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 32) }.buttonStyle(AxonSurfaceButtonStyle()).help(store.text("Comment on this diff line", "评论此差异行")).accessibilityIdentifier("axon-git-line-\(offset + 1)")
                        Text(line.isEmpty ? " " : line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(3).background(selectedLine == offset + 1 ? Palette.selected : Color.clear).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if workspace.diff.components(separatedBy: "\n").count > 2000 { Text(store.text("Preview limited to 2,000 lines", "预览最多显示 2,000 行")).font(.caption).foregroundStyle(Palette.muted) }
            } }
        }.padding(12).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

enum GitDiffReview {
    static func reference(_ diff: String, line: Int) -> String {
        let rows = diff.components(separatedBy: "\n"); guard line > 0, line <= rows.count, line <= 2000 else { return "invalid diff line" }
        var old: Int?, new: Int?, location = ""
        for (index, row) in rows.prefix(line).enumerated() {
            if row.hasPrefix("@@ ") {
                let fields = row.split(separator: " "); if fields.count >= 3 { old = fields[1].dropFirst().split(separator: ",").first.flatMap { Int($0) }; new = fields[2].dropFirst().split(separator: ",").first.flatMap { Int($0) } }
            } else if old != nil, new != nil {
                if index == line - 1 { location = row.hasPrefix("-") ? " · original line \(old!)" : " · proposed line \(new!)" }
                if row.hasPrefix("-") { old! += 1 } else if row.hasPrefix("+") { new! += 1 } else if row.hasPrefix(" ") { old! += 1; new! += 1 }
            }
        }
        return "diff line \(line)" + location + " · reviewed text: " + String(rows[line - 1].prefix(500))
    }
}

struct LocalProjectAgentSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject var ai: AIAssistant
    let directory: String
    let feedback: String
    let executor: AICommandExecutor
    init(directory: String, settingsURL: URL, feedback: String = "") {
        self.directory = directory; self.feedback = feedback
        let journal = settingsURL.deletingLastPathComponent().appendingPathComponent("project-tasks/" + AIFileCheckpoint.digest(Data(directory.utf8)) + ".json")
        let assistant = LocalProjectAgentSessions.session(settingsURL: settingsURL, journal: journal); _ai = StateObject(wrappedValue: assistant)
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory)
        let inode = attributes?[.systemFileNumber] as? NSNumber, device = attributes?[.systemNumber] as? NSNumber
        executor = AICommandExecutor(sessionID: assistant.id, source: "Local project: " + directory, directory: directory, valid: {
            guard let now = try? FileManager.default.attributesOfItem(atPath: directory) else { return false }; return inode != nil && now[.systemFileNumber] as? NSNumber == inode && now[.systemNumber] as? NSNumber == device
        }, execute: { [weak assistant] command, update in guard let assistant else { throw CancellationError() }; return try await AICommandExecutor.local(command: command, directory: directory, timeout: assistant.settings.policy.commandSeconds, update: update) })
        executor.fileBackend = { LocalFiles() }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(directory).font(.caption).textSelection(.enabled); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() }.accessibilityIdentifier("axon-project-close") }.padding(12)
            AIAssistantPane(ai: ai, terminal: false, executionOverride: executor, availableHeight: 700).environmentObject(store)
        }.frame(width: 740, height: 740).background(Palette.background)
        .onReceive(store.ai.$settings) { settings in ai.settings = settings }
        .onAppear { if !ai.busy { ai.prepare(source: executor.source, text: "Project directory: " + directory, sessionID: executor.sessionID, question: feedback.isEmpty ? "" : "Review these human comments; inspect the actual files before making changes.\n" + feedback) } }.onDisappear { ai.cancel() }
    }
}

@MainActor enum LocalProjectAgentSessions {
    private final class WeakSession { weak var value: AIAssistant?; init(_ value: AIAssistant) { self.value = value } }
    private static var sessions: [String: WeakSession] = [:]
    static func session(settingsURL: URL, journal: URL) -> AIAssistant {
        sessions = sessions.filter { $0.value.value != nil }
        if let existing = sessions[journal.path]?.value { return existing }
        let value = AIAssistant(fileURL: settingsURL, sessionJournalURL: journal); sessions[journal.path] = WeakSession(value); return value
    }
}
