import Foundation
import AppKit
import SwiftUI

struct LogViewerLine: Identifiable, Equatable {
    let id: UInt64
    let text: String
    var isError: Bool {
        ["error", "fatal", "exception", "failed", "panic"].contains { text.localizedCaseInsensitiveContains($0) }
    }
}

@MainActor final class LogViewerModel: ObservableObject, Identifiable {
    let id = UUID()
    let pane: FilePane
    let entry: FileEntry
    let title: String
    var hostID: UUID?
    var onClose: (() -> Void)?
    var path: String { entry.path }
    @Published private(set) var lines: [LogViewerLine] = []
    @Published private(set) var pendingText = ""
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published private(set) var droppedLines = 0
    @Published private(set) var unreadBytes: UInt64 = 0
    @Published var following = true
    @Published var filter = ""
    @Published var search = ""
    @Published var onlyErrors = false
    @Published var error = ""
    static let maximumLines = 10_000
    static let maximumBufferedBytes = 2 * 1024 * 1024
    static let initialReadLimit = 1024 * 1024
    static let initialLineCount = 200
    private var nextLineID: UInt64 = 0
    private var offset: UInt64 = 0
    private var anchor = Data()
    private var pending = Data()
    private var bufferedBytes = 0
    private var initialized = false
    private var visible = false
    private var closed = false
    private var polling = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(pane: FilePane, entry: FileEntry, title: String) {
        self.pane = pane; self.entry = entry; self.title = title
        pane.readerCount += 1
    }
    var visibleLines: [LogViewerLine] {
        lines.filter { (!onlyErrors || $0.isError) && (filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter)) }
    }
    var searchMatches: [LogViewerLine] {
        search.isEmpty ? [] : visibleLines.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }
    var exportedText: String { (lines.map(\.text) + (pendingText.isEmpty ? [] : [pendingText])).joined(separator: "\n") + "\n" }

    func activate() { visible = true; resumePolling() }
    func deactivate() { visible = false; stopPolling(); status = "paused" }
    func setFollowing(_ value: Bool) {
        following = value
        if value { resumePolling() } else { stopPolling(); status = "paused" }
    }
    func close() {
        guard !closed else { return }; closed = true; visible = false; stopPolling()
        pane.readerCount -= 1
        onClose?(); onClose = nil
    }
    func jumpToLatest() {
        stopPolling(); initialized = false; pending = Data(); pendingText = ""; anchor = Data(); error = ""
        resumePolling(force: true)
    }
    private func stopPolling() { generation = UUID(); task?.cancel(); task = nil }
    private func resumePolling(force: Bool = false) {
        guard !closed, visible, task == nil, following || !initialized || force else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            repeat {
                // A cancelled SFTP request can take time to settle. A forced
                // refresh waits for it instead of silently losing Latest.
                while polling && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                }
                guard !Task.isCancelled else { break }
                await pollOnce()
                guard !Task.isCancelled, token == generation, visible, following else { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            } while !Task.isCancelled
            if token == generation { task = nil }
        }
    }

    /// Reads are independent of the interactive shell. No terminal input or
    /// remote program is needed, and all retained content has a hard bound.
    func pollOnce() async {
        guard !closed, !polling else { return }; polling = true
        loading = !initialized
        defer { polling = false; loading = false }
        do {
            guard await pane.backend.isAvailable() else { status = "disconnected"; return }
            try Task.checkCancellation()
            guard let current = try await fileIfExists(path, backend: pane.backend) else { status = "missing"; error = ""; return }
            guard !current.directory, !current.symlink else { throw AppFailure.message("Choose a regular UTF-8 text file") }
            try Task.checkCancellation()
            if !initialized {
                try await readTail(current); status = following ? "following" : "paused"; error = ""; return
            }
            var rotated = current.size < offset
            if !rotated, !anchor.isEmpty, offset >= UInt64(anchor.count) {
                let observed = try await pane.backend.read(path, offset: offset - UInt64(anchor.count), count: anchor.count)
                try Task.checkCancellation()
                rotated = observed != anchor
            }
            if rotated {
                appendLine("—— File truncated or replaced · 文件截断或替换 ——")
                pending = Data(); pendingText = ""; anchor = Data()
                try await readTail(current, replace: false); status = "rotated"; error = ""; return
            }
            let end = min(current.size, offset + UInt64(Self.initialReadLimit))
            while offset < end {
                try Task.checkCancellation()
                let requested = Int(min(256 * 1024, end - offset))
                let bytes = try await pane.backend.read(path, offset: offset, count: requested)
                try Task.checkCancellation()
                guard !bytes.isEmpty, bytes.count <= requested else { break }
                try consume(bytes); offset += UInt64(bytes.count)
                anchor.append(bytes); anchor = Data(anchor.suffix(256))
            }
            unreadBytes = current.size > offset ? current.size - offset : 0
            status = following ? "following" : "paused"; error = ""
        } catch is CancellationError {
        } catch is FileMissing { status = "missing"; error = "" }
        catch {
            guard !Task.isCancelled else { return }
            status = await pane.backend.isAvailable() ? "error" : "disconnected"; self.error = error.localizedDescription
        }
    }

    private func readTail(_ current: FileEntry, replace: Bool = true) async throws {
        let start = current.size > UInt64(Self.initialReadLimit) ? current.size - UInt64(Self.initialReadLimit) : 0
        var data = Data(), cursor = start
        while cursor < current.size {
            try Task.checkCancellation()
            let requested = Int(min(256 * 1024, current.size - cursor))
            let bytes = try await pane.backend.read(path, offset: cursor, count: requested)
            try Task.checkCancellation()
            guard !bytes.isEmpty, bytes.count <= requested else { throw AppFailure.message("File changed while reading; refresh the log") }
            data.append(bytes); cursor += UInt64(bytes.count)
        }
        guard !data.contains(0) else { throw AppFailure.message("Binary files cannot be viewed as logs") }
        let rawAnchor = Data(data.suffix(256))
        // The first line can start in the middle of a UTF-8 scalar.
        if start > 0 {
            if let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
            else { data = Self.boundedUTF8Tail(data) }
        }
        var parts = data.split(separator: 10, omittingEmptySubsequences: false)
        let last = parts.popLast().map(Data.init) ?? Data()
        parts = Array(parts.suffix(Self.initialLineCount))
        if replace { lines = []; bufferedBytes = 0; droppedLines = 0 }
        pending = Data(); pendingText = ""
        for bytes in parts {
            guard let text = String(data: Data(bytes), encoding: .utf8) else { throw AppFailure.message("The log is not UTF-8 text") }
            appendLine(text.hasSuffix("\r") ? String(text.dropLast()) : text)
        }
        pending = Self.boundedUTF8Tail(last); pendingText = String(decoding: pending, as: UTF8.self)
        offset = current.size; anchor = rawAnchor; unreadBytes = 0; initialized = true
    }

    private func consume(_ bytes: Data) throws {
        guard !bytes.contains(0) else { throw AppFailure.message("Binary files cannot be viewed as logs") }
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let data = Data(pending.prefix(upTo: newline))
            guard let value = String(data: data, encoding: .utf8) else { throw AppFailure.message("The log is not UTF-8 text") }
            appendLine(value.hasSuffix("\r") ? String(value.dropLast()) : value)
            pending.removeSubrange(...newline)
        }
        if pending.count > 64 * 1024 {
            appendLine("[Earlier bytes of a long line omitted · 过长日志行的前段已省略]")
            pending = Self.boundedUTF8Tail(pending)
        }
        pendingText = String(decoding: pending, as: UTF8.self)
    }
    private static func boundedUTF8Tail(_ data: Data) -> Data {
        guard data.count > 64 * 1024 else { return data }
        var tail = Data(data.suffix(64 * 1024))
        // Keep a possible incomplete final scalar for the next read, but never
        // retain a continuation byte at the start of a clipped line.
        while let first = tail.first, first & 0xC0 == 0x80 { tail.removeFirst() }
        return Data(tail)
    }
    private func appendLine(_ text: String) {
        let bounded = String(text.prefix(64 * 1024))
        lines.append(LogViewerLine(id: nextLineID, text: bounded)); nextLineID += 1
        bufferedBytes += bounded.utf8.count
        while lines.count > Self.maximumLines || bufferedBytes > Self.maximumBufferedBytes {
            let removed = lines.removeFirst(); bufferedBytes -= removed.text.utf8.count; droppedLines += 1
        }
    }
    func export(chinese: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name + ".txt"
        panel.title = chinese ? "导出已加载日志" : "Export loaded log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(exportedText.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
}

