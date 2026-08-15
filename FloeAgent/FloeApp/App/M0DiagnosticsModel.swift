#if DEBUG && canImport(UIKit)
import CloudKit
import Foundation
import SwiftUI
import FloeCore
import FloeDocuments
import FloePersistence
import FloeSecurity
import FloeSSH
import FloeSync
import FloeSyncCore
import FloeVNC

@MainActor
final class M0DiagnosticsModel: ObservableObject {
    @Published private(set) var bootstrapStatus = "Not started"
    @Published private(set) var syncStatus = "Paused"
    @Published private(set) var providerCount = 0
    @Published private(set) var secretStatus = "Not checked"
    @Published private(set) var remoteStatus = "Disconnected"
    @Published private(set) var terminalOutput = ""
    @Published private(set) var documentStatus = "Not tested"
    @Published var trustPrompt: HostKeyChallenge?
    @Published var vncSession: VNCSession?

    @Published var apiKey = ""
    @Published var targetAddress = ""
    @Published var targetPort = "22"
    @Published var targetUser = "floe"
    @Published var targetPassword = ""
    @Published var jumpAddress = ""
    @Published var jumpPort = "2222"
    @Published var jumpUser = "floe"
    @Published var jumpPassword = ""
    @Published var vncHost = "vnc"
    @Published var vncPort = "5900"
    @Published var vncPassword = ""
    @Published var terminalInput = "echo 'Floe Agent SSH M0'"

