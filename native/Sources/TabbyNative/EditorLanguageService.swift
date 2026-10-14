import Foundation
import SwiftUI
import Darwin

struct LSPFrameDecoder {
    private var bytes = Data()
    mutating func append(_ data: Data) throws -> [[String: Any]] {
        bytes.append(data); guard bytes.count <= 2 * 1024 * 1024 + 4096 else { throw AIModelError.invalidReply }
        var messages: [[String: Any]] = []
        while let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
            guard boundary.lowerBound <= 4096, let header = String(data: bytes[..<boundary.lowerBound], encoding: .ascii) else { throw AIModelError.invalidReply }
            let lengths = header.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("content-length:") }
            guard lengths.count == 1, let length = Int(lengths[0].dropFirst(15).trimmingCharacters(in: .whitespaces)), (1...2 * 1024 * 1024).contains(length) else { throw AIModelError.invalidReply }
            let start = boundary.upperBound; guard bytes.count >= start + length else { break }
            let body = bytes.subdata(in: start..<start + length)
            guard String(data: body, encoding: .utf8) != nil, let value = try JSONSerialization.jsonObject(with: body) as? [String: Any], value["jsonrpc"] as? String == "2.0" else { throw AIModelError.invalidReply }
            messages.append(value); bytes.removeSubrange(0..<start + length)
        }
        if bytes.range(of: Data("\r\n\r\n".utf8)) == nil, bytes.count > 4096 { throw AIModelError.invalidReply }
        return messages
    }
    static func encode(_ value: [String: Any]) throws -> Data { let body = try JSONSerialization.data(withJSONObject: value); return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body }
}

private final class LSPTransport: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock(), writes = DispatchQueue(label: "axon.lsp.write")
    private var decoder = LSPFrameDecoder()
    var message: (([String: Any]) -> Void)?
    var failure: ((String) -> Void)?
    init(executable: String, arguments: [String], directory: String) throws {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LANG", "TMPDIR"].contains($0.key) }; environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; process.environment = environment
    }
    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }; let data = handle.availableData; guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            do { self.lock.lock(); defer { self.lock.unlock() }; for value in try self.decoder.append(data) { self.message?(value) } }
            catch { self.failure?("Invalid or oversized language server response / 语言服务响应无效或过大") }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
        process.terminationHandler = { [weak self] _ in self?.failure?("Language server stopped / 语言服务已停止") }
        try process.run()
    }
    func send(_ value: [String: Any]) async throws {
        let data = try LSPFrameDecoder.encode(value)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { do { try self.input.fileHandleForWriting.write(contentsOf: data); continuation.resume() } catch { continuation.resume(throwing: error) } }
        }
    }
    func stop() {
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil; process.terminationHandler = nil
        if process.isRunning { process.terminate(); let process = process; DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } }
        try? input.fileHandleForWriting.close()
    }
    deinit { stop() }
}

