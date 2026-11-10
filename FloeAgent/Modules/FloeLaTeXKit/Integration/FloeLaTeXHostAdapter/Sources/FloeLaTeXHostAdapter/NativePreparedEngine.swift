// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXEngine

/// Preparation has already compiled this coherent revision to XDV and joined
/// its native worker. The real build reuses only verified resource data, then
/// compiles its own immutable snapshot and renders its own PDF.
struct LaTeXNativePreparedEngine: LaTeXEngineRunning {
    let engine: LaTeXAppleNativeEngine
    let manifest: LaTeXProjectManifest
    let owner: LaTeXExecutionOwner
    let configuration: LaTeXBuildConfiguration
    let preparationProgress: @Sendable (LaTeXPreparationProgress) -> Void
    func capabilities() async -> [LaTeXEngineCapability] { await engine.capabilities() }
    func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        guard request.executionOwner == owner, request.snapshot.manifest == manifest else {
            throw LaTeXError.unavailable("The original or its owning run changed during preparation. Retry its current revision.")
        }
        var native = request
        // Task policy can tighten offline behavior; tool arguments cannot
        // grant networking that this native preparation did not authorize.
        native.configuration.offline = configuration.offline || request.configuration.offline
        native.configuration.bundlePath = configuration.bundlePath
        native.configuration.timeoutSeconds = min(configuration.timeoutSeconds, request.configuration.timeoutSeconds)
        preparationProgress(.init(stage: .compiling))
        return try await engine.run(native, progress: progress)
    }
}
