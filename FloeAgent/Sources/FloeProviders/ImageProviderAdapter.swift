// FloeProviders — Capability-aware remote image operation adapter.
// See docs/ALPHA_DAILY_PLAN.md §"Files, documents and images": add remote
// image adapter foundations for OpenAI, Volcengine and Alibaba; expose only
// operations actually supported by the selected provider. Unsupported
// operations are labelled, never emulated. No credentials are embedded —
// they resolve from Keychain at the call site.

import Foundation
import FloeCore

/// A remote image operation a provider may support. Maps to a provider API
/// capability; the adapter reports which it can actually perform.
public enum RemoteImageOperation: String, Sendable, Codable, CaseIterable, Hashable {
    case generate
    case edit
    case variation
    case inpaint
    case upscale
    case removeBackground
}

/// A request to run a remote image operation. Source images are supplied as
/// data already loaded by the caller (never as security-scoped URLs, which
/// the provider cannot reach). The optional mask applies to inpaint/edit.
public struct RemoteImageRequest: Sendable {
    public var operation: RemoteImageOperation
    public var prompt: String
    /// Source images as raw data (PNG/JPEG). Empty for pure generation.
    public var sourceImages: [Data]
    /// Optional mask for inpaint/edit, same dimensions as the first source.
    public var mask: Data?
    /// Requested output size hint (provider-specific; may be ignored).
    public var sizeHint: String?
    /// Provider-neutral controls translated by the concrete adapter.
    public var selection: ImageGenerationSelection
    /// Maximum number of images to return.
    public var count: Int
    /// The exact configured provider model/endpoint ID. Adapters must not
    /// silently replace a user-selected auxiliary model.
    public var modelRemoteID: String?

    public init(
        operation: RemoteImageOperation,
        prompt: String,
        sourceImages: [Data] = [],
        mask: Data? = nil,
        sizeHint: String? = nil,
        selection: ImageGenerationSelection? = nil,
        count: Int = 1,
        modelRemoteID: String? = nil
    ) {
        self.operation = operation
        self.prompt = prompt
        self.sourceImages = sourceImages
        self.mask = mask
        self.sizeHint = sizeHint
        self.selection = selection ?? ImageGenerationSelection(nativeSizeOverride: sizeHint)
        self.count = count
        self.modelRemoteID = modelRemoteID
    }
}

/// One image produced by a remote operation, plus optional provider metadata.
public struct RemoteImageResult: Sendable, Hashable {
    public var images: [Data]
    /// Revised/expanded prompt if the provider returns one.
    public var revisedPrompt: String?
    /// Provider-specific opaque metadata (never a secret).
    public var metadata: [String: String]

    public init(images: [Data], revisedPrompt: String? = nil, metadata: [String: String] = [:]) {
        self.images = images
        self.revisedPrompt = revisedPrompt
        self.metadata = metadata
    }
}

/// Error surfaced when a provider does not support a requested operation.
public enum RemoteImageError: Error, Sendable, Hashable, LocalizedError {
    case unsupportedOperation(RemoteImageOperation, provider: String)
    case requestFailed(String)
    case providerRejected(statusCode: Int, message: String)
    case invalidResponse(String)

    /// Only explicit pre-execution auth/model/rate refusals may switch routes.
    /// Timeouts, policy refusals and server failures have no such guarantee.
    public var allowsRouteFallback: Bool {
        if case .providerRejected(let status, _) = self { return [401, 404, 429].contains(status) }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let operation, let provider):FloeL10n.l("providers.image_provider_adapter.does_not_support_image_actions", provider, operation.rawValue)
        case .providerRejected(_, let message):
            message
        case .requestFailed(let message):
            message.isEmpty ? FloeL10n.l("providers.image_provider_adapter.the_image_service_request_failed") : message
        case .invalidResponse(let message):
            message.isEmpty ? FloeL10n.l("providers.image_provider_adapter.the_image_service_returned_an_invalid") : message
        }
    }
}

/// A provider-specific remote image adapter. Implementations declare the
/// operations they actually support; calling an unsupported operation throws
/// `unsupportedOperation` rather than fabricating a result.
public protocol ImageProviderAdapter: Sendable {
    /// Operations this adapter can perform for the given provider.
    func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation>

