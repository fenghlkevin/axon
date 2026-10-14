import SwiftUI
import AppKit

struct AIManualIllustration: Decodable, Identifiable {
    var id: String { image }
    let image: String
    let title: String
    let caption: String
}

struct AIManualChapter: Decodable, Identifiable {
    let id: String
    let group: String
    let title: String
    let summary: String
    let entry: String
    let flow: [String]
    let steps: [String]
    let example: String
    let check: String
    let note: String
    let image: String?
    let caption: String?
    let imageTitle: String?
    let additionalImages: [AIManualIllustration]?
    var illustrations: [AIManualIllustration] {
        (image.map { [AIManualIllustration(image: $0, title: imageTitle ?? title, caption: caption ?? "")] } ?? []) + (additionalImages ?? [])
    }
    func matches(_ query: String) -> Bool {
        let content = ([group, title, summary, entry, example, check, note, caption ?? ""] + steps + flow + illustrations.flatMap { [$0.title, $0.caption] }).joined(separator: "\n")
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { content.localizedStandardContains(String($0)) }
    }
}

enum AIManualContent {
    static func resource(_ name: String) -> URL? { Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "AIManual") }
    static func load() throws -> [AIManualChapter] {
        guard let url = resource("manual.json") else { throw AppFailure.message("Manual resource missing / 手册资源缺失") }
        return try JSONDecoder().decode([AIManualChapter].self, from: Data(contentsOf: url))
    }
}

