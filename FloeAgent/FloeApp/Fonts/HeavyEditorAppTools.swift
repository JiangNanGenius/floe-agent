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
        // Each editor has its own native store. A missing GIS binding must not
        // discard the fonts or notation descriptors already authorized here.
        var available: [ToolCatalog.Descriptor] = []
        for (domain, load) in [
            ("font", font.bridge.descriptors(for:)),
            ("score", score.descriptors(for:)),
            ("gis", gis.descriptors(for:))
        ] as [(String, @MainActor (ToolContext) async throws -> [ToolCatalog.Descriptor])] {
            try Task.checkCancellation()
            try context.cancellation.throwIfCancelled()
            do {
                available += try await load(context)
            } catch {
                try Task.checkCancellation()
                try context.cancellation.throwIfCancelled()
                FloeLogger(category: .tools).warning("editorDiscoveryUnavailable domain=\(domain)")
            }
        }
        return available
    }
}
#endif
