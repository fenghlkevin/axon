import Foundation

/// Tool arguments are buffered privately and dispatched only after provider completion.
struct AIStreamEvents {
    var text = ""
    var usage = AIUsageSample()
    var completed = false
    var payload: [String] = []
    var toolName = ""
    var toolID = ""
    var toolArguments = ""
    var toolIndex: Int?
    var toolStopped = false
    var finishReason = ""
    var structured = false
    mutating func line(_ line: String, backend: AIBackend) throws {
        if line.hasPrefix("data:") { payload.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        else if line.isEmpty, !payload.isEmpty {
            let value = payload.joined(separator: "\n"); payload.removeAll()
            guard !completed else { throw AIModelError.invalidReply }
            if value == "[DONE]" { guard backend == .chatgpt, !finishReason.isEmpty else { throw AIModelError.incompleteStream }; completed = true; return }
            guard let event = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { throw AppFailure.message("Invalid stream / 流式响应无效") }
            if event["error"] != nil || event["type"] as? String == "error" {
                let detail = event["error"] as? [String: Any] ?? [:]
                let code = detail["type"] as? String ?? detail["code"] as? String ?? ""
                if ["overloaded_error", "server_error", "api_error"].contains(code) { throw AIModelError.http(503, nil) }
                if ["rate_limit_error", "rate_limit_exceeded"].contains(code) { throw AIModelError.http(429, nil) }
                throw AppFailure.message("Provider stream failed / 服务流式响应失败")
            }
            if let values = event["usage"] as? [String: Any], let sample = AIUsageSample.parse(values, backend: backend) { usage.merge(sample) }
            if backend == .claude {
                if let message = event["message"] as? [String: Any], let values = message["usage"] as? [String: Any], let sample = AIUsageSample.parse(values, backend: backend) { usage.merge(sample) }
                if event["type"] as? String == "content_block_start", let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                    guard structured, toolIndex == nil, let index = event["index"] as? Int else { throw AIModelError.invalidReply }
                    toolIndex = index; toolName = block["name"] as? String ?? ""; toolID = block["id"] as? String ?? ""
                    if let input = block["input"] as? [String: Any], !input.isEmpty { toolArguments = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self) }
                }
                if event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta" {
                    guard structured, !toolStopped, let index = event["index"] as? Int, index == toolIndex else { throw AIModelError.invalidReply }
                    toolArguments += delta["partial_json"] as? String ?? ""
                }
                if event["type"] as? String == "content_block_stop", let index = event["index"] as? Int, index == toolIndex { toolStopped = true }
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { finishReason = reason }
                if event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" { text += delta["text"] as? String ?? "" }
                if event["type"] as? String == "message_stop" { guard ["end_turn", "stop_sequence", "tool_use"].contains(finishReason) else { throw AIModelError.incompleteStream }; completed = true }
                if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "max_tokens" { throw AppFailure.message("Answer reached its length limit / 回答达到长度上限") }
            } else {
                let choices = event["choices"] as? [[String: Any]] ?? []
                guard choices.count <= 1 else { throw AIModelError.invalidReply }
                if let choice = choices.first {
                    if let index = choice["index"] as? Int, index != 0 { throw AIModelError.invalidReply }
                    if !finishReason.isEmpty, let delta = choice["delta"] as? [String: Any], !delta.isEmpty { throw AIModelError.invalidReply }
                    if let calls = (choice["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] {
                        guard structured, finishReason.isEmpty else { throw AIModelError.invalidReply }
                        for call in calls {
                            guard call["index"] as? Int == 0, (call["type"] as? String ?? "function") == "function" else { throw AIModelError.invalidReply }
                            toolIndex = 0
                            if let id = call["id"] as? String { toolID += id }
                            if let function = call["function"] as? [String: Any] {
                                toolName += function["name"] as? String ?? ""
                                toolArguments += function["arguments"] as? String ?? ""
                            }
                        }
                    }
                    text += (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
                    if choice["finish_reason"] as? String == "length" { throw AppFailure.message("Answer reached its length limit / 回答达到长度上限") }
                    if let reason = choice["finish_reason"] as? String {
                        guard ["stop", "length", "tool_calls"].contains(reason) else { throw AppFailure.message("Unexpected provider completion / 服务返回了非预期结束状态") }
                        finishReason = reason
                    }
                }
            }
            guard text.utf8.count <= 2 * 1024 * 1024, toolArguments.utf8.count <= 180_000 else { throw AppFailure.message("Answer too large / 回答过大") }
        }
    }
    func result() throws -> String {
        guard completed else { throw AIModelError.incompleteStream }
        if structured {
            guard toolName == AIStructuredReply.toolName, !toolID.isEmpty, toolIndex != nil,
                  ["tool_calls", "tool_use"].contains(finishReason), finishReason != "tool_use" || toolStopped else { throw AIModelError.invalidReply }
            return try AIStructuredReply.decode(toolArguments).serialized()
        }
        guard toolIndex == nil, ["stop", "end_turn", "stop_sequence"].contains(finishReason), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIModelError.incompleteStream }
        return text
    }
}

