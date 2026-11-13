// SPDX-License-Identifier: MPL-2.0
//
// G09-R2ProviderRoutingTests — synthetic regressions for the nine media
// provider sources refreshed from public iOS 10fc0083:
//   * Alibaba Model Studio connection-family identity (PAYG, Token Plan,
//     Agent Plan, Coding Plan exclusion) and image/video wire routing;
//   * Seedream 5.0 pro/flash/lite family limits and Agent Plan presets;
//   * verified Kimi Code Coding Plan image route and strict non-routes;
//   * HappyHorse text/image request bodies, Wan 3.0 first-frame body and the
//     documented refusals (no audio, no prompt extension, image-aspect rule);
//   * reference-image policy + inline data URL sniffing.
//
// No test performs a real provider request, reads a credential or opens a
// socket: every path exercised here is a pure routing/body/refusal decision.
// Authored for the existing FloeAndroidCoreTests target; execution is left to
// the coherent R2 batch because it would compile the full Core test target.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore
import FloeTransport
import Testing
@testable import FloeProviders

@Suite("G09R2ProviderRoutingTests")
struct G09R2ProviderRoutingTests {

    // MARK: - Fixtures (synthetic configuration only)

    private func provider(
        kind: ProviderKind = .custom,
        baseURL: String,
        enabled: Bool = true
    ) -> ProviderProfile {
        ProviderProfile(
            kind: kind,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: baseURL)!,
            isEnabled: enabled
        )
    }

    private func model(
        provider: ProviderProfile,
        remoteModelID: String,
        capabilities: ModelCapabilities
    ) -> ModelProfile {
        ModelProfile(
            providerID: provider.id,
            remoteModelID: remoteModelID,
            displayName: remoteModelID,
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: capabilities
        )
    }

    private func parameters(_ body: [String: Any]) -> [String: Any] {
        body["parameters"] as? [String: Any] ?? [:]
    }

    private func input(_ body: [String: Any]) -> [String: Any] {
        body["input"] as? [String: Any] ?? [:]
    }

    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    // MARK: - Alibaba connection identity

    @Test("Token Plan identity requires the documented host/path, not just a host prefix")
    func tokenPlanIdentityIsPathBound() {
        let billingURL = URL(string: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")!
        #expect(ProviderBillingEndpoint.resolve(billingURL) == .alibabaTokenPlan)
        #expect(AlibabaEndpointIdentity.isTokenPlan(billingURL))
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(billingURL))

        // The documented Token Plan Anthropic root is recognised by the host
        // prefix even though the billing resolver only names the OpenAI root.
        let anthropicRoot = URL(string: "https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic/v1")!
        #expect(AlibabaEndpointIdentity.isTokenPlan(anthropicRoot))

        // Host alone is not an identity: an undocumented path on the Token
        // Plan host falls through every connection family.
        let undocumented = URL(string: "https://token-plan.cn-beijing.maas.aliyuncs.com/other/v1")!
        #expect(!AlibabaEndpointIdentity.isTokenPlan(undocumented))
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(undocumented))
    }

    @Test("PAYG roots include dashscope and workspace hosts but exclude Coding Plan")
    func payAsYouGoRoots() {
        #expect(AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "https://dashscope.aliyuncs.com")!))
        #expect(AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "https://dashscope-intl.aliyuncs.com")!))
        #expect(AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "https://ws-123.cn-beijing.maas.aliyuncs.com")!))
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "https://coding.dashscope.aliyuncs.com/v1")!))
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "https://api.kimi.com/coding")!))
        // Plain HTTP is never an accepted DashScope identity.
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(URL(string: "http://dashscope.aliyuncs.com")!))
    }

    @Test("Agent Plan is a Volcengine subscription identity, not a DashScope PAYG root")
    func agentPlanIdentity() {
        let plan = URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3")!
        #expect(ProviderBillingEndpoint.resolve(plan) == .volcengineAgentPlan)
        #expect(!AlibabaEndpointIdentity.isPayAsYouGo(plan))
        #expect(!AlibabaEndpointIdentity.isTokenPlan(plan))
    }

    @Test("compatible-mode normalisation keeps proxies and only rewrites DashScope roots")
    func compatibleModeRootNormalisation() {
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(
            baseURL: URL(string: "https://dashscope.aliyuncs.com/api/v1")!
        ).absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1")
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(
            baseURL: URL(string: "https://ws-123.cn-beijing.maas.aliyuncs.com")!
        ).absoluteString == "https://ws-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(
            baseURL: URL(string: "https://proxy.example.com/dashscope/api/v1")!
        ).absoluteString == "https://proxy.example.com/dashscope/compatible-mode/v1")
        // Already-compatible and unrelated custom paths are preserved.
        let compatible = URL(string: "https://proxy.example.com/compatible-mode/v1")!
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(baseURL: compatible) == compatible)
        let custom = URL(string: "https://proxy.example.com/v1")!
        #expect(AlibabaEndpointIdentity.compatibleModeRoot(baseURL: custom) == custom)
    }

    // MARK: - Alibaba image routing

    @Test("Token Plan image models always use native multimodal generation")
    func tokenPlanImageRouting() {
        let plan = provider(baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        for remoteID in ["qwen-image-3.0-plus", "wan2.6-image", "unknown-model"] {
            #expect(AlibabaImageWireRoute.resolve(provider: plan, modelRemoteID: remoteID) == .nativeMultimodal)
        }
    }

    @Test("PAYG image routing separates Qwen OpenAI-compatible, multimodal and legacy task APIs")
    func payAsYouGoImageRouting() {
        let payg = provider(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "qwen-image-3.0-plus") == .openAICompatible)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "qwen-image-2.1") == .openAICompatible)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "qwen-image-2.0") == .nativeMultimodal)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "wan2.6-image") == .nativeMultimodal)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "wan2.7-image-pro") == .nativeMultimodal)
        #expect(AlibabaImageWireRoute.resolve(provider: payg, modelRemoteID: "wanx2.1-t2i-turbo") == .nativeTask)
    }

    @Test("Qwen reference-image allowances follow the documented family contract")
    func qwenReferenceAllowances() {
        let adapter = AlibabaImageAdapter()
        #expect(adapter.maximumSourceImages(for: .generate, modelRemoteID: "qwen-image-3.0-plus") == 0)
        #expect(adapter.maximumSourceImages(for: .edit, modelRemoteID: "qwen-image-3.0-plus") == 3)
        #expect(adapter.maximumSourceImages(for: .edit, modelRemoteID: "qwen-image-2.1") == 10)
        #expect(adapter.maximumSourceImages(for: .edit, modelRemoteID: "wan2.7-image-pro") == 9)
        #expect(adapter.maximumSourceImages(for: .edit, modelRemoteID: "wan2.6-image") == 4)
        #expect(adapter.maximumSourceImages(for: .edit, modelRemoteID: "unknown") == 0)
        #expect(!adapter.supports(.variation, for: provider(
            baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        )))
    }

    // MARK: - Seedream 5.0 family

    @Test("Seedream 5.0 resolves every official spelling and rejects other families")
    func seedreamFamilyResolution() {
        #expect(Seedream5ImageFamily.resolve("seedream-5.0-pro-260915") == .pro)
        #expect(Seedream5ImageFamily.resolve("seedream-5-0-flash") == .flash)
        #expect(Seedream5ImageFamily.resolve("seedream-5.0-lite") == .lite)
        #expect(Seedream5ImageFamily.resolve("seedream-4.0-pro") == nil)
        #expect(Seedream5ImageFamily.resolve(nil) == nil)
        #expect(Seedream5ImageFamily.resolve("seedream-5.0") == nil)
    }

    @Test("Agent Plan parameter contract uses the documented pro/flash/lite limits")
    func agentPlanSeedreamContracts() {
        let plan = provider(baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3")

        let pro = ImageGenerationPresetResolver.parameterContract(
            provider: plan,
            model: model(provider: plan, remoteModelID: "seedream-5.0-pro-260915",
                         capabilities: [.imageGeneration]),
            operation: .generate
        )
        #expect(pro.verifiedModel)
        #expect(pro.resolution == ["1K", "1.5K", "2K"])
        #expect(pro.defaultResolution == "2K")
        #expect(pro.maximumCount == 1)
        #expect(pro.maximumReferenceImages == 0)

        let flash = ImageGenerationPresetResolver.parameterContract(
            provider: plan,
            model: model(provider: plan, remoteModelID: "seedream-5.0-flash",
                         capabilities: [.imageGeneration]),
            operation: .generate
        )
        #expect(flash.resolution == ["1K", "1.5K", "2K"])
        #expect(flash.maximumCount == 1)

        let lite = ImageGenerationPresetResolver.parameterContract(
            provider: plan,
            model: model(provider: plan, remoteModelID: "seedream-5.0-lite",
                         capabilities: [.imageGeneration]),
            operation: .generate
        )
        #expect(lite.resolution == ["2K", "3K", "4K"])
        #expect(lite.maximumCount == 4)
    }

    @Test("Seedream 5.0 pro/flash reject 3K while lite keeps it; 1.5K stays 8-pixel aligned")
    func seedreamNativeSizes() throws {
        #expect(try ImageGenerationPresetResolver.nativeSize(
            provider: .volcengineArk,
            modelRemoteID: "seedream-5.0-pro-260915",
            operation: .generate,
            selection: ImageGenerationSelection(resolution: "1.5K")
        ) == "1536x1536")

        #expect(throws: RemoteImageError.self) {
            _ = try ImageGenerationPresetResolver.nativeSize(
                provider: .volcengineArk,
                modelRemoteID: "seedream-5.0-pro-260915",
                operation: .generate,
                selection: ImageGenerationSelection(resolution: "3K")
            )
        }
        #expect(throws: RemoteImageError.self) {
            _ = try ImageGenerationPresetResolver.nativeSize(
                provider: .volcengineArk,
                modelRemoteID: "seedream-5-0-flash",
                operation: .generate,
                selection: ImageGenerationSelection(resolution: "3K")
            )
        }
        #expect(try ImageGenerationPresetResolver.nativeSize(
            provider: .volcengineArk,
            modelRemoteID: "seedream-5.0-lite",
            operation: .generate,
            selection: ImageGenerationSelection(resolution: "3K")
        ) == "3072x3072")
    }

    // MARK: - Kimi Code image route

    @Test("Kimi route accepts only the two evidenced Coding Plan roots")
    func kimiRootVariants() {
        #expect(KimiCodeEndpointIdentity.apiRoot(
            for: URL(string: "https://api.kimi.com/coding")!
        )?.absoluteString == "https://api.kimi.com/coding/v1")
        #expect(KimiCodeEndpointIdentity.apiRoot(
            for: URL(string: "https://api.kimi.com/coding/v1/")!
        )?.absoluteString == "https://api.kimi.com/coding/v1")
        #expect(KimiCodeEndpointIdentity.apiRoot(
            for: URL(string: "https://api.kimi.com/coding/")!
        )?.absoluteString == "https://api.kimi.com/coding/v1")

        #expect(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.kimi.com")!) == nil)
        #expect(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.kimi.com/coding/chat")!) == nil)
        #expect(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.kimi.com/coding?x=1")!) == nil)
        #expect(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "http://api.kimi.com/coding")!) == nil)
        #expect(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.moonshot.ai/v1")!) == nil)
    }

    @Test("Image adapter factory selects Kimi only for the verified custom route")
    func kimiFactoryIdentity() {
        let factory = ImageProviderAdapterFactory()
        let kimi = provider(baseURL: "https://api.kimi.com/coding")
        #expect(factory.adapter(for: kimi) is KimiImageAdapter)

        let moonshot = provider(baseURL: "https://api.moonshot.ai/v1")
        #expect(factory.adapter(for: moonshot) == nil)

        let payg = provider(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        #expect(factory.adapter(for: payg) is AlibabaImageAdapter)

        let tokenPlan = provider(baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        #expect(factory.adapter(for: tokenPlan) is AlibabaImageAdapter)
    }

    @Test("Kimi adapter pins one output and one edit reference")
    func kimiAdapterLimits() {
        let adapter = KimiImageAdapter()
        let kimi = provider(baseURL: "https://api.kimi.com/coding/v1")
        #expect(adapter.supportedOperations(for: kimi) == [.generate, .edit])
        #expect(adapter.maximumSourceImages(for: .generate, modelRemoteID: "kimi-k2-image") == 0)
        #expect(adapter.maximumSourceImages(for: .edit, modelRemoteID: "kimi-k2-image") == 1)
        #expect(adapter.maximumOutputImages(modelRemoteID: "kimi-k2-image") == 1)
    }

    @Test("Kimi refuses an unevidenced operation before any request")
    func kimiUnsupportedOperationIsPreflightRefusal() async {
        let kimi = provider(baseURL: "https://api.kimi.com/coding")
        let request = RemoteImageRequest(
            operation: .variation,
            prompt: "synthetic",
            modelRemoteID: "kimi-k2-image"
        )
        await #expect(throws: RemoteImageError.self) {
            _ = try await KimiImageAdapter().perform(
                request,
                provider: kimi,
                credentials: ProviderCredentials(apiKey: "synthetic-not-used")
            )
        }
    }

    // MARK: - Alibaba video routing and bodies

    @Test("Video model family classification covers Wan 3.0/2.7, HappyHorse and legacy")
    func alibabaVideoRoutes() {
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "wan3.0-t2v") == .wan3)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "wan3-0-i2v") == .wan3)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "wan2.7-i2v") == .wan27)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "happyhorse-1.1-t2v") == .happyHorseText)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "happyhorse-1.1-i2v") == .happyHorseImage)
        #expect(AlibabaVideoWireRoute.resolve(modelRemoteID: "wan2.6-t2v") == .legacy)
        #expect(AlibabaVideoWireRoute.happyHorseText.isHappyHorse)
        #expect(AlibabaVideoWireRoute.happyHorseImage.isHappyHorse)
        #expect(!AlibabaVideoWireRoute.wan3.isHappyHorse)
    }

    @Test("HappyHorse text-to-video body carries ratio, duration, resolution and no audio")
    func happyHorseTextBody() throws {
        let body = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
            prompt: "a synthetic garden",
            modelRemoteID: "happyhorse-1.1-t2v",
            options: VideoGenerationOptions(
                aspectRatio: "16:9",
                resolution: "720p",
                durationSeconds: 5,
                seed: 7,
                watermark: true
            )
        ))
        #expect(body["model"] as? String == "happyhorse-1.1-t2v")
        #expect(input(body)["prompt"] as? String == "a synthetic garden")
        #expect(input(body)["media"] == nil)
        let parameters = parameters(body)
        #expect(parameters["ratio"] as? String == "16:9")
        #expect(parameters["duration"] as? Int == 5)
        #expect(parameters["resolution"] as? String == "720P")
        #expect(parameters["watermark"] as? Bool == true)
        #expect(parameters["seed"] as? Int == 7)
        #expect(parameters["audio"] == nil)
    }

    @Test("HappyHorse image-to-video body carries exactly one first-frame data URL")
    func happyHorseImageBody() throws {
        let reference = try VideoReferenceImagePolicy.inlineDataURL(
            data: pngBytes, declaredMIMEType: "image/png"
        )
        let body = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
            prompt: "a synthetic garden",
            modelRemoteID: "happyhorse-1.1-i2v",
            options: VideoGenerationOptions(resolution: "1080P", durationSeconds: 8),
            referenceAssetURLs: [reference]
        ))
        let media = input(body)["media"] as? [[String: Any]]
        #expect(media?.count == 1)
        #expect(media?.first?["type"] as? String == "first_frame")
        let url = media?.first?["url"] as? String
        #expect(url?.hasPrefix("data:image/png;base64,") == true)
        #expect(parameters(body)["ratio"] == nil)
        #expect(parameters(body)["duration"] as? Int == 8)
        #expect(parameters(body)["resolution"] as? String == "1080P")
    }

    @Test("HappyHorse refusals stay preflight: aspect on i2v, image on t2v, audio, prompt extension, bounds")
    func happyHorseRefusals() throws {
        let reference = try VideoReferenceImagePolicy.inlineDataURL(data: pngBytes)

        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "happyhorse-1.1-i2v",
                options: VideoGenerationOptions(aspectRatio: "16:9"),
                referenceAssetURLs: [reference]
            ))
        }
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "happyhorse-1.1-t2v",
                referenceAssetURLs: [reference]
            ))
        }
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "happyhorse-1.1-i2v",
                options: VideoGenerationOptions(includeAudio: true),
                referenceAssetURLs: [reference]
            ))
        }
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "happyhorse-1.1-t2v",
                options: VideoGenerationOptions(promptOptimization: true)
            ))
        }
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "happyhorse-1.1-t2v",
                options: VideoGenerationOptions(durationSeconds: 16)
            ))
        }
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "happyhorse-1.1-t2v",
                options: VideoGenerationOptions(resolution: "4K")
            ))
        }
        // Image-to-video without the required first frame is not silently
        // downgraded to text-to-video.
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "happyhorse-1.1-i2v"
            ))
        }
    }

    @Test("Wan 3.0 first-frame body forces adaptive ratio and uppercases resolution")
    func wan3ReferenceBody() throws {
        let reference = try VideoReferenceImagePolicy.inlineDataURL(data: pngBytes)
        let body = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
            prompt: "p",
            modelRemoteID: "wan3.0-t2v",
            options: VideoGenerationOptions(
                aspectRatio: "9:16",
                resolution: "1080p",
                durationSeconds: 10,
                includeAudio: true
            ),
            referenceAssetURLs: [reference]
        ))
        let media = input(body)["media"] as? [[String: Any]]
        #expect(media?.first?["type"] as? String == "first_frame")
        let parameters = parameters(body)
        #expect(parameters["ratio"] as? String == "adaptive")
        #expect(parameters["duration"] as? Int == 10)
        #expect(parameters["resolution"] as? String == "1080P")
        #expect(parameters["audio"] as? Bool == true)
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "wan3.0-t2v",
                options: VideoGenerationOptions(durationSeconds: 31)
            ))
        }
        // Wan 2.7 has no verified first-frame field.
        #expect(throws: RemoteVideoError.self) {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "p", modelRemoteID: "wan2.7-i2v",
                referenceAssetURLs: [reference]
            ))
        }
    }

    // MARK: - Reference-image policy

    @Test("Reference-image support is advertised only for verified video families")
    func referenceImageSupportMatrix() {
        #expect(VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .alibabaStudio, modelRemoteID: "wan3.0-t2v"
        ))
        #expect(!VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .alibabaStudio, modelRemoteID: "wan2.7-i2v"
        ))
        #expect(!VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .alibabaStudio, modelRemoteID: "happyhorse-1.1-t2v"
        ))
        #expect(VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .alibabaStudio, modelRemoteID: "happyhorse-1.1-i2v"
        ))

        let payg = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        #expect(VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .custom, modelRemoteID: "happyhorse-1.1-i2v", baseURL: payg
        ))
        #expect(!VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .custom, modelRemoteID: "happyhorse-1.1-i2v",
            baseURL: URL(string: "https://api.example.com/v1")!
        ))
        #expect(!VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .openAI, modelRemoteID: "sora"
        ))
    }

    @Test("Inline reference URLs sniff real bytes and reject empty/mismatched/unsupported data")
    func inlineDataURLValidation() throws {
        let url = try VideoReferenceImagePolicy.inlineDataURL(
            data: pngBytes, declaredMIMEType: "image/png"
        )
        #expect(url.scheme == "data")
        #expect(url.absoluteString.hasPrefix("data:image/png;base64,"))

        // JPEG signature is accepted when the declared type agrees.
        let jpeg = try VideoReferenceImagePolicy.inlineDataURL(
            data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
            declaredMIMEType: "image/jpeg"
        )
        #expect(jpeg.absoluteString.hasPrefix("data:image/jpeg;base64,"))

        #expect(throws: RemoteVideoError.self) {
            _ = try VideoReferenceImagePolicy.inlineDataURL(data: Data())
        }
        #expect(throws: RemoteVideoError.self) {
            _ = try VideoReferenceImagePolicy.inlineDataURL(
                data: pngBytes, declaredMIMEType: "image/jpeg"
            )
        }
        #expect(throws: RemoteVideoError.self) {
            _ = try VideoReferenceImagePolicy.inlineDataURL(data: Data("<svg></svg>".utf8))
        }
    }

    // MARK: - Video route usability

    @Test("Video usability requires an enabled native adapter and a real remote id")
    func videoUsability() {
        let dashscope = provider(kind: .alibabaStudio, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        let happyHorse = model(provider: dashscope, remoteModelID: "happyhorse-1.1-t2v",
                               capabilities: [.videoGeneration])
        #expect(VideoModelRegistry.isUsable(model: happyHorse, provider: dashscope))

        let disabled = provider(kind: .alibabaStudio,
                                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                                enabled: false)
        #expect(!VideoModelRegistry.isUsable(model: happyHorse, provider: disabled))

        let empty = model(provider: dashscope, remoteModelID: "   ", capabilities: [.videoGeneration])
        #expect(!VideoModelRegistry.isUsable(model: empty, provider: dashscope))

        // A hand-entered DashScope PAYG base keeps the native adapter.
        let customPayg = provider(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        let customModel = model(provider: customPayg, remoteModelID: "wan3.0-t2v",
                                capabilities: [.videoGeneration])
        #expect(VideoModelRegistry.isUsable(model: customModel, provider: customPayg))

        // Unrelated custom hosts and the Agent Plan subscription have no
        // native video route in this round.
        let unrelated = provider(baseURL: "https://api.example.com/v1")
        let unrelatedModel = model(provider: unrelated, remoteModelID: "wan3.0-t2v",
                                   capabilities: [.videoGeneration])
        #expect(!VideoModelRegistry.isUsable(model: unrelatedModel, provider: unrelated))

        let agentPlan = provider(baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3")
        let planModel = model(provider: agentPlan, remoteModelID: "seedance-1.0-pro",
                              capabilities: [.videoGeneration])
        #expect(!VideoModelRegistry.isUsable(model: planModel, provider: agentPlan))
    }
}


// MARK: - Provider-issued image URL download + bounded wire phases

/// One provider-issued image URL is downloaded through the injectable seam
/// (production uses `RemoteImageHTTP.makeImageDownloadSession`, which on
/// Linux/Android is a `StreamingTransport` session — the previous custom
/// `URLSession(configuration:delegate:)` failed closed with
/// `sessionNotStreamable` AFTER the provider had generated and billed the
/// image). These cases pin the URL branch and the non-secret phase trace used
/// by the durable failure diagnostic.
@Suite("G09R2ImageWireDiagnosticsTests")
struct G09R2ImageWireDiagnosticsTests {
    private final class PhaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [RemoteImageWirePhase] = []

        func append(_ phase: RemoteImageWirePhase) {
            lock.withLock { storage.append(phase) }
        }

        var values: [RemoteImageWirePhase] {
            lock.withLock { storage }
        }
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: URLRequest?

        func store(_ request: URLRequest) {
            lock.withLock { storage = request }
        }

        var value: URLRequest? {
            lock.withLock { storage }
        }
    }

    private let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xDF, 0xC0, 0xF0,
        0x1F, 0x00, 0x06, 0x80, 0x02, 0x7F, 0x10, 0x4C, 0x1B, 0xE1, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    private func urlResponse(
        _ url: URL, mimeType: String, byteCount: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": String(byteCount),
            ])!
    }

    @Test("A provider URL result downloads through the seam and records bounded phases")
    func providerURLResultDownloadsAndRecordsPhases() async throws {
        let responseBody = Data(
            #"{"data":[{"url":"https://cdn.example.com/generated.png"}]}"#.utf8)
        let phases = PhaseBox()
        let captured = RequestBox()
        let images = try await RemoteImageDecoder.images(
            from: responseBody,
            b64Key: "b64_json",
            urlKey: "url",
            requestedCount: 1,
            observer: { phases.append($0) },
            downloader: { request in
                captured.store(request)
                let url = request.url ?? URL(string: "https://invalid.example")!
                return (self.pngBytes, self.urlResponse(
                    url, mimeType: "image/png",
                    byteCount: self.pngBytes.count))
            })
        #expect(images == [pngBytes])
        #expect(phases.values == [
            .downloadStarted, .downloadCompleted, .imagesDecoded,
        ])
        #expect(captured.value?.url?.absoluteString
            == "https://cdn.example.com/generated.png")
        #expect(captured.value?.timeoutInterval
            == RemoteImageHTTP.nonStreamingRequestTimeout)
    }

    @Test("A failed provider URL download records only downloadStarted and propagates the typed error")
    func failedProviderURLDownloadRecordsStartedOnly() async throws {
        let responseBody = Data(
            #"{"data":[{"url":"https://cdn.example.com/generated.png"}]}"#.utf8)
        let phases = PhaseBox()
        await #expect(throws: IncrementalTransportError.self) {
            _ = try await RemoteImageDecoder.images(
                from: responseBody,
                b64Key: "b64_json",
                urlKey: "url",
                requestedCount: 1,
                observer: { phases.append($0) },
                downloader: { _ in
                    throw IncrementalTransportError.sessionNotStreamable(
                        reason: "synthetic non-streamable download session")
                })
        }
        #expect(phases.values == [.downloadStarted])
    }

    @Test("A non-image download response is rejected before any bytes are returned")
    func nonImageDownloadIsRejected() async throws {
        let responseBody = Data(
            #"{"data":[{"url":"https://cdn.example.com/not-an-image"}]}"#.utf8)
        let phases = PhaseBox()
        await #expect(throws: RemoteImageError.self) {
            _ = try await RemoteImageDecoder.images(
                from: responseBody,
                b64Key: "b64_json",
                urlKey: "url",
                requestedCount: 1,
                observer: { phases.append($0) },
                downloader: { request in
                    let url = request.url ?? URL(string: "https://invalid.example")!
                    return (Data("not an image".utf8), self.urlResponse(
                        url, mimeType: "text/plain", byteCount: 12))
                })
        }
        #expect(phases.values == [.downloadStarted])
    }

    @Test("A provider base64 result records imagesDecoded without any download")
    func base64ResultRecordsDecodedOnly() async throws {
        let responseBody = Data(
            #"{"data":[{"b64_json":"\#(pngBytes.base64EncodedString())"}]}"#.utf8)
        let phases = PhaseBox()
        let images = try await RemoteImageDecoder.images(
            from: responseBody,
            b64Key: "b64_json",
            urlKey: "url",
            requestedCount: 1,
            observer: { phases.append($0) })
        #expect(images == [pngBytes])
        #expect(phases.values == [.imagesDecoded])
    }

    #if os(Linux) || os(Android)
    @Test("Shared image request and download sessions are real incremental transport sessions")
    func sharedImageSessionsAreStreamable() {
        #expect(StreamingTransport.isStreamable(RemoteImageHTTP.nonStreamingSession))
        let download = RemoteImageHTTP.makeImageDownloadSession()
        #expect(StreamingTransport.isStreamable(download))
        download.invalidateAndCancel()
    }
    #endif
}