/// A separate reading window keeps terminal connections and task ownership intact.
@MainActor final class AIManualWindowController {
    static let shared = AIManualWindowController()
    private(set) var window: NSWindow?
    func show(store: AppStore) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = store.text("AI assistant manual", "AI 助手使用手册")
        window.minSize = NSSize(width: 720, height: 560)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AIManualView().environmentObject(store))
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct AIManualView: View {
    @EnvironmentObject var store: AppStore
    @State private var chapters: [AIManualChapter] = []
    @State private var error = ""
    @State private var query = ""
    @State private var selection = "start"
    @State private var zoom: AIManualIllustration?
    @State private var copied = ""
    @FocusState private var searching: Bool
    var initialChapter = "start"
    private var groups: [String] { chapters.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } }
    private var results: [AIManualChapter] { chapters.filter { $0.matches(query) } }
    private var current: AIManualChapter? { results.first { $0.id == selection } ?? results.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(store.text("AI assistant manual", "AI 助手使用手册"), systemImage: "book.closed").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(store.text("Offline · 24 chapters · Chinese edition", "离线手册 · 24 章 · 基础到高级")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(18).background(Palette.card)
            Divider()
            HStack(spacing: 0) {
                ScrollViewReader { directory in
                VStack(alignment: .leading, spacing: 12) {
                    Label(store.text("Contents", "目录"), systemImage: "list.bullet").font(.system(size: 16, weight: .semibold)).accessibilityIdentifier("axon-manual-contents")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            Button {
                                query = ""
                                if let chapter = chapters.first(where: { $0.group == group }) { selection = chapter.id; copied = ""; directory.scrollTo(chapter.id, anchor: .top) }
                            } label: {
                                Text(group).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, minHeight: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(WorkspaceMenuItemStyle(selected: current?.group == group, background: Palette.card)).accessibilityIdentifier("axon-manual-group-" + String(index))
                        }
                    }
                    TextField(store.text("Search all chapters", "搜索全部章节、步骤、示例"), text: $query).appInput().focused($searching).accessibilityIdentifier("axon-manual-search")
                    HStack {
                        Text(store.text("\(results.count) chapters", "\(results.count) 个章节")).font(.caption).foregroundStyle(Palette.muted)
                        Spacer()
                        if !query.isEmpty { Button(store.text("Clear", "清除")) { query = "" }.buttonStyle(.plain).foregroundStyle(Palette.accent).accessibilityIdentifier("axon-manual-clear") }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, chapter in
                                if index == 0 || results[index - 1].group != chapter.group {
                                    Text(chapter.group).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).padding(.top, 10)
                                }
                                Button { selection = chapter.id; copied = "" } label: {
                                    Text(chapter.title).font(.system(size: 12, weight: current?.id == chapter.id ? .semibold : .regular)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(10).clipShape(RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(WorkspaceMenuItemStyle(selected: current?.id == chapter.id)).accessibilityIdentifier("axon-manual-chapter-" + chapter.id).accessibilityAddTraits(current?.id == chapter.id ? .isSelected : []).id(chapter.id)
                            }
                        }
                    }
                }.padding(16).frame(width: 260).background(Palette.sidebar)
                .onChange(of: selection) { _, value in directory.scrollTo(value, anchor: .top) }
                }
                Divider()
                if let chapter = current {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(chapter.title).font(.system(size: 25, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(chapter.summary).font(.system(size: 15)).foregroundStyle(Palette.muted)
                            Label(chapter.entry, systemImage: "location").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            diagram(chapter)
                            heading(store.text("Illustrated instructions", "看图操作"), "photo.on.rectangle")
                            Text(store.text("\(chapter.illustrations.count) figures · follow the numbered instructions · click to enlarge", "本章 \(chapter.illustrations.count) 张操作图 · 按编号操作 · 点击可放大")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            ForEach(Array(chapter.illustrations.enumerated()), id: \.element.id) { index, illustration in
                                if let url = AIManualContent.resource(illustration.image), let picture = NSImage(contentsOf: url) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(store.text("Figure \(index + 1) · ", "图 \(index + 1) · ") + illustration.title).font(.system(size: 14, weight: .semibold))
                                        Button { zoom = illustration } label: {
                                            Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: .infinity).padding(8).background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain).accessibilityLabel(store.text("Enlarge: ", "放大：") + illustration.title).accessibilityIdentifier("axon-manual-image-" + chapter.id + (index == 0 ? "" : "-" + String(index)))
                                        Text(illustration.caption + store.text(" Click to enlarge.", " 点击图片可放大。")).font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            heading(store.text("How to use", "操作步骤"), "list.number")
                            ForEach(Array(chapter.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(String(index + 1)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 26, height: 26).background(Palette.selected).clipShape(Circle())
                                    Text(step).font(.system(size: 14)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    heading(store.text("Try this prompt", "可复制的提问示例"), "text.bubble")
                                    Spacer()
                                    Button(copied == chapter.id ? store.text("Copied", "已复制") : store.text("Copy", "复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chapter.example, forType: .string); copied = chapter.id }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-manual-copy")
                                }
                                Text(chapter.example).font(.system(size: 13, design: .monospaced)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                                Text(store.text("Copying does not send or execute the prompt.", "复制只写入剪贴板，不会发送或执行。")).font(.caption).foregroundStyle(Palette.muted)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10))
                            heading(store.text("Check the result", "结果检查"), "checkmark.circle")
                            Text(chapter.check).font(.system(size: 14)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            heading(store.text("Notes and boundaries", "注意与边界"), "info.circle")
                            Text(chapter.note).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            Divider()
                            HStack {
                                if let index = chapters.firstIndex(where: { $0.id == chapter.id }), index > 0 {
                                    Button(store.text("Previous", "上一章")) { query = ""; selection = chapters[index - 1].id }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-manual-previous")
                                }
                                Spacer()
                                if let index = chapters.firstIndex(where: { $0.id == chapter.id }), index + 1 < chapters.count {
                                    Button(store.text("Next", "下一章")) { query = ""; selection = chapters[index + 1].id }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-manual-next")
                                }
                            }
                        }.textSelection(.enabled).padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
                    }.id(chapter.id)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: error.isEmpty ? "magnifyingglass" : "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Palette.muted)
                        Text(error.isEmpty ? store.text("No matching chapters. Try another keyword.", "没有匹配章节，请更换关键词。") : error).multilineTextAlignment(.center)
                        Button(store.text("Show all chapters", "查看全部章节")) { query = ""; load() }.buttonStyle(ChromeButtonStyle())
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .contain).accessibilityIdentifier("axon-manual-empty")
                }
            }
        }.foregroundStyle(Palette.text).background(Palette.background).preferredColorScheme(.light)
        .onAppear { selection = initialChapter; load() }
        .background(Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden())
        .sheet(item: $zoom) { illustration in
            VStack(spacing: 12) {
                HStack { Text(illustration.title).font(.headline); Spacer(); Button(store.text("Done", "完成")) { zoom = nil }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction).accessibilityIdentifier("axon-manual-image-close") }
                ScrollView([.horizontal, .vertical]) {
                    if let url = AIManualContent.resource(illustration.image), let picture = NSImage(contentsOf: url) {
                        Image(nsImage: picture).resizable().scaledToFit().frame(width: min(1100, picture.size.width)).accessibilityLabel(illustration.title).accessibilityIdentifier("axon-manual-zoom-image-" + illustration.image)
                    }
                }
                Text(illustration.caption).font(.caption).foregroundStyle(Palette.muted)
            }.padding(20).frame(width: min(960, (NSScreen.main?.visibleFrame.width ?? 1100) - 80), height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 80)).background(Palette.background)
        }
    }
    private func load() { do { chapters = try AIManualContent.load(); error = "" } catch { self.error = error.localizedDescription } }
    private func heading(_ title: String, _ symbol: String) -> some View { Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold)) }
    private func diagram(_ chapter: AIManualChapter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(store.text("Workflow illustration", "操作流程图"), "point.3.connected.trianglepath.dotted")
            // Adaptive diagram remains readable in the narrow manual window.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
                ForEach(Array(chapter.flow.enumerated()), id: \.offset) { index, label in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Image(systemName: ["scope", "slider.horizontal.3", "hand.raised", "checkmark.shield"][index % 4]).font(.system(size: 24)); Spacer(); Text(String(index + 1)).font(.system(size: 12, weight: .bold)).padding(6).background(Palette.selected).clipShape(Circle()) }.foregroundStyle(Palette.accent)
                        Text(label).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Label(index == chapter.flow.count - 1 ? store.text("Check", "核对结果") : store.text("Then continue", "然后继续"), systemImage: index == chapter.flow.count - 1 ? "checkmark" : "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.padding(14).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
                }
            }
        }.padding(16).background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(chapter.flow.joined(separator: " → "))
    }
}
