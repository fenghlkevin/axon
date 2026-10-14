import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AIKnowledgeSheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var ai: AIAssistant
    @ObservedObject var library: AIKnowledgeLibrary
    let endpoint: String
    let directory: String?
    let executor: AICommandExecutor?
    var initialKind = "all"
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var kind = "all"
    @State private var editing: AIKnowledgeEntry?
    @State private var chosen: AIKnowledgeEntry?
    @State private var input = ""
    @State private var message = ""
    private var visible: [AIKnowledgeEntry] { library.entries.filter { (kind == "all" || $0.kind.rawValue == kind) && (search.isEmpty || ($0.title + $0.body).localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Reusable knowledge & skills", "可复用知识与技能")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }
            HStack {
                TextField(store.text("Search", "搜索"), text: $search).appInput()
                AxonChoiceField(selection: $kind, choices: [("all", store.text("All types", "全部类型"))] + AIKnowledgeEntry.Kind.allCases.map { ($0.rawValue, title($0)) }, placeholder: store.text("Type", "类型"), symbol: "books.vertical", identifier: "axon-ai-library-kind").frame(width: 160)
            }
            HStack {
                Button(store.text("New", "新建")) { editing = AIKnowledgeEntry(title: "", body: "", kind: AIKnowledgeEntry.Kind(rawValue: kind) ?? .prompt) }.buttonStyle(ChromeButtonStyle(prominent: true)).accessibilityIdentifier("axon-ai-library-new")
                Button(store.text("Import", "导入")) { importFile() }.buttonStyle(ChromeButtonStyle())
                Button(store.text("Export", "导出")) { exportFile() }.buttonStyle(ChromeButtonStyle()).disabled(library.entries.isEmpty)
                Spacer()
                if let executor { Button(store.text("Discover skills", "发现技能")) { Task { await ai.discoverSkills(executor: executor) } }.buttonStyle(ChromeButtonStyle()).disabled(ai.busy || ai.settings.skillsEnabled == false) }
            }
            Toggle(store.text("Use reviewed memory in future tasks", "后续任务使用已确认记忆"), isOn: Binding(get: { ai.settings.persistentMemoryEnabled == true }, set: { value in var settings = ai.settings; settings.persistentMemoryEnabled = value; do { try ai.save(settings, key: "") } catch { message = error.localizedDescription } })).toggleStyle(.switch).controlSize(.small).font(.system(size: 12)).disabled(ai.busy)
            if !message.isEmpty || !library.error.isEmpty { Text(message.isEmpty ? library.error : message).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if visible.isEmpty { Text(store.text("Save prompts, workflows, facts or skills here.", "在这里保存提示、工作流、知识或技能。")).foregroundStyle(Palette.muted).font(.caption) }
                    ForEach(visible) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Label(entry.title, systemImage: entry.kind == .memory ? "brain" : "doc.text").font(.system(size: 12, weight: .medium)); Spacer(); Text(title(entry.kind)).font(.caption).foregroundStyle(Palette.muted) }
                            Text(entry.body).font(.system(size: 11)).lineLimit(3).foregroundStyle(Palette.muted)
                            Text(entry.endpoint.isEmpty ? store.text("Global", "全局") : entry.endpoint + (entry.project.isEmpty ? "" : " · " + entry.project)).font(.system(size: 10)).lineLimit(2).foregroundStyle(Palette.muted)
                            HStack {
                                Button(store.text("Use", "使用")) { chosen = entry; input = "" }.buttonStyle(ChromeButtonStyle()).disabled(ai.busy || !entry.matches(endpoint: endpoint, directory: directory)).accessibilityIdentifier("axon-ai-library-use-" + entry.id.uuidString)
                                Button(store.text("Edit", "编辑")) { editing = entry }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-ai-library-edit-" + entry.id.uuidString)
                                Spacer()
                                Button { _ = library.remove(entry.id) } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle()).help(store.text("Delete", "删除"))
                            }
                        }.padding(10).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if kind == "all" || kind == "skill" {
                        ForEach(ai.availableSkills) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) { Text("/" + item.name).font(.system(size: 12, weight: .medium)); Text(item.description).font(.caption).foregroundStyle(Palette.muted); Text(item.path).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                                Spacer()
                                Button(store.text("Use", "使用")) { ai.question = "Use skill " + item.name + " from " + item.path + ". Read its fresh SKILL.md before following it. " + input; dismiss() }.buttonStyle(ChromeButtonStyle()).disabled(ai.busy || ai.settings.skillsEnabled == false)
                            }.padding(10).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Text(store.text("Local records. Sharing exports a file you choose. {{input}} inserts literal parameters. Knowledge and memory may be stale and never approve actions.", "记录保存在本机，通过导出文件共享。{{input}} 仅替换参数文本；知识和记忆可能过期，不批准任何操作。")).font(.caption).foregroundStyle(Palette.muted)
        }.padding(20).frame(width: 620, height: 620).foregroundStyle(Palette.text).background(Palette.background)
        .onAppear { kind = initialKind }
        .sheet(item: $editing) { entry in AIKnowledgeEditor(library: library, initial: entry, endpoint: endpoint, directory: directory).environmentObject(store) }
        .sheet(item: $chosen) { entry in
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(entry.title).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { chosen = nil } }
                TextField(store.text("Parameters for {{input}}", "{{input}} 的参数"), text: $input).appInput()
                ScrollView { Text((try? entry.expanded(input: input)) ?? "").font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button(store.text("Insert into draft", "填入草稿")) { if ai.applyReusable(entry, input: input, endpoint: endpoint, directory: directory) { chosen = nil; dismiss() } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.busy || (try? entry.expanded(input: input)) == nil).accessibilityIdentifier("axon-ai-library-insert") }
            }.padding(20).frame(width: 500, height: 400).background(Palette.background).foregroundStyle(Palette.text)
        }
    }
    private func title(_ kind: AIKnowledgeEntry.Kind) -> String { store.text(kind.rawValue.capitalized, ["prompt":"提示", "workflow":"工作流", "knowledge":"知识", "memory":"记忆", "skill":"技能"][kind.rawValue] ?? kind.rawValue) }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .plainText]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; guard size <= 2 * 1024 * 1024 else { throw AIModelError.invalidReply }
                let data = try Data(contentsOf: url)
                if url.pathExtension.lowercased() == "md" {
                    let body = String(decoding: data, as: UTF8.self); let metadata = try AISkills.metadata(body, path: url.path)
                    _ = library.save(.init(title: metadata.name, body: body, kind: .skill))
                } else { _ = library.importData(data) }
            } catch { message = error.localizedDescription }
        }
    }
    private func exportFile() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "axon-knowledge.json"
        if panel.runModal() == .OK, let url = panel.url { do { try library.exportData().write(to: url, options: .atomic) } catch { message = error.localizedDescription } }
    }
}

