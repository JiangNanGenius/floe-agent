// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeHeavyEditorSupport
import FloeHeavyEditorsHostAdapter

/// One App-owned composition retains every domain host and registers exactly
/// six names per host. No Settings presenter or visible controller is global.
@MainActor final class HeavyEditorAppTools {
    static let names = FontDesignAIHost.names.union(MusicNotationAITools.names).union(GISProductionHost.names)
    private weak var environment: AppEnvironment?
    private let font: FontDesignAIHost
    private let score: MusicNotationAITools
    private let gis: HeavyEditorToolBridge
    private(set) var registered = false
    init(environment: AppEnvironment, font: FontDesignAIHost) {
        self.environment = environment; self.font = font
        score = MusicNotationAITools(environment: environment)
        gis = makeGISProductionToolBridge(environment: environment)
    }
    func register(in registry: ToolRunnerRegistry = .shared) throws {
        guard !registered else { return }
        try font.bridge.register(in: registry, kinds: [.font])
        try score.register(in: registry)
        try gis.register(in: registry, kinds: [.gis])
        registered = true
    }
    /// Actual ToolContext only. Each host repeats the saved-run/binding checks;
    /// this index grants nothing and no execution tool name is fabricated.
    func descriptors(for context: ToolContext) async throws -> [ToolCatalog.Descriptor] {
        guard registered else { return [] }
        let a = try await font.bridge.descriptors(for: context)
        let b = try await score.descriptors(for: context)
        let c = try await gis.descriptors(for: context)
        return a + b + c
    }
}
#endif
