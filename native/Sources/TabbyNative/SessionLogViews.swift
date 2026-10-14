import SwiftUI
import AppKit

struct SessionLogControls: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.store.text("Session transcript", "会话输出日志")).font(.system(size: 14, weight: .semibold))
            HStack {
                Label(session.transcriptID == nil ? session.store.text("Not recording", "未记录") : session.store.text("Recording output", "正在记录输出"), systemImage: session.transcriptID == nil ? "record.circle" : "record.circle.fill").font(.system(size: 11)).foregroundStyle(session.transcriptID == nil ? TerminalChrome.muted : TerminalChrome.accent)
                Spacer()
                Button(session.transcriptID == nil ? session.store.text("Start", "开始") : session.store.text("Stop", "停止")) { if session.transcriptID == nil { session.startTranscript() } else { session.stopTranscript() } }.buttonStyle(ChromeButtonStyle()).disabled(!session.connected && session.transcriptID == nil)
            }
            Text(session.store.text("Opt-in text output only; echoed secrets may be included. Up to 20 MiB per log, 25 completed logs. Full-screen cursor motion is not replayed.", "手动开启，仅记录文本输出，可能包含回显的秘密。每份最多 20 MiB，保留 25 份已完成日志；不回放全屏光标动作。"))
                .font(.system(size: 10)).foregroundStyle(TerminalChrome.muted).fixedSize(horizontal: false, vertical: true)
            Button(session.store.text("Browse saved logs", "查看已保存日志")) {
                session.store.sessionLogs.selectedID = session.transcriptID ?? session.store.sessionLogs.records.first { $0.sessionID == session.id }?.id
                session.store.section = "logs"
            }.buttonStyle(ChromeButtonStyle())
        }
    }
}
struct SessionLogsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var logs: SessionLogStore
    @State private var query = ""
    @State private var contentQuery = ""
    @State private var markerID: UUID?
    @State private var data = Data()
    @State private var page = 0
    @State private var text = ""
    @State private var focusRange: NSRange?
    @State private var deleting: SessionLogRecord?
    @State private var error = ""
    private let pageBytes = 256 * 1024
    private var records: [SessionLogRecord] { logs.records.filter { query.isEmpty || ($0.title + $0.endpoint).localizedCaseInsensitiveContains(query) } }
    private var record: SessionLogRecord? { records.first { $0.id == logs.selectedID } ?? records.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeading(title: store.text("Session transcripts", "会话输出日志"), subtitle: store.text("Search saved output and jump to a recorded command", "搜索已保存输出，区分 AI / 人工并定位命令"))
            HStack(spacing: 12) {
                VaultSearchField(placeholder: store.text("Search host or session", "搜索主机或会话"), text: $query).frame(maxWidth: 320)
                AxonChoiceField(selection: Binding(get: { record?.id }, set: { logs.selectedID = $0; logs.selectedMarker = nil }), choices: records.map { (Optional($0.id), $0.title + " · " + $0.started.formatted(date: .numeric, time: .shortened)) }, placeholder: store.text("Choose transcript", "选择日志"), symbol: "doc.text", identifier: "axon-transcript-selector").frame(maxWidth: 440)
            }
            if let record {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) { Text(record.title).font(.system(size: 14, weight: .semibold)); Text(record.endpoint).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                        Spacer()
                        Label(logs.isRecording(record.id) ? store.text("Recording", "记录中") : store.text("Saved", "已保存"), systemImage: logs.isRecording(record.id) ? "record.circle" : "checkmark.circle").foregroundStyle(Palette.accent)
                        Button(store.text("Refresh", "刷新")) { reload() }.buttonStyle(ChromeButtonStyle())
                        Button(store.text("AI analysis", "AI 分析")) {
                            store.prepareAI(source: record.title + " · page " + String(page + 1), text: AIContext.numbered(text), sessionID: nil, question: store.text("Analyze anomalies on this transcript page; cite supplied line numbers.", "分析当前日志页的异常，引用提供的行号。")); store.aiAnalysisPresented = true
                        }.buttonStyle(ChromeButtonStyle()).disabled(text.isEmpty)
                        Button(store.text("Export", "导出")) { export(record) }.buttonStyle(ChromeButtonStyle())
                        Button { deleting = record } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle()).disabled(logs.isRecording(record.id)).help(store.text("Delete transcript", "删除日志"))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { markerField(record).frame(width: 330); outputSearch.frame(width: 280); findButton; Spacer() }
                        VStack(alignment: .leading, spacing: 10) { markerField(record); HStack { outputSearch; findButton } }
                    }
                    if record.limited { Label(store.text("Recording stopped at the 20 MiB limit", "达到 20 MiB 上限，已停止记录"), systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger) }
                    TranscriptTextSurface(text: text, selection: focusRange, foreground: NSColor(hex: store.workspace.preferences.foreground), background: NSColor(hex: store.workspace.preferences.background), analyze: { selected in store.prepareAI(source: record.title + " · selection", text: AIContext.numbered(selected), sessionID: nil, question: store.text("Explain this selected output and suggest checks.", "解释所选输出并给出检查建议。")); store.aiAnalysisPresented = true })
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8)).frame(minHeight: 260)
                    HStack(spacing: 12) {
                        Text(store.text("Text transcript · \(data.count.formatted()) bytes", "文本日志 · \(data.count.formatted()) 字节")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button(store.text("Previous", "上一段")) { page -= 1; renderPage() }.buttonStyle(ChromeButtonStyle()).disabled(page == 0)
                        Text("\(page + 1) / \(max(1, (data.count + pageBytes - 1) / pageBytes))").monospacedDigit().foregroundStyle(Palette.muted)
                        Button(store.text("Next", "下一段")) { page += 1; renderPage() }.buttonStyle(ChromeButtonStyle()).disabled((page + 1) * pageBytes >= data.count)
                    }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
            } else { ContentUnavailableView(store.text("No session transcripts", "暂无会话输出日志"), systemImage: "doc.text", description: Text(store.text("Open Terminal tools → Session tools to start recording output.", "在终端工具 → 会话工具中，手动开启输出记录。"))).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if !error.isEmpty || logs.error != nil { Label(error.isEmpty ? logs.error ?? "" : error, systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger).textSelection(.enabled) }
        }.padding(22).foregroundStyle(Palette.text).font(.system(size: 12)).background(Palette.background)
            .onChange(of: record?.id, initial: true) { _, _ in page = 0; reload() }
            .onChange(of: logs.selectedMarker) { _, _ in reload() }
            .onChange(of: logs.navigationRequest) { _, _ in query = ""; page = 0; reload() }
            .onChange(of: markerID) { _, id in logs.selectedMarker = id; locateMarker() }
            .appAlert(store.text("Delete transcript?", "删除会话日志？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                AppAlertButton(store.text("Cancel", "取消"), role: .cancel) { deleting = nil }
                AppAlertButton(store.text("Delete", "删除"), role: .destructive) { if let record = deleting { do { try logs.remove(record.id) } catch { self.error = error.localizedDescription } }; deleting = nil }
            } message: { Text((deleting?.title ?? "") + "\n" + store.text("Removes the saved output and command positions.", "删除保存的输出和命令定位信息。")) }
    }
    private var outputSearch: some View { TextField(store.text("Search full transcript", "搜索整份日志"), text: $contentQuery).appInput().onSubmit { find() } }
    private var findButton: some View { Button(store.text("Find next", "查找下一处")) { find() }.buttonStyle(ChromeButtonStyle()).disabled(contentQuery.isEmpty) }
    private func markerField(_ record: SessionLogRecord) -> some View { AxonChoiceField(selection: $markerID, choices: [(nil, store.text("Choose command position", "选择命令位置"))] + record.markers.map { (Optional($0.id), "[" + ($0.origin ?? .unknown).title(chinese: store.chinese) + "] " + String($0.command.prefix(100))) }, placeholder: store.text("Command position", "命令位置"), symbol: "terminal", identifier: "axon-transcript-command").disabled(record.markers.isEmpty) }
    private func reload() {
        guard let record else { data = Data(); text = ""; return }
        do { data = try logs.content(record.id); page = min(page, max(0, (data.count - 1) / pageBytes)); renderPage(); error = ""; locateMarker() } catch { self.error = error.localizedDescription }
    }
    private func renderPage(offset: Int? = nil, length: Int = 0) {
        var lower = min(data.count, max(0, page * pageBytes))
        while lower < data.count && data[lower] & 0xc0 == 0x80 { lower += 1 }
        var upper = min(data.count, (page + 1) * pageBytes)
        while upper < data.count && data[upper] & 0xc0 == 0x80 { upper += 1 }
        text = String(decoding: data[lower..<max(lower, upper)], as: UTF8.self)
        focusRange = nil
        if let offset, offset >= lower, offset <= upper {
            let location = String(decoding: data[lower..<offset], as: UTF8.self).utf16.count
            let end = min(upper, offset + length)
            focusRange = NSRange(location: location, length: String(decoding: data[offset..<end], as: UTF8.self).utf16.count)
        }
    }
    private func locateMarker() {
        guard let id = logs.selectedMarker, let marker = record?.markers.first(where: { $0.id == id }) else { return }
        markerID = id; page = min(marker.offset / pageBytes, max(0, (data.count - 1) / pageBytes)); renderPage(offset: min(marker.offset, data.count))
    }
    private func find() {
        guard let needle = contentQuery.data(using: .utf8), !needle.isEmpty else { return }
        // Search is byte-exact and case-sensitive; UTF-8 positions map to the displayed page.
        let start = min(data.count, page * pageBytes + (focusRange.map { range in (text as NSString).substring(to: min(range.location + range.length, (text as NSString).length)).utf8.count } ?? 0))
        let found = data.range(of: needle, in: start..<data.count) ?? data.range(of: needle, in: 0..<start)
        guard let found else { error = store.text("No matching text", "未找到匹配文本"); return }
        error = ""; page = found.lowerBound / pageBytes; renderPage(offset: found.lowerBound, length: found.count)
    }
    private func export(_ record: SessionLogRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Axon-\(record.id.uuidString.prefix(8)).txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try logs.content(record.id).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
}
struct TranscriptTextSurface: NSViewRepresentable {
    let text: String
    let selection: NSRange?
    let foreground: NSColor
    let background: NSColor
    var analyze: ((String) -> Void)? = nil
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TranscriptScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = AITranscriptTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textContainerInset = NSSize(width: 12, height: 12)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.autoresizingMask = []; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude); view.textContainer?.widthTracksTextView = false; view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view; view.setAccessibilityIdentifier("axon-transcript-output"); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        (view as? AITranscriptTextView)?.analyze = analyze
        view.textColor = foreground; view.backgroundColor = background; scroll.backgroundColor = background
        (scroll as? TranscriptScrollView)?.resizeDocument()
        if let selection, NSMaxRange(selection) <= (text as NSString).length { view.setSelectedRange(selection); view.scrollRangeToVisible(selection) }
    }
}

final class TranscriptScrollView: NSScrollView {
    override func tile() { super.tile(); resizeDocument() }
    func resizeDocument() {
        guard let view = documentView as? NSTextView, let container = view.textContainer, let layout = view.layoutManager else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = NSSize(width: max(contentSize.width, ceil(used.width + view.textContainerInset.width * 2)),
                          height: max(contentSize.height, ceil(used.height + view.textContainerInset.height * 2)))
        if view.frame.size != size { view.setFrameSize(size) }
    }
}

final class AITranscriptTextView: NSTextView {
    var analyze: ((String) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if selectedRange().length > 0, analyze != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "AI · Analyze selection / 分析所选内容", action: #selector(analyzeSelectedText), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc func analyzeSelectedText() { let range = selectedRange(); guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }; analyze?((string as NSString).substring(with: range)) }
}
