// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameRGSS

/// Prepares one owned run copy from the immutable project source. It never
/// writes into the source and never turns a save layer into a second project.
public actor RGSSGuestRunStager {
    public let layout: RGSSGuestRunLayout
    public let limits: RGSSGuestTreeLimits

    public init(layout: RGSSGuestRunLayout,
                limits: RGSSGuestTreeLimits = .default) {
        self.layout = layout
        self.limits = limits
    }

    /// Bounded read-only route inspection. It performs the real marker/script
    /// inspection and hashes the selected root; it does not copy, execute or
    /// decrypt. This shape is usable before a display is attached.
    public func inspect(context: GameProjectContext, engine: GameEngineID,
                        rootRelative: String,
                        engineOverride: Bool = false) async throws -> RGSSGuestRoutePlan {
        try Task.checkCancellation()
        let profile = try RGSSEngineProfiles.profile(for: engine)
        let selectedRoot = try RGSSGuestRootResolver.resolve(
            root: context.rootURL, relativeRoot: rootRelative, limits: limits)
        let inspection: RGSSProjectInspection
        do {
            inspection = try RGSSCompatibilityInspector().inspect(rootURL: selectedRoot)
        } catch let error as RGSSRuntimeError {
            throw RGSSGuestRunError.sourceRootUnavailable(String(describing: error))
        }
        guard inspection.engine == engine || engineOverride else {
            throw RGSSGuestRunError.engineMismatch(detected: inspection.engine, requested: engine)
        }
        let digest = try RGSSGuestSafeTree.digest(rootURL: selectedRoot, limits: limits)
        try Task.checkCancellation()
        var notes: [String] = [
            "Source, data and unknown files stay in the imported project; the run uses a separate owned copy.",
            "Standard Save*.\(profile.dataExtension) files are staged from a save layer outside the source.",
            "Native EXE/DLL files, encrypted RGSS archives and RTP references are preserved and not executed or decrypted.",
            "The reviewed Tapir install, pin and notices are checked again at start; a missing install fails closed.",
        ]
        if engineOverride && inspection.engine != engine {
            notes.append("User override: marker/detected engine is \(inspection.engine.rawValue); running with \(engine.rawValue). Data compatibility is the user's decision.")
        }
        if !inspection.encryptedArchives.isEmpty {
            notes.append("Encrypted archive(s) preserved; loose scripts are required for this run.")
        }
        if !inspection.nativeExecutables.isEmpty || !inspection.nativeLibraries.isEmpty {
            notes.append("Native Windows executables/libraries are preserved as data and never executed.")
        }
        if inspection.rtpReference != nil {
            notes.append("The project references an RTP; no RTP is bundled. Missing assets remain missing.")
        }
        return RGSSGuestRoutePlan(
            context: context, engine: engine, rootRelative: rootRelative,
            engineOverride: engineOverride, version: profile.version, profile: profile,
            selectedRoot: selectedRoot, sourceDigest: digest, inspection: inspection,
            routeID: "guest.rgss-\(engine.rawValue)", notes: notes)
    }

    /// Bounded read-only plan bound to one exact run request.
    public func plan(_ request: RGSSGuestRunRequest) async throws -> RGSSGuestRunPlan {
        let route = try await inspect(context: request.context, engine: request.engine,
                                      rootRelative: request.rootRelative,
                                      engineOverride: request.engineOverride)
        return RGSSGuestRunPlan(
            request: request, version: route.version, profile: route.profile,
            selectedRoot: route.selectedRoot, sourceDigest: route.sourceDigest,
            inspection: route.inspection, routeID: route.routeID,
            prerequisites: [], notes: route.notes)
    }

    /// Prepares a fresh run copy. Any existing run at this exact identity is
    /// first drained of standard saves into the persistent save layer, then
    /// removed. A source change between plan and copy fails closed.
    public func stage(_ request: RGSSGuestRunRequest) async throws -> RGSSGuestStagedRun {
        let plan = try await plan(request)
        try Task.checkCancellation()
        let sourceRoot = request.context.rootURL
        let runRoot = layout.runRoot(for: request, sourceDigest: plan.sourceDigest)
        let saveRoot = layout.saveRoot(for: request)
        let homeRoot = layout.homeRoot(for: request)
        let logFile = layout.logFile(for: request)

        try RGSSGuestRootResolver.requireOutside(runRoot, source: sourceRoot, kind: "run layer")
        try RGSSGuestRootResolver.requireOutside(saveRoot, source: sourceRoot, kind: "save layer")
        try RGSSGuestRootResolver.requireOutside(homeRoot, source: sourceRoot, kind: "home layer")
        try RGSSGuestRootResolver.requireOutside(logFile.deletingLastPathComponent(),
                                                 source: sourceRoot, kind: "log layer")
        try RGSSGuestRootResolver.requireOutside(layout.baseDirectory,
                                                 source: sourceRoot, kind: "run layout base")

        let saveStore = try RGSSGuestSaveStore(root: saveRoot, engine: request.engine,
                                               sourceRoot: sourceRoot)
        // Preserve standard saves from an existing run copy before replacing
        // it. Unknown files are reported and left in the old run copy until the
        // caller removes it; they are never promoted to saves.
        if FileManager.default.fileExists(atPath: runRoot.path) {
            _ = try saveStore.collect(from: runRoot)
            try FileManager.default.removeItem(at: runRoot)
        }
        try FileManager.default.createDirectory(at: runRoot.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let copied = try RGSSGuestSafeTree.copy(from: plan.selectedRoot, to: runRoot, limits: limits)
        guard !copied.isEmpty else {
            throw RGSSGuestRunError.sourceRootUnavailable("selected root is empty")
        }
        let importedSaves = try saveStore.stage(into: runRoot)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            guard FileManager.default.createFile(atPath: logFile.path, contents: Data()) else {
                throw RGSSGuestRunError.runLayerViolation("cannot create job log")
            }
        }
        // Re-hash the source. A late source change is reported before a
        // player is created; the copied bytes cannot be silently stale. The
        // run copy additionally contains staged saves, so its digest is not
        // expected to equal the source digest.
        let sourceAfter = try RGSSGuestSafeTree.digest(rootURL: plan.selectedRoot, limits: limits)
        guard sourceAfter == plan.sourceDigest else {
            throw RGSSGuestRunError.sourceChangedDuringPreparation
        }
        return RGSSGuestStagedRun(
            request: request,
            plan: plan,
            selectedRoot: plan.selectedRoot,
            sourceRoot: sourceRoot,
            sourceDigest: plan.sourceDigest,
            runRoot: runRoot,
            saveRoot: saveRoot,
            homeRoot: homeRoot,
            logFile: logFile,
            importedSaveNames: importedSaves,
            stagedAt: Date())
    }

    /// Collects standard saves after a confirmed job stop. The run copy is
    /// retained; only the owned save layer is updated.
    public func collectSaves(from staged: RGSSGuestStagedRun) async throws -> RGSSGuestSaveCollection {
        try RGSSGuestRootResolver.requireOutside(staged.runRoot, source: staged.sourceRoot,
                                                 kind: "run layer")
        try RGSSGuestRootResolver.requireOutside(staged.saveRoot, source: staged.sourceRoot,
                                                 kind: "save layer")
        let store = try RGSSGuestSaveStore(root: staged.saveRoot,
                                           engine: staged.request.engine,
                                           sourceRoot: staged.sourceRoot)
        return try store.collect(from: staged.runRoot)
    }

    /// Explicit cleanup for one completed run copy. The save layer, home layer
    /// and log are preserved; only the disposable run copy is removed.
    public func discardRunCopy(_ staged: RGSSGuestStagedRun) throws {
        try RGSSGuestRootResolver.requireOutside(staged.runRoot, source: staged.sourceRoot,
                                                 kind: "run layer")
        guard FileManager.default.fileExists(atPath: staged.runRoot.path) else { return }
        try FileManager.default.removeItem(at: staged.runRoot)
    }
}