enum CodexReplyError: Error { case empty }

struct CodexAnswerStream {
    var allowAxonTool = false
    var usage: AIUsageSample?
    var text = ""
    var completed = false
    mutating func event(_ event: [String: Any]) throws {
        if let error = event["error"] as? [String: Any] { throw AppFailure.message(AIContext.sanitize(error["message"] as? String ?? "Codex request failed")) }
        let method = event["method"] as? String ?? "", params = event["params"] as? [String: Any] ?? [:]
        if method == "thread/tokenUsage/updated", let tokens = params["tokenUsage"] as? [String: Any], let last = tokens["last"] as? [String: Any] { usage = AIUsageSample.parse(last, backend: .codex) }
        if method == "error", params["willRetry"] as? Bool != true { throw AppFailure.message(AIContext.sanitize(String(describing: params["error"] ?? "Codex stream failed"))) }
        if method == "item/agentMessage/delta" { text += params["delta"] as? String ?? "" }
        if ["item/started", "item/completed"].contains(method), let item = params["item"] as? [String: Any], let type = item["type"] as? String {
            guard ["userMessage", "agentMessage", "reasoning"].contains(type) || (allowAxonTool && type == "dynamicToolCall") else { throw AppFailure.message("Unexpected Codex tool output / Codex 返回了非预期工具输出") }
            if method == "item/completed", type == "agentMessage" { takeMessage(item) }
        }
        if method == "turn/completed" {
            guard let turn = params["turn"] as? [String: Any] else { throw AppFailure.message("Invalid Codex completion / Codex 结束响应无效") }
            guard turn["status"] as? String == "completed" else {
                let detail = (turn["error"] as? [String: Any])?["message"] as? String
                throw AppFailure.message("Codex turn failed or stopped / Codex 回答失败或已停止" + (detail.map { "：" + AIContext.sanitize($0) } ?? ""))
            }
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "agentMessage" { takeMessage(item) }
                else if let type = item["type"] as? String, !["userMessage", "reasoning"].contains(type), !(allowAxonTool && type == "dynamicToolCall") { throw AppFailure.message("Unexpected Codex tool output / Codex 返回了非预期工具输出") }
            }
            completed = true
        }
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw AppFailure.message("Answer too large / 回答过大") }
    }
    private mutating func takeMessage(_ item: [String: Any]) {
        // Some completions carry only the turn snapshot; an empty snapshot must
        // never erase text already received from public message deltas.
        if let value = item["text"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = value }
    }
    func result() throws -> String {
        guard completed else { throw AppFailure.message("Codex answer incomplete / Codex 回答尚未完成") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CodexReplyError.empty }
        return text
    }

}
