import SwiftUI

struct AITerminalControlView: View {
    @EnvironmentObject var store: AppStore
    let session: TerminalSession
    @ObservedObject var control: AITerminalControl
    @State private var programsPresented = false
    init(session: TerminalSession) { self.session = session; control = session.aiControl }
    var body: some View {
        HStack(spacing: 8) {
            Text(control.mode == .agent ? store.text("AI controls terminal", "AI 控制终端") : control.mode == .human ? store.text("Human control", "人工控制") : store.text("Terminal monitoring", "终端监控"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
            if control.mode == .agent {
                Button(store.text("Take over", "人工接管")) { control.takeover(); store.takeOverAI(sessionID: session.id) }
                    .buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-terminal-takeover")
            } else if store.ai.canResume && session.connected {
                Button(store.text("Hand back", "交回 AI")) { store.ai.resume(executor: AICommandExecutor(session: session, policy: store.ai.settings.policy)) }
                    .buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-terminal-handback")
            }
            Button { programsPresented = true } label: { Image(systemName: "terminal").help(store.text("Running programs", "运行程序")) }
                .buttonStyle(IconButtonStyle()).accessibilityIdentifier("axon-terminal-programs")
        }.padding(.horizontal, 16).padding(.vertical, 8)
        .sheet(isPresented: $programsPresented) { AIProgramsView().environmentObject(store) }
    }
}
struct AIProgramsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Terminal programs", "终端程序")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }
            Text(store.text("Stopping AI leaves programs running in their original terminal. Disconnecting ends monitoring.", "停止 AI 后程序可在原终端继续运行；连接断开后不再监控。"))
                .font(.caption).foregroundStyle(Palette.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.sessions) { session in AIProgramRows(session: session).environmentObject(store) }
                    if store.sessions.allSatisfy({ $0.aiControl.programs.isEmpty }) { Text(store.text("No managed programs", "暂无已记录程序")).foregroundStyle(Palette.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(minWidth: 300, idealWidth: 600, minHeight: 320, idealHeight: 500).background(Palette.background)
    }
}
struct AIProgramRows: View {
    @EnvironmentObject var store: AppStore
    let session: TerminalSession
    @ObservedObject var control: AITerminalControl
    @State private var failure = ""
    init(session: TerminalSession) { self.session = session; control = session.aiControl }
    private func status(_ program: AITerminalControl.Program) -> String {
        if let code = program.exitCode { return store.text("Finished · exit \(code)", "已结束 · 退出码 \(code)") }
        switch program.state {
        case "human": return store.text("Human control", "人工接管")
        case "background": return store.text("Continues in terminal", "在终端继续运行")
        case "running", "starting": return store.text("Running", "运行中")
        case "disconnected": return store.text("Disconnected · state unknown", "连接断开 · 状态未知")
        default: return store.text("Completion unknown", "结束状态未知")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(control.programs.reversed()) { program in
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.displayTitle).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(program.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text((program.startedByAgent ? "AI · " : store.text("Human · ", "人工 · ")) + status(program)).font(.caption).foregroundStyle(Palette.muted)
                    if !program.output.isEmpty { DisclosureGroup(store.text("Output", "输出")) { Text(program.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) } }
                    if program.active, let record = store.ai.taskRecords.first(where: { $0.id == program.owner }) {
                        Button(store.text("Hand back to AI", "交回 AI 继续")) {
                            store.activeSession = session.id; store.prepareTerminalAI(); store.ai.restoreTask(record)
                            store.ai.resume(executor: AICommandExecutor(session: session, policy: store.ai.settings.policy))
                        }.buttonStyle(ChromeButtonStyle()).disabled(store.ai.busy || !session.connected)
                    }
                    HStack {
                        Button(store.text("Show terminal", "打开终端")) { store.activeSession = session.id; store.aiAnalysisPresented = false }
                            .buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-program-show-terminal")
                        Button(store.text("Interrupt", "中断程序")) {
                            Task { do { try await control.interrupt(program.id, session: session) } catch { failure = error.localizedDescription } }
                        }.buttonStyle(ChromeButtonStyle()).disabled(!control.canInterrupt(program.id, session: session) || store.ai.busy)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !failure.isEmpty { Text(failure).foregroundStyle(.red).font(.caption) }
        }.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in control.refresh(session) }
    }
}
