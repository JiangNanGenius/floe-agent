import Foundation

// MARK: - Provider-neutral media configuration

public enum MediaKind: String, Sendable, Codable, CaseIterable, Hashable {
    case image, video, audio, document
}

public enum MediaProviderFamily: String, Sendable, Codable, CaseIterable, Hashable {
    case openAI, googleGemini, volcengineArk, alibabaModelStudio, custom
}

public struct MediaModelDescriptor: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var provider: MediaProviderFamily
    public var kind: MediaKind
    public var remoteModelID: String
    public var displayName: String
    public var supportedAspectRatios: [String]
    public var supportedDurations: [Int]
    public var supportedQualities: [String]
    public var maximumReferenceAssets: Int
    public var supportsAudio: Bool
    public var supportsWatermark: Bool
    public var supportsSeed: Bool
    public var supportsPromptOptimization: Bool
    public var region: String?
    public var isDeprecated: Bool
    public var verifiedAt: Date
    public var manifestVersion: Int

    public init(
        id: String,
        provider: MediaProviderFamily,
        kind: MediaKind,
        remoteModelID: String,
        displayName: String,
        supportedAspectRatios: [String] = [],
        supportedDurations: [Int] = [],
        supportedQualities: [String] = [],
        maximumReferenceAssets: Int = 0,
        supportsAudio: Bool = false,
        supportsWatermark: Bool = false,
        supportsSeed: Bool = false,
        supportsPromptOptimization: Bool = false,
        region: String? = nil,
        isDeprecated: Bool = false,
        verifiedAt: Date,
        manifestVersion: Int = 1
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.remoteModelID = remoteModelID
        self.displayName = displayName
        self.supportedAspectRatios = supportedAspectRatios
        self.supportedDurations = supportedDurations
        self.supportedQualities = supportedQualities
        self.maximumReferenceAssets = maximumReferenceAssets
        self.supportsAudio = supportsAudio
        self.supportsWatermark = supportsWatermark
        self.supportsSeed = supportsSeed
        self.supportsPromptOptimization = supportsPromptOptimization
        self.region = region
        self.isDeprecated = isDeprecated
        self.verifiedAt = verifiedAt
        self.manifestVersion = manifestVersion
    }
}

public struct ImageGenerationOptions: Sendable, Codable, Hashable {
    public var aspectRatio: String?
    public var size: String?
    public var quality: String?
    public var count: Int
    public var seed: Int?
    public var watermark: Bool?
    public var promptOptimization: Bool?

    public init(
        aspectRatio: String? = nil,
        size: String? = nil,
        quality: String? = nil,
        count: Int = 1,
        seed: Int? = nil,
        watermark: Bool? = nil,
        promptOptimization: Bool? = nil
    ) {
        self.aspectRatio = aspectRatio
        self.size = size
        self.quality = quality
        self.count = count
        self.seed = seed
        self.watermark = watermark
        self.promptOptimization = promptOptimization
    }
}

public struct VideoGenerationOptions: Sendable, Codable, Hashable {
    public var aspectRatio: String?
    public var resolution: String?
    public var durationSeconds: Int?
    public var includeAudio: Bool?
    public var seed: Int?
    public var watermark: Bool?
    public var promptOptimization: Bool?

    public init(
        aspectRatio: String? = nil,
        resolution: String? = nil,
        durationSeconds: Int? = nil,
        includeAudio: Bool? = nil,
        seed: Int? = nil,
        watermark: Bool? = nil,
        promptOptimization: Bool? = nil
    ) {
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.durationSeconds = durationSeconds
        self.includeAudio = includeAudio
        self.seed = seed
        self.watermark = watermark
        self.promptOptimization = promptOptimization
    }
}

// MARK: - Durable media jobs

