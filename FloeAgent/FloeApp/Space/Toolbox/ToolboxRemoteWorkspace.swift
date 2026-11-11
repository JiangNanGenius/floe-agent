// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeEnvironments
import FloeModels
import FloePersistence
import FloeSSH
import FloeToolboxCore
import FloeToolboxUI
import FloeVNC

private actor ToolboxMemorySessionRegistry: RemoteSessionRegistry {
    private var values: [UUID: RemoteSessionRecord] = [:]
    func upsert(_ value: RemoteSessionRecord) { values[value.id] = value }
    func session(id: UUID) -> RemoteSessionRecord? { values[id] }
    func sessions(hostID: UUID) -> [RemoteSessionRecord] { values.values.filter { $0.hostID == hostID } }
    func activeSessions() -> [RemoteSessionRecord] { Array(values.values) }
    func updateState(id: UUID, state: RemoteSessionRecord.State, lastHeartbeatAt: Date?) {
        values[id]?.state = state; values[id]?.lastHeartbeatAt = lastHeartbeatAt; values[id]?.updatedAt = Date()
    }
    func removeSession(id: UUID) { values[id] = nil }
}

@MainActor final class ToolboxRemoteCenter: ObservableObject {
    @Published private(set) var machines: [ToolboxMachineChoice] = []
    @Published private(set) var local: LocalTerminalOwner?
    @Published private(set) var localDisplay: LocalLinuxDisplayOwner?
    @Published private(set) var terminalID: UUID?
    @Published private(set) var vncID: UUID?
    @Published private(set) var temporarySSH: SSHSessionOwner?
    @Published private(set) var temporaryVNC: VNCSessionOwner?
    @Published private(set) var terminalSession: ToolboxTerminalSession?
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var revision: UInt64 = 0
    private weak var environment: AppEnvironment?
    private var rootLease: WorkspaceCenter.TaskRootLease?
    private var ownedVNC = false
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var localConversationID: UUID?
    init(environment: AppEnvironment) { self.environment = environment }
    func load() async {
        guard let environment else { return }
        await environment.remoteSessionCenter.loadHosts()
        let containers = await environment.environmentRegistry.all()
        var choices: [ToolboxMachineChoice] = []
        if containers.contains(where: { $0.id == EnvironmentRegistry.sharedContainerID && $0.state != .deleting }) {
            choices.append(.init(id: .builtIn(environmentID: EnvironmentRegistry.sharedContainerID),
                title: IDELanguageRunText.t("内置 Linux 环境", "Built-in Linux environment"), detail: "",
                supportsTerminal: true, supportsVNC: false))
        }
        for host in environment.remoteSessionCenter.hosts {
            choices.append(.init(id: host.isRemoteExecutionEnvironment ? .systemEnvironment(hostID: host.id) : .toolboxMachine(hostID: host.id),
                title: host.displayName.isEmpty ? host.address : host.displayName, detail: host.address,
                supportsTerminal: host.hasSSHConnection, supportsVNC: !host.vncEndpoints.isEmpty))
        }
        machines = choices
    }
    func select(_ machine: MachineReference, kind: ToolboxRemoteTargetKind) {
        begin { [weak self] token in
            guard let self, let environment = self.environment else { throw ToolboxError.staleSession }
            switch machine {
            case .builtIn(let environmentID):
                guard environmentID == EnvironmentRegistry.sharedContainerID, kind == .terminal else { throw ToolboxError.denied }
                let id = self.localConversationID ?? UUID(); self.localConversationID = id
                let now = Date()
                if try await environment.conversationStore.conversation(id: id) == nil {
                    try await environment.conversationStore.saveConversation(.init(id: id,
                        title: IDELanguageRunText.t("工具箱终端", "Toolbox terminal"), createdAt: now, updatedAt: now, titleOrigin: .manual))
                }
                let workspace = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id,
                    title: IDELanguageRunText.t("工具箱终端", "Toolbox terminal"))
                try await environment.conversationStore.setArchived(id: id, archived: true)
                let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: id)
                do { try self.check(token) } catch { lease.release(); throw error }
                self.rootLease = lease
                let owner = environment.localTerminals.owner(workspaceID: workspace.id, root: lease.url, conversationID: id)
                self.local = owner
                self.localDisplay = environment.localLinuxDisplays.owner(conversationID: id, workspaceRoot: lease.url)
                let capture = try await ToolboxTerminalSession.open(environment: environment, machine: machine,
                    title: IDELanguageRunText.t("内置 Linux", "Built-in Linux"), workingRoot: lease.url,
                    output: { [weak owner] in .init(bytes: owner?.output ?? Data(), byteEnd: owner?.outputEnd ?? 0, generation: owner?.outputGeneration ?? token) },
                    input: { [weak owner] data in guard let owner, owner.alive else { throw ToolboxError.staleSession }; owner.enqueue(data) })
                do { try self.check(token) } catch { await capture.close(); throw error }
                self.terminalSession = capture
            case .systemEnvironment(let hostID), .toolboxMachine(let hostID):
                guard let host = environment.remoteSessionCenter.hosts.first(where: { $0.id == hostID }) else { throw ToolboxError.staleSession }
                if kind == .terminal {
                    let id = try await environment.remoteSessionCenter.connectTerminal(to: host)
                    do { try self.check(token) } catch { await environment.remoteSessionCenter.disconnectTerminal(sessionID: id); throw error }
                    self.terminalID = id
                    let capture = try await ToolboxTerminalSession.open(environment: environment, machine: machine,
                        title: host.displayName.isEmpty ? IDELanguageRunText.t("SSH 终端", "SSH terminal") : host.displayName,
                        workingRoot: try ToolboxCaptureStore.exportsRoot().deletingLastPathComponent(), savedHostID: hostID,
                        output: { [weak environment] in .init(bytes: environment?.remoteSessionCenter.terminalOutput(for: id) ?? Data(), byteEnd: environment?.remoteSessionCenter.terminalOutputEnd(for: id) ?? 0, generation: id) },
                        input: { [weak environment] data in guard let environment else { throw ToolboxError.staleSession }; try await environment.remoteSessionCenter.send(data, to: id) },
                        sshHandle: { [weak environment] in environment?.remoteSessionCenter.toolboxSSHHandle(for: id) })
                    do { try self.check(token) } catch { await capture.close(); throw error }
                    self.terminalSession = capture
                }
                else {
                    let previous = Set(environment.remoteSessionCenter.sessions.keys)
                    let id = try await environment.remoteSessionCenter.connectVNC(to: host)
                    do { try self.check(token) } catch {
                        if !previous.contains(id) { await environment.remoteSessionCenter.disconnectVNC(sessionID: id) }; throw error
                    }
                    self.vncID = id; self.ownedVNC = !previous.contains(id)
                }
            case .temporary: throw ToolboxError.invalid("Use the native temporary connection form")
            }
        }
    }
    func temporary(address: String, port: String, user: String, secret: String, kind: ToolboxRemoteTargetKind) {
        begin { [weak self] token in
            guard let self, let environment = self.environment, let number = UInt16(port), number > 0 else { throw ToolboxError.invalid("port") }
            let registry = ToolboxMemorySessionRegistry(), sessionID = UUID(), hostID = UUID()
            if kind == .terminal {
                let reference = SecretReference(keychainAccount: "toolbox.temporary." + hostID.uuidString, synchronizable: false)
                let profile = RemoteHostProfile(id: hostID, displayName: address, address: address, port: Int(number), user: user,
                    auth: .password(reference), isRemoteExecutionEnvironment: false)
                let bytes = Data(secret.utf8)
                let handle = try await SSHConnectionService(hostStore: environment.remoteHostStore).connectTemporary(profile: profile,
                    credentialResolver: { requested in
                        guard requested == reference else { throw SSHConnectionError.invalidCredential }; return bytes
                    }, hostKeyDecision: { [weak environment] challenge in
                        await environment?.remoteSessionCenter.decideToolboxHostKey(challenge) ?? false
                    })
                do {
                    try Task.checkCancellation()
                    let pty = try await handle.openPTY()
                    await registry.upsert(.init(id: sessionID, hostID: hostID, kind: .sshTerminal, state: .connected))
                    try self.check(token)
                    let owner = SSHSessionOwner(sessionID: sessionID, hostID: hostID, registry: registry)
                    owner.onOutput = { [weak self] in self?.revision &+= 1 }
                    owner.onDisconnect = { [weak self] in self?.revision &+= 1 }
                    owner.attach(handle: handle, pty: pty)
                    self.temporarySSH = owner
                    let capture = try await ToolboxTerminalSession.open(environment: environment, machine: .temporary(connectionID: sessionID),
                        title: IDELanguageRunText.t("临时 SSH", "Temporary SSH"), workingRoot: try ToolboxCaptureStore.exportsRoot().deletingLastPathComponent(), knownSecrets: [bytes],
                        output: { [weak owner] in .init(bytes: owner?.output ?? Data(), byteEnd: owner?.outputEnd ?? 0, generation: sessionID) },
                        input: { [weak owner] data in guard let owner, owner.pty != nil else { throw ToolboxError.staleSession }; try await owner.send(data) },
                        sshHandle: { [weak owner] in owner?.handle })
                    do { try self.check(token) } catch { await capture.close(); throw error }
                    self.terminalSession = capture
                } catch { await handle.close(); throw error }
            } else {
                guard !address.isEmpty, address.utf8.count <= 253 else { throw ToolboxError.invalid("address") }
                let owner = VNCSessionOwner(sessionID: sessionID, hostID: hostID, endpointHost: address, endpointPort: Int(number), registry: registry)
                let session = VNCSession(host: address, port: number, password: secret.isEmpty ? nil : secret)
                owner.onStateChange = { [weak self] in self?.revision &+= 1 }
                owner.attach(session: session); self.temporaryVNC = owner; session.connect()
            }
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw ToolboxError.staleSession }
    }
    private func begin(_ work: @escaping @MainActor (UUID) async throws -> Void) {
        let token = UUID(); generation = token; operation?.cancel(); busy = true; failed = false
        operation = Task { [weak self] in
            guard let self, generation == token else { return }
            await closeHandles()
            do { try check(token); try await work(token); try check(token) }
            catch { if generation == token { failed = !(error is CancellationError); await closeHandles() } }
            guard generation == token else { return }; busy = false; operation = nil
        }
    }
    @discardableResult func closeNow() -> Task<Void, Never> {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        return detachHandles()
    }
    func close() async { await closeNow().value }
    private func closeHandles() async { await detachHandles().value }
    private func detachHandles() -> Task<Void, Never> {
        let terminal = terminalID, vnc = vncID, ownedVNC = ownedVNC
        let capture = terminalSession
        capture?.invalidate()
        if let capture { environment?.toolboxCenter.releaseTerminal(capture) }
        terminalSession = nil
        terminalID = nil; vncID = nil; self.ownedVNC = false
        let temporarySSH = temporarySSH, temporaryVNC = temporaryVNC, local = local, lease = rootLease
        self.temporarySSH = nil; self.temporaryVNC = nil; self.local = nil; rootLease = nil
        let remote = environment?.remoteSessionCenter
        return Task {
            await capture?.close()
            await temporarySSH?.disconnect(); await temporaryVNC?.disconnect(); await local?.close()
            if let terminal { await remote?.disconnectTerminal(sessionID: terminal) }
            if let vnc, ownedVNC { await remote?.disconnectVNC(sessionID: vnc) }
            lease?.release()
        }
    }
}

