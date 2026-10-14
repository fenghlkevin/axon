import Foundation
import Combine
import Darwin

struct AIMCPServer: Codable, Identifiable, Equatable {
    enum Transport: String, Codable, CaseIterable { case stdio, http }
    var id = UUID()
    var name = ""
    var transport = Transport.stdio
    var command = ""
    var arguments: [String] = []
    var directory = ""
    var endpoint = ""
    var secretEnvironment = "MCP_TOKEN"
    var credentialRevision = 0
    var enabled = true
    var permission = AIToolPermission.ask
    var allowedTools: [String] = []
    var connectionIdentity: String { [transport.rawValue, command, arguments.joined(separator: "\0"), directory, endpoint, secretEnvironment, String(credentialRevision)].joined(separator: "\n") }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), allowedTools.count <= 64,
              Set(allowedTools).count == allowedTools.count, allowedTools.allSatisfy(AIMCPTool.validName),
              !AIBackend.allCases.map(\.secretID).contains(id) else { throw AppFailure.message("Invalid MCP server name or tool selection / MCP 名称或工具选择无效") }
        if transport == .stdio {
            guard CodexRuntime.isExecutable(command), !AIBuiltInDeny.matches(command), arguments.count <= 32,
                  arguments.reduce(0, { $0 + $1.utf8.count }) <= 8192,
                  !arguments.contains(where: { $0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }),
                  !AIBuiltInDeny.matches(arguments.joined(separator: " ")), AIContext.sanitize(arguments.joined(separator: " ")) == arguments.joined(separator: " "),
                  directory.hasPrefix("/"), directory != "/", !AIAutomaticContext.sensitive(directory),
                  (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !directory.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  secretEnvironment.range(of: "^[A-Z_][A-Z0-9_]{0,63}$", options: .regularExpression) != nil,
                  !["HOME", "PATH", "TMPDIR", "CODEX_HOME"].contains(secretEnvironment), !secretEnvironment.hasPrefix("DYLD_"), !secretEnvironment.hasPrefix("LD_"), !secretEnvironment.hasPrefix("PYTHON"), !secretEnvironment.hasPrefix("NODE_") else { throw AppFailure.message("Use an executable, a project directory and literal JSON arguments / 请填写可执行文件、项目目录及字面 JSON 参数") }
        } else { _ = try Self.url(endpoint) }
    }
    static func url(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let host = url.host, url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              raw.utf8.count <= 2048, AIContext.sanitize(raw) == raw,
              url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host) else { throw AppFailure.message("Use an HTTPS MCP endpoint; HTTP is limited to localhost / 请使用 HTTPS MCP 地址，HTTP 仅限本机") }
        return url
    }
    static func validate(_ values: [Self]) throws {
        guard values.count <= 8, Set(values.map(\.id)).count == values.count else { throw AppFailure.message("Up to eight distinct MCP servers / 最多 8 个不同 MCP 服务") }
        for value in values { try value.validate() }
    }
}
struct AIMCPTool: Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let schema: [String: Any]
    let readOnly: Bool
    static func validName(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil }
    static func prohibited(_ name: String) -> Bool {
        name.range(of: "(?i)(delete|remove|write|edit|exec|shell|format|shutdown|reboot|install|patch|publish|commit|push)", options: .regularExpression) != nil
    }
}
struct AIMCPCall {
    let server: UUID
    let tool: String
    let arguments: [String: Any]
    static func decode(_ raw: String) throws -> Self {
        guard raw.utf8.count <= 8192, let values = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              Set(values.keys) == Set(["server", "tool", "arguments"]), let id = values["server"] as? String, let server = UUID(uuidString: id),
              let tool = values["tool"] as? String, AIMCPTool.validName(tool), !AIMCPTool.prohibited(tool), let arguments = values["arguments"] as? [String: Any],
              AIContext.sanitize(raw) == raw, !AIBuiltInDeny.matches(raw) else { throw AppFailure.message("Invalid, sensitive or prohibited MCP request / MCP 请求无效、包含敏感内容或禁止操作") }
        return Self(server: server, tool: tool, arguments: arguments)
    }
}