public enum MediaGenerationJobState: String, Sendable, Codable, CaseIterable, Hashable {
    case preparing, submitted, running, completed, downloading, ready
    case failed, cancelled, expired

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .cancelled, .expired: true
        default: false
        }
    }

    public var rank: Int {
        switch self {
        case .preparing: 0
        case .submitted: 1
        case .running: 2
        case .completed: 3
        case .downloading: 4
        case .ready: 5
        case .failed, .cancelled, .expired: 6
        }
    }

    public func canTransition(to next: Self) -> Bool {
        if self == next { return true }
        if isTerminal { return false }
        if [.failed, .cancelled, .expired].contains(next) { return true }
        return next.rank >= rank
    }
}

public struct MediaGenerationJob: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var providerTaskID: String?
    public var providerID: UUID
    public var modelID: UUID
    public var mediaKind: MediaKind
    public var credentialReference: SecretReference?
    public var canvasID: UUID
    public var documentID: UUID
    public var sourceNodeIDs: [UUID]
    public var resultNodeID: UUID
    public var requestJSON: Data
    public var assetReferences: [UUID]
    public var state: MediaGenerationJobState
    public var createdAt: Date
    public var estimatedCompletionAt: Date?
    public var resultRetentionExpiresAt: Date?
    public var lastPolledAt: Date?
    public var nextPollAt: Date?
    public var retryCount: Int
    public var lastError: String?
    public var resultURL: URL?
    public var resultURLExpiresAt: Date?
    public var localAssetID: UUID?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), providerTaskID: String? = nil,
        providerID: UUID, modelID: UUID, mediaKind: MediaKind,
        credentialReference: SecretReference?, canvasID: UUID, documentID: UUID,
        sourceNodeIDs: [UUID], resultNodeID: UUID, requestJSON: Data,
        assetReferences: [UUID] = [], state: MediaGenerationJobState = .preparing,
        createdAt: Date = Date(), estimatedCompletionAt: Date? = nil,
        resultRetentionExpiresAt: Date? = nil, lastPolledAt: Date? = nil,
        nextPollAt: Date? = nil, retryCount: Int = 0, lastError: String? = nil,
        resultURL: URL? = nil, resultURLExpiresAt: Date? = nil,
        localAssetID: UUID? = nil, updatedAt: Date = Date()
    ) {
        self.id = id; self.providerTaskID = providerTaskID
        self.providerID = providerID; self.modelID = modelID; self.mediaKind = mediaKind
        self.credentialReference = credentialReference; self.canvasID = canvasID
        self.documentID = documentID; self.sourceNodeIDs = sourceNodeIDs
        self.resultNodeID = resultNodeID; self.requestJSON = requestJSON
        self.assetReferences = assetReferences; self.state = state
        self.createdAt = createdAt; self.estimatedCompletionAt = estimatedCompletionAt
        self.resultRetentionExpiresAt = resultRetentionExpiresAt
        self.lastPolledAt = lastPolledAt; self.nextPollAt = nextPollAt
        self.retryCount = retryCount; self.lastError = lastError
        self.resultURL = resultURL; self.resultURLExpiresAt = resultURLExpiresAt
        self.localAssetID = localAssetID; self.updatedAt = updatedAt
    }
}

public enum CloudAssetReleaseState: String, Sendable, Codable, Hashable {
    case pending, releasing, confirmed, failed
}

public struct CloudAssetRelease: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var assetID: UUID
    public var contentHash: String
    public var estimatedBytes: Int64
    public var deleteLocalAfterRelease: Bool
    public var state: CloudAssetReleaseState
    public var retryCount: Int
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), assetID: UUID, contentHash: String,
        estimatedBytes: Int64, deleteLocalAfterRelease: Bool = true,
        state: CloudAssetReleaseState = .pending,
        retryCount: Int = 0, lastError: String? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.assetID = assetID; self.contentHash = contentHash
        self.estimatedBytes = estimatedBytes
        self.deleteLocalAfterRelease = deleteLocalAfterRelease
        self.state = state
        self.retryCount = retryCount; self.lastError = lastError
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
