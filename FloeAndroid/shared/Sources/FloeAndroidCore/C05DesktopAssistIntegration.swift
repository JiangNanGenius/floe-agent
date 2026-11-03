// SPDX-License-Identifier: MPL-2.0
//
// C05 desktop-assist production wiring.
//
// This is the ONLY place the two previously-nil tool seams are connected:
//   * the contextual text recognizer is the real Linux/Tesseract adapter run
//     through the task's EXISTING `LocalShellService` (`exec.shell`);
//   * the credential-card resolver is bound to the ONE installed
//     `AndroidCredentialVault` (original metadata + AndroidKeystore gateway)
//     and the task's actual workspace ownership store.
//
// No second registry, database, credential store, OCR model or network
// client is created. Main applies the one-line composition change in
// `G02DomainServices` (see the handoff patch); the App settings bridge uses
// the same vault through `C05AndroidCredentialCardStore`.

import Foundation
import FloeCore
import FloePersistence
import FloeSecurity
import FloeTools

// MARK: - Credential card store conformance

/// Thin conformance over the ORIGINAL `AndroidCredentialVault`. It adds no
/// state and no policy: metadata comes from the vault's exported
/// `CredentialStore`, secret bytes from the existing approved-use gateway.
public struct C05AndroidCredentialCardStore: C05DesktopCredentialCardStoring {
    public let vault: AndroidCredentialVault

    public init(vault: AndroidCredentialVault) {
        self.vault = vault
    }

    public func credentialRecord(id: UUID) async throws -> CredentialRecord? {
        try await vault.records.record(id: id)
    }

    public func listCredentialRecords() async throws -> [CredentialRecord] {
        try await vault.records.records(owner: nil)
    }

    public func captureCredential(
        _ secret: Data,
        kind: CredentialKind,
        owner: CredentialOwner,
        label: String,
        hostID: UUID?,
        origin: String
    ) async throws -> CredentialHandle {
        try await vault.capture(
            secret,
            kind: kind,
            owner: owner,
            label: label,
            hostID: hostID,
            origin: origin
        )
    }

    public func resolveCredentialSecret(_ handle: CredentialHandle) async throws -> Data {
        try await vault.resolveForApprovedUse(handle)
    }

    public func replaceCredentialSecret(
        _ handle: CredentialHandle,
        secret: Data
    ) async throws {
        try await vault.replaceSecret(handle, secret: secret)
    }

    public func updateCredentialLabel(
        _ handle: CredentialHandle,
        label: String
    ) async throws {
        try await vault.updateLabel(handle, label: label)
    }

    public func deleteCredential(_ handle: CredentialHandle) async throws {
        _ = try await vault.delete(handle)
    }
}

// MARK: - Linux shell OCR runner

/// Runs the OCR command through the SAME `LocalShellService` that backs
/// `exec.shell`: the real task workspace, the real Linux environment lease,
/// the existing shell policy, journaling, output bounds and cancellation.
public struct C05LinuxShellOCRCommandRunner: C05LinuxOCRCommandRunning {
    public init() {}

    public func run(_ command: C05LinuxOCRCommand) async -> C05LinuxOCRCommandOutcome {
        guard let service = RuntimeFacadeLinuxBindings.shared.components?.service else {
            return .notStarted("The task Linux shell service is not composed")
        }
        let result = await service.run(
            command: command.command,
            cwd: command.cwd,
            environment: ["OMP_THREAD_LIMIT": "1"],
            stdin: nil,
            timeout: command.timeout,
            maxOutputBytes: command.maxOutputBytes,
            isBackground: false,
            context: command.context
        )
        switch result {
        case .blocked(let verdict):
            return .blocked(
                verdict.reason ?? "The shell policy blocked the text-recognition command"
            )
        case .outcome(let outcome):
            switch outcome {
            case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, _):
                let output = stdout + (stderr.isEmpty ? "" : "\n" + stderr)
                return .exited(
                    code: code,
                    output: output,
                    truncated: truncated || stderrTruncated
                )
            case .timedOut(let stdout, let stderr, _):
                return .timedOut(output: stdout + (stderr.isEmpty ? "" : "\n" + stderr))
            case .cancelled:
                return .cancelled
            case .notStarted(let reason):
                return .notStarted(reason)
            case .failed(let message):
                return .failed(message)
            }
        }
    }
}

// MARK: - Composition

public enum C05DesktopAssistProduction {
    /// One process-wide actor: the bounded readiness cache and install
    /// serialization are shared, while every recognition still validates the
    /// exact task/session/frame ownership passed in its request.
    public static let recognizer = C05LinuxTesseractRecognizer(
        runner: C05LinuxShellOCRCommandRunner()
    )

    /// Builds the real tool environment over the accepted generation's
    /// original vault and workspace store. `artifactRootURL` is the same
    /// App-owned artifact root the runtime already exposes to the provider
    /// image reader.
    public static func toolEnvironment(
        vault: AndroidCredentialVault,
        workspaceStore: SQLiteWorkspaceStore,
        epoch: UInt64,
        artifactRootURL: URL?
    ) -> C05RemoteDesktopToolEnvironment {
        let linuxServiceComposed = RuntimeFacadeLinuxBindings.shared.components != nil
        let resolver = C05SecureCredentialCardResolver(
            store: C05AndroidCredentialCardStore(vault: vault),
            workspaceID: { conversationID in
                try? await workspaceStore.workspaceID(conversationID: conversationID)
            }
        )
        return C05RemoteDesktopToolEnvironment(
            currentEpoch: {
                guard let installed = G02RuntimeComposition.shared.installedComposition,
                      installed.epoch == epoch else { return nil }
                return epoch
            },
            artifactRoot: { artifactRootURL },
            contextualTextRecognizer: linuxServiceComposed ? recognizer : nil,
            textRecognitionPreparer: linuxServiceComposed ? recognizer : nil,
            cardResolver: resolver
        )
    }
}
