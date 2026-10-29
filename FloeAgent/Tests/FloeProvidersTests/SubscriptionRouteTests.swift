// FloeProvidersTests — Subscription gateway and Alibaba route contracts.
//
// Offline only: pure identity/route resolvers, request-body builders and the
// connection-probe request shape. No network, credentials or paid calls.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

private func profile(
    kind: ProviderKind,
    baseURL: String
) -> ProviderProfile {
    ProviderProfile(
        kind: kind,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: baseURL)!
    )
}

@Suite("FloeProviders.SubscriptionRoutes")
struct SubscriptionRouteTests {

    private let paygImageURL = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
    private let tokenPlanURL = URL(string: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")!
    private let workspaceURL = URL(string: "https://ws-123.cn-beijing.maas.aliyuncs.com")!

    @Test("Token Plan, PAYG workspace and Coding Plan remain distinct hosts")
    func hostIdentity() {
        #expect(AlibabaEndpointIdentity.isTokenPlan(tokenPlanURL))
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(tokenPlanURL))
        #expect(AlibabaEndpointIdentity.isPayAsYouGo(paygImageURL))
        #expect(AlibabaEndpointIdentity.isPayAsYouGo(workspaceURL))
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "https://coding.dashscope.aliyuncs.com/v1")!))
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "https://example.com/compatible-mode/v1")!))
    }

    @Test("Saved workspace URLs keep their key across path edits but not hosts")
    func savedWorkspaceCredentialBoundary() {
        let compatible = ProviderConfigurationValidation.ProviderConnectionIdentity.isCompatible
        let workspace = URL(string: "https://ws-123.cn-beijing.maas.aliyuncs.com")!
        let compatibleMode = URL(string: "https://ws-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")!
        let otherWorkspace = URL(string: "https://ws-456.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")!
        #expect(compatible(.custom, workspace, .custom, compatibleMode))
        #expect(!compatible(.custom, compatibleMode, .custom, otherWorkspace))
        #expect(!compatible(.alibabaStudio, paygImageURL, .custom, tokenPlanURL))
    }

    @Test("Compatible and native roots preserve saved path overrides")
    func rootMatrix() {
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(baseURL: paygImageURL).path == "/compatible-mode/v1")
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(baseURL: workspaceURL).path == "/compatible-mode/v1")
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(
            baseURL: URL(string: "https://dashscope.aliyuncs.com/api/v1")!
        ).path == "/compatible-mode/v1")
        let proxy = URL(string: "https://proxy.example/alibaba/compatible-mode/v1")!
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(baseURL: proxy) == proxy)
        #expect(AlibabaEndpointIdentity.nativeAPIRoot(baseURL: workspaceURL).path == "/api/v1")
        #expect(AlibabaEndpointIdentity.nativeAPIRoot(baseURL: tokenPlanURL).path == "/api/v1")
        #expect(AlibabaEndpointIdentity.nativeAPIRoot(baseURL: paygImageURL).path == "/api/v1")
    }

    @Test("Image families choose the documented wire route")
    func imageRouteMatrix() {
        let payg = profile(kind: .alibabaStudio, baseURL: paygImageURL.absoluteString)
        let token = profile(kind: .custom, baseURL: tokenPlanURL.absoluteString)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "qwen-image-3.0-pro") == .openAICompatible)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "qwen-image-2.1-pro") == .openAICompatible)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "qwen-image-2.1-turbo") == .openAICompatible)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "wan2.7-image") == .nativeMultimodal)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "wan2.6-image") == .nativeMultimodal)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "wan2.5-t2i-preview") == .nativeTask)
        // Token Plan uses the native multimodal route for every image model,
        // including Qwen Image 3.0 Pro.
        #expect(AlibabaImageWireRoute.resolve(provider: token, modelRemoteID: "qwen-image-3.0-pro") == .nativeMultimodal)
        #expect(AlibabaImageWireRoute.resolve(provider: token, modelRemoteID: "wan2.7-image") == .nativeMultimodal)
    }

    @Test("Video families classify Wan and HappyHorse without mixing contracts")
    func videoRouteMatrix() {
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "wan3.0-video") == .wan3)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "wan2.7-t2v") == .wan27)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "happyhorse-1.1-t2v") == .happyHorseText)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "happyhorse-1.1-i2v") == .happyHorseImage)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "wan2.5-t2v") == .legacy)
    }

    @Test("Adapter factories follow the endpoint identity, not kind alone")
    func factoryRouting() {
        let imageFactory = ImageProviderAdapterFactory()
        let videoFactory = VideoProviderAdapterFactory()
        let agent = profile(kind: .custom, baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL.absoluteString)
        #expect(imageFactory.adapter(for: agent) is VolcengineImageAdapter)
        // Agent Plan video stays closed this round, including a legacy
        // profile that stored the plan URL under another kind.
        #expect(videoFactory.adapter(for: agent) == nil)
        let legacyAgent = profile(kind: .volcengineArk, baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL.absoluteString)
        #expect(videoFactory.adapter(for: legacyAgent) == nil)

        let token = profile(kind: .custom, baseURL: tokenPlanURL.absoluteString)
        #expect(imageFactory.adapter(for: token) is AlibabaImageAdapter)
        #expect(videoFactory.adapter(for: token) is AlibabaVideoAdapter)

        let legacyPayg = profile(kind: .custom, baseURL: workspaceURL.absoluteString)
        #expect(imageFactory.adapter(for: legacyPayg) is AlibabaImageAdapter)
        #expect(videoFactory.adapter(for: legacyPayg) is AlibabaVideoAdapter)

        let coding = profile(kind: .custom, baseURL: "https://coding.dashscope.aliyuncs.com/v1")
        #expect(imageFactory.adapter(for: coding) == nil)
        #expect(videoFactory.adapter(for: coding) == nil)
    }

    @Test("Subscription probe uses chat/completions and never the listing route")
    func subscriptionProbeRequest() throws {
        let agent = profile(kind: .custom, baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL.absoluteString)
        let token = profile(kind: .custom, baseURL: tokenPlanURL.absoluteString)
        let payg = profile(kind: .alibabaStudio, baseURL: paygImageURL.absoluteString)
        #expect(ProviderConnectionProbe.usesMinimalChatProbe(provider: agent))
        #expect(ProviderConnectionProbe.usesMinimalChatProbe(provider: token))
        #expect(!ProviderConnectionProbe.usesMinimalChatProbe(provider: payg))

        for (provider, model) in [
            (agent, "ark-code-latest"),
            (token, "qwen3.8-flash")
        ] {
            let request = try ProviderConnectionProbe.minimalChatRequest(
                provider: provider,
                credentials: ProviderCredentials(apiKey: "test-key"),
                modelRemoteID: model
            )
            #expect(request.httpMethod == "POST")
            let path = try #require(request.url?.path)
            #expect(path.hasSuffix("/chat/completions"))
            #expect(!path.contains("/models"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == model)
            #expect(json["stream"] as? Bool == false)
            #expect((json["messages"] as? [[String: Any]])?.count == 1)
        }
    }

    @Test("Plan media offers exclude the undeclared conversation role")
    func planOffersDoNotInventConversation() {
        let agent = ProviderServiceOfferResolver.resolvedOffers(
            for: .custom,
            presetID: "volcengine-agent-plan",
            baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL,
            authStyle: "bearer",
            availability: .available,
            declared: [ProviderCatalogServiceOffer(role: .image, models: ["doubao-seedream-5.0-lite"])]
        )
        #expect(agent.map(\.role) == [.image])
        #expect(agent.first?.isUsable == true)

        let token = ProviderServiceOfferResolver.resolvedOffers(
            for: .custom,
            presetID: "alibaba-token-plan",
            baseURL: tokenPlanURL,
            authStyle: "bearer",
            availability: .available,
            declared: [
                ProviderCatalogServiceOffer(role: .image, models: ["qwen-image-3.0-pro"]),
                ProviderCatalogServiceOffer(role: .video, models: ["wan3.0-video"])
            ]
        )
        #expect(token.map(\.role) == [.image, .video])
        #expect(token.allSatisfy { $0.isUsable })
    }

    @Test("HappyHorse requests keep their documented family parameters")
    func happyHorseRequestBodies() throws {
        let text = try AlibabaVideoAdapter.requestBody(
            RemoteVideoRequest(
                prompt: "city at night",
                modelRemoteID: "happyhorse-1.1-t2v",
                options: VideoGenerationOptions(
                    aspectRatio: "9:16",
                    resolution: "720p",
                    durationSeconds: 10,
                    seed: 7,
                    watermark: true
                )
            )
        )
        let textParameters = try #require(text["parameters"] as? [String: Any])
        #expect(textParameters["ratio"] as? String == "9:16")
        #expect(textParameters["resolution"] as? String == "720P")
        #expect(textParameters["duration"] as? Int == 10)
        #expect(textParameters["seed"] as? Int == 7)
        #expect(textParameters["watermark"] as? Bool == true)
        #expect(textParameters["audio"] == nil)

        let firstFrame = URL(string: "https://example.com/frame.png")!
        let image = try AlibabaVideoAdapter.requestBody(
            RemoteVideoRequest(
                prompt: "animate",
                modelRemoteID: "happyhorse-1.1-i2v",
                options: VideoGenerationOptions(resolution: "1080P", durationSeconds: 5),
                referenceAssetURLs: [firstFrame]
            )
        )
        let imageInput = try #require(image["input"] as? [String: Any])
        let media = try #require(imageInput["media"] as? [[String: Any]])
        #expect(media.first?["type"] as? String == "first_frame")
        #expect(media.first?["url"] as? String == firstFrame.absoluteString)
        let imageParameters = try #require(image["parameters"] as? [String: Any])
        #expect(imageParameters["ratio"] == nil)
        #expect(imageParameters["resolution"] as? String == "1080P")

        #expect(throws: RemoteVideoError.self) {
            try AlibabaVideoAdapter.requestBody(
                RemoteVideoRequest(
                    prompt: "bad duration",
                    modelRemoteID: "happyhorse-1.1-t2v",
                    options: VideoGenerationOptions(durationSeconds: 16)
                )
            )
        }
        #expect(throws: RemoteVideoError.self) {
            try AlibabaVideoAdapter.requestBody(
                RemoteVideoRequest(
                    prompt: "bad audio",
                    modelRemoteID: "happyhorse-1.1-t2v",
                    options: VideoGenerationOptions(includeAudio: true)
                )
            )
        }
        #expect(throws: RemoteVideoError.self) {
            try AlibabaVideoAdapter.requestBody(
                RemoteVideoRequest(
                    prompt: "ratio follows image",
                    modelRemoteID: "happyhorse-1.1-i2v",
                    options: VideoGenerationOptions(aspectRatio: "16:9"),
                    referenceAssetURLs: [firstFrame]
                )
            )
        }
    }

    @Test("Token Plan video contracts expose the real HappyHorse limits")
    func tokenPlanVideoContract() {
        let token = profile(kind: .custom, baseURL: tokenPlanURL.absoluteString)
        func model(_ remoteID: String) -> ModelProfile {
            ModelProfile(
                providerID: token.id,
                remoteModelID: remoteID,
                displayName: remoteID,
                limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
                capabilities: [.videoGeneration],
                useSurfaces: .videoGeneration
            )
        }
        let text = VideoModelRegistry.contract(model: model("happyhorse-1.1-t2v"), provider: token)
        #expect(text.supportedDurations == Array(3...15))
        #expect(text.resolutions == ["480P", "720P", "1080P"])
        #expect(text.aspectRatios.contains("21:9"))
        #expect(text.maximumReferenceAssets == 0)
        #expect(!text.supportsAudio)
        #expect(text.supportsWatermark)
        #expect(text.supportsSeed)

        let image = VideoModelRegistry.contract(model: model("happyhorse-1.1-i2v"), provider: token)
        #expect(image.aspectRatios.isEmpty)
        #expect(image.maximumReferenceAssets == 1)
        #expect(image.referenceMode == "first_frame")
    }

    @Test("Alibaba video task status keeps the real task identity and failures")
    func videoStatusDecoding() throws {
        let succeeded = try AlibabaVideoAdapter.decodeStatus([
            "output": [
                "task_id": "task-real-1",
                "task_status": "SUCCEEDED",
                "video_url": "https://dashscope-result.example/video.mp4"
            ]
        ])
        #expect(succeeded.state == .completed)
        #expect(succeeded.resultURL?.absoluteString == "https://dashscope-result.example/video.mp4")

        let failed = try AlibabaVideoAdapter.decodeStatus([
            "output": [
                "task_id": "task-real-1",
                "task_status": "FAILED",
                "code": "InvalidParameter",
                "message": "bad request"
            ]
        ])
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("bad request") == true)

        let unknown = try AlibabaVideoAdapter.decodeStatus([
            "output": ["task_id": "task-real-1", "task_status": "UNKNOWN"]
        ])
        #expect(unknown.state == .expired)
    }
}
