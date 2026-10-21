// FloeApp — typed contracts for the local system media library/player.
//
// SPDX-License-Identifier: MPL-2.0
//
// Scope is the user's authorized ON-DEVICE media library and the app-scoped
// application queue player. There is deliberately no store/catalog lookup,
// subscription, purchase, account sign-in, playlist mutation or
// systemMusicPlayer path in these types.

#if canImport(UIKit) && canImport(MediaPlayer)
import Foundation
import FloeTools

enum SystemMediaAccess: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case unavailable

    var canRead: Bool { self == .authorized }
}

enum SystemMediaSearchField: String, CaseIterable, Sendable {
    case any
    case title
    case artist
    case album
}

enum SystemMediaPlaybackState: String, Sendable, Equatable {
    case stopped
    case playing
    case paused
    case interrupted
    case seeking
}

struct SystemMediaItem: Sendable, Equatable {
    var persistentID: String
    var title: String
    var artist: String
    var album: String
    var durationSeconds: Int?
    var mediaType: UInt
}

struct SystemMediaSearchScan: Sendable, Equatable {
    var items: [SystemMediaItem]
    var rawCount: Int
    var truncated: Bool
    var authorization: SystemMediaAccess
}

struct SystemMediaPlayerSnapshot: Sendable, Equatable {
    var state: SystemMediaPlaybackState
    var nowPlayingID: String?
    var title: String?
    var artist: String?
    var album: String?
    var index: Int?
    var currentTime: TimeInterval?
}

struct SystemMediaNowPlaying: Sendable, Equatable {
    var persistentID: String?
    var title: String?
    var artist: String?
    var album: String?
    var state: SystemMediaPlaybackState
    var queueIDs: [String]
    var queueIndex: Int?
    var currentTime: TimeInterval?
}

enum SystemMediaControlAction: String, CaseIterable, Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
    case stop
}

enum SystemMediaPlaybackOutcome: Sendable, Equatable {
    case playing(SystemMediaNowPlaying)
    case paused(SystemMediaNowPlaying)
    case stopped
    case interrupted(SystemMediaNowPlaying)
    /// Queue preparation succeeded, but no playing state was observed inside
    /// the bounded probe. This is not audible/playing proof.
    case acceptedNotYetPlaying(SystemMediaNowPlaying)
    case state(SystemMediaNowPlaying)
    case idle
    case untracked(state: SystemMediaPlaybackState)
    case busy
    case replaceNotAuthorized
    case notOwner
    case noActivePlayback
    case itemsUnavailable(missing: Int)
    case emptyQueue
    case audioBusy(reason: String)
    case authorizationRequired
    case authorizationDenied
    case authorizationRestricted
    case unavailable
    case cancelled(effectApplied: Bool)
    case timedOut
    case failed(code: String)
    case superseded
}

enum SystemMediaError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case authorizationRequired
    case authorizationDenied
    case authorizationRestricted
    case authorizationChanged
    case foregroundRequired
    case cancelled
    case timedOut
    case invalidQuery
    case invalidID
    case queryFailed(code: Int)
    case queueUnavailable
    case prepareFailed(code: Int)

    var status: String {
        switch self {
        case .unavailable: "mediaUnavailable"
        case .authorizationRequired: "authorizationRequired"
        case .authorizationDenied: "authorizationDenied"
        case .authorizationRestricted: "authorizationRestricted"
        case .authorizationChanged: "authorizationChanged"
        case .foregroundRequired: "foregroundRequired"
        case .cancelled: "cancelled"
        case .timedOut: "timedOut"
        case .invalidQuery: "invalidQuery"
        case .invalidID: "invalidMediaID"
        case .queryFailed: "queryFailed"
        case .queueUnavailable: "queueUnavailable"
        case .prepareFailed: "prepareFailed"
        }
    }

    var exitStatus: Int32 {
        switch self {
        case .cancelled: 130
        case .timedOut: 124
        case .foregroundRequired, .unavailable, .authorizationChanged, .queueUnavailable: 75
        case .authorizationRequired, .authorizationDenied, .authorizationRestricted: 77
        case .invalidQuery, .invalidID: 64
        case .queryFailed, .prepareFailed: 1
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The local media library is not available."
        case .authorizationRequired:
            "Media library access has not been granted. Keep Floe in the foreground and try again."
        case .authorizationDenied:
            "Media library access was denied; no library data was read."
        case .authorizationRestricted:
            "Media library access is restricted on this device; no library data was read."
        case .authorizationChanged:
            "Media library access changed; no partial result was returned."
        case .foregroundRequired:
            "Keep Floe in the foreground while searching or controlling local media."
        case .cancelled:
            "The media request was cancelled."
        case .timedOut:
            "The media request timed out."
        case .invalidQuery:
            "The media search query is invalid."
        case .invalidID:
            "A media persistent ID is invalid."
        case .queryFailed:
            "The local media search failed."
        case .queueUnavailable:
            "The requested local media items are no longer available."
        case .prepareFailed:
            "The media player could not prepare the requested queue."
        }
    }
}

