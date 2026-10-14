import SwiftUI

/// Optional fields preserve the behavior of older saved profiles.
enum AIToolPermission: String, Codable, CaseIterable {
    case inherit, ask, allow, deny
}
enum AIToolCategory: String, Codable, CaseIterable {
    case filesRead, filesWrite, commands, terminal, web, mcp
    static func category(for tool: String) -> Self? {
        switch tool {
        case "read_file", "read_configuration", "list_directory", "read_file_range", "search_files", "search_text", "project_context", "read_skill": return .filesRead
        case "replace_file", "replace_files": return .filesWrite
        case "command", "verify_command", "terminal_execute": return .commands
        case "mcp_call": return .mcp
        case "fetch_url", "web_search": return .web
        default: return tool.hasPrefix("terminal_") ? .terminal : .commands
        }
    }
    @MainActor func title(_ store: AppStore) -> String {
        switch self {
        case .filesRead: return store.text("Read and search files", "读取与检索文件")
        case .filesWrite: return store.text("Apply file changes", "应用文件修改")
        case .commands: return store.text("Execute commands and checks", "执行命令与检查")
        case .terminal: return store.text("Interact with running terminals", "交互运行中的终端")
        case .mcp: return store.text("Selected MCP tools", "已选择的 MCP 工具")
        case .web: return store.text("Fetch pages and search the web", "读取网页与公开搜索")
        }
    }
}
struct AIToolPermissionFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var policy: AIExecutionPolicy
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.text("Tool permissions", "工具权限")).font(.system(size: 12, weight: .semibold))
            ForEach(AIToolCategory.allCases, id: \.self) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title(store)).foregroundStyle(Palette.muted)
                    AxonChoiceField(selection: Binding(get: { policy.toolPermission(category) }, set: { value in
                        var permissions = policy.toolPermissions ?? [:]
                        if value == .inherit { permissions.removeValue(forKey: category.rawValue) } else { permissions[category.rawValue] = value }
                        policy.toolPermissions = permissions.isEmpty ? nil : permissions
                    }), choices: AIToolPermission.allCases.map { ($0, title($0)) }, placeholder: category.title(store), symbol: "lock.shield", identifier: "axon-ai-tool-" + category.rawValue).frame(maxWidth: 360)
                }
            }
            Text(store.text("Saved with presets. Never overrides allow rules; Always ask cannot be skipped by remembered approval. Approve every time still asks. Built-in prohibitions and system/server deny rules always win. Web attachments are explicitly requested context but still obey Never. MCP also obeys per-server permissions.", "随预设保存。「禁止」优先于允许规则；「始终确认」不能被已记住的批准跳过。「每次批准」仍逐次确认。内置禁止及系统／服务器 deny 规则始终优先。主动添加的网页引用属于明确请求的上下文，仍遵守「禁止」。MCP 同时遵守逐服务权限。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
    private func title(_ value: AIToolPermission) -> String {
        switch value {
        case .inherit: return store.text("Use approval mode", "遵循批准模式")
        case .ask: return store.text("Always ask", "始终确认")
        case .allow: return store.text("Allow automatically", "自动允许")
        case .deny: return store.text("Never", "禁止")
        }
    }
}
