// FloeMacUnified LocalModelsParity — settings/download ownership surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// Mac settings-facing state for the local-model lifecycle. Owns no engine
// and no network code: every operation is an explicit user action delegated
// to the shared `LocalModelStore`, and every state change is derived from
// the store afterwards. The coordinator's settings UI binds to this object;
// when a download/remove finishes it asks the service to re-publish the
// installed model set to the host.
//
// Work admission: the host injects a Bridge-style lease
// (`admitWork`) that is taken before every state-changing action (download,
// pause/cancel, remove) and before an actual load/benchmark, and released
// only on durable termination of that action. Closing the settings surface
// never cancels an owned download — the download runs to its own end state
// and the lease tracks that, not view lifetime.

import Foundation
import Combine
import FloeCore
import FloeLocalModelCatalog
import FloeLocalModels

@available(macOS 15.4, *)
@MainActor
public final class MacLocalModelsSettingsModel: ObservableObject {
    public enum EntryState: String, Sendable, Equatable {
        case notInstalled
        /// A `.downloads` resume set exists for this entry.
        case resumable
        case downloading
        case installed
    }

    public struct EntryItem: Identifiable, Sendable, Equatable {
        public let catalogEntry: LocalModelCatalogEntry
        public var state: EntryState
        /// Installed weight bytes (real, from the store) when installed.
        public var installedBytes: Int64?

        public var id: String { catalogEntry.id }
    }

    /// Admission lease borrowed from the host (BridgeUpdateActivity-style):
    /// throw to refuse the action; otherwise the returned closure releases
    /// the lease on durable termination.
    public typealias AdmitWork = @MainActor () throws -> () -> Void

    /// The download operation the model owns. Production always runs the
    /// shared `LocalModelStore.download`; the seam exists so focused tests
    /// can script transfer behavior (hang/cancel/fail) deterministically.
    public typealias DownloadRunner = @Sendable (
        LocalModelCatalogEntry,
        @escaping @Sendable (LocalModelDownloadProgress) -> Void
    ) async throws -> URL

    /// Availability verdict for the settings banner. Immutable per launch
    /// unless the host re-probes.
    public private(set) var runtimeSupport: MacLocalModelRuntimeSupport
    @Published public private(set) var items: [EntryItem] = []
    @Published public private(set) var progress: LocalModelDownloadProgress?
    @Published public private(set) var activeError: String?
    /// The id of the model whose download currently owns the serial slot;
    /// nil when no download is in flight. Drives pause/cancel controls.
    @Published public private(set) var activeDownloadID: String?
    /// True while a whole-model download owns the serial slot. Load/benchmark
    /// are quick operations reported through `isWorking` instead.
    @Published public private(set) var isDownloading = false
    /// True while any admitted action (download, load, benchmark, remove) is
    /// in flight — the single busy flag for the settings chrome.
    @Published public private(set) var isBusy = false

    private let service: MacLocalModelService
    private let availabilityProbe: MacLocalModelAvailability.Probe
    private let admitWork: AdmitWork
    private let downloadRunner: DownloadRunner
    /// The lease of the one long-running download. Released only when the
    /// download reaches a durable end state (installed, failed, paused or
    /// cancelled) — never on settings close.
    private var downloadLease: (() -> Void)?
    /// Serialize whole-model download operations so pause/cancel target the
    /// right in-flight transfer and progress isn't multiplexed.
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: UUID?

    public init(
        service: MacLocalModelService,
        availabilityProbe: MacLocalModelAvailability.Probe = MacLocalModelAvailability.currentProbe(),
        admitWork: @escaping AdmitWork = { {} },
        downloadRunner: DownloadRunner? = nil
    ) {
        self.service = service
        self.availabilityProbe = availabilityProbe
        self.admitWork = admitWork
        let store = service.store
        self.downloadRunner = downloadRunner ?? { entry, progress in
            try await store.download(entry, progress: progress)
        }
        self.runtimeSupport = MacLocalModelAvailability.support(probe: availabilityProbe)
    }

    // MARK: Queries

    public func refresh() async {
        let store = service.store
        var refreshed: [EntryItem] = []
        for entry in CuratedLocalModelCatalog.entries {
            let state: EntryState
            let bytes: Int64?
            if await store.isInstalled(id: entry.id) {
                state = .installed
                bytes = await store.installedWeightBytes(id: entry.id).map(Int64.init)
            } else {
                bytes = nil
                state = await store.resumableModelIDs().contains(entry.id) ? .resumable : .notInstalled
            }
            refreshed.append(.init(catalogEntry: entry, state: state, installedBytes: bytes))
        }
        let retired = await retiredItems(using: store)
        items = refreshed + retired
    }

