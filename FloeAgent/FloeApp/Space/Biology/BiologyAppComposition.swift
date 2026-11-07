// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools

/// A single service composition for every Biology editor and model call.
/// Organizational wrapper folders never become the native storage root.
@MainActor final class BiologyAppComposition {
    private weak var environment: AppEnvironment?
    private var ready: BiologyHostServices?
    private var libraryOwner: BiologyLibraryCoordinator?
    private var pending: Task<BiologyHostServices, Error>?
    init(environment: AppEnvironment) { self.environment = environment }

    /// One pure location seam for the permanent native store and read-only
    /// saved previews. This does not initialize services or create a directory.
    static func permanentRoot(forLibraryRoot root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent("Biology", isDirectory: true)
    }
    func host() async throws -> BiologyHostServices {
        if let ready { return ready }
        if let pending { return try await pending.value }
        guard let environment, let jobs = environment.backgroundJobService else { throw BiologyHostError.unavailable }
        let task = Task { @MainActor in
            let root = Self.permanentRoot(forLibraryRoot: try PersonalContentLibrary.applicationRoot())
            let library = BiologyLibraryCoordinator(environment: environment)
            let runtime = BiologyNativeToolRuntime(environment: environment,
                approval: { [weak environment] action, context, descriptor, intent in
                    guard let environment else { throw BiologyHostError.unavailable }
                    return try await environment.conversationCenter.recordNativeWorkbenchApproval(action,
                        context: context, descriptor: descriptor, intent: intent)
                })
            let host = try BiologyHostServices(environment: environment, root: root, jobs: jobs,
                hooks: library.hooks, nativeRuntime: runtime)
            try library.bind(host: host)
            try runtime.bind(host: host)
            try await host.registerTools()
            try await host.recoverAfterProcessRestart()
            await PersonalContentService.shared.configureBiology(host)
            self.libraryOwner = library
            return host
        }
        pending = task
        do {
            let result = try await task.value
            ready = result; pending = nil
            return result
        } catch { pending = nil; throw error }
    }

    func libraryLifecycle() async throws -> BiologyLibraryCoordinator {
        _ = try await host()
        guard let libraryOwner else { throw BiologyHostError.unavailable }
        return libraryOwner
    }

    var typedServiceStorePaths: [String: String] {
        guard let ready else { return [:] }
        return [TypedMutationContract.nativeBiologyStoreKey: ready.root.path]
    }

    func prepare() async {
        do { _ = try await host() }
        catch { FloeLogger(category: .persistence).warning("biologyCompositionUnavailable") }
    }

    func discoverableToolNames(for context: ToolContext) async -> Set<String> {
        guard let ready else { return [] }
        do { return Set(try await ready.descriptors(for: context).map(\.name)) }
        catch { return [] }
    }
}
#endif
