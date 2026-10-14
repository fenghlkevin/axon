import SwiftUI
import Citadel

/// Authenticates without opening a shell or persisting the host draft.
@MainActor enum SSHConnectionTest {
    static func run(host: Host, material: Secrets.Value?, store: AppStore) async throws {
        let authentication = TerminalSession(host: host, store: store)
        var chain = [host], seen: Set<UUID> = [host.id]
        var current = store.resolvedHost(host)
        while let id = current.jumpHostID {
            guard seen.insert(id).inserted, chain.count < 16,
                  let hop = store.workspace.hosts.first(where: { $0.id == id }) else {
                throw AppFailure.message(store.text("Invalid jump route", "跳板路线无效"))
            }
            current = store.resolvedHost(hop); chain.insert(hop, at: 0)
        }
        var clients: [SSHClient] = []
        do {
            for hop in chain {
                try Task.checkCancellation()
                let settings = try authentication.settings(for: hop, draftMaterial: hop.id == host.id ? material : nil, useDraftHost: hop.id == host.id)
                let client: SSHClient
                if let parent = clients.last { client = try await parent.jump(to: settings) }
                else { client = try await SSHClient.connect(to: settings) }
                clients.append(client)
            }
            try Task.checkCancellation()
        } catch {
            for client in clients.reversed() { try? await client.close() }
            throw error
        }
        for client in clients.reversed() { try? await client.close() }
    }
}

struct SSHConnectionTestControl: View {
    @EnvironmentObject var store: AppStore
    let host: Host
    let material: Secrets.Value?
    @State private var running = false
    @State private var result = ""
    @State private var succeeded = false
    @State private var showingResult = false
    @State private var revision = 0
    var body: some View {
        SSHConnectionTestButton(running: running, succeeded: succeeded, chinese: store.chinese) {
            guard !running else { return }
            running = true; succeeded = false
            let snapshot = host, credentials = material
            let requestRevision = revision
            Task { @MainActor in
                defer { running = false }
                do {
                    try await SSHConnectionTest.run(host: snapshot, material: credentials, store: store)
                    guard revision == requestRevision else { return }
                    succeeded = true
                } catch {
                    guard revision == requestRevision else { return }
                    succeeded = false; result = error.localizedDescription
                    showingResult = true
                }
            }
        }
            .accessibilityIdentifier("axon-host-test-connection")
            .onChange(of: host) { _, _ in invalidate() }
            .onChange(of: material?.secret) { _, _ in invalidate() }
            .onChange(of: material?.privateKey) { _, _ in invalidate() }
            .onChange(of: store.workspace.credentials) { _, _ in invalidate() }
            .onChange(of: store.workspace.groupDefaults) { _, _ in invalidate() }
            .onChange(of: store.workspace.hosts) { _, _ in invalidate() }
            .alert(store.text("Connection test failed", "连接测试失败"), isPresented: $showingResult) {
                Button(store.text("OK", "好"), role: .cancel) {}
            } message: { Text(result) }
    }
    private func invalidate() { revision += 1; succeeded = false; showingResult = false }
}

struct SSHConnectionTestButton: View {
    let running: Bool
    let succeeded: Bool
    let chinese: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.small) }
                else { Image(systemName: succeeded ? "checkmark.circle.fill" : "network") }
                Text(running ? (chinese ? "测试中…" : "Testing…") : succeeded ? (chinese ? "测试通过" : "Test passed") : (chinese ? "连接测试" : "Test connection"))
            }
        }.buttonStyle(ChromeButtonStyle(prominent: succeeded, accentColor: succeeded ? .green : nil)).disabled(running)
    }
}