protocol SystemMediaLibraryProviding: Sendable {
    var isAvailable: Bool { get }
    var authorization: SystemMediaAccess { get }
    func requestAuthorization(cancellation: CancellationToken) async throws -> SystemMediaAccess
    func search(
        query: String,
        field: SystemMediaSearchField,
        maxRows: Int,
        cancellation: CancellationToken
    ) async throws -> SystemMediaSearchScan
    func lookup(
        persistentIDs: [UInt64],
        cancellation: CancellationToken
    ) async throws -> [SystemMediaItem]
    func hasAnyItems() async -> Bool
}

/// The player seam is application-queue only. `systemMusicPlayer` is not
/// present in this protocol, so no tool path can take over the user's
/// unrelated Music playback.
@MainActor
protocol SystemMediaPlayerBackend: AnyObject, Sendable {
    func setQueue(persistentIDs: [UInt64]) throws
    func prepareToPlay() async throws
    func play()
    func pause()
    func stop()
    func skipToNext()
    func skipToPrevious()
    func snapshot() -> SystemMediaPlayerSnapshot
}

/// Trusted process-wide audio coordination seam. The default is honestly
/// free (this folder cannot see AppEnvironment's PiP/TTS/voice services); the
/// primary wires the real closure shown in the handoff before registration.
final class SystemMediaAudioCoordination: @unchecked Sendable {
    typealias Probe = @Sendable () async -> String?

    static let shared = SystemMediaAudioCoordination()

    private let lock = NSLock()
    private var probe: Probe

    init(probe: @escaping Probe = { nil }) {
        self.probe = probe
    }

    func update(probe: @escaping Probe) {
        lock.withLock { self.probe = probe }
    }

    /// Returns a short trusted reason ("recording", "speech", "taskAudio",
    /// "video") when existing Floe audio ownership must not be replaced.
    func busyReason() async -> String? {
        let probe = lock.withLock { self.probe }
        let reason = await probe()
        guard let reason, !reason.isEmpty else { return nil }
        return String(reason.prefix(40))
    }
}

struct SystemMediaCaller: Sendable, Equatable {
    var owner: PersonalToolOwnerID
    var runID: UUID
    var toolCallID: String?
    var toolIdempotencyKey: String
    var clientSessionID: String?
    var temporary: Bool

    init(
        owner: PersonalToolOwnerID,
        runID: UUID,
        toolCallID: String? = nil,
        toolIdempotencyKey: String = "",
        clientSessionID: String? = nil,
        temporary: Bool = false
    ) {
        self.owner = owner
        self.runID = runID
        self.toolCallID = toolCallID
        self.toolIdempotencyKey = toolIdempotencyKey
        self.clientSessionID = clientSessionID
        self.temporary = temporary
    }

    init(context: ToolContext) {
        self.owner = PersonalToolOwnerID(context: context)
        self.runID = context.runID
        self.toolCallID = context.toolCallID
        self.toolIdempotencyKey = context.toolIdempotencyKey
        self.clientSessionID = context.clientSessionID
        self.temporary = context.temporaryReadOnly || context.publicWebOnly
    }
}
#endif
