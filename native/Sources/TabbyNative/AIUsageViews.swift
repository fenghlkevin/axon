import SwiftUI

struct AIUsageBudgetFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var policy: AIExecutionPolicy
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.text("Task resource limits · optional", "每任务资源限额 · 可选")).font(.system(size: 12, weight: .semibold))
            AIResourceNumberField(value: Binding(get: { policy.tokenBudget.map(Double.init) }, set: { policy.tokenBudget = $0.map { Int($0) } }), placeholder: store.text("Token limit · blank means unlimited", "Token 限额 · 留空不限"), integer: true).frame(maxWidth: 360).accessibilityIdentifier("axon-ai-token-budget")
            AIResourceNumberField(value: $policy.costBudgetUSD, placeholder: store.text("Estimated USD limit · blank means unlimited", "估算费用美元限额 · 留空不限")).frame(maxWidth: 360).accessibilityIdentifier("axon-ai-cost-budget")
            Text(store.text("Checked after each response and before the next request or action. An in-flight response may exceed the limit. Missing usage pauses a budgeted task; estimates are not billing limits.", "每次响应后及下一次请求或操作前检查；正在进行的响应可能超过限额。设有预算但用量缺失时暂停任务。估算限额不是账单硬上限。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}
struct AIUsagePricingFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var settings: AISettings
    private var model: String { settings.backend == .codex ? settings.codexModel : settings.provider.model }
    private var matched: Bool { settings.usagePricing?.backend == settings.backend && settings.usagePricing?.model == model }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.text("Usage and cost estimation", "用量与费用估算")).font(.system(size: 14, weight: .semibold))
            Toggle(store.text("Set prices for this model", "为当前模型填写单价"), isOn: Binding(get: { matched }, set: { settings.usagePricing = $0 ? AIUsagePricing(backend: settings.backend, model: model) : nil })).toggleStyle(.switch).disabled(model.isEmpty)
            if matched {
                Text(model).font(.system(size: 12)).textSelection(.enabled)
                price(store.text("Input · USD / million tokens", "输入 · 美元 / 百万 Token"), \.inputUSD)
                price(store.text("Output · USD / million tokens", "输出 · 美元 / 百万 Token"), \.outputUSD)
                price(store.text("Cached input", "缓存读取"), \.cachedUSD)
                price(store.text("Cache creation", "缓存写入"), \.cacheWriteUSD)
            }
            Text(store.text("Uses provider-reported tokens and your prices. Reasoning is included in output; cached input is not counted twice. CLI subscriptions, discounts and tool/service charges are not invoices and cannot be inferred.", "使用服务返回的 Token 与您填写的单价。推理包含在输出中，缓存输入不重复计费。CLI 订阅、折扣及工具／服务收费无法据此推断，显示值不是账单。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(18).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func price(_ title: String, _ path: WritableKeyPath<AIUsagePricing, Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            AIResourceNumberField(value: Binding(get: { settings.usagePricing?[keyPath: path] }, set: { settings.usagePricing?[keyPath: path] = $0 ?? -1 }), placeholder: "0", allowsBlank: false).frame(maxWidth: 300)
        }
    }
}
struct AIUsageSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @ObservedObject var ai: AIAssistant
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(store.text("Task usage", "任务用量")).font(.system(size: 18, weight: .semibold)); Spacer(); Button(store.text("Done", "完成")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary(ai.usage)
                    ForEach(ai.usage.calls.reversed()) { call in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(call.backend.title + " · " + (call.model.isEmpty ? store.text("CLI default", "CLI 默认模型") : call.model)).font(.system(size: 12, weight: .semibold))
                            Text(call.sample.known ? "\(call.sample.input!) / \(call.sample.output!) " + store.text("input / output tokens", "输入 / 输出 Token") : store.text("Usage not fully provided", "未完整提供用量")).font(.system(size: 12))
                            Text(call.cost.map { String(format: "$%.6f", $0) } ?? store.text("Unpriced", "未定价")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Text(call.date.formatted() + " · " + (call.status == "completed" ? store.text("Response complete", "响应完成") : call.status == "failed" ? store.text("Response failed", "响应失败") : store.text("Receiving", "接收中"))).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(store.text("Recent 200 requests are listed; older totals remain in the task. History retains usage. New tasks start a new ledger. Estimates exclude external tool charges.", "列出最近 200 次请求，更早累计仍计入任务。会话历史保留用量，新任务重新统计。估算不包含外部工具收费。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }.padding(20).frame(minWidth: 420, idealWidth: 580, minHeight: 360, idealHeight: 620).background(Palette.sidebar)
    }
    private func summary(_ ledger: AIUsageLedger) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.text("Requests", "请求") + ": \(ledger.requests) · " + store.text("Reported token subtotal", "已知 Token 小计") + ": \(ledger.tokens.total)")
            Text(store.text("Input / output", "输入 / 输出") + ": \(ledger.tokens.input ?? 0) / \(ledger.tokens.output ?? 0)")
            Text(store.text("Cache read / creation / reasoning", "缓存读取 / 写入 / 推理") + ": \(ledger.tokens.cached ?? 0) / \(ledger.tokens.cacheWrite ?? 0) / \(ledger.tokens.reasoning ?? 0)")
            Text(store.text("Estimated priced subtotal", "已定价估算小计") + ": " + String(format: "$%.6f", ledger.cost))
            Text(store.text("Incomplete usage / unpriced requests", "用量不完整 / 未定价请求") + ": \(ledger.unknown) / \(ledger.unpriced)").foregroundStyle(Palette.muted)
            if let cap = ai.settings.policy.tokenBudget { Text(store.text("Token limit", "Token 限额") + ": \(cap)") }
            if let cap = ai.settings.policy.costBudgetUSD { Text(store.text("Estimated USD limit", "估算美元限额") + ": \(cap)") }
            if ledger.unreportedHistory == true { Text(store.text("This older task has unrecorded usage; historical cost is unknown.", "此旧版任务有未记录的历史用量，历史费用未知。")).foregroundStyle(Palette.muted) }
            if ledger.requests == 0 && ledger.unreportedHistory != true { Text(store.text("No model requests yet", "尚无模型请求")).foregroundStyle(Palette.muted) }
        }.font(.system(size: 12)).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Keep partial decimal input editable while validation rejects an incomplete draft.
struct AIResourceNumberField: View {
    @Binding var value: Double?
    let placeholder: String
    var integer = false
    var allowsBlank = true
    @State private var text = ""
    private func number(_ raw: String) -> Double? {
        if raw.isEmpty && allowsBlank { return nil }
        let parsed = integer ? Int(raw).map(Double.init) : Double(raw)
        return parsed?.isFinite == true ? parsed : -1
    }
    var body: some View {
        TextField(placeholder, text: $text).appInput()
            .onAppear { text = value.map { integer ? String(Int($0)) : String($0) } ?? "" }
            .onChange(of: text) { _, raw in value = number(raw) }
            .onChange(of: value) { _, next in
                if number(text) != next { text = next.map { integer ? String(Int($0)) : String($0) } ?? "" }
            }
    }
}
