import Foundation

struct AIPlanExecution: Codable, Equatable {
    var selected: [String] = []
    var active: String?
    var paused = false
    func validate(_ plan: AIAgentPlan) throws {
        guard !selected.isEmpty, Set(selected).count == selected.count,
              Set(selected).isSubset(of: Set(plan.items.map(\.id))), active == nil || selected.contains(active!) else { throw AIModelError.invalidReply }
    }
    mutating func begin(_ id: String, plan: AIAgentPlan) throws {
        try validate(plan)
        guard !paused, selected.contains(id), let item = plan.items.first(where: { $0.id == id }), !["completed", "cancelled"].contains(item.status),
              (item.dependencies ?? []).allSatisfy({ dependency in plan.items.first { $0.id == dependency }?.status == "completed" }) else {
            throw AppFailure.message("Stage is not selected, paused, completed or has unfinished dependencies. / 阶段未选中、已暂停/完成或存在未完成依赖。")
        }
        active = id
    }
    func allowsMutation(_ plan: AIAgentPlan?) -> Bool {
        guard !paused, let plan, (try? validate(plan)) != nil, let active,
              let item = plan.items.first(where: { $0.id == active }), !["completed", "cancelled"].contains(item.status) else { return false }
        return (item.dependencies ?? []).allSatisfy { id in plan.items.first { $0.id == id }?.status == "completed" }
    }
    func accepts(_ next: AIAgentPlan, previous: AIAgentPlan, unverified: Bool) -> Bool {
        guard (try? validate(next)) != nil else { return false }
        for item in next.items {
            if !selected.contains(item.id), let old = previous.items.first(where: { $0.id == item.id }), old.status != item.status { return false }
            if item.status == "running" && item.id != active { return false }
            if item.status == "completed", previous.items.first(where: { $0.id == item.id })?.status != "completed", item.id != active || unverified { return false }
        }
        return true
    }
    func complete(_ plan: AIAgentPlan) -> Bool { selected.allSatisfy { id in plan.items.first { $0.id == id }?.status == "completed" } }
    var prompt: String { "Application-selected stages: " + selected.joined(separator: ", ") + ". Before actions call begin_plan_step with a selected ID. Active: " + (active ?? "none") + ". Do not execute unselected stages. Dependencies must be completed. Stage status is advisory, never acceptance evidence.\n" }
}

extension AIAgentPlan {
    struct Difference: Identifiable { var id: String; var before: Item?; var after: Item? }
    func differences(from old: Self) -> [Difference] {
        let ids = old.items.map(\.id) + items.map(\.id).filter { id in !old.items.contains { $0.id == id } }
        return ids.compactMap { id in
            let before = old.items.first { $0.id == id }, after = items.first { $0.id == id }
            return before == after && old.items.firstIndex(where: { $0.id == id }) == items.firstIndex(where: { $0.id == id }) ? nil : Difference(id: id, before: before, after: after)
        }
    }
}