    private let testProviderID = UUID(uuidString: "F10EA900-0000-4000-8000-000000000001")!
    private let hostID = UUID(uuidString: "F10EA900-0000-4000-8000-000000000002")!
    private var database: DatabaseManager?
    private var configurationStore: ModelConfigurationStore?
    private var syncEngine: ConfigSyncEngine?
    private var secretStore = KeychainSecretStore()
    private var sshSession: SSHSessionHandle?
    private var ptySession: PTYSessionHandle?
    private var forwarder: LoopbackSSHForwarder?
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var didBootstrap = false

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        bootstrapStatus = "Preparing local database…"
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support.appendingPathComponent("FloeAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try DatabaseManager(path: directory.appendingPathComponent("floe.sqlite"))
            try await database.migrate()
            let configurationStore = ModelConfigurationStore(database: database)
            let metadataStore = ConfigSyncMetadataStore(database: database)
            let engine = ConfigSyncEngine(
                configurationStore: configurationStore,
                metadataStore: metadataStore
            )
            self.database = database
            self.configurationStore = configurationStore
            self.syncEngine = engine
            bootstrapStatus = "Local schema v\(DatabaseManager.currentSchemaVersion) ready"

            do {
                try await engine.configure(container: CKContainer.default())
                syncStatus = Self.describe(await engine.status)
            } catch {
                syncStatus = "CloudKit unavailable: \(error.localizedDescription)"
            }
            await refreshConfigurationStatus()
        } catch {
            bootstrapStatus = "Failed: \(error.localizedDescription)"
        }
    }

    func saveTestProvider() async {
        guard let syncEngine else { return }
        do {
            let now = Date()
            let existing = try await configurationStore?.provider(id: testProviderID)
            let provider = ProviderProfile(
                id: testProviderID,
                kind: .custom,
                wireProtocol: .openAIResponses,
                baseURL: URL(string: "https://m0.floeagent.org/v1")!,
                secretRef: SecretReference(
                    keychainAccount: "provider.\(testProviderID.uuidString)",
                    synchronizable: true
                ),
                region: "m0-device-validation",
                nonSecretHeaders: ["X-Floe-M0": "true"],
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                syncRevision: (existing?.syncRevision ?? 0) + 1
            )
            if !apiKey.isEmpty {
                try await secretStore.setSyncEnabled(true, for: testProviderID)
                try await secretStore.storeSecret(Data(apiKey.utf8), scope: .provider(testProviderID))
                apiKey = ""
            }
            try await syncEngine.saveProvider(provider)
            try await syncEngine.synchronize()
            await refreshConfigurationStatus()
        } catch {
            syncStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    func deleteTestProvider() async {
        guard let syncEngine else { return }
        do {
            try await syncEngine.deleteProvider(id: testProviderID)
            try await secretStore.deleteSecret(scope: .provider(testProviderID))
            try await syncEngine.synchronize()
            await refreshConfigurationStatus()
        } catch {
            syncStatus = "Delete failed: \(error.localizedDescription)"
        }
    }

    func refreshSync() async {
        do {
            try await syncEngine?.synchronize()
            await refreshConfigurationStatus()
        } catch {
            syncStatus = "Refresh failed: \(error.localizedDescription)"
        }
    }

    func connectSSH() async {
        guard let database,
              let targetPort = Int(targetPort),
              (1...65535).contains(targetPort)
        else {
            remoteStatus = "Invalid target settings"
            return
        }
        remoteStatus = "Connecting…"
        do {
            let keychain = KeychainStore(service: "org.floeagent.ios.m0.ssh", synchronizable: false)
            let targetAccount = "target.\(hostID.uuidString)"
            try keychain.store(account: targetAccount, secret: Data(targetPassword.utf8))
            var jumps: [JumpHop] = []
            if !jumpAddress.isEmpty {
                guard let jumpPort = Int(jumpPort), (1...65535).contains(jumpPort) else {
                    throw FloeError.validationFailed("Invalid jump port")
                }
                let jumpAccount = "jump.\(hostID.uuidString)"
                try keychain.store(account: jumpAccount, secret: Data(jumpPassword.utf8))
                jumps = [JumpHop(
                    address: jumpAddress,
                    port: jumpPort,
                    user: jumpUser,
                    auth: .password(SecretReference(keychainAccount: jumpAccount, synchronizable: false))
                )]
            }
            targetPassword = ""
            jumpPassword = ""
            let profile = RemoteHostProfile(
                id: hostID,
                displayName: "M0 validation host",
                address: targetAddress,
                port: targetPort,
                user: targetUser,
                auth: .password(SecretReference(keychainAccount: targetAccount, synchronizable: false)),
                jumpChain: jumps,
                hostKeyPolicy: .trustOnFirstUse,
                vncEndpoint: VNCEndpoint(host: vncHost, port: Int(vncPort) ?? 5900)
            )
            let service = SSHConnectionService(hostStore: RemoteHostStore(database: database))
            let session = try await service.connect(
                profile: profile,
                credentialResolver: { reference in try keychain.read(account: reference.keychainAccount) },
                hostKeyDecision: { [weak self] challenge in
                    guard let self else { return false }
                    return await self.requestTrust(challenge)
                }
            )
            sshSession = session
            let pty = try await session.openPTY()
            ptySession = pty
            remoteStatus = "SSH connected"
            Task { [weak self] in
                do {
                    for try await data in pty.output {
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        self?.appendTerminal(text)
                    }
                } catch {
                    self?.setRemoteError(error)
                }
            }
        } catch {
            remoteStatus = "SSH failed: \(error.localizedDescription)"
        }
    }

    func sendTerminalInput() async {
        guard let ptySession else { return }
        do {
            try await ptySession.write(Data((terminalInput + "\n").utf8))
        } catch {
            remoteStatus = "Write failed: \(error.localizedDescription)"
        }
    }

    func connectVNC() async {
        guard let sshSession,
              let port = Int(vncPort),
              (1...65535).contains(port)
        else {
            remoteStatus = "Connect SSH and check VNC port first"
            return
        }
        do {
            let forwarder = try await LoopbackSSHForwarder.start(
                session: sshSession,
                targetHost: vncHost,
                targetPort: port
            )
            guard let endpoint = forwarder.endpoint else {
                throw FloeError.internalError("Loopback VNC endpoint did not become ready")
            }
            self.forwarder = forwarder
            let session = VNCSession(host: endpoint.host, port: endpoint.port, password: vncPassword)
            vncPassword = ""
            session.onStateChange { [weak self] state in
                Task { @MainActor in self?.remoteStatus = "VNC: \(String(describing: state))" }
            }
            vncSession = session
            session.connect()
        } catch {
            remoteStatus = "VNC failed: \(error.localizedDescription)"
        }
    }

    func disconnectRemote() async {
        vncSession?.disconnect()
        vncSession = nil
        await forwarder?.close()
        forwarder = nil
        await ptySession?.close()
        ptySession = nil
        await sshSession?.close()
        sshSession = nil
        remoteStatus = "Disconnected"
    }

    func probeDocument(_ url: URL) async {
        do {
            let workspace = try SecurityScopedDocumentWorkspace()
            let session = try await workspace.open(securityScopedURL: url)
            try await workspace.save(session)
            await workspace.close(session)
            documentStatus = "Safe open/save round trip passed for \(url.lastPathComponent)"
        } catch {
            documentStatus = "Document probe failed: \(error.localizedDescription)"
        }
    }

    func resolveTrust(_ accepted: Bool) {
        trustPrompt = nil
        trustContinuation?.resume(returning: accepted)
        trustContinuation = nil
    }

    private func requestTrust(_ challenge: HostKeyChallenge) async -> Bool {
        if let trustContinuation { trustContinuation.resume(returning: false) }
        return await withCheckedContinuation { continuation in
            trustContinuation = continuation
            trustPrompt = challenge
        }
    }

    private func refreshConfigurationStatus() async {
        do {
            let providers = try await configurationStore?.providers() ?? []
            let provider = try await configurationStore?.provider(id: testProviderID)
            providerCount = providers.count
            secretStatus = Self.describe(await secretStore.status(
                for: testProviderID,
                hasConfiguration: provider != nil
            ))
            if let syncEngine { syncStatus = Self.describe(await syncEngine.status) }
        } catch {
            syncStatus = "Status failed: \(error.localizedDescription)"
        }
    }

    private func appendTerminal(_ text: String) {
        terminalOutput.append(text)
        if terminalOutput.count > 50_000 { terminalOutput.removeFirst(terminalOutput.count - 50_000) }
    }

    private func setRemoteError(_ error: Error) {
        remoteStatus = "PTY ended: \(error.localizedDescription)"
    }

    private static func describe(_ status: SyncStatus) -> String {
        switch status {
        case .syncing: "Syncing"
        case .synced: "Synced"
        case .paused: "Paused"
        case .waitingForSecret: "Waiting for iCloud Keychain"
        case .error(let reason): "Error: \(reason)"
        }
    }
}
#endif
