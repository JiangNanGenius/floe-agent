// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench
import FloeMedia

/// App-owned adapters are installed once by AppEnvironment. Native media
/// editing never selects a parallel provider store or reads credentials.
@MainActor enum MediaV2ProviderBridge {
    enum Capability: String,Sendable,Hashable { case imageEditing,transcription,translation,stemSeparation }
    struct ImageRoute: Sendable,Hashable,Identifiable {
        let id: UUID
        let title: String
    }
    struct ImageRequest: Sendable {
        let sourcePNG: Data
        /// Transparent pixels are editable, matching the existing inpaint API.
        let maskPNG: Data
        let prompt: String
        let modelID: UUID?
        let width: Int
        let height: Int
    }
    struct ImageResult: Sendable {
        let imageData: Data
        let modelTitle: String
    }
    struct TimedText: Sendable {
        let start: Double
        let end: Double
        let text: String
    }
    struct CaptionText: Sendable,Codable,Hashable {
        let id: UUID
        let text: String
    }
    struct VoiceSeparationHandlers:Sendable {
        let makeAPI:@MainActor @Sendable () throws -> MusicAIStemAPI
    }
    struct Handlers {
        let available: @MainActor @Sendable () -> Set<Capability>
        let imageRoutes: @MainActor @Sendable () -> [ImageRoute]
        let editImage: @MainActor @Sendable (ImageRequest,MediaV2ProviderAuthority) async throws -> ImageResult
        let transcribeFile: @MainActor @Sendable (URL,MediaV2ProviderAuthority) async throws -> [TimedText]
        let translateCaptions: @MainActor @Sendable ([CaptionText],String,MediaV2ProviderAuthority) async throws -> [CaptionText]
        // Default preserves existing image/transcription-only adapter initializers.
        var voiceSeparation:VoiceSeparationHandlers? = nil
    }
    private static var handlers: Handlers?
    static func install(_ value: Handlers) { handlers = value }
    /// Scoped dependency replacement restores the exact installed adapter,
    /// including an unconfigured state. Calls remain on the owning actor.
    static func withTemporaryHandlers<Result: Sendable>(_ value: Handlers,
        operation: @MainActor () async throws -> Result) async rethrows -> Result {
        let previous = handlers;handlers = value
        defer { handlers = previous }
        return try await operation()
    }
    static var capabilities: Set<Capability> { handlers?.available() ?? [] }
    static var imageRoutes: [ImageRoute] { handlers?.imageRoutes() ?? [] }
    static func editImage(_ request:ImageRequest,authority:MediaV2ProviderAuthority) async throws -> ImageResult {
        guard let handlers,capabilities.contains(.imageEditing) else {
            throw MediaPreparedCoreError.invalidOperation("Configure an image-editing provider first")
        }
        try await authority.authorize(capability:.imageEditing,projectID:authority.projectID,revision:authority.revision)
        return try await handlers.editImage(request,authority)
    }
    static func transcribeFile(_ source:URL,authority:MediaV2ProviderAuthority) async throws -> [TimedText] {
        guard let handlers,capabilities.contains(.transcription) else {
            throw MediaPreparedCoreError.invalidOperation("Configure a transcription service first")
        }
        try await authority.authorize(capability:.transcription,projectID:authority.projectID,revision:authority.revision)
        return try await handlers.transcribeFile(source,authority)
    }
    static func translateCaptions(_ captions:[CaptionText],language:String,authority:MediaV2ProviderAuthority) async throws -> [CaptionText] {
        guard let handlers,capabilities.contains(.translation) else {
            throw MediaPreparedCoreError.invalidOperation("Configure a text model first")
        }
        try await authority.authorize(capability:.translation,projectID:authority.projectID,revision:authority.revision)
        return try await handlers.translateCaptions(captions,language,authority)
    }
    /// The configured Music.AI route for M55. The owning session re-enters
    /// this gate before every provider step; the returned client carries the
    /// existing transport/credential seams, never model-minted authority.
    static func voiceSeparationAPI(authority:MediaV2ProviderAuthority) async throws -> MusicAIStemAPI {
        guard let handlers,let value = handlers.voiceSeparation,capabilities.contains(.stemSeparation) else {
            throw MediaPreparedCoreError.invalidOperation("Install a local stem model or configure Music.AI first")
        }
        try await authority.authorize(capability:.stemSeparation,projectID:authority.projectID,revision:authority.revision)
        return try value.makeAPI()
    }
}

#endif