struct AIKnowledgeEditor: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var library: AIKnowledgeLibrary
    let initial: AIKnowledgeEntry
    let endpoint: String
    let directory: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIKnowledgeEntry
    @State private var scope = "global"
    private var originalScope: String { initial.endpoint.isEmpty ? "global" : initial.project.isEmpty ? "target" : "project" }
    private var selectedEndpoint: String { scope == originalScope ? initial.endpoint : scope == "global" ? "" : endpoint }
    private var selectedProject: String { scope == originalScope ? initial.project : scope == "project" ? directory ?? "" : "" }
    init(library: AIKnowledgeLibrary, initial: AIKnowledgeEntry, endpoint: String, directory: String?) { self.library = library; self.initial = initial; self.endpoint = endpoint; self.directory = directory; _draft = State(initialValue: initial); _scope = State(initialValue: initial.endpoint.isEmpty ? "global" : initial.project.isEmpty ? "target" : "project") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Edit reusable entry", "编辑可复用记录")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }
            Text(store.text("Title *", "标题 *")).font(.caption); TextField(store.text("Title", "标题"), text: $draft.title).appInput().accessibilityIdentifier("axon-ai-library-title")
            HStack {
                AxonChoiceField(selection: Binding(get: { draft.kind.rawValue }, set: { draft.kind = AIKnowledgeEntry.Kind(rawValue: $0) ?? .prompt }), choices: AIKnowledgeEntry.Kind.allCases.map { ($0.rawValue, store.text($0.rawValue.capitalized, ["prompt":"提示", "workflow":"工作流", "knowledge":"知识", "memory":"记忆", "skill":"技能"][$0.rawValue]!)) }, placeholder: store.text("Type", "类型"), symbol: "doc.text", identifier: "axon-ai-library-editor-kind")
                AxonChoiceField(selection: $scope, choices: [("global", store.text("Global", "全局")), ("target", store.text("Target", "目标")), ("project", store.text("Project directory", "项目目录"))], placeholder: store.text("Scope", "范围"), symbol: "scope", identifier: "axon-ai-library-scope")
            }
            if !selectedEndpoint.isEmpty { Text(selectedEndpoint + (selectedProject.isEmpty ? "" : " · " + selectedProject)).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled) }
            Text(store.text("Text * · skill entries need YAML name/description", "正文 * · 技能需要 YAML name/description")).font(.caption)
            TextEditor(text: $draft.body).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("axon-ai-library-body")
            Toggle(store.text("Enabled", "启用"), isOn: $draft.enabled).toggleStyle(.switch).controlSize(.small)
            if !library.error.isEmpty { Text(library.error).font(.caption).foregroundStyle(Palette.muted) }
            HStack { Spacer(); Button(store.text("Save", "保存")) { draft.endpoint = selectedEndpoint; draft.project = selectedProject; if library.save(draft) { dismiss() } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(draft.title.isEmpty || draft.body.isEmpty || (scope == "project" && selectedProject.isEmpty)).accessibilityIdentifier("axon-ai-library-save") }
        }.padding(20).frame(width: 580, height: 520).foregroundStyle(Palette.text).background(Palette.background)
    }
}
