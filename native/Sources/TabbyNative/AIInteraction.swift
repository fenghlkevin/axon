import Foundation

struct AIQueuedPrompt: Identifiable, Equatable {
    let id: UUID
    var text: String
    init(text: String) { id = UUID(); self.text = text }
}

/// Conversation control tools never enter the command executor or grant permissions.
struct AIClarification: Codable, Equatable {
    struct Question: Codable, Equatable {
        var question: String
        var options: [String]
        var multiple: Bool? = nil
    }
    var question: String
    var options: [String]
    var questions: [Question]? = nil
    var fields: [Question] { questions ?? [Question(question: question, options: options)] }
    var summary: String { fields.map(\.question).joined(separator: "\n") }
    static func decode(_ argument: String) throws -> Self {
        let data = Data(argument.utf8)
        guard data.count <= 12000 else { throw AIModelError.invalidReply }
        // Keep existing single-question calls compatible; batches need no legacy fields.
        struct Payload: Decodable { var question: String?; var options: [String]?; var questions: [Question]? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let value = Self(question: payload.question ?? "", options: payload.options ?? [], questions: payload.questions)
        guard (1...3).contains(value.fields.count), value.fields.allSatisfy({ field in
            !field.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && field.question.count <= 2000 && field.options.count <= 6 &&
            field.options.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 300 } && Set(field.options).count == field.options.count
        }) else { throw AIModelError.invalidReply }
        return value
    }
    func response(selections: [Int: Set<String>], text: [Int: String]) -> String? {
        var answers: [String] = []
        for (index, field) in fields.enumerated() {
            let selected = selections[index] ?? []
            guard selected.isSubset(of: Set(field.options)), field.multiple == true || selected.count <= 1 else { return nil }
            let free = (text[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = field.options.filter { selected.contains($0) } + (free.isEmpty ? [] : [free])
            guard !parts.isEmpty else { return nil }
            answers.append(fields.count == 1 ? parts.joined(separator: "; ") : "\(index + 1). \(field.question): " + parts.joined(separator: "; "))
        }
        let result = answers.joined(separator: "\n")
        return result.utf8.count <= 8000 ? result : nil
    }
}

struct AIAgentPlan: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var status: String
        var dependencies: [String]? = nil
    }
    var title: String
    var items: [Item]
    static func decode(_ argument: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(argument.utf8))
        guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.title.count <= 300, (1...20).contains(value.items.count),
              Set(value.items.map(\.id)).count == value.items.count,
              value.items.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 500 && ["pending", "running", "completed", "cancelled"].contains($0.status) }),
              value.items.filter({ $0.status == "running" }).count <= 1 else { throw AIModelError.invalidReply }
        let ids = Set(value.items.map(\.id))
        guard value.items.allSatisfy({ item in
            let deps = item.dependencies ?? []
            return deps.count <= 20 && Set(deps).count == deps.count && !deps.contains(item.id) && Set(deps).isSubset(of: ids)
        }) else { throw AIModelError.invalidReply }
        var resolved = Set<String>()
        for _ in 0..<value.items.count {
            for item in value.items where Set(item.dependencies ?? []).isSubset(of: resolved) { resolved.insert(item.id) }
        }
        guard resolved == ids else { throw AIModelError.invalidReply }
        return value
    }
}
