import SwiftUI

/// Named presets contain configuration only. Secrets remain in provider Keychain entries.
struct AIAgentProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var backend: AIBackend
    var claude: AIProviderSettings
    var chatgpt: AIProviderSettings
    var codexPath: String
    var codexModel: String
    var codexReasoningEffort: String?
    var codexServiceTier: String?
    var codexNodePath: String?
    var agentRuntime: AIAgentRuntime?
    var usagePricing: AIUsagePricing?
    var mcpServers: [AIMCPServer]?
    var policy: AIExecutionPolicy
    var globalInstructions: String?
    var projectInstructionsEnabled: Bool?
    var skillsEnabled: Bool?
    var skillRoots: [String]?
    init(name: String, settings: AISettings) {
        self.name = name; backend = settings.backend; claude = settings.claude; chatgpt = settings.chatgpt
        codexPath = settings.codexPath; codexModel = settings.codexModel; codexReasoningEffort = settings.codexReasoningEffort
        codexServiceTier = settings.codexServiceTier; codexNodePath = settings.codexNodePath; policy = settings.policy
        usagePricing = settings.usagePricing; mcpServers = settings.mcpServers
        agentRuntime = settings.agentRuntime
        skillsEnabled = settings.skillsEnabled; skillRoots = settings.skillRoots
        globalInstructions = settings.globalInstructions; projectInstructionsEnabled = settings.projectInstructionsEnabled
    }
    func applying(to value: AISettings) -> AISettings {
        var value = value
        value.backend = backend; value.claude = claude; value.chatgpt = chatgpt
        value.codexPath = codexPath; value.codexModel = codexModel; value.codexReasoningEffort = codexReasoningEffort
        value.codexServiceTier = codexServiceTier; value.codexNodePath = codexNodePath; value.executionPolicy = policy
        value.usagePricing = usagePricing; value.mcpServers = mcpServers
        value.agentRuntime = agentRuntime
        value.skillsEnabled = skillsEnabled; value.skillRoots = skillRoots
        value.globalInstructions = globalInstructions; value.projectInstructionsEnabled = projectInstructionsEnabled; value.selectedProfileID = id
        return value
    }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              (globalInstructions?.utf8.count ?? 0) <= 16000 else { throw AppFailure.message("Invalid agent profile / 代理配置无效") }
        try usagePricing?.validate(); try AIMCPServer.validate(mcpServers ?? [])
        try policy.validate(); try AISkills.validateRoots(skillRoots)
    }
}

struct AIAgentProfileFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var draft: AISettings
    var busy: Bool
    @State private var name = ""
    private var selection: Binding<String> {
        Binding(get: { draft.selectedProfileID?.uuidString ?? "current" }, set: { value in
            if let profile = draft.agentProfiles?.first(where: { $0.id.uuidString == value }) { draft = profile.applying(to: draft); name = profile.name }
            else { draft.selectedProfileID = nil; name = "" }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.text("AI settings presets", "AI 设置预设")).font(.system(size: 14, weight: .semibold))
            Text(store.text("Save a set of AI settings and switch between tasks, such as read-only diagnosis and development.", "将一套 AI 设置存成预设，方便在只读诊断、开发等任务之间切换。")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(store.text("Current preset", "当前预设")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            AxonChoiceField(selection: selection, choices: [("current", store.text("Unsaved settings", "未使用预设"))] + (draft.agentProfiles ?? []).map { ($0.id.uuidString, $0.name) }, placeholder: store.text("Choose preset", "选择预设"), symbol: "person.crop.rectangle.stack", identifier: "axon-ai-profile-choice").frame(maxWidth: 360).disabled(busy)
            TextField(store.text("Preset name, e.g. Read-only diagnosis", "预设名称，例如：只读诊断"), text: $name).appInput().frame(maxWidth: 360).disabled(busy).accessibilityIdentifier("axon-ai-profile-name")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            Text(store.text("Configure the settings below, enter a name, then save a preset. Choosing a preset applies its service, model, permissions, resource limits, prices, MCP configuration and guidance. After editing settings, use Update preset to replace the saved copy. API keys stay in Keychain.", "先调整下方设置，输入名称后保存预设；选择预设即可应用其中的服务、模型、权限、资源限额、单价、MCP 配置和指引。修改下方设置会自动生效，点击「更新预设」才会覆盖已存的预设。API Key 单独保存在钥匙串。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
            .onAppear { name = draft.agentProfiles?.first(where: { $0.id == draft.selectedProfileID })?.name ?? "" }
    }
    private var actions: some View {
        Group {
            Button(store.text("Save preset", "保存为新预设")) {
                let profile = AIAgentProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: draft)
                guard (try? profile.validate()) != nil else { return }
                var profiles = draft.agentProfiles ?? []; profiles.append(profile); draft.agentProfiles = profiles; draft.selectedProfileID = profile.id
            }.buttonStyle(ChromeButtonStyle()).disabled(busy || !validName || (draft.agentProfiles?.count ?? 0) >= 20).accessibilityIdentifier("axon-ai-profile-add")
            Button(store.text("Update preset", "更新预设")) {
                guard let index = draft.agentProfiles?.firstIndex(where: { $0.id == draft.selectedProfileID }), let id = draft.selectedProfileID else { return }
                var profile = AIAgentProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: draft); profile.id = id; draft.agentProfiles?[index] = profile
            }.buttonStyle(ChromeButtonStyle()).disabled(busy || !validName || draft.selectedProfileID == nil).accessibilityIdentifier("axon-ai-profile-update")
            Button(store.text("Delete preset", "删除预设"), role: .destructive) {
                draft.agentProfiles?.removeAll { $0.id == draft.selectedProfileID }; draft.selectedProfileID = nil; name = ""
            }.buttonStyle(ChromeButtonStyle()).disabled(busy || draft.selectedProfileID == nil).accessibilityIdentifier("axon-ai-profile-delete")
        }
    }
    private var validName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 }
}
