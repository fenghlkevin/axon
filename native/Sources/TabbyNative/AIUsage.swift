import Foundation
import CoreFoundation

struct AIUsageSample: Codable, Equatable {
    var input: Int?
    var output: Int?
    var cached: Int?
    var cacheWrite: Int?
    var reasoning: Int?
    var known: Bool { input != nil && output != nil }
    var total: Int { (input ?? 0) + (output ?? 0) }
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, (0...1_000_000_000).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
    static func parse(_ value: [String: Any], backend: AIBackend) -> Self? {
        if backend == .claude {
            let cached = count(value["cache_read_input_tokens"]), write = count(value["cache_creation_input_tokens"])
            let base = count(value["input_tokens"])
            let sample = Self(input: base.map { $0 + (cached ?? 0) + (write ?? 0) }, output: count(value["output_tokens"]), cached: cached, cacheWrite: write)
            return sample.input != nil || sample.output != nil ? sample : nil
        }
        let input = count(value[backend == .codex ? "inputTokens" : "prompt_tokens"])
        let output = count(value[backend == .codex ? "outputTokens" : "completion_tokens"])
        let cached = backend == .codex ? count(value["cachedInputTokens"]) : count((value["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
        let reasoning = backend == .codex ? count(value["reasoningOutputTokens"]) : count((value["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"])
        guard input != nil || output != nil, cached == nil || input == nil || cached! <= input!, reasoning == nil || output == nil || reasoning! <= output! else { return nil }
        return Self(input: input, output: output, cached: cached, cacheWrite: 0, reasoning: reasoning)
    }
    mutating func merge(_ other: Self) {
        // Provider updates within one request are cumulative. Duplicate or older
        // samples must never reduce a budget already accounted for.
        if let value = other.input { input = max(input ?? 0, value) }; if let value = other.output { output = max(output ?? 0, value) }
        if let value = other.cached { cached = max(cached ?? 0, value) }; if let value = other.cacheWrite { cacheWrite = max(cacheWrite ?? 0, value) }; if let value = other.reasoning { reasoning = max(reasoning ?? 0, value) }
    }
    mutating func add(_ other: Self) {
        if let value = other.input { input = (input ?? 0) + value }; if let value = other.output { output = (output ?? 0) + value }
        if let value = other.cached { cached = (cached ?? 0) + value }; if let value = other.cacheWrite { cacheWrite = (cacheWrite ?? 0) + value }; if let value = other.reasoning { reasoning = (reasoning ?? 0) + value }
    }
    func subtracting(_ previous: Self) -> Self? {
        guard known, previous.known, input! >= previous.input!, output! >= previous.output! else { return nil }
        return Self(input: input! - previous.input!, output: output! - previous.output!, cached: max(0, (cached ?? 0) - (previous.cached ?? 0)), cacheWrite: 0, reasoning: max(0, (reasoning ?? 0) - (previous.reasoning ?? 0)))
    }
}
struct AIUsagePricing: Codable, Equatable {
    var backend: AIBackend
    var model: String
    var inputUSD: Double = 0
    var outputUSD: Double = 0
    var cachedUSD: Double = 0
    var cacheWriteUSD: Double = 0
    func validate() throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 200,
              [inputUSD, outputUSD, cachedUSD, cacheWriteUSD].allSatisfy({ $0.isFinite && (0...100_000).contains($0) }) else { throw AppFailure.message("Choose a model and valid USD prices per million tokens / 请选择模型并填写有效的每百万 Token 美元单价") }
    }
    func cost(_ sample: AIUsageSample) -> Double? {
        guard sample.known else { return nil }
        let cached = sample.cached ?? 0, write = sample.cacheWrite ?? 0
        guard cached + write <= sample.input! else { return nil }
        return (Double(sample.input! - cached - write) * inputUSD + Double(sample.output!) * outputUSD + Double(cached) * cachedUSD + Double(write) * cacheWriteUSD) / 1_000_000
    }
}
struct AIUsageCall: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var backend: AIBackend
    var model: String
    var sample = AIUsageSample()
    var status = "pending"
    var pricing: AIUsagePricing?
    var cost: Double? { pricing?.cost(sample) }
    var accounted: Bool { status == "completed" && sample.known }
}
struct AIUsageLedger: Codable, Equatable {
    var calls: [AIUsageCall] = []
    var unreportedHistory: Bool?
    static func restored(_ entry: AITaskRecord) -> Self {
        if let ledger = entry.usage { return ledger }
        var ledger = Self(); ledger.unreportedHistory = true; return ledger
    }
    var archivedRequests = 0
    var archivedUnknown = 0
    var archivedTokens = AIUsageSample(input: 0, output: 0, cached: 0, cacheWrite: 0, reasoning: 0)
    var archivedCost: Double = 0
    var archivedUnpriced = 0
    var requests: Int { archivedRequests + calls.count }
    var unknown: Int { (unreportedHistory == true ? 1 : 0) + archivedUnknown + calls.filter { !$0.accounted }.count }
    var tokens: AIUsageSample { calls.reduce(archivedTokens) { result, call in var result = result; result.add(call.sample); return result } }
    var cost: Double { archivedCost + calls.compactMap(\.cost).reduce(0, +) }
    var unpriced: Int { (unreportedHistory == true ? 1 : 0) + archivedUnpriced + calls.filter { $0.cost == nil || !$0.accounted }.count }
    mutating func begin(_ settings: AISettings) -> UUID {
        let model = settings.backend == .codex ? settings.codexModel : settings.provider.model
        var call = AIUsageCall(backend: settings.backend, model: model)
        if let pricing = settings.usagePricing, pricing.backend == settings.backend, pricing.model == model { call.pricing = pricing }
        if calls.count >= 200 {
            let previous = calls.removeFirst(); archivedRequests += 1
            if !previous.accounted { archivedUnknown += 1 }
            archivedTokens.add(previous.sample); archivedCost += previous.cost ?? 0
            if previous.cost == nil || !previous.accounted { archivedUnpriced += 1 }
        }
        calls.append(call); return call.id
    }
    mutating func report(_ id: UUID, _ sample: AIUsageSample, incremental: Bool = false) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        if incremental { calls[index].sample.add(sample) } else { calls[index].sample.merge(sample) }
    }
    mutating func finish(_ id: UUID, success: Bool) { if let index = calls.firstIndex(where: { $0.id == id && $0.status == "pending" }) { calls[index].status = success ? "completed" : "failed" } }
    func check(_ settings: AISettings, before: Bool = false) throws {
        let policy = settings.policy
        if policy.tokenBudget != nil || policy.costBudgetUSD != nil, unknown > 0 { throw AIUsageLimitError.unknown }
        if let budget = policy.tokenBudget, tokens.total >= budget { throw AIUsageLimitError.tokens }
        if let budget = policy.costBudgetUSD {
            let model = settings.backend == .codex ? settings.codexModel : settings.provider.model
            guard let pricing = settings.usagePricing, pricing.backend == settings.backend, pricing.model == model, unpriced == 0 else { throw AIUsageLimitError.pricing }
            try pricing.validate()
            if cost >= budget { throw AIUsageLimitError.cost }
        }
    }
}
enum AIUsageLimitError: LocalizedError {
    case tokens, cost, unknown, pricing
    var errorDescription: String? {
        switch self {
        case .tokens: "Task token budget reached; no further model request or tool action / 已达到任务 Token 限额，暂停后续模型请求和工具操作"
        case .cost: "Task estimated cost budget reached; no further model request or tool action / 已达到任务估算费用限额，暂停后续模型请求和工具操作"
        case .unknown: "Usage was not fully reported; budget cannot be verified. Task paused / 服务未完整返回用量，无法核对预算，任务已暂停"
        case .pricing: "Set prices for the current model before using a cost budget; earlier unpriced usage cannot be assumed free / 费用预算需要当前模型的单价；历史未定价用量不能视为免费"
        }
    }
}