    private func retiredItems(using store: LocalModelStore) async -> [EntryItem] {
        var result: [EntryItem] = []
        for entry in CuratedLocalModelCatalog.retiredEntries {
            // Retired entries are listed only while an installation still
            // exists so the user can delete it — never for download.
            if await store.isInstalled(id: entry.id) {
                result.append(.init(
                    catalogEntry: entry,
                    state: .installed,
                    installedBytes: await store.installedWeightBytes(id: entry.id).map(Int64.init)
                ))
            }
        }
        return result
    }

    // MARK: Explicit actions

    /// Starts (or resumes) the download for `entry`. Resumable artifacts
    /// continue through the store's durable `.downloads` bookkeeping.
    /// Cancellation happens only through `pauseDownload`/`cancelDownload` —
    /// dismissing settings never cancels the owned transfer, and the
    /// admission lease is released only when the download reaches its
    /// durable end state (installed, failed, paused or cancelled).
    public func download(_ entry: LocalModelCatalogEntry) {
        guard !isBusy, downloadTask == nil, downloadLease == nil else { return }
        progress = nil
        activeError = nil
        let release: () -> Void
        do {
            release = try admitWork()
        } catch {
            activeError = error.localizedDescription
            return
        }
        downloadLease = release
        activeDownloadID = entry.id
        isDownloading = true
        isBusy = true
        let generation = UUID()
        downloadGeneration = generation
        let service = self.service
        let runner = downloadRunner
        downloadTask = Task { [weak self, release] in
            var failure: String?
            do {
                _ = try await runner(entry) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.downloadGeneration == generation else { return }
                        self.progress = value
                    }
                }
            } catch is CancellationError {
                // Explicit pause/cancel: a user action, not an error.
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                // Pause/cancel interrupts the transfer at URLSession level.
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else {
                    // Durable termination without a live view model: still
                    // honor the host lease contract.
                    release()
                    return
                }
                self.downloadTask = nil
                self.downloadGeneration = nil
                self.downloadLease?()
                self.downloadLease = nil
                self.activeDownloadID = nil
                self.isDownloading = false
                self.isBusy = false
                self.progress = nil
                if let failure {
                    self.activeError = failure
                }
            }
            await self?.refresh()
            // Publish the (possibly changed) installed model set even when
            // the settings view model is gone.
            await service.refreshInstalledModels()
        }
    }

    /// Pauses the in-flight download, preserving resumable artifact state.
    /// Awaits the download task's own completion: the admission lease is
    /// released there, at the durable stop, never concurrently.
    public func pauseDownload(id: String) async {
        guard let task = downloadTask, activeDownloadID == id else { return }
        await service.store.pauseDownload(id: id)
        await task.value
        await refresh()
    }

    /// Cancels the in-flight download and drops its resumable state.
    /// Awaits the download task's own completion before returning.
    public func cancelDownload(id: String) async {
        guard let task = downloadTask, activeDownloadID == id else { return }
        await service.store.cancelDownload(id: id)
        await task.value
        await refresh()
    }

    /// Removes an installed model. Serialized against in-flight inference:
    /// the resident engine is unloaded first so no mapped weights are
    /// deleted under a running turn. Explicit user action only; nothing is
    /// deleted silently.
    public func remove(id: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard await !service.hasActiveInferenceOperation() else {
            activeError = String(localized: "mac.localModels.removeWhileRunning")
            return
        }
        let release: () -> Void
        do {
            release = try admitWork()
        } catch {
            activeError = error.localizedDescription
            return
        }
        do {
            try await service.runtime.removeInstalledModel(id: id)
            activeError = nil
        } catch {
            activeError = error.localizedDescription
        }
        release()
        await refresh()
        await service.refreshInstalledModels()
    }

    /// Warm-up load (settings "load" affordance, benchmark preparation).
    public func load(id: String) async {
        guard !isBusy else { return }
        let release: () -> Void
        do {
            release = try admitWork()
        } catch {
            activeError = error.localizedDescription
            return
        }
        isBusy = true
        defer {
            release()
            isBusy = downloadTask != nil
        }
        do {
            try await service.preload(modelID: id)
            activeError = nil
        } catch {
            activeError = error.localizedDescription
        }
    }

    /// Explicit unload from settings.
    public func unload(id: String? = nil) async {
        await service.unload(modelID: id)
    }

    /// Settings benchmark, same shared benchmark as the iPad settings.
    @discardableResult
    public func benchmark(id: String) async -> LocalModelBenchmarkResult? {
        guard !isBusy else { return nil }
        let release: () -> Void
        do {
            release = try admitWork()
        } catch {
            activeError = error.localizedDescription
            return nil
        }
        isBusy = true
        defer {
            release()
            isBusy = downloadTask != nil
        }
        do {
            let result = try await service.benchmark(modelID: id)
            activeError = nil
            return result
        } catch {
            activeError = error.localizedDescription
            return nil
        }
    }

}