    /// Whether the adapter can perform `operation` for `provider`.
    func supports(_ operation: RemoteImageOperation, for provider: ProviderProfile) -> Bool

    /// Maximum number of source images accepted by this concrete provider/model
    /// contract. A zero value means the operation must not contain references.
    /// Callers use this before crossing the network so references are never
    /// silently truncated by an adapter.
    func maximumSourceImages(
        for operation: RemoteImageOperation,
        modelRemoteID: String?
    ) -> Int

    /// Maximum number of images this adapter can return from one provider
    /// request. This prevents a UI `count` from being silently ignored.
    func maximumOutputImages(modelRemoteID: String?) -> Int

    /// Runs a remote image operation. Must throw
    /// `RemoteImageError.unsupportedOperation` when unsupported, and must
    /// honour task cancellation. Never logs the API key.
    func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult
}

public extension ImageProviderAdapter {
    func supports(_ operation: RemoteImageOperation, for provider: ProviderProfile) -> Bool {
        supportedOperations(for: provider).contains(operation)
    }

    func validateSourceImageCount(_ request: RemoteImageRequest, providerName: String) throws {
        let maximum = max(0, maximumSourceImages(
            for: request.operation,
            modelRemoteID: request.modelRemoteID
        ))
        guard request.sourceImages.count <= maximum else {
            let model = request.modelRemoteID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelDetail = model.flatMap { $0.isEmpty ? nil : $0 }.map { "（\($0)）" } ?? ""
            throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_provider_adapter.supports_up_to_reference_images_are", providerName, modelDetail, maximum, request.sourceImages.count)
            )
        }
    }

    func validateOutputImageCount(_ request: RemoteImageRequest, providerName: String) throws {
        let maximum = max(1, maximumOutputImages(modelRemoteID: request.modelRemoteID))
        let requested = max(1, request.count)
        guard requested <= maximum else {
            throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_provider_adapter.the_current_model_can_generate_at", providerName, maximum, requested)
            )
        }
    }
}

/// Builds the right image adapter for a provider kind. Returns `nil` when a
/// provider family has no remote image capability, so the UI can label the
/// feature unavailable instead of offering a dead control.
public struct ImageProviderAdapterFactory: Sendable {
    public init() {}

    public func adapter(for provider: ProviderProfile) -> (any ImageProviderAdapter)? {
        switch provider.kind {
        case .openAI:
            return OpenAIImageAdapter()
        case .volcengineArk:
            return VolcengineImageAdapter()
        case .alibabaStudio:
            return AlibabaImageAdapter()
        case .googleGemini:
            return GoogleGeminiImageAdapter()
        case .anthropic, .local, .custom:
            // Anthropic has no image-generation endpoint; custom endpoints are
            // not assumed to support image operations.
            return nil
        }
    }
}

/// Resolves the strictest reference-image limit declared by the selected
/// model catalog and its concrete provider adapter. The adapter remains the
/// wire-contract authority for custom/new remote IDs; the first-party catalog
/// may narrow that allowance for a specific product model.
public enum ImageReferenceCapabilityResolver {
    public static func maximumReferenceImages(
        provider: ProviderProfile,
        model: ModelProfile
    ) -> Int {
        guard model.capabilities.contains(.imageEditing),
              let adapter = ImageProviderAdapterFactory().adapter(for: provider),
              adapter.supports(.edit, for: provider) else { return 0 }
        let adapterMaximum = max(0, adapter.maximumSourceImages(
            for: .edit,
            modelRemoteID: model.remoteModelID
        ))
        let catalogMaximum = OfficialMediaModelCatalog.models.first {
            $0.remoteModelID == model.remoteModelID
                && $0.kind == .image
                && $0.provider == mediaProviderFamily(for: provider.kind)
        }.map(\.maximumReferenceAssets) ?? 0
        if catalogMaximum > 0, adapterMaximum > 0 {
            return min(catalogMaximum, adapterMaximum)
        }
        return max(catalogMaximum, adapterMaximum)
    }

    private static func mediaProviderFamily(for kind: ProviderKind) -> MediaProviderFamily? {
        switch kind {
        case .openAI: return .openAI
        case .googleGemini: return .googleGemini
        case .volcengineArk: return .volcengineArk
        case .alibabaStudio: return .alibabaModelStudio
        case .anthropic, .local, .custom: return nil
        }
    }
}