struct LogViewerWorkspace: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: LogViewerModel
    @State private var autoScroll = true
    @State private var matchIndex = 0
    @State private var newLines = 0
    @State private var wrapLines = false
    @State private var latestRequest = UUID()
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(model.title, systemImage: "doc.text.magnifyingglass").font(.headline)
                    Text(statusTitle).font(.caption).foregroundStyle(Palette.muted)
                    if model.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle(store.text("Follow", "跟随"), isOn: Binding(get: { model.following }, set: { model.setFollowing($0) })).toggleStyle(.switch)
                    Button(store.text("Latest", "最新")) { autoScroll = true; newLines = 0; latestRequest = UUID(); model.jumpToLatest() }.buttonStyle(ChromeButtonStyle())
                    Button(store.text("AI analysis", "AI 分析")) {
                        let lines = model.visibleLines.suffix(200).map { "L\($0.id + 1): \($0.text)" }.joined(separator: "\n")
                        store.prepareAI(source: model.title + " · " + model.path, text: lines, sessionID: nil, question: store.text("Analyze anomalies in these loaded log lines. Cite line numbers and suggest checks.", "分析这些已加载日志的异常，引用行号并给出检查建议。")); store.aiAnalysisPresented = true
                    }.buttonStyle(ChromeButtonStyle()).disabled(model.visibleLines.isEmpty)
                    Button(store.text("Export loaded", "导出已加载内容")) { model.export(chinese: store.chinese) }.buttonStyle(ChromeButtonStyle())
                }
                Text(model.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                HStack {
                    TextField(store.text("Filter loaded lines", "筛选已加载日志"), text: $model.filter).appInput()
                    Toggle(store.text("Errors only", "仅错误"), isOn: $model.onlyErrors).toggleStyle(AxonCheckboxStyle()).fixedSize()
                    TextField(store.text("Find in loaded lines", "搜索已加载日志"), text: $model.search).appInput()
                    Text(model.searchMatches.isEmpty ? "0" : "\(matchIndex % model.searchMatches.count + 1)/\(model.searchMatches.count)").font(.caption).monospacedDigit()
                    Toggle(store.text("Wrap", "自动换行"), isOn: $wrapLines).toggleStyle(AxonCheckboxStyle()).fixedSize()
                    Button { matchIndex += 1 } label: { Image(systemName: "chevron.down") }.buttonStyle(IconButtonStyle()).disabled(model.searchMatches.isEmpty)
                }
            }.padding(14).background(Palette.sidebar)
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
            GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(wrapLines ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.visibleLines) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(line.id + 1)).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Palette.muted).frame(width: 56, alignment: .trailing)
                                Text(highlighted(line.text.isEmpty ? " " : line.text))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(line.isError ? Color(hex: "#D94848") : Palette.text)
                                    .fixedSize(horizontal: !wrapLines, vertical: true)
                                    .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
                                    .textSelection(.enabled)
                                if !wrapLines { Spacer(minLength: 0) }
                            }.frame(width: wrapLines ? max(100, geometry.size.width - 28) : nil, alignment: .leading)
                                .padding(.vertical, 2).id(line.id)
                                .contextMenu { Button(store.text("Analyze this line with AI", "使用 AI 分析此行")) { store.prepareAI(source: model.title + " · " + model.path, text: "L\(line.id + 1): \(line.text)", sessionID: nil, question: store.text("Explain this log line and suggest checks.", "解释此日志行并给出检查建议。")); store.aiAnalysisPresented = true } }

                        }
                        if !model.pendingText.isEmpty && model.filter.isEmpty && !model.onlyErrors {
                            Text(highlighted(model.pendingText)).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: !wrapLines, vertical: true).padding(.leading, 68).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                            .onAppear { autoScroll = true; newLines = 0 }.onDisappear { autoScroll = false }
                    }.padding(14).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: latestRequest) { _, _ in proxy.scrollTo("log-bottom", anchor: .bottom) }
                .onChange(of: model.lines.last?.id) { _, _ in
                    if autoScroll { proxy.scrollTo("log-bottom", anchor: .bottom) }
                    else { newLines += 1 }
                }
                .onChange(of: matchIndex) { _, value in
                    let matches = model.searchMatches
                    if !matches.isEmpty { autoScroll = false; proxy.scrollTo(matches[value % matches.count].id, anchor: .center) }
                }
                .onChange(of: model.search) { _, _ in matchIndex = 0; if let line = model.searchMatches.first { autoScroll = false; proxy.scrollTo(line.id, anchor: .center) } }
                .overlay(alignment: .bottomTrailing) {
                    if newLines > 0 {
                        Button(store.text("New lines · Latest", "有新日志 · 回到最新")) { autoScroll = true; newLines = 0; proxy.scrollTo("log-bottom", anchor: .bottom) }
                            .buttonStyle(ChromeButtonStyle(prominent: true)).padding(16)
                    }
                }
            }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(store.text("Loaded \(model.lines.count) lines · initial last 200 · UTF-8", "已加载 \(model.lines.count) 行 · 初始末尾 200 行 · UTF-8")).font(.caption)
                if model.droppedLines > 0 { Text(store.text("Older lines discarded: \(model.droppedLines)", "已丢弃较早日志：\(model.droppedLines) 行")).font(.caption) }
                if model.unreadBytes > 0 { Text(store.text("Reading backlog", "正在读取积压日志")).font(.caption) }
                Spacer()
                Text(store.text("Visible \(model.visibleLines.count) · Errors \(model.lines.filter(\.isError).count)", "当前显示 \(model.visibleLines.count) 行 · 错误 \(model.lines.filter(\.isError).count) 行")).font(.caption)
            }.foregroundStyle(Palette.muted).padding(10).background(Palette.sidebar)
        }.background(Palette.background).foregroundStyle(Palette.text)
            .onAppear { model.activate() }.onDisappear { model.deactivate() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.deactivate() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.activate() }
    }
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !model.search.isEmpty else { return result }
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: model.search, options: [.caseInsensitive], range: remaining) {
            if let start = AttributedString.Index(range.lowerBound, within: result),
               let end = AttributedString.Index(range.upperBound, within: result) {
                result[start..<end].backgroundColor = Color(hex: "#F0C849")
                result[start..<end].foregroundColor = Color(hex: "#252738")
            }
            remaining = range.upperBound..<text.endIndex
        }
        return result
    }
    private var statusTitle: String {
        switch model.status {
        case "following": return store.text("Following", "正在跟随")
        case "paused": return store.text("Paused", "已暂停")
        case "missing": return store.text("Waiting for the file", "等待日志文件出现")
        case "disconnected": return store.text("Connection closed · reconnect, close this tab and reopen the log", "连接已关闭 · 重连后关闭此标签并重新打开日志")
        case "rotated": return store.text("File changed · resumed from tail", "文件已轮转 · 从末尾继续")
        case "error": return store.text("Read failed", "读取失败")
        default: return store.text("Loading", "正在加载")
        }
    }
}