/// Only explicit, locally managed read-only tools. No inherited model-side MCP.
@MainActor final class AIMCPClient {
    let configuration: AIMCPServer
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var diagnostics: Pipe?
    private var buffer = Data()
    private var sequence = 0
    private var version = "2025-06-18"
    private var sessionID: String?
    private let credential: String
    private var busy = false
    private var closed = false
    private var receivedBytes = 0
    private var diagnosticTail = Data()
    private var serverRequests = 0
    private let seconds: Double
    init(_ server: AIMCPServer, credential: String, seconds: Double = 30) throws {
        try server.validate(); self.configuration = server; self.credential = credential; self.seconds = seconds
        if server.transport == .stdio {
            func canonical(_ path: String) -> String { guard let value = realpath(path, nil) else { return path }; defer { free(value) }; return String(cString: value) }
            var executable = canonical(server.command)
            if executable == "/usr/bin/python3" {
                let resolver = Process(), resolved = Pipe(); resolver.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); resolver.arguments = ["--find", "python3"]; resolver.standardOutput = resolved; resolver.standardError = FileHandle.nullDevice
                try resolver.run(); resolver.waitUntilExit()
                let path = String(decoding: resolved.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard resolver.terminationStatus == 0, CodexRuntime.isExecutable(path) else { throw AppFailure.message("Choose the actual Python interpreter path / 请填写实际 Python 解释器路径") }; executable = canonical(path)
            }
            if executable.contains("/Python3.framework/Versions/") {
                let bin = (executable as NSString).deletingLastPathComponent
                let direct = ((bin as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
                if CodexRuntime.isExecutable(direct) { executable = direct }
            }
            let directory = canonical(server.directory)
            guard directory != "/", directory != canonical(NSHomeDirectory()), !AIAutomaticContext.sensitive(directory) else { throw AppFailure.message("Choose a project directory, not a home or sensitive directory / 请选择项目目录，不能使用用户主目录或敏感目录") }
            let arguments = server.arguments.map { $0.hasPrefix("/") ? canonical($0) : $0 }
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            let runtime = executable.contains("/Applications/Xcode.app/") ? "/Applications/Xcode.app" : (executable as NSString).deletingLastPathComponent
            var roots = Set(["/System", "/usr", "/Library", "/private/etc", "/dev", directory, runtime])
            for argument in arguments where argument.hasPrefix("/") && FileManager.default.fileExists(atPath: argument) {
                let parent = (argument as NSString).deletingLastPathComponent
                guard parent != "/", !AIAutomaticContext.sensitive(argument) else { throw AppFailure.message("MCP argument read scope is too broad or sensitive / MCP 参数读取范围过大或包含敏感路径") }; roots.insert(parent)
            }
            // Fail closed: no network, file writes, signals or arbitrary child executables.
            // literal("/") permits only the root directory itself (Python startup),
            // never subpath("/"). Outside-project synthetic reads/writes are tested denied.
            let profile = "(version 1)(allow default)(deny file-write*)(deny file-read-data)(deny network*)(deny signal)(deny process-exec)(allow file-read-data (literal \"/\"))" + "(allow process-exec (literal " + quote(executable) + "))" + roots.sorted().map { "(allow file-read-data (subpath " + quote($0) + "))" }.joined()
            let process = Process(), input = Pipe(), output = Pipe()
            // A disconnected server must raise EPIPE, never terminate Axon with SIGPIPE.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw AppFailure.message("MCP pipe protection unavailable / MCP 管道保护不可用") }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec"); process.arguments = ["-p", profile, executable] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "PYTHONDONTWRITEBYTECODE": "1"]
            if !credential.isEmpty { environment[server.secretEnvironment] = credential }
            process.environment = environment; process.standardInput = input; process.standardOutput = output; let diagnostics = Pipe(); process.standardError = diagnostics; self.diagnostics = diagnostics
            _ = fcntl(diagnostics.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            try process.run(); self.process = process; self.input = input; self.output = output
            _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        }
    }
    deinit { if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }; try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close() }
    func close() { closed = true; if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }; try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close() }
    func initialize() async throws -> [AIMCPTool] {
        let result = try await request("initialize", ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "Axon", "version": "0.19.18"]])
        guard let negotiated = result["protocolVersion"] as? String, ["2024-11-05", "2025-03-26", "2025-06-18"].contains(negotiated), (result["capabilities"] as? [String: Any])?["tools"] != nil else { throw AppFailure.message("MCP protocol or tools capability unsupported / 不支持该 MCP 协议或工具能力") }
        version = negotiated; _ = try await exchange(["jsonrpc": "2.0", "method": "notifications/initialized"], expectedID: nil)
        var tools: [AIMCPTool] = [], cursor: String?
        for _ in 0..<4 {
            let page = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            guard let values = page["tools"] as? [[String: Any]], tools.count + values.count <= 64 else { throw AppFailure.message("MCP tool list exceeds 64 entries / MCP 工具列表超过 64 项") }
            for value in values {
                guard let name = value["name"] as? String, AIMCPTool.validName(name), !tools.contains(where: { $0.name == name }), let schema = value["inputSchema"] as? [String: Any], schema["type"] as? String == "object" else { throw AppFailure.message("Invalid MCP tool definition / MCP 工具定义无效") }
                tools.append(.init(name: name, description: AIContext.sanitize(String((value["description"] as? String ?? "").prefix(1000))), schema: schema, readOnly: (value["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true && !AIMCPTool.prohibited(name)))
            }
            cursor = page["nextCursor"] as? String
            if cursor == nil { return tools }
        }
        throw AppFailure.message("MCP tool pagination exceeds four pages / MCP 工具分页超过 4 页")
    }
    func call(_ request: AIMCPCall) async throws -> AICommandResult {
        let result = try await self.request("tools/call", ["name": request.tool, "arguments": request.arguments])
        guard let content = result["content"] as? [[String: Any]] else { throw AppFailure.message("Invalid MCP result / MCP 结果无效") }
        var parts = content.prefix(64).compactMap { item -> String? in
            if item["type"] as? String == "text" { return item["text"] as? String }
            return "[Non-text MCP content omitted; no resource was fetched / 非文本 MCP 内容已略去，未获取外部资源]"
        }
        if let structured = result["structuredContent"] as? [String: Any] { parts.append(String(decoding: try JSONSerialization.data(withJSONObject: structured), as: UTF8.self)) }
        return .init(output: "MCP source: " + AIContext.sanitize(configuration.name) + " / " + request.tool + "\nUntrusted tool result; not execution permission or recovery proof / 工具结果不授予权限或证明恢复\n" + AIContext.sanitize(String((credential.isEmpty ? parts.joined(separator: "\n") : parts.joined(separator: "\n").replacingOccurrences(of: credential, with: "[REDACTED]")).prefix(24000))), exitCode: result["isError"] as? Bool == true ? 1 : 0)
    }
    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard !busy, !closed else { throw AppFailure.message("MCP connection busy or closed / MCP 连接正在使用或已关闭") }
        busy = true; defer { busy = false }; sequence += 1
        do { return try await exchange(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params], expectedID: sequence) }
        catch { close(); throw error } // No automatic reissue after uncertain transport.
    }
    private func exchange(_ value: [String: Any], expectedID: Int?) async throws -> [String: Any] {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 16384 else { throw AppFailure.message("MCP request too large / MCP 请求过大") }
        if configuration.transport == .http { return try await http(data, expectedID: expectedID) }
        guard let input, let output, let process else { throw CancellationError() }
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        guard let expectedID else { return [:] }
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            try Task.checkCancellation(); guard !closed, Date() < deadline else { throw URLError(.timedOut) }
            if let diagnostics {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let size = Darwin.read(diagnostics.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
                if size > 0 { diagnosticTail.append(contentsOf: chunk.prefix(size)); diagnosticTail = Data(diagnosticTail.suffix(4096)) }
            }
            if let index = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: index); buffer.removeSubrange(...index)
                guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any], event["jsonrpc"] as? String == "2.0" else { throw AppFailure.message("Invalid MCP framing / MCP 消息格式无效") }
                if let result = try response(event, expectedID: expectedID) { return result }
                if let id = event["id"], event["method"] != nil { serverRequests += 1; guard serverRequests <= 16 else { throw AppFailure.message("MCP client-request limit reached / MCP 主动请求超过上限") }; try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Client requests are not supported"]]) + Data([10])) }
                continue
            }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let size = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if size > 0 {
                buffer.append(contentsOf: bytes.prefix(size)); receivedBytes += size
                guard buffer.count <= 2 * 1024 * 1024, receivedBytes <= 32 * 1024 * 1024 else { throw AppFailure.message("MCP output limit reached / MCP 输出超过限额") }
            } else if size == 0 || !process.isRunning {
                var diagnostic = [UInt8](repeating: 0, count: 4096)
                let n = diagnostics.map { Darwin.read($0.fileHandleForReading.fileDescriptor, &diagnostic, diagnostic.count) } ?? 0
                if n > 0 { diagnosticTail.append(contentsOf: diagnostic.prefix(n)) }
                let detail = String(decoding: diagnosticTail.suffix(4096), as: UTF8.self)
                throw AppFailure.message("MCP process ended before completion / MCP 进程提前结束：" + AIContext.sanitize(credential.isEmpty ? detail : detail.replacingOccurrences(of: credential, with: "[REDACTED]")))
            }
            else if errno != EAGAIN && errno != EWOULDBLOCK { throw AppFailure.message("MCP read failed / MCP 读取失败") }
            else { try await Task.sleep(for: .milliseconds(20)) }
        }
    }
    private func response(_ event: [String: Any], expectedID: Int) throws -> [String: Any]? {
        if event["method"] as? String == "notifications/tools/list_changed" { throw AppFailure.message("MCP tools changed; reconnect and review tools / MCP 工具已变化，请重新连接并检查选择") }
        if event["method"] != nil { return nil }
        guard AIUsageSample.count(event["id"]) == expectedID else { throw AppFailure.message("MCP response ID mismatch / MCP 响应编号不匹配") }
        if event["error"] != nil { throw AppFailure.message("MCP server rejected the request / MCP 服务拒绝请求") }
        guard let result = event["result"] as? [String: Any] else { throw AppFailure.message("Invalid MCP result / MCP 结果无效") }
        return result
    }
    private func http(_ data: Data, expectedID: Int?) async throws -> [String: Any] {
        let url = try AIMCPServer.url(configuration.endpoint)
        if !["localhost", "127.0.0.1", "::1"].contains(url.host!) { try await AIWebContext.resolvePublic(url.host!) }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = seconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if !credential.isEmpty { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: AIRedirectPolicy(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AppFailure.message("MCP HTTP failed; request was not retried / MCP HTTP 失败，未重试请求") }
        if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id") { guard value.utf8.count <= 256, value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw AppFailure.message("Invalid MCP session / MCP 会话标识无效") }; guard sessionID == nil || sessionID == value else { throw AppFailure.message("MCP session changed / MCP 会话已改变") }; sessionID = value }
        guard let expectedID else { guard response.statusCode == 202 || response.statusCode == 204 else { throw AppFailure.message("MCP notification not acknowledged / MCP 通知未确认") }; return [:] }
        let sse = response.mimeType == "text/event-stream"
        guard sse || response.mimeType == "application/json" else { throw AppFailure.message("Unsupported MCP response type / 不支持该 MCP 响应类型") }
        let deadline = Date().addingTimeInterval(seconds)
        var body = Data(), line = Data(), payload: [String] = [], received = 0
        for try await byte in bytes {
            try Task.checkCancellation(); guard Date() < deadline else { throw AppFailure.message("MCP response timed out / MCP 响应超时") }; received += 1; guard received <= 2 * 1024 * 1024 else { throw AppFailure.message("MCP response too large / MCP 响应过大") }
            if !sse { body.append(byte); continue }
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                guard let text = String(data: line, encoding: .utf8) else { throw AppFailure.message("Invalid MCP encoding / MCP 编码无效") }; line.removeAll(keepingCapacity: true)
                if text.hasPrefix("data:") { payload.append(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                if text.isEmpty, !payload.isEmpty {
                    guard let event = try JSONSerialization.jsonObject(with: Data(payload.joined(separator: "\n").utf8)) as? [String: Any], event["jsonrpc"] as? String == "2.0" else { throw AppFailure.message("Invalid MCP SSE / MCP 流式消息无效") }; payload.removeAll()
                    if event["method"] != nil, event["id"] != nil { throw AppFailure.message("MCP server-initiated requests unavailable / 不支持 MCP 服务主动请求") }
                    if let result = try self.response(event, expectedID: expectedID) { return result }
                }
            } else { line.append(byte) }
        }
        guard !sse, let event = try JSONSerialization.jsonObject(with: body) as? [String: Any], event["jsonrpc"] as? String == "2.0", let result = try self.response(event, expectedID: expectedID) else { throw AIModelError.incompleteStream }
        return result
    }
}

@MainActor final class AIMCPManager: ObservableObject {
    @Published private(set) var tools: [UUID: [AIMCPTool]] = [:]
    @Published private(set) var status: [UUID: String] = [:]
    @Published private(set) var busy = Set<UUID>()
    private var clients: [UUID: AIMCPClient] = [:]
    var credentialReader: (UUID) throws -> String = Secrets.readChecked
    func disconnect(_ id: UUID) { clients.removeValue(forKey: id)?.close(); tools.removeValue(forKey: id); status[id] = "Disconnected / 未连接" }
    func synchronize(_ servers: [AIMCPServer]) {
        for (id, client) in clients { if !servers.contains(where: { $0.id == id && $0.enabled && $0.connectionIdentity == client.configuration.connectionIdentity }) { disconnect(id) } }
    }
    func connect(_ server: AIMCPServer) async {
        guard !busy.contains(server.id), server.enabled else { return }
        disconnect(server.id); busy.insert(server.id); status[server.id] = "Connecting… / 正在连接…"; defer { busy.remove(server.id) }
        do {
            let client = try AIMCPClient(server, credential: credentialReader(server.id))
            clients[server.id] = client
            let listed = try await client.initialize()
            guard clients[server.id] === client else { client.close(); throw CancellationError() }
            tools[server.id] = listed; status[server.id] = "Connected / 已连接"
        } catch { disconnect(server.id); status[server.id] = "Connection failed / 连接失败：" + AIContext.sanitize(error.localizedDescription) }
    }
    func permits(_ call: AIMCPCall, servers: [AIMCPServer]) throws -> AIMCPServer {
        guard let server = servers.first(where: { $0.id == call.server && $0.enabled }), server.permission != .deny,
              server.allowedTools.contains(call.tool), let client = clients[server.id], client.configuration.connectionIdentity == server.connectionIdentity,
              let tool = tools[server.id]?.first(where: { $0.name == call.tool }), tool.readOnly else { throw AppFailure.message("MCP tool unavailable, unselected or not read-only / MCP 工具未连接、未选择或不是只读工具") }
        let required = tool.schema["required"] as? [String] ?? []
        guard required.allSatisfy({ call.arguments[$0] != nil }) else { throw AppFailure.message("Missing MCP tool argument / MCP 工具缺少必填参数") }
        return server
    }
    func catalog(_ servers: [AIMCPServer]) -> String {
        let sections: [(String, [String])] = servers.filter { $0.enabled && $0.permission != .deny }.compactMap { server in
            let permitted = (tools[server.id] ?? []).filter { $0.readOnly && server.allowedTools.contains($0.name) }
            guard !permitted.isEmpty, clients[server.id]?.configuration.connectionIdentity == server.connectionIdentity else { return nil }
            return ("Server \(server.id) · \(AIContext.sanitize(server.name)) · \(server.transport.rawValue)", permitted.map { tool in
                let schema = (try? JSONSerialization.data(withJSONObject: tool.schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return tool.name + " · " + tool.description + "\nInput schema: " + schema
            })
        }
        return Self.boundedCatalog(sections)
    }
    static func boundedCatalog(_ sections: [(String, [String])]) -> String {
        // Keep each schema complete. A clipped JSON schema invites invalid calls.
        var result = "", omitted = 0
        for (header, tools) in sections {
            var included = false
            for tool in tools {
                let addition = (included ? "\n" : "\n" + header + "\n") + tool
                guard result.count + addition.count <= 23800 else { omitted += 1; continue }
                result += addition; included = true
            }
        }
        if omitted > 0 { result += "\nCatalog limit: \(omitted) tool(s) omitted. Select fewer tools in AI settings to expose their complete schemas." }
        return result.trimmingCharacters(in: .newlines)
    }
    func call(_ call: AIMCPCall, servers: @escaping () -> [AIMCPServer], check: @escaping () throws -> Void) async throws -> AICommandResult {
        try check(); let server = try permits(call, servers: servers())
        guard !busy.contains(server.id), let client = clients[server.id] else { throw AppFailure.message("MCP server is in use / MCP 服务正在使用") }
        busy.insert(server.id); defer { busy.remove(server.id) }
        do {
            let result = try await client.call(call)
            try check(); _ = try permits(call, servers: servers())
            return result
        } catch { disconnect(server.id); throw error }
    }
}