@MainActor final class EditorLanguageService: ObservableObject {
    struct Position: Codable, Equatable { var line: Int; var character: Int }
    struct Span: Codable, Equatable { var start: Position; var end: Position }
    struct TextEdit: Codable { var range: Span; var newText: String }
    struct Diagnostic: Identifiable { var id: Int; var message: String; var range: Span; var severity: Int }
    struct Symbol: Identifiable { var id: Int; var name: String; var range: Span; var depth: Int }
    @Published private(set) var ready = false
    @Published private(set) var diagnostics: [Diagnostic] = []
    @Published private(set) var symbols: [Symbol] = []
    @Published private(set) var formatting = false
    @Published var error = ""
    private var transport: LSPTransport?
    private var generation = UUID()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var uri = ""
    private var text = ""
    private(set) var version = 0
    private var symbolSupport = false
    static func range(_ span: Span, text: String) throws -> Range<String.Index> {
        let units = Array(text.utf16)
        var starts = [0], ends: [Int] = [], index = 0
        while index < units.count {
            if units[index] == 10 || units[index] == 13 {
                ends.append(index)
                if units[index] == 13, index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                index += 1; starts.append(index)
            } else { index += 1 }
        }
        ends.append(units.count)
        func offset(_ position: Position) throws -> Int {
            guard starts.indices.contains(position.line), position.character >= 0, position.character <= ends[position.line] - starts[position.line] else { throw AIModelError.invalidReply }
            return starts[position.line] + position.character
        }
        let start = try offset(span.start), end = try offset(span.end)
        func boundary(_ offset: Int) -> Bool { offset == 0 || offset == units.count || !((0xDC00...0xDFFF).contains(units[offset]) && (0xD800...0xDBFF).contains(units[offset - 1])) }
        guard end >= start, boundary(start), boundary(end), let range = Range(NSRange(location: start, length: end - start), in: text) else { throw AIModelError.invalidReply }; return range
    }
    static func apply(_ edits: [TextEdit], text: String) throws -> String {
        guard edits.count <= 1000 else { throw AIModelError.invalidReply }
        let values = try edits.map { (try range($0.range, text: text), $0.newText) }.sorted { $0.0.lowerBound < $1.0.lowerBound }
        for index in values.indices.dropFirst() { guard values[index - 1].0.upperBound <= values[index].0.lowerBound, values[index - 1].0 != values[index].0 else { throw AIModelError.invalidReply } }
        var result = text
        for (range, replacement) in values.reversed() { result.replaceSubrange(range, with: replacement) }
        guard result.utf8.count <= 2 * 1024 * 1024, !result.contains("\0") else { throw AIModelError.invalidReply }; return result
    }
    func start(executable: String, arguments: [String], path: String, text: String, language: String) async throws {
        stop(); error = ""; guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable), arguments.count <= 20, arguments.allSatisfy({ $0.utf8.count <= 4096 }), text.utf8.count <= 2 * 1024 * 1024 else { throw AppFailure.message("Choose an installed executable and bounded arguments / 请选择已安装的可执行程序，参数需在限额内") }
        self.uri = URL(fileURLWithPath: path).absoluteString; self.text = text; version = 1
        let token = generation; let transport = try LSPTransport(executable: executable, arguments: arguments, directory: (path as NSString).deletingLastPathComponent); self.transport = transport
        transport.message = { [weak self] message in Task { @MainActor in guard let self, self.generation == token else { return }; self.receive(message) } }
        transport.failure = { [weak self] reason in Task { @MainActor in guard let self, self.generation == token else { return }; self.stop(); self.error = reason } }
        do {
            try transport.start()
            let result = try await request("initialize", ["processId": Int(getpid()), "rootUri": URL(fileURLWithPath: (path as NSString).deletingLastPathComponent).absoluteString, "capabilities": ["general": ["positionEncodings": ["utf-16"]], "workspace": ["applyEdit": false], "textDocument": ["documentSymbol": ["hierarchicalDocumentSymbolSupport": true], "publishDiagnostics": ["versionSupport": true]]]])
            let capabilities = result["capabilities"] as? [String: Any] ?? [:]
            guard (capabilities["positionEncoding"] as? String ?? "utf-16") == "utf-16" else { throw AppFailure.message("Only UTF-16 language server positions are supported / 仅支持 UTF-16 位置编码") }
            let sync = capabilities["textDocumentSync"] as? Int ?? (capabilities["textDocumentSync"] as? [String: Any])?["change"] as? Int ?? 0
            guard [1, 2].contains(sync) else { throw AppFailure.message("Server must support document synchronization / 服务需支持文档同步") }
            formatting = capabilities["documentFormattingProvider"] as? Bool == true || capabilities["documentFormattingProvider"] is [String: Any]
            symbolSupport = capabilities["documentSymbolProvider"] as? Bool == true || capabilities["documentSymbolProvider"] is [String: Any]
            try await notify("initialized", [:]); try await notify("textDocument/didOpen", ["textDocument": ["uri": uri, "languageId": language, "version": version, "text": text]])
            ready = true; try await refreshSymbols()
        } catch { stop(); throw error }
    }
    func synchronize(_ value: String) async throws {
        guard ready else { throw AppFailure.message("Language service is not connected / 语言服务未连接") }
        guard value.utf8.count <= 2 * 1024 * 1024 else { throw AIModelError.invalidReply }
        if value != text { text = value; version += 1; diagnostics = []; symbols = []; try await notify("textDocument/didChange", ["textDocument": ["uri": uri, "version": version], "contentChanges": [["text": text]]]) }
    }
    func refreshSymbols() async throws {
        guard ready, symbolSupport else { symbols = []; return }; let revision = version
        let response = try await request("textDocument/documentSymbol", ["textDocument": ["uri": uri]])
        guard version == revision else { return }; let entries = response["value"] as? [[String: Any]] ?? []
        var values: [Symbol] = []
        func flatten(_ entries: [[String: Any]], depth: Int) {
            guard depth < 10 else { return }
            for entry in entries.prefix(500) where values.count < 500 {
                let raw = entry["selectionRange"] ?? entry["range"] ?? (entry["location"] as? [String: Any])?["range"]
                if let raw, let data = try? JSONSerialization.data(withJSONObject: raw), let span = try? JSONDecoder().decode(Span.self, from: data), let name = entry["name"] as? String { values.append(.init(id: values.count, name: String(name.prefix(300)), range: span, depth: depth)) }
                flatten(entry["children"] as? [[String: Any]] ?? [], depth: depth + 1)
            }
        }
        flatten(entries, depth: 0); symbols = values
    }
    func format(_ value: String) async throws -> String {
        guard formatting else { throw AppFailure.message("This server does not provide formatting / 此服务不支持格式化") }; try await synchronize(value); let revision = version
        let result = try await request("textDocument/formatting", ["textDocument": ["uri": uri], "options": ["tabSize": 4, "insertSpaces": true]])
        guard version == revision else { throw AppFailure.message("Document changed while formatting / 格式化期间文档已变化") }
        let data = try JSONSerialization.data(withJSONObject: result["value"] as? [Any] ?? []); return try Self.apply(JSONDecoder().decode([TextEdit].self, from: data), text: value)
    }
    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let transport else { throw CancellationError() }; sequence += 1; let id = sequence
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in do { try await Task.sleep(for: .seconds(15)) } catch { return }; guard let self, self.pending[id] != nil else { return }; self.stop(); self.error = "Language server request timed out / 语言服务请求超时" }
                Task { do { try await transport.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) } catch { if let continuation = self.pending.removeValue(forKey: id) { self.timers.removeValue(forKey: id)?.cancel(); continuation.resume(throwing: error) } } }
            }
        }, onCancel: { Task { @MainActor [weak self] in
            guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
            self.timers.removeValue(forKey: id)?.cancel(); continuation.resume(throwing: CancellationError())
            try? await self.notify("$/cancelRequest", ["id": id])
        } })
    }
    private func notify(_ method: String, _ params: [String: Any]) async throws { guard let transport else { throw CancellationError() }; try await transport.send(["jsonrpc": "2.0", "method": method, "params": params]) }
    private func receive(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            if let id = message["id"] { let transport = transport; Task { try? await transport?.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Client request unsupported; no workspace edit or command executed"]]) }; return }
            if method == "textDocument/publishDiagnostics", let params = message["params"] as? [String: Any], params["uri"] as? String == uri, (params["version"] as? Int == nil || params["version"] as? Int == version) {
                diagnostics = (params["diagnostics"] as? [[String: Any]] ?? []).prefix(200).enumerated().compactMap { index, value in
                    guard let raw = value["range"], let data = try? JSONSerialization.data(withJSONObject: raw), let span = try? JSONDecoder().decode(Span.self, from: data), let message = value["message"] as? String else { return nil }; return .init(id: index, message: String(message.prefix(2000)), range: span, severity: value["severity"] as? Int ?? 1)
                }
            }
        } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            timers.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] { continuation.resume(throwing: AppFailure.message(AIContext.sanitize(error["message"] as? String ?? "Language server error"))) }
            else if let result = message["result"] as? [String: Any] { continuation.resume(returning: result) }
            else { continuation.resume(returning: ["value": message["result"] ?? NSNull()]) }
        }
    }
    func stop() {
        generation = UUID(); transport?.stop(); transport = nil; ready = false; formatting = false; diagnostics = []; symbols = []
        let waiters = pending.values; pending = [:]; timers.values.forEach { $0.cancel() }; timers = [:]; waiters.forEach { $0.resume(throwing: CancellationError()) }
    }
}
