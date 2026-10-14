import SwiftUI

struct AIMCPFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var settings: AISettings
    @ObservedObject var manager: AIMCPManager
    @State private var editing: AIMCPServer?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("MCP").font(.system(size: 14, weight: .semibold)); Spacer(); Button(store.text("Add server", "添加服务")) { editing = AIMCPServer() }.buttonStyle(ChromeButtonStyle()).disabled((settings.mcpServers?.count ?? 0) >= 8) }
            Text(store.text("Connect a trusted service, then select read-only tools. stdio is sandboxed without writes or network. HTTP relies on the service's read-only claim; connect only services you trust. Credentials stay in Keychain. No automatic connection or inherited CLI MCP.", "连接可信服务后，逐个选择只读工具。stdio 沙箱禁止写入和网络；HTTP 的只读声明由服务提供，请仅连接可信服务。凭据存入钥匙串；不会自动连接或继承 CLI 的 MCP。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            if settings.mcpServers?.isEmpty != false { Text(store.text("No MCP servers", "尚未配置 MCP 服务")).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            ForEach(settings.mcpServers ?? []) { server in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(server.name).font(.system(size: 12, weight: .semibold)).lineLimit(2); Spacer(); Button(store.text("Edit", "编辑")) { editing = server }.buttonStyle(ChromeButtonStyle()).disabled(manager.busy.contains(server.id)) }
                    Text(manager.status[server.id] ?? store.text("Disconnected", "未连接")).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    HStack { Button(store.text("Connect and list tools", "连接并列出工具")) { Task { await manager.connect(server) } }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-mcp-connect-" + server.id.uuidString).disabled(!server.enabled || manager.busy.contains(server.id)); Button(store.text("Disconnect", "断开")) { manager.disconnect(server.id) }.buttonStyle(ChromeButtonStyle()).disabled(manager.busy.contains(server.id)); if manager.busy.contains(server.id) { ProgressView().controlSize(.small) } }
                    ForEach(manager.tools[server.id] ?? []) { tool in
                        Toggle(isOn: Binding(get: { (settings.mcpServers?.first { $0.id == server.id }?.allowedTools ?? []).contains(tool.name) }, set: { value in
                            guard let index = settings.mcpServers?.firstIndex(where: { $0.id == server.id }) else { return }
                            settings.mcpServers?[index].allowedTools.removeAll { $0 == tool.name }; if value { settings.mcpServers?[index].allowedTools.append(tool.name) }
                        })) { VStack(alignment: .leading, spacing: 3) { Text(tool.name).font(.system(size: 12)); Text(tool.readOnly ? tool.description : store.text("Unavailable: no supported read-only declaration", "不可用：未提供受支持的只读声明")).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(3) } }.toggleStyle(AxonCheckboxStyle()).accessibilityIdentifier("axon-mcp-tool-" + tool.name).disabled(!tool.readOnly || manager.busy.contains(server.id))
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }.padding(18).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
            .sheet(item: $editing) { server in
                AIMCPServerSheet(server: server, save: { value in
                    var values = settings.mcpServers ?? []; values.removeAll { $0.id == value.id }; values.append(value); try AIMCPServer.validate(values); settings.mcpServers = values; manager.synchronize(values)
                }, remove: { settings.mcpServers?.removeAll { $0.id == server.id }; manager.disconnect(server.id) }).environmentObject(store)
            }
    }
}
struct AIMCPServerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var server: AIMCPServer
    let save: (AIMCPServer) throws -> Void
    let remove: () -> Void
    @State private var secret = ""
    @State private var args = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.text("MCP server", "MCP 服务")).font(.system(size: 18, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    field(store.text("Name", "名称"), $server.name)
                    AxonChoiceField(selection: $server.transport, choices: [(AIMCPServer.Transport.stdio, "stdio"), (.http, "Streamable HTTP")], placeholder: store.text("Transport", "传输方式"), symbol: "network", identifier: "axon-mcp-transport")
                    if server.transport == .stdio {
                        field(store.text("Executable · absolute path", "可执行文件 · 绝对路径"), $server.command)
                        field(store.text("Arguments · JSON string array", "参数 · JSON 字符串数组"), $args)
                        field(store.text("Project directory · absolute path", "项目目录 · 绝对路径"), $server.directory)
                        field(store.text("Credential environment variable", "凭据环境变量"), $server.secretEnvironment)
                    } else { field(store.text("MCP endpoint", "MCP 接口地址"), $server.endpoint) }
                    VStack(alignment: .leading, spacing: 4) { Text(store.text("Credential · blank keeps saved value", "凭据 · 留空保留已保存值")).font(.system(size: 12)).foregroundStyle(Palette.muted); SecureField("", text: $secret).appInput() }
                    Toggle(store.text("Enabled", "启用"), isOn: $server.enabled).toggleStyle(.switch)
                    AxonChoiceField(selection: $server.permission, choices: [(AIToolPermission.ask, store.text("Always ask", "始终确认")), (.allow, store.text("Follow Axon permissions", "遵循 Axon 权限")), (.deny, store.text("Never", "禁止"))], placeholder: store.text("Permission", "权限"), symbol: "lock.shield", identifier: "axon-mcp-permission")
                    Text(store.text("Saving does not start the server. Connect explicitly; tools must be selected after discovery. Configuration changes require reconnection. Arguments are literal, never a shell command.", "保存不会启动服务。手动连接后选择工具；连接配置改变后需重新连接。参数按字面传递，不作为 Shell 命令执行。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Palette.danger).textSelection(.enabled) }
                }
            }
            HStack {
                Button(store.text("Delete", "删除"), role: .destructive) { remove(); dismiss() }.buttonStyle(ChromeButtonStyle())
                Spacer(); Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Button(store.text("Save", "保存")) {
                    do {
                        if server.transport == .stdio { server.arguments = try JSONDecoder().decode([String].self, from: Data(args.utf8)) }
                        try server.validate()
                        if !secret.isEmpty { try Secrets.save(secret, id: server.id); server.credentialRevision += 1 }
                        try save(server); secret = ""; dismiss()
                    } catch { self.error = AIContext.sanitize(error.localizedDescription) }
                }.buttonStyle(ChromeButtonStyle(prominent: true)).accessibilityIdentifier("axon-mcp-save").keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 540, height: 640).background(Palette.sidebar).onAppear { args = String(decoding: (try? JSONEncoder().encode(server.arguments)) ?? Data("[]".utf8), as: UTF8.self) }
    }
    private func field(_ title: String, _ text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted); TextField("", text: text).appInput() } }
}