struct ToolboxRemoteWorkspace: View {
    let kind: ToolboxRemoteTargetKind
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View { ToolboxRemotePage(kind: kind, center: environment.toolboxRemote) }
}
private struct ToolboxRemotePage: View {
    let kind: ToolboxRemoteTargetKind
    @ObservedObject var center: ToolboxRemoteCenter
    @EnvironmentObject private var environment: AppEnvironment
    @State private var temporary = false
    @State private var settings = false
    @State private var address = ""
    @State private var port = ""
    @State private var user = ""
    @State private var secret = ""
    @State private var panel: TerminalSidePanel?
    @State private var expandedFiles = false
    var body: some View {
        Group {
            if kind == .terminal, let session = center.terminalSession {
                TerminalToolboxWorkspace(panel: $panel) { terminalSurface }
                    assistant: { ToolboxTerminalAssistantView(session: session) }
                    files: { ToolboxTerminalFilesView(session: session, expanded: false) { panel = nil; expandedFiles = true } }
                    .fullScreenCover(isPresented: $expandedFiles) {
                        NavigationStack {
                            ToolboxTerminalFilesView(session: session, expanded: true)
                                .navigationTitle(IDELanguageRunText.t("文件传输", "File transfer"))
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(IDELanguageRunText.t("返回终端", "Back to terminal")) { expandedFiles = false } } }
                        }
                    }
            }
            else if let id = center.vncID { VNCView(sessionID: id, center: environment.remoteSessionCenter) }
            else if let owner = center.temporaryVNC, let session = owner.session { VNCViewer(session: session) }
            else {
                ToolboxMachinePicker(kind: kind, machines: center.machines,
                    onSelect: { center.select($0, kind: kind) }, onTemporary: { temporary = true }, onSettings: { settings = true })
            }
        }
        .overlay(alignment: .bottom) {
            if center.busy { ProgressView().padding().background(.regularMaterial, in: Capsule()) }
            else if center.failed { Text(IDELanguageRunText.t("连接未完成，请检查配置后重试。", "Unable to connect. Check the configuration and retry.")).padding().background(.regularMaterial) }
        }
        .toolbar { Button(IDELanguageRunText.t("断开", "Disconnect")) { Task { await center.close() } } }
        .task { await center.load() }
        .sheet(isPresented: $settings, onDismiss: { Task { await center.load() } }) { NavigationStack { HostListView(center: environment.remoteSessionCenter) } }
        .sheet(isPresented: $temporary) {
            NavigationStack {
                Form {
                    TextField(IDELanguageRunText.t("地址或主机名", "Address or hostname"), text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(IDELanguageRunText.t("端口", "Port"), text: $port).keyboardType(.numberPad)
                    if kind == .terminal { TextField(IDELanguageRunText.t("用户名", "Username"), text: $user).textInputAutocapitalization(.never) }
                    SecureField(IDELanguageRunText.t("密码", "Password"), text: $secret)
                    Button(IDELanguageRunText.t("连接", "Connect")) {
                        center.temporary(address: address, port: port, user: user, secret: secret, kind: kind)
                        secret = ""; temporary = false
                    }.disabled(address.isEmpty || port.isEmpty || (kind == .terminal && user.isEmpty))
                }
                .navigationTitle(IDELanguageRunText.t("临时连接", "Temporary connection"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("取消", "Cancel")) { secret = ""; temporary = false } } }
            }.onAppear { if port.isEmpty { port = kind == .terminal ? "22" : "5900" } }
        }
        .sheet(item: Binding(get: { environment.remoteSessionCenter.pendingTrust }, set: { _ in })) { trust in
            HostKeyTrustSheet(challenge: trust.challenge) { environment.remoteSessionCenter.resolveTrust($0) }
        }
    }
    @ViewBuilder private var terminalSurface: some View {
        if let owner = center.local { LocalTerminalView(owner: owner, embedded: true, display: center.localDisplay) }
        else if let id = center.terminalID { TerminalView(sessionID: id, center: environment.remoteSessionCenter) }
        else if let owner = center.temporarySSH {
            VStack(spacing: 0) {
                TerminalControls(presentation: owner.presentation, interactive: owner.pty != nil) { data in Task { try? await owner.send(data) } }
                SSHEmulatorView(output: owner.output, byteEnd: owner.outputEnd, generation: owner.sessionID,
                    presentation: owner.presentation, isInteractive: owner.pty != nil,
                    onSend: { data in Task { try? await owner.send(data) } },
                    onResize: { columns, rows in Task { try? await owner.resize(columns: columns, rows: rows) } })
            }
        }
    }

}

struct ToolboxBrowserWorkspace: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var ownerID: UUID?
    @State private var failed = false
    var body: some View {
        Group {
            if ownerID != nil { BrowserView(center: environment.toolboxBrowser.center) }
            else if failed { ContentUnavailableView(IDELanguageRunText.t("暂时无法打开浏览器", "Unable to open browser"), systemImage: "globe") }
            else { ProgressView() }
        }
            .task {
                do {
                    let id = try await environment.toolboxBrowser.owner()
                    ownerID = id; environment.toolboxBrowser.center.bind(to: id)
                } catch { ownerID = nil; failed = true }
            }
    }
}
#endif
