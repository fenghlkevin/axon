import Foundation

/// One complete model reply. The provider never executes the requested action.
struct AIStructuredReply: Codable {
    var answer: String
    var action: AIAgentAction?
    var memory: AITaskMemory.Update? = nil
    var checks: [AIVerificationCheck]? = nil
    enum CodingKeys: String, CodingKey { case answer, action, memory, checks }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(answer, forKey: .answer); try values.encode(action, forKey: .action)
        try values.encode(memory, forKey: .memory); try values.encode(checks, forKey: .checks)
    }

    static let toolName = "axon_step"
    static var schema: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        func object(_ properties: [String: Any], nullable: Bool = false) -> [String: Any] {
            ["type": nullable ? ["object", "null"] as Any : "object" as Any, "properties": properties,
             "required": properties.keys.sorted(), "additionalProperties": false]
        }
        let strings: [String: Any] = ["type": "array", "items": string]
        return object([
            "answer": string,
            "action": object(["tool": ["type": "string", "enum": AIAgentAction.tools],
                              "argument": nullableString, "reason": string, "path": nullableString,
                              "find": nullableString, "replacement": nullableString], nullable: true),
            "memory": object(["facts": strings, "decisions": strings, "remaining": strings], nullable: true),
            "checks": ["type": ["array", "null"], "items": object([
                "goal": string, "tool": ["type": "string", "enum": AIVerificationCheck.readTools], "argument": string, "expectedOutput": string
            ])]
        ])
    }
    static func decode(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        guard data.count <= 180_000 else { throw AIModelError.invalidReply }
        // Reject additional fields locally as well as in the provider schema.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys) == Set(["answer", "action", "memory", "checks"]) else { throw AIModelError.invalidTaskReply("Reply must be one JSON object containing exactly answer, action, memory and checks. Unused fields must be null; no Markdown fences or additional fields.") }
        if let action = json["action"] as? [String: Any], Set(action.keys) != Set(["tool", "argument", "reason", "path", "find", "replacement"]) { throw AIModelError.invalidTaskReply("action must contain exactly tool, argument, reason, path, find and replacement. Include unused fields as null.") }
        if let memory = json["memory"] as? [String: Any], Set(memory.keys) != Set(["facts", "decisions", "remaining"]) { throw AIModelError.invalidReply }
        if let checks = json["checks"] as? [[String: Any]], checks.contains(where: { Set($0.keys) != Set(["goal", "tool", "argument", "expectedOutput"]) }) { throw AIModelError.invalidReply }
        let reply: Self
        do { reply = try JSONDecoder().decode(Self.self, from: data) }
        catch let error as DecodingError {
            let context: DecodingError.Context
            switch error {
            case .typeMismatch(_, let value), .valueNotFound(_, let value), .keyNotFound(_, let value), .dataCorrupted(let value): context = value
            @unknown default: throw AIModelError.invalidReply
            }
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw AIModelError.invalidTaskReply("Invalid JSON field " + (field.isEmpty ? "reply" : field) + ". Follow the field types in the schema, with unused values null.")
        } catch { throw AIModelError.invalidReply }
        guard reply.answer.count <= 24000, reply.action != nil || !reply.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIModelError.invalidReply }
        if let action = reply.action { try action.validate() }
        if let memory = reply.memory { try memory.validate() }
        guard (reply.checks?.count ?? 0) <= 8 else { throw AIModelError.invalidReply }
        return reply
    }
    func serialized() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    static func visible(_ text: String) -> String {
        // Never expose partially streamed JSON or tool arguments in the answer pane.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return (try? decode(text))?.answer ?? "" }
        return AIAgentAction.visible(text)
    }
    static func fromProvider(_ json: [String: Any], backend: AIBackend) throws -> String {
        let arguments: String
        if backend == .claude {
            let blocks = json["content"] as? [[String: Any]] ?? []
            let calls = blocks.filter { $0["type"] as? String == "tool_use" }
            guard json["stop_reason"] as? String == "tool_use", calls.count == 1,
                  calls[0]["name"] as? String == toolName, let input = calls[0]["input"] as? [String: Any] else { throw AIModelError.invalidReply }
            arguments = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        } else {
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  choice["finish_reason"] as? String == "tool_calls",
                  let message = choice["message"] as? [String: Any], let calls = message["tool_calls"] as? [[String: Any]],
                  calls.count == 1, calls[0]["type"] as? String == "function",
                  let function = calls[0]["function"] as? [String: Any], function["name"] as? String == toolName,
                  let value = function["arguments"] as? String else { throw AIModelError.invalidReply }
            arguments = value
        }
        return try decode(arguments).serialized()
    }
}

enum AIModelError: Error, LocalizedError {
    case invalidReply, incompleteStream
    case invalidTaskReply(String)
    var repairHint: String? {
        switch self {
        case .invalidReply: return "Reply must be one complete JSON object with answer, action, memory and checks; all unused fields must be null. Use checks=null or [] when no new checks are proposed."
        case .invalidTaskReply(let reason): return reason
        default: return nil
        }
    }
    case http(Int, TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .invalidReply: return "The next model reply is invalid; no new action was executed. Earlier execution records are retained. / 下一步模型响应无效，本次响应未执行新操作；此前执行记录已保留。"
        case .invalidTaskReply(let reason): return "Next model reply rejected; earlier execution records are retained / 下一步模型响应校验未通过，未执行新操作；此前执行记录已保留：\n" + reason
        case .incompleteStream: return "The model connection ended before completion; recorded operations are retained. / 模型连接提前结束，已保留执行记录。"
        case .http(let status, _): return "AI request failed (HTTP \(status)); check endpoint, credentials and model. / AI 请求失败（HTTP \(status)），请检查接口、凭据及模型。"
        }
    }
}

enum AIModelRetry {
    static func delay(for error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < 2, !(error is CancellationError) else { return nil }
        if let value = error as? AIModelError {
            switch value {
            case .incompleteStream: return pow(2, Double(attempt))
            case .http(let status, let retryAfter) where [408, 429, 500, 502, 503, 504, 529].contains(status):
                return min(30, max(pow(2, Double(attempt)), retryAfter ?? 0))
            default: return nil
            }
        }
        if let value = error as? URLError, [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains(value.code) { return pow(2, Double(attempt)) }
        return nil
    }
    static func retryAfter(_ text: String?, now: Date = Date()) -> TimeInterval? {
        guard let text else { return nil }
        if let seconds = Double(text), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: text).map { max(0, $0.timeIntervalSince(now)) }
    }
}
