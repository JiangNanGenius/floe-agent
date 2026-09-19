import Foundation
import Testing
import FloeCore
@testable import FloeProviders

/// Video routes are selected by their public candidate names. These tests pin
/// the contract that the conversation model (not the user) chooses among the
/// `video.models` candidates and that no internal UUID is ever required.
@Suite("FloeProviders.VideoModelRouteResolution")
struct VideoModelRouteResolutionTests {
    private func arkProvider(id: UUID = UUID()) -> ProviderProfile {
        ProviderProfile(
            id: id,
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
            displayName: "火山方舟",
            isEnabled: true
        )
    }

    private func videoModel(
        providerID: UUID,
        remoteModelID: String,
        displayName: String,
        enabled: Bool = true
    ) -> ModelProfile {
        ModelProfile(
            id: UUID(),
            providerID: providerID,
            remoteModelID: remoteModelID,
            displayName: displayName,
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.videoGeneration],
            useSurfaces: .videoGeneration,
            isEnabled: enabled
        )
    }

    @Test("public remote ID, display name, UUID spelling and normalized spelling all resolve")
    func publicSelectionsResolve() throws {
        let providerID = UUID()
        let seedance = videoModel(
            providerID: providerID,
            remoteModelID: "doubao-seedance-2-5-260628",
            displayName: "Seedance 2.5"
        )
        let routes = VideoModelRegistry.routes(
            models: [seedance],
            providers: [arkProvider(id: providerID)],
            preferredModelID: seedance.id
        )
        #expect(routes.count == 1)
        #expect(routes[0].publicModelID == "doubao-seedance-2-5-260628")

        let byRemoteID = try VideoModelRegistry.resolve(
            modelID: nil, selection: "doubao-seedance-2-5-260628", routes: routes
        )
        #expect(byRemoteID.modelID == seedance.id)
        let byName = try VideoModelRegistry.resolve(
            modelID: nil, selection: "Seedance 2.5", routes: routes
        )
        #expect(byName.modelID == seedance.id)
        let byUUIDSpelling = try VideoModelRegistry.resolve(
            modelID: nil, selection: seedance.id.uuidString.lowercased(), routes: routes
        )
        #expect(byUUIDSpelling.modelID == seedance.id)
        let byNormalizedPrefix = try VideoModelRegistry.resolve(
            modelID: nil, selection: "doubao seedance 2.5", routes: routes
        )
        #expect(byNormalizedPrefix.modelID == seedance.id)
        let byInternalID = try VideoModelRegistry.resolve(
            modelID: seedance.id, selection: nil, routes: routes
        )
        #expect(byInternalID.modelID == seedance.id)
    }

    @Test("omitting or blanking the selection uses the preferred route")
    func preferredFallback() throws {
        let providerID = UUID()
        let first = videoModel(
            providerID: providerID,
            remoteModelID: "doubao-seedance-2-5-260628",
            displayName: "Seedance 2.5"
        )
        let second = videoModel(
            providerID: providerID,
            remoteModelID: "veo-3.1-generate-preview",
            displayName: "Veo 3.1"
        )
        let provider = arkProvider(id: providerID)
        let routes = VideoModelRegistry.routes(
            models: [first, second],
            providers: [provider],
            preferredModelID: second.id
        )
        #expect(routes.first?.modelID == second.id)
        #expect(try VideoModelRegistry.resolve(modelID: nil, selection: nil, routes: routes).modelID == second.id)
        #expect(try VideoModelRegistry.resolve(modelID: nil, selection: "   ", routes: routes).modelID == second.id)
    }

    @Test("ambiguous and unknown selections fail with the public candidate list")
    func ambiguityAndUnknownAreExplicit() throws {
        let providerID = UUID()
        let base = videoModel(
            providerID: providerID,
            remoteModelID: "doubao-seedance-2-5-260628",
            displayName: "Seedance 2.5"
        )
        let extended = videoModel(
            providerID: providerID,
            remoteModelID: "doubao-seedance-2-5-260628-extra",
            displayName: "Seedance 2.5 Pro"
        )
        let routes = VideoModelRegistry.routes(
            models: [base, extended],
            providers: [arkProvider(id: providerID)],
            preferredModelID: nil
        )

        do {
            _ = try VideoModelRegistry.resolve(modelID: nil, selection: "seedance", routes: routes)
            Issue.record("ambiguous selection must fail")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("matches several candidates"))
            #expect(message.contains("doubao-seedance-2-5-260628"))
            #expect(!message.contains(base.id.uuidString))
        }
        do {
            _ = try VideoModelRegistry.resolve(modelID: nil, selection: "no-such-model", routes: routes)
            Issue.record("unknown selection must fail")
        } catch {
            #expect(error.localizedDescription.contains("Unknown video model"))
        }
        do {
            _ = try VideoModelRegistry.resolve(modelID: UUID(), selection: nil, routes: routes)
            Issue.record("stale internal UUID must fail")
        } catch {
            #expect(error.localizedDescription.contains("no longer enabled"))
        }
        do {
            _ = try VideoModelRegistry.resolve(modelID: nil, selection: nil, routes: [])
            Issue.record("empty catalog must fail")
        } catch {
            #expect(error.localizedDescription.contains("No configured, enabled and adapter-backed video model"))
        }
    }

    @Test("disabled models and non-adapter providers stay out of the catalog")
    func unusableRoutesAreNotExposed() {
        let arkID = UUID()
        let customID = UUID()
        let disabled = videoModel(
            providerID: arkID,
            remoteModelID: "doubao-seedance-2-5-260628",
            displayName: "Seedance 2.5",
            enabled: false
        )
        let custom = videoModel(
            providerID: customID,
            remoteModelID: "custom-video-1",
            displayName: "Custom Video"
        )
        let customProvider = ProviderProfile(
            id: customID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://video.example.com/v1")!,
            displayName: "Custom",
            isEnabled: true
        )
        let routes = VideoModelRegistry.routes(
            models: [disabled, custom],
            providers: [arkProvider(id: arkID), customProvider],
            preferredModelID: nil
        )
        #expect(routes.isEmpty)
        #expect(VideoModelRegistry.publicCandidates(routes).isEmpty)
    }
}
