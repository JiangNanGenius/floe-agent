// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes cloud OCR — accepted-generation attachment.
//
// This is the ONLY production binding: the same installed composition, the
// same `ModelConfigurationStore`, the same `RunCredentialResolver`, the same
// owned-work registry/epoch fence, the same qualified transport gate and the
// original `ProviderAdapterFactory`. The staging root is derived from the
// accepted runtime root; no caller path is accepted.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders

public enum NotesOCRComposition {
    /// Idempotently binds the process OCR domain to the accepted generation.
    /// `false` means the runtime/root is not live; OCR stays typed
    /// `notConfigured` and ordinary Notes editing is untouched.
    @discardableResult
    public static func attach(epoch: UInt64) async -> Bool {
        if await NotesOCRDomain.shared.boundEpoch == epoch { return true }
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { return false }
        guard let root = AndroidRuntimeBootstrap.notesBinding(
            epoch: epoch, ownerToken: nil) else { return false }

        let modelStore = installed.runComponents.modelStore
        let credentials = installed.credentialResolver
        let assembly = RunModelAssembly(configurationStore: modelStore,
                                        credentials: credentials)
        let routing = NotesOCRRunModelRouting(
            assembly: assembly,
            store: modelStore,
            credentials: credentials,
            transportAdmitted: {
                G02RuntimeComposition.shared.transportGate.admitsCloudNetwork
            },
            adapterFactory: { provider in
                OriginalProviderAdapterFactory().adapter(for: provider)
            })
        let ownedWork = ConfigOwnedWorkLifecycle(
            registry: RuntimeOwnedWorkRegistry.shared,
            epochProvider: G02CompositionEpochProvider())
        let stagingRoot = root.artifactStoreURL
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("OCRStaging", isDirectory: true)
        do {
            try await NotesOCRDomain.shared.bind(
                epoch: epoch,
                source: NotesOCRServiceSource(epoch: epoch),
                routing: routing,
                ownedWork: ownedWork,
                stagingRoot: stagingRoot)
            return true
        } catch {
            return false
        }
    }

    /// Final owner teardown (after the real root drain). A live provider
    /// stream keeps the owned-work token and this call waits its actual
    /// settlement; no timeout detaches it.
    public static func detach(epoch: UInt64) async {
        await NotesOCRDomain.shared.retire(epoch: epoch)
    }
}
