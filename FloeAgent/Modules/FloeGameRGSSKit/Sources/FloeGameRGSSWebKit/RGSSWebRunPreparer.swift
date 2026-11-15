// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit
import FloeGameRGSS

/// A real `GameWebRunPreparationHost` for the reviewed RGSS1 Web adapter. It
/// seals a source-bound artifact; it creates no process and no general
/// executor. The host's GameWebRuntimePolicy must enable WebAssembly for RGSS
/// before this can be used in the App. That policy is root-owned.
public actor RGSSWebRunPreparer: GameWebRunPreparationHost {
    public let pack: RGSSRuntimePack
    public let artifactDirectory: URL
    public let mode: RGSSWebRuntimeMode
    private let builder: RGSSArtifactBuilder
    private var jobs: [UUID: Task<GamePreparedWebRun, any Error>] = [:]

    public init(pack: RGSSRuntimePack, artifactDirectory: URL, mode: RGSSWebRuntimeMode,
                limits: GameRepositoryLimits? = nil) throws {
        guard artifactDirectory.isFileURL else { throw RGSSRuntimeError.invalidArtifact("artifact directory is not a file URL") }
        self.pack = pack
        self.artifactDirectory = artifactDirectory.standardizedFileURL
        self.mode = mode
        self.builder = RGSSArtifactBuilder(limits: limits)
        try FileManager.default.createDirectory(at: self.artifactDirectory, withIntermediateDirectories: true)
    }

    public func prepare(_ request: GameWebRunRequest) async throws -> GamePreparedWebRun {
        guard RGSSEngineProfiles.isRGSS(request.engine) else {
            throw RGSSRuntimeError.invalidEngine(request.engine.rawValue)
        }
        guard case .verifiedAsyncify = try RGSSRuntimeMatrix.support(for: request.engine).web else {
            throw RGSSRuntimeError.unsupportedWebEngine(request.engine)
        }
        try RGSSWebRuntimeRequirements.validate(policy: GameWebRuntimePolicy(engine: request.engine))
        guard jobs[request.id] == nil else { throw RGSSRuntimeError.invalidArtifact("duplicate run request") }
        let target = artifactDirectory.appendingPathComponent(request.id.uuidString.lowercased())
        let pack = pack, mode = mode, builder = builder
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let inspection = try GameProjectInspector().inspect(context: request.context)
            let artifact = try builder.build(source: request.context, engine: request.engine,
                                             pack: pack, mode: mode, to: target)
            try Task.checkCancellation()
            return GamePreparedWebRun(inspection: inspection, package: artifact.package)
        }
        jobs[request.id] = task
        defer { jobs.removeValue(forKey: request.id) }
        return try await withTaskCancellationHandler(operation: { try await task.value },
                                                    onCancel: { task.cancel() })
    }

    public func cancel(_ request: GameWebRunRequest) async {
        guard let task = jobs[request.id] else { return }
        task.cancel()
        _ = await task.result
        jobs.removeValue(forKey: request.id)
    }
}
