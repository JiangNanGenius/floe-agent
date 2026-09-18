// Build191 media-review — video provider fixture.
//
// Compiled directly with the EDITED FloeCore and FloeProviders sources (no
// stale .build modules), so it exercises the current `MediaGenerationJob`,
// reference-image policy and adapter request bodies. No network, no paid call.

import Foundation
import FloeCore

@main
@MainActor
struct ReviewProviderTests {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    static func checkThrows<T>(_ label: String, _ body: () throws -> T) {
        do {
            _ = try body()
            failures.append("\(label): expected an error")
            checks += 1
        } catch {
            check(true, label)
        }
    }

    static func main() async {
        do {
            try run()
        } catch {
            failures.append("unexpected error: \(error)")
        }
        if failures.isEmpty {
            print("REVIEW-PROVIDERS: PASS (\(checks) checks)")
        } else {
            print("REVIEW-PROVIDERS: FAIL (\(failures.count)/\(checks))")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }

    // MARK: fixtures

    /// 1x1 PNG.
    static let pngBytes: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89
    ]

    static func provider(kind: ProviderKind, baseURL: String) -> ProviderProfile {
        ProviderProfile(
            id: UUID(), kind: kind, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: baseURL)!,
            displayName: nil, secretRef: nil, nonSecretHeaders: [:], isEnabled: true
        )
    }

    static func run() throws {
        try referenceImagePolicy()
        try endpointRouting()
        try redirectPolicy()
        try registryContracts()
        try googleRequests()
        try arkRequests()
        try alibabaRequests()
    }

    // MARK: reference image policy

    static func referenceImagePolicy() throws {
        let png = Data(pngBytes)
        check(VideoReferenceImagePolicy.detectedMIMEType(png) == "image/png", "PNG sniffed")
        check(VideoReferenceImagePolicy.detectedMIMEType(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg", "JPEG sniffed")
        var webp = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
        check(VideoReferenceImagePolicy.detectedMIMEType(Data(webp)) == "image/webp", "WebP sniffed")
        check(VideoReferenceImagePolicy.detectedMIMEType(Data("<svg/>".utf8)) == nil, "SVG is not accepted inline")

        let url = try VideoReferenceImagePolicy.inlineDataURL(data: png)
        check(url.scheme == "data", "inline URL is a data URL")
        let parsed = try VideoReferenceImagePolicy.inlineImage(from: url, providerName: "fixture")
        check(parsed.mimeType == "image/png", "inline round-trip keeps MIME")
        check(parsed.base64 == png.base64EncodedString(), "inline round-trip keeps base64 payload")
        // A payload large enough to matter must still round-trip exactly.
        var large = Data(png)
        large.append(Data(repeating: 0x41, count: 200_000))
        let largeURL = try VideoReferenceImagePolicy.inlineDataURL(data: large)
        check(try VideoReferenceImagePolicy.inlineImage(from: largeURL, providerName: "fixture").base64
                == large.base64EncodedString(), "large inline payload round-trips")
        checkThrows("empty image rejected") {
            _ = try VideoReferenceImagePolicy.inlineDataURL(data: Data())
        }
        checkThrows("unsupported bytes rejected") {
            _ = try VideoReferenceImagePolicy.inlineDataURL(data: Data("not an image".utf8))
        }
        checkThrows("oversized image rejected") {
            var huge = Data(png)
            huge.append(Data(repeating: 0, count: VideoReferenceImagePolicy.maximumBytes + 1))
            _ = try VideoReferenceImagePolicy.inlineDataURL(data: huge)
        }
        check(VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .googleGemini, modelRemoteID: "veo-3.1-generate-preview"), "Veo advertises references")
        check(VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .googleGemini, modelRemoteID: "gemini-omni-flash-preview"), "Omni advertises references")
        check(VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .volcengineArk, modelRemoteID: "doubao-seedance-2-5-260628"), "Ark advertises first-frame")
        check(VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .alibabaStudio, modelRemoteID: "wan3.0-video"), "Wan 3.0 advertises first-frame")
        check(!VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .alibabaStudio, modelRemoteID: "wan2.7-t2v"), "Wan 2.7 does not advertise image input")
        check(!VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .custom, modelRemoteID: "any"), "custom is not advertised")
    }

    // MARK: endpoint routing

    static func endpointRouting() throws {
        let google = provider(kind: .googleGemini, baseURL: "https://generativelanguage.googleapis.com/v1")
        check(VideoEndpointRouting.googleRoot(baseURL: google.baseURL, modelRemoteID: "veo-3.1-generate-preview")
                .absoluteString == "https://generativelanguage.googleapis.com/v1beta", "Veo moves to v1beta")
        check(VideoEndpointRouting.googleRoot(baseURL: google.baseURL, modelRemoteID: "gemini-omni-flash-preview")
                .absoluteString == "https://generativelanguage.googleapis.com/v1", "Omni stays on v1")
        let proxy = provider(kind: .googleGemini, baseURL: "https://proxy.example.com/google/v1")
        check(VideoEndpointRouting.googleRoot(baseURL: proxy.baseURL, modelRemoteID: "veo-3.1-generate-preview")
                .absoluteString == "https://proxy.example.com/google/v1beta", "custom Google prefix preserved")
        check(VideoEndpointRouting.googleRoot(baseURL: proxy.baseURL, modelRemoteID: "veo-3.1-generate-preview")
                .absoluteString.hasPrefix("https://proxy.example.com/google/"), "custom host preserved")

        let dash = provider(kind: .alibabaStudio, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        check(VideoEndpointRouting.dashScopeAPIRoot(baseURL: dash.baseURL)
                .absoluteString == "https://dashscope.aliyuncs.com/api/v1", "compatible-mode normalizes to api/v1")
        let workspace = provider(kind: .alibabaStudio, baseURL: "https://ws123.cn-beijing.maas.aliyuncs.com")
        check(VideoEndpointRouting.dashScopeAPIRoot(baseURL: workspace.baseURL)
                .absoluteString == "https://ws123.cn-beijing.maas.aliyuncs.com/api/v1", "workspace host gets api/v1")
        let custom = provider(kind: .alibabaStudio, baseURL: "https://gateway.internal/dash")
        check(VideoEndpointRouting.dashScopeAPIRoot(baseURL: custom.baseURL)
                .absoluteString == "https://gateway.internal/dash", "unknown custom DashScope host preserved verbatim")
    }

    // MARK: download redirect policy

    static func redirectPolicy() throws {
        let sameHost = URL(string: "https://generativelanguage.googleapis.com/v1beta/files/x")!
        check(VideoDownloadRedirectPolicy.allowsRedirect(from: "generativelanguage.googleapis.com", to: sameHost),
              "same-host https redirect allowed")
        let googleMedia = URL(string: "https://storage.googleapis.com/bucket/video.mp4")!
        check(VideoDownloadRedirectPolicy.allowsRedirect(from: "generativelanguage.googleapis.com", to: googleMedia),
              "Google media host redirect allowed")
        check(VideoDownloadRedirectPolicy.isAllowedMediaRedirectHost("content.googleapis.com"),
              "googleapis subdomain allowed")
        let attacker = URL(string: "https://evil.example.com/collect")!
        check(!VideoDownloadRedirectPolicy.allowsRedirect(from: "generativelanguage.googleapis.com", to: attacker),
              "cross-host redirect to third party refused")
        let sneaky = URL(string: "https://evilgoogleapis.com/collect")!
        check(!VideoDownloadRedirectPolicy.allowsRedirect(from: "generativelanguage.googleapis.com", to: sneaky),
              "suffix-spoofed host refused")
        let insecure = URL(string: "http://storage.googleapis.com/bucket/video.mp4")!
        check(!VideoDownloadRedirectPolicy.allowsRedirect(from: "generativelanguage.googleapis.com", to: insecure),
              "non-https redirect refused")
    }

    // MARK: model registry

    static func registryContracts() throws {
        let ark = provider(kind: .volcengineArk, baseURL: "https://ark.cn-beijing.volces.com/api/v3")
        let model = ModelProfile(
            id: UUID(), providerID: ark.id, remoteModelID: "doubao-seedance-2-5-260628",
            displayName: "Seedance", limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 0),
            capabilities: [.text, .videoGeneration], useSurfaces: [.videoGeneration]
        )
        check(VideoModelRegistry.isUsable(model: model, provider: ark), "enabled Ark video model is usable")
        let disabledProvider = ProviderProfile(
            id: ark.id, kind: .volcengineArk, wireProtocol: .openAIChatCompletions,
            baseURL: ark.baseURL, displayName: nil, secretRef: nil,
            nonSecretHeaders: [:], isEnabled: false
        )
        check(!VideoModelRegistry.isUsable(model: model, provider: disabledProvider), "disabled provider excluded")
        let emptyID = ModelProfile(
            id: UUID(), providerID: ark.id, remoteModelID: " ",
            displayName: "x", limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 0),
            capabilities: [.text, .videoGeneration], useSurfaces: [.videoGeneration]
        )
        check(!VideoModelRegistry.isUsable(model: emptyID, provider: ark), "empty remote ID excluded")
        let custom = provider(kind: .custom, baseURL: "https://example.com/v1")
        check(!VideoModelRegistry.isUsable(model: model, provider: custom), "no native adapter -> excluded")

        let routes = VideoModelRegistry.routes(models: [model], providers: [ark], preferredModelID: model.id)
        check(routes.count == 1 && routes[0].preferred, "preferred route resolved")
        check(routes[0].contract.maximumReferenceAssets == 1, "Seedance contract advertises one reference")
        check(routes[0].contract.referenceMode == "first_frame", "Seedance reference mode is first_frame")

        // Veo's official catalog entry advertises reference images; the mode
        // must not claim a first-frame-only contract.
        let google = provider(kind: .googleGemini, baseURL: "https://generativelanguage.googleapis.com/v1")
        let veoModel = ModelProfile(
            id: UUID(), providerID: google.id, remoteModelID: "veo-3.1-generate-preview",
            displayName: "Veo", limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 0),
            capabilities: [.text, .videoGeneration], useSurfaces: [.videoGeneration]
        )
        let veoRoutes = VideoModelRegistry.routes(models: [veoModel], providers: [google], preferredModelID: nil)
        check(veoRoutes.first?.contract.referenceMode == "reference_image",
              "Veo catalog contract advertises reference_image")
        check(veoRoutes.first?.contract.maximumReferenceAssets == 3,
              "Veo catalog contract keeps the manifest reference count")
        check(VideoModelRegistry.referenceMode(modelRemoteID: "gemini-omni-flash-preview", providerKind: .googleGemini)
                == "first_frame", "Omni mode stays first_frame")
    }

    // MARK: Google request bodies

    static func googleRequests() throws {
        let imageURL = try VideoReferenceImagePolicy.inlineDataURL(data: Data(pngBytes))
        let veo = RemoteVideoRequest(
            prompt: "a cat", modelRemoteID: "veo-3.1-generate-preview",
            options: VideoGenerationOptions(durationSeconds: 8),
            referenceAssetURLs: [imageURL]
        )
        let veoBody = try GoogleVideoAdapter.veoRequestBody(veo)
        let instances = veoBody["instances"] as? [[String: Any]]
        let references = instances?.first?["referenceImages"] as? [[String: Any]]
        let inline = (references?.first?["image"] as? [String: Any])?["inlineData"] as? [String: Any]
        check(inline?["mimeType"] as? String == "image/png", "Veo reference uses inlineData mime")
        check(inline?["data"] as? String == Data(pngBytes).base64EncodedString(), "Veo reference uses inlineData base64")
        check(references?.first?["referenceType"] as? String == "asset", "Veo reference type is asset")
        check((veoBody["parameters"] as? [String: Any])?["durationSeconds"] as? Int == 8, "Veo duration forwarded")

        checkThrows("Veo rejects reference image with duration 4") {
            _ = try GoogleVideoAdapter.veoRequestBody(RemoteVideoRequest(
                prompt: "a cat", modelRemoteID: "veo-3.1-generate-preview",
                options: VideoGenerationOptions(durationSeconds: 4),
                referenceAssetURLs: [imageURL]
            ))
        }
        let textVeo = try GoogleVideoAdapter.veoRequestBody(RemoteVideoRequest(
            prompt: "a cat", modelRemoteID: "veo-3.1-generate-preview"
        ))
        let textInstances = textVeo["instances"] as? [[String: Any]]
        check(textInstances?.first?["referenceImages"] == nil, "Veo text-only request has no reference field")

        let geminiShape: [String: Any] = [
            "generateVideoResponse": [
                "generatedSamples": [["video": ["uri": "https://example.com/gemini.mp4"]]]
            ]
        ]
        let vertexShape: [String: Any] = [
            "generatedVideos": [["video": ["gcsUri": "gs://bucket/video.mp4"]]]
        ]
        check(GoogleVideoAdapter.veoVideoURI(geminiShape) == "https://example.com/gemini.mp4",
              "Gemini generatedSamples shape parsed")
        check(GoogleVideoAdapter.veoVideoURI(vertexShape) == "gs://bucket/video.mp4",
              "Vertex generatedVideos shape parsed")
        check(GoogleVideoAdapter.veoVideoURI(["unexpected": 1]) == nil, "unknown shape yields no URI")

        // Omni
        let omni = RemoteVideoRequest(
            prompt: "a cat", modelRemoteID: "gemini-omni-flash-preview",
            options: VideoGenerationOptions(aspectRatio: "9:16", durationSeconds: 5),
            referenceAssetURLs: [imageURL]
        )
        let omniBody = try GoogleVideoAdapter.omniRequestBody(omni)
        let parts = omniBody["input"] as? [[String: Any]]
        check(parts?.first?["type"] as? String == "image", "Omni image part present")
        check(parts?.first?["data"] as? String == Data(pngBytes).base64EncodedString(), "Omni inline base64")
        check(parts?.first?["mime_type"] as? String == "image/png", "Omni inline mime")
        check(parts?.last?["type"] as? String == "text", "Omni text part last")
        let responseFormat = omniBody["response_format"] as? [String: Any]
        check(responseFormat?["aspect_ratio"] as? String == "9:16", "Omni aspect ratio in response_format")
        check(responseFormat?["delivery"] as? String == "uri", "Omni requests URI delivery")
        let videoConfig = (omniBody["generation_config"] as? [String: Any])?["video_config"] as? [String: Any]
        check(videoConfig?["task"] as? String == "image_to_video", "Omni selects image_to_video task")
        check(videoConfig?["aspect_ratio"] == nil, "Omni no longer sends aspect_ratio in video_config")
        let textOmni = try GoogleVideoAdapter.omniRequestBody(RemoteVideoRequest(
            prompt: "a cat", modelRemoteID: "gemini-omni-flash-preview"
        ))
        check(textOmni["input"] as? String == "a cat", "Omni text-only input stays a string")
        check((textOmni["generation_config"] as? [String: Any])?["video_config"] == nil,
              "Omni text-only has no video_config")

        let activeURI = URL(string: "https://generativelanguage.googleapis.com/v1beta/files/abc123")!
        let active = GoogleVideoAdapter.decodeOmniFileState(["state": ["name": "ACTIVE"]], uri: activeURI)
        check(active?.state == .completed && active?.resultURL == activeURI, "Omni file ACTIVE completes")
        let processing = GoogleVideoAdapter.decodeOmniFileState(["state": ["name": "PROCESSING"]], uri: activeURI)
        check(processing?.state == .running, "Omni file PROCESSING keeps polling")
        let failed = GoogleVideoAdapter.decodeOmniFileState(
            ["state": ["name": "FAILED"], "error": ["message": "boom"]], uri: activeURI
        )
        check(failed?.state == .failed && failed?.error == "boom", "Omni file FAILED is terminal")
        check(GoogleVideoAdapter.decodeOmniFileState(["state": ["name": "OTHER"]], uri: activeURI) == nil,
              "unknown Omni file state defers to the interaction URI")
    }

    // MARK: Ark

    static func arkRequests() throws {
        let imageURL = try VideoReferenceImagePolicy.inlineDataURL(data: Data(pngBytes))
        let body = try VolcengineVideoAdapter.requestBody(RemoteVideoRequest(
            prompt: "a cat", modelRemoteID: "doubao-seedance-2-5-260628",
            options: VideoGenerationOptions(resolution: "720p", durationSeconds: 5, includeAudio: true),
            referenceAssetURLs: [imageURL]
        ))
        let content = body["content"] as? [[String: Any]]
        let image = content?.first { ($0["type"] as? String) == "image_url" }
        check((image?["image_url"] as? [String: Any])?["url"] as? String == imageURL.absoluteString,
              "Ark inline data URL forwarded")
        check(image?["role"] as? String == "first_frame", "Ark first-frame role set")
        check(body["duration"] as? Int == 5, "Ark duration forwarded")
        check(body["ratio"] as? String == "adaptive", "Ark ratio adaptive with image")
        check(body["generate_audio"] as? Bool == true, "Ark audio forwarded")

        let httpsBody = try VolcengineVideoAdapter.requestBody(RemoteVideoRequest(
            prompt: "a cat", modelRemoteID: "doubao-seedance-2-5-260628",
            referenceAssetURLs: [URL(string: "https://cdn.example.com/a.png")!]
        ))
        let httpsContent = httpsBody["content"] as? [[String: Any]]
        check(httpsContent?.contains { (($0["image_url"] as? [String: Any])?["url"] as? String) == "https://cdn.example.com/a.png" } == true,
              "Ark https reference accepted")
        checkThrows("Ark file URL rejected") {
            _ = try VolcengineVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "a cat", modelRemoteID: "doubao-seedance-2-5-260628",
                referenceAssetURLs: [URL(string: "file:///tmp/secret.png")!]
            ))
        }
        checkThrows("Ark rejects two reference images") {
            _ = try VolcengineVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "a cat", modelRemoteID: "doubao-seedance-2-5-260628",
                referenceAssetURLs: [
                    URL(string: "https://cdn.example.com/a.png")!,
                    URL(string: "https://cdn.example.com/b.png")!
                ]
            ))
        }

        let expired = try VolcengineVideoAdapter.decodeStatus(["status": "expired"])
        check(expired.state == .expired, "Ark expired maps to expired")
        let cancelled = try VolcengineVideoAdapter.decodeStatus(["status": "cancelled"])
        check(cancelled.state == .cancelled, "Ark cancelled maps to cancelled")
        let failed = try VolcengineVideoAdapter.decodeStatus([
            "status": "failed", "error": ["code": "InvalidParameter", "message": "bad prompt"]
        ])
        check(failed.state == .failed && failed.error == "InvalidParameter: bad prompt",
              "Ark object error decoded")
        let succeeded = try VolcengineVideoAdapter.decodeStatus([
            "status": "succeeded", "content": ["video_url": "https://cdn.example.com/v.mp4"]
        ])
        check(succeeded.state == .completed, "Ark succeeded completes")
        if let expiry = succeeded.resultURLExpiresAt {
            let delta = expiry.timeIntervalSinceNow
            check(delta > 23.5 * 3600 && delta <= 24.1 * 3600, "Ark result URL expiry is ~24h")
        } else {
            check(false, "Ark result URL expiry missing")
        }
    }

    // MARK: Alibaba

    static func alibabaRequests() throws {
        let imageURL = try VideoReferenceImagePolicy.inlineDataURL(data: Data(pngBytes))
        let body = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
            prompt: "a cat", modelRemoteID: "wan3.0-video",
            options: VideoGenerationOptions(resolution: "720p", durationSeconds: 5),
            referenceAssetURLs: [imageURL]
        ))
        let media = (body["input"] as? [String: Any])?["media"] as? [[String: Any]]
        check(media?.first?["type"] as? String == "first_frame", "Wan media type first_frame")
        check(media?.first?["url"] as? String == imageURL.absoluteString, "Wan inline data URL forwarded")
        check((body["parameters"] as? [String: Any])?["ratio"] as? String == "adaptive", "Wan ratio adaptive with image")
        check((body["parameters"] as? [String: Any])?["resolution"] as? String == "720P", "Wan resolution uppercased")
        checkThrows("Wan 2.7 rejects image input") {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "a cat", modelRemoteID: "wan2.7-t2v", referenceAssetURLs: [imageURL]
            ))
        }
        checkThrows("Wan file URL rejected") {
            _ = try AlibabaVideoAdapter.requestBody(RemoteVideoRequest(
                prompt: "a cat", modelRemoteID: "wan3.0-video",
                referenceAssetURLs: [URL(string: "file:///tmp/secret.png")!]
            ))
        }

        let succeeded = try AlibabaVideoAdapter.decodeStatus([
            "output": ["task_status": "SUCCEEDED", "video_url": "https://cdn.example.com/v.mp4"]
        ])
        check(succeeded.state == .completed, "DashScope SUCCEEDED completes")
        if let expiry = succeeded.resultURLExpiresAt {
            let delta = expiry.timeIntervalSinceNow
            check(delta > 23.5 * 3600 && delta <= 24.1 * 3600, "DashScope result URL expiry is ~24h")
        } else {
            check(false, "DashScope result URL expiry missing")
        }
        let unknown = try AlibabaVideoAdapter.decodeStatus([
            "output": ["task_status": "UNKNOWN", "message": "任务不存在或状态未知"]
        ])
        check(unknown.state == .expired, "DashScope UNKNOWN is terminal")
        check(unknown.error == "任务不存在或状态未知", "DashScope UNKNOWN keeps the provider message")
        let unknownNoMessage = try AlibabaVideoAdapter.decodeStatus([
            "output": ["task_status": "UNKNOWN"]
        ])
        check((unknownNoMessage.error ?? "").contains("UNKNOWN"),
              "DashScope UNKNOWN without message names the provider state")
        let failed = try AlibabaVideoAdapter.decodeStatus([
            "output": ["task_status": "FAILED", "code": "DataInspectionFailed", "message": "blocked"]
        ])
        check(failed.state == .failed && failed.error == "DataInspectionFailed: blocked",
              "DashScope FAILED keeps code and message")
        let running = try AlibabaVideoAdapter.decodeStatus(["output": ["task_status": "RUNNING"]])
        check(running.state == .running, "DashScope RUNNING keeps polling")
    }
}
