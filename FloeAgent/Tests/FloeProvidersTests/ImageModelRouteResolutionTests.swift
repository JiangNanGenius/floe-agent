import Foundation
import Testing
import FloeCore
@testable import FloeProviders

/// Image routes accept a public selection name exactly like video routes: the
/// conversation model (not the user) chooses among the `image.models` public
/// candidates, an internal UUID is never required, and an ambiguous or unknown
/// selection fails closed with the public candidate list.
@Suite("FloeProviders.ImageModelRouteResolution")
struct ImageModelRouteResolutionTests {
    private func seedream(
        providerID: UUID,
        remoteModelID: String = "doubao-seedream-4-5-251128",
        displayName: String = "Seedream 4.5",
        enabled: Bool = true
    ) -> ModelProfile {
        ModelProfile(
            id: UUID(),
            providerID: providerID,
            remoteModelID: remoteModelID,
            displayName: displayName,
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.imageGeneration],
            useSurfaces: .imageGeneration,
            isEnabled: enabled
        )
    }

    @Test("public remote ID, display name, UUID spelling and normalized spelling all resolve")
    func publicSelectionsResolve() throws {
        let providerID = UUID()
        let model = seedream(providerID: providerID)
        let models = [model]

        #expect(try ImageModelRouteResolver.resolve(selection: "doubao-seedream-4-5-251128", models: models).id == model.id)
        #expect(try ImageModelRouteResolver.resolve(selection: "Seedream 4.5", models: models).id == model.id)
        #expect(try ImageModelRouteResolver.resolve(selection: model.id.uuidString, models: models).id == model.id)
        // Separator/case-insensitive normalized spelling.
        #expect(try ImageModelRouteResolver.resolve(selection: "Doubao Seedream 4 5 251128", models: models).id == model.id)
    }

    @Test("a public selection alone routes without any internal UUID")
    func publicModelOnlyRoutes() throws {
        let providerID = UUID()
        let preferred = seedream(providerID: providerID, remoteModelID: "seedream-lite", displayName: "Seedream Lite")
        let other = seedream(providerID: providerID, remoteModelID: "doubao-seedream-4-5-251128", displayName: "Seedream 4.5")
        // Resolution is by public name, independent of catalog order.
        let reordered = [other, preferred]
        #expect(try ImageModelRouteResolver.resolve(selection: "seedream-lite", models: reordered).id == preferred.id)
        #expect(try ImageModelRouteResolver.resolve(selection: "Seedream 4.5", models: reordered).id == other.id)
    }

    @Test("ambiguous and unknown selections fail closed with the public candidates")
    func ambiguousAndUnknownFailClosed() throws {
        let providerID = UUID()
        let a = seedream(providerID: providerID, remoteModelID: "seedream-pro", displayName: "Seedream Pro")
        let b = seedream(providerID: providerID, remoteModelID: "seedream-pro-max", displayName: "Seedream Pro Max")
        let models = [a, b]

        // "seedream" matches both via containment -> ambiguity, not a guess.
        do {
            _ = try ImageModelRouteResolver.resolve(selection: "seedream", models: models)
            Issue.record("ambiguous selection must fail")
        } catch {
            #expect(error.localizedDescription.contains("matches several candidates"))
            #expect(!error.localizedDescription.contains(a.id.uuidString))
        }
        do {
            _ = try ImageModelRouteResolver.resolve(selection: "nonexistent-model", models: models)
            Issue.record("unknown selection must fail")
        } catch {
            #expect(error.localizedDescription.contains("Unknown image model"))
        }
        do {
            _ = try ImageModelRouteResolver.resolve(selection: "   ", models: models)
            Issue.record("empty selection must fail")
        } catch {
            #expect(error.localizedDescription.contains("empty"))
        }
    }

    @Test("public candidate list never exposes internal UUIDs")
    func publicCandidatesAreSecretFree() {
        let providerID = UUID()
        let model = seedream(providerID: providerID)
        let list = ImageModelRouteResolver.publicCandidates([model])
        #expect(list.contains(model.remoteModelID))
        #expect(!list.contains(model.id.uuidString))
    }
}
