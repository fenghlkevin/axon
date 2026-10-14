import Foundation

/// One mature Agent thread and app-server process. Only registered Axon tools can execute.
@MainActor final class AICodexSession {
    let process: Process
    private let root: URL
    private let output: URL
    private let writer: FileHandle
    private let input = Pipe()
    private let settings: AISettings
    private let instructions: String
    private var images: [AIImageContext]
    private var consumed = 0
    private var sequence = 3
    private var threadID: String?
    private var pending: (rpcID: Any, callID: String)?
    private var seenCalls = Set<String>()
    private var started = false
    private var closed = false
    private var stream = CodexAnswerStream(allowAxonTool: true)
    var usageHandler: ((AIUsageSample) -> Void)?
    private var usageTotal = AIUsageSample(input: 0, output: 0, cached: 0, cacheWrite: 0, reasoning: 0)
    private(set) var lastCallID: String?

    init(settings: AISettings, environment: [String: String], instructions: String, images: [AIImageContext] = []) throws {
        guard let executable = CodexRuntime.executable(settings.codexPath, environment: environment) else { throw AppFailure.message("Codex CLI not found / 未找到 Codex CLI") }
        self.settings = settings; self.instructions = instructions; self.images = images
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-model-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        output = root.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        writer = try FileHandle(forWritingTo: output)
        let launch = try CodexRuntime.launch(executable: executable, settings: settings, environment: environment)
        process = Process(); process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.prefix + CodexRuntime.appServerArguments(); process.environment = launch.environment
        process.currentDirectoryURL = root; process.standardInput = input; process.standardOutput = writer; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { try? writer.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close(); try? writer.close()
        try? FileManager.default.removeItem(at: root)
    }
    func close() {
        guard !closed else { return }; closed = true
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close(); try? writer.close(); try? FileManager.default.removeItem(at: root)
        pending = nil
    }
    static var toolSchema: [String: Any] {
        var schema = AIStructuredReply.schema
        var properties = schema["properties"] as! [String: Any]
        var action = properties["action"] as! [String: Any]
        action["type"] = "object"; properties["action"] = action; schema["properties"] = properties
        return schema
    }
    private var nativeTools: Bool { settings.effectiveAgentRuntime == .codexNative }
    private var definitions: [[String: Any]] {
        nativeTools ? AINativeAgentTools.definitions : [["name": AIStructuredReply.toolName, "description": "Request one Axon operation. Execution, approval and verification are handled by Axon; wait for its real result.", "inputSchema": Self.toolSchema]]
    }
    private var agentInstructions: String {
        if nativeTools { return instructions.replacingOccurrences(of: AICommandExecutor.replyProtocol, with: AINativeAgentTools.protocolInstructions) }
        return instructions + "\nNATIVE AXON TOOL PROTOCOL: Use axon_step for every operation. Do not emit an action as assistant text or invoke other tools. Only Axon executes the action after its checks/approval. When finished, give a normal text answer, not JSON. Never finish while verification is pending. Execute one operation at a time; await its tool result before planning another."
    }
    private func send(_ value: [String: Any]) throws {
        guard !closed, process.isRunning else { throw AIModelError.incompleteStream }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    }
    private func startTurn(_ prompt: String) throws {
        guard let threadID else { throw AIModelError.incompleteStream }
        sequence += 1; stream = CodexAnswerStream(allowAxonTool: true); lastCallID = nil
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": prompt]] + images.map { ["type": "image", "url": $0.url] }, "approvalPolicy": "never", "sandboxPolicy": ["type": "readOnly"]]
        images = []
        if let effort = settings.codexReasoningEffort { params["effort"] = effort }
        try send(["id": sequence, "method": "turn/start", "params": params])
    }
    func next(_ feedback: String, images nextImages: [AIImageContext] = [], publish: @escaping (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        if !started {
            started = true
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "axon_ai", "version": "0.19.1"], "capabilities": ["experimentalApi": true]]])
        } else if let call = pending {
            pending = nil
            try send(["id": call.rpcID, "result": ["success": !feedback.contains("Rejection reason:"), "contentItems": [["type": "inputText", "text": feedback]]]])
        } else if stream.completed { images = nextImages; try startTurn(feedback) }
        var emptyRetries = 0
        let deadline = Date().addingTimeInterval(120)
        while true {
            try Task.checkCancellation()
            guard !closed, process.isRunning else { throw AIModelError.incompleteStream }
            guard Date() < deadline else { throw URLError(.timedOut) }
            let data = try Data(contentsOf: output)
            guard data.count <= 16 * 1024 * 1024 else { throw AppFailure.message("Model session output too large / 模型会话输出超过限额，请开始新对话。") }
            if let end = data[consumed...].firstIndex(of: 10) {
                let line = Data(data[consumed..<end]); consumed = end + 1
                guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw AIModelError.invalidReply }
                let method = event["method"] as? String
                if method == "thread/tokenUsage/updated", let params = event["params"] as? [String: Any], params["threadId"] as? String == threadID,
                   let values = (params["tokenUsage"] as? [String: Any])?["total"] as? [String: Any], let sample = AIUsageSample.parse(values, backend: .codex),
                   let delta = sample.subtracting(usageTotal) { usageTotal = sample; usageHandler?(delta) }
                if let rpcID = event["id"], let method {
                    guard method == "item/tool/call", let params = event["params"] as? [String: Any],
                          params["threadId"] as? String == threadID, let toolName = params["tool"] as? String,
                          (nativeTools ? AINativeAgentTools.recognizes(toolName) : toolName == AIStructuredReply.toolName),
                          params["namespace"] == nil || params["namespace"] is NSNull,
                          let callID = params["callId"] as? String, !callID.isEmpty, seenCalls.insert(callID).inserted,
                          let arguments = params["arguments"] as? [String: Any] else {
                        throw AppFailure.message("Unexpected model tool request; execution stopped / 模型请求了未授权工具，已停止执行。")
                    }
                    pending = (rpcID, callID); lastCallID = callID
                    // Validation failures return to this exact pending call on the next iteration.
                    return nativeTools ? try AINativeAgentTools.reply(name: toolName, arguments: arguments) : String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                }
                if method == nil, let id = event["id"] as? Int {
                    if event["error"] != nil { try stream.event(event) }
                    if id == 1 {
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 2, "method": "config/read", "params": ["includeLayers": false]])
                    } else if id == 2 {
                        guard let result = event["result"] as? [String: Any], let effective = result["config"] as? [String: Any] else { throw AIModelError.invalidReply }
                        let servers = effective["mcp_servers"] as? [String: Any] ?? [:]
                        let disabled = servers.mapValues { _ in ["enabled": false] }
                        var config: [String: Any] = ["mcp_servers": disabled, "project_doc_max_bytes": 0]
                        if let effort = settings.codexReasoningEffort { config["model_reasoning_effort"] = effort }
                        var params: [String: Any] = ["ephemeral": true, "cwd": root.path, "modelProvider": "openai", "sandbox": "read-only", "approvalPolicy": "never", "config": config,
                            "developerInstructions": agentInstructions,
                            "dynamicTools": definitions]
                        if !settings.codexModel.isEmpty { params["model"] = settings.codexModel }
                        if let tier = settings.codexServiceTier { params["serviceTier"] = tier }
                        try send(["id": 3, "method": "thread/start", "params": params])
                    } else if id == 3 {
                        guard let result = event["result"] as? [String: Any], let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw AIModelError.invalidReply }
                        threadID = id; try startTurn(feedback)
                    }
                    continue
                }
                try stream.event(event)
                if stream.completed {
                    do { return try AIStructuredReply(answer: stream.result(), action: nil).serialized() }
                    catch CodexReplyError.empty {
                        guard emptyRetries == 0 else { throw AppFailure.message("Codex completed twice without an answer. / Codex 连续两次未返回回答，请重试或切换模型。") }
                        emptyRetries += 1
                        try startTurn("Previous turn completed without an answer. Continue from the actual result below; do not replay any operation.\n" + feedback)
                    }
                }
                publish(stream.text)
                continue
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}
