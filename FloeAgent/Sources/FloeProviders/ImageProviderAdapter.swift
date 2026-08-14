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
    /// Maximum number of images to return.
    public var count: Int

    public init(
        operation: RemoteImageOperation,
        prompt: String,
        sourceImages: [Data] = [],
        mask: Data? = nil,
        sizeHint: String? = nil,
        count: Int = 1
    ) {
        self.operation = operation
        self.prompt = prompt
        self.sourceImages = sourceImages
        self.mask = mask
        self.sizeHint = sizeHint
        self.count = count
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
public enum RemoteImageError: Error, Sendable, Hashable {
    case unsupportedOperation(RemoteImageOperation, provider: String)
    case requestFailed(String)
}

/// A provider-specific remote image adapter. Implementations declare the
/// operations they actually support; calling an unsupported operation throws
/// `unsupportedOperation` rather than fabricating a result.
public protocol ImageProviderAdapter: Sendable {
    /// Operations this adapter can perform for the given provider.
    func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation>

    /// Whether the adapter can perform `operation` for `provider`.
    func supports(_ operation: RemoteImageOperation, for provider: ProviderProfile) -> Bool

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
        case .anthropic, .custom:
            // Anthropic has no image-generation endpoint; custom endpoints are
            // not assumed to support image operations.
            return nil
        }
    }
}
