//
//  CADAnimationExportRecovery.swift
//  FloeCADKit
//
//  Narrow host sink for the DIRECT Present MP4 export (X30).
//
//  The tool/assistant export already owns a durable NativeCADTaskRegistry
//  record in the Floe App host. The Present pane used to call
//  `startAnimationExportMP4` directly, so a process death could lose the exact
//  user choices even though the renderer itself was always fenced and
//  verified. This file is only the package-side seam:
//
//    * one optional, host-installed sink per FloeCADDocument;
//    * a value-only request that carries the exact UI choices, the production
//      settings they map to, and the document/clip source identity;
//    * an exactly-once begin/finish session used by the Present pane.
//
//  It deliberately contains no store, no encoder, no retry and no automatic
//  execution. A recovered value is inert metadata: the host may re-offer the
//  saved choices, but every new export still resolves the current document,
//  destination and permissions. The headless/tool `exportAnimationMP4` API
//  never consults this sink, so the host tool record stays the only record for
//  a tool export.
//

import Foundation

// MARK: - Saved choices

/// Exact, host-readable snapshot of one Present export choice. The UI enum
/// values are kept as raw strings so this contract stays independent of the
/// SwiftUI options file (and can be stored by the App host without a second
/// mapping layer). The production settings are stored alongside them; the UI
/// choices are for re-offering the same sheet, never for authorizing a write.
public nonisolated struct CADAnimationExportRecoveryOptions: Codable, Sendable, Equatable {
    public var orientation: String
    public var resolution: Int
    public var frameRate: Int
    public var codec: String
    public var quality: String
    public var width: Int
    public var height: Int
    public var bitrate: Int?
    public var overwrite: Bool
    public var posterEnabled: Bool

    public init(orientation: String,
                resolution: Int,
                frameRate: Int,
                codec: String,
                quality: String,
                width: Int,
                height: Int,
                bitrate: Int?,
                overwrite: Bool,
                posterEnabled: Bool) {
        self.orientation = orientation
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.quality = quality
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.overwrite = overwrite
        self.posterEnabled = posterEnabled
    }

    // A record written by a newer build must not make the whole native-task
    // envelope undecodable. Missing/unknown values stay inert and the UI
    // refuses to restore a selection it cannot name; it never invents one.
    private enum CodingKeys: String, CodingKey {
        case orientation, resolution, frameRate, codec, quality
        case width, height, bitrate, overwrite, posterEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orientation = try container.decodeIfPresent(String.self,
                                                    forKey: .orientation) ?? ""
        resolution = try container.decodeIfPresent(Int.self,
                                                   forKey: .resolution) ?? 0
        frameRate = try container.decodeIfPresent(Int.self,
                                                  forKey: .frameRate) ?? 0
        codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? ""
        quality = try container.decodeIfPresent(String.self,
                                                forKey: .quality) ?? ""
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        overwrite = try container.decodeIfPresent(Bool.self,
                                                  forKey: .overwrite) ?? false
        posterEnabled = try container.decodeIfPresent(Bool.self,
                                                      forKey: .posterEnabled) ?? true
    }
}

// MARK: - Request / result

public nonisolated enum CADAnimationExportRecoveryDestination: String,
    Codable, Sendable {
    /// The Present pane renders to a temporary file and then hands the bytes to
    /// the system export picker. The host must never present that temporary
    /// URL as a user-selected permanent destination.
    case exportPicker = "export_picker"
}

/// Everything the host needs to describe an interrupted native export without
/// guessing. `sourceChangeCount` is the live edit fence; revision/hash are the
/// last committed identity at request time (a pending autosave may advance
/// them during the exporter's own prepare step, which is why the request is
/// revalidated against the live change count before the frame loop starts).
public nonisolated struct CADAnimationExportRecoveryRequest: Sendable, Equatable {
    public var documentURL: URL
    public var options: CADAnimationExportRecoveryOptions
    public var sourceRevision: Int
    public var sourceContentSHA256: String
    public var sourceChangeCount: Int
    public var clipID: UUID
    public var clipDuration: Double
    public var suggestedFilename: String
    public var destination: CADAnimationExportRecoveryDestination

    public init(documentURL: URL,
                options: CADAnimationExportRecoveryOptions,
                sourceRevision: Int,
                sourceContentSHA256: String,
                sourceChangeCount: Int,
                clipID: UUID,
                clipDuration: Double,
                suggestedFilename: String,
                destination: CADAnimationExportRecoveryDestination = .exportPicker) {
        self.documentURL = documentURL
        self.options = options
        self.sourceRevision = sourceRevision
        self.sourceContentSHA256 = sourceContentSHA256
        self.sourceChangeCount = sourceChangeCount
        self.clipID = clipID
        self.clipDuration = clipDuration
        self.suggestedFilename = suggestedFilename
        self.destination = destination
    }
}

public nonisolated enum CADAnimationExportRecoveryOutcome: String,
    Codable, Sendable, Equatable {
    case completed
    case failed
    case cancelled
}

/// Interrupted metadata as the host can safely re-offer it. This is a value
/// snapshot, not a live job: showing it does not resume a renderer or write a
/// file.
public nonisolated struct CADAnimationExportRecoverySummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var options: CADAnimationExportRecoveryOptions
    public var sourceRevision: Int
    public var sourceContentSHA256: String
    public var sourceChangeCount: Int
    public var clipID: UUID
    public var clipDuration: Double
    public var suggestedFilename: String
    public var updatedAt: Date
    public var detail: String?

    public init(id: UUID,
                options: CADAnimationExportRecoveryOptions,
                sourceRevision: Int,
                sourceContentSHA256: String,
                sourceChangeCount: Int,
                clipID: UUID,
                clipDuration: Double,
                suggestedFilename: String,
                updatedAt: Date,
                detail: String? = nil) {
        self.id = id
        self.options = options
        self.sourceRevision = sourceRevision
        self.sourceContentSHA256 = sourceContentSHA256
        self.sourceChangeCount = sourceChangeCount
        self.clipID = clipID
        self.clipDuration = clipDuration
        self.suggestedFilename = suggestedFilename
        self.updatedAt = updatedAt
        self.detail = detail
    }
}

public nonisolated enum CADAnimationExportRecoveryError: Error,
    LocalizedError, Sendable, Equatable {
    case documentMismatch
    case beginInProgress
    case recordUnavailable

    public var errorDescription: String? {
        switch self {
        case .documentMismatch:
            return "The export recovery record belongs to a different document."
        case .beginInProgress:
            return "The export recovery record is still being saved."
        case .recordUnavailable:
            return "The interrupted export is no longer available."
        }
    }
}

// MARK: - Host sink

/// Installed by the Floe App on the FloeCADDocument instances it owns. The
/// package never creates an implementation and works unchanged when this is
/// nil (standalone workbench/tests). The document retains the sink; an
/// implementation must not retain that document back. Methods are nonisolated
/// so the App can back them with its NativeCADTaskRegistry actor; the UI calls
/// them from the main actor.
public nonisolated protocol CADAnimationExportRecoverySink: AnyObject, Sendable {
    /// Save the complete request atomically before the caller starts a frame
    /// loop. Throwing means no renderer, output or in-memory task may start.
    func beginAnimationExport(_ request: CADAnimationExportRecoveryRequest) async throws -> UUID

    /// Report the single terminal outcome after the exporter's own cleanup.
    /// Implementations must tolerate a repeated/late call without changing a
    /// record twice.
    func finishAnimationExport(id: UUID,
                               outcome: CADAnimationExportRecoveryOutcome,
                               detail: String?) async

    /// Newest interrupted native-editor export for exactly this document, if
    /// any. This is read-only and never authorizes an output write.
    func lastInterruptedAnimationExport(
        documentURL: URL) async -> CADAnimationExportRecoverySummary?

    /// Dismiss only an interrupted record belonging to this document. Return
    /// after the dismissal is durable; a failed save must leave it recoverable.
    func dismissInterruptedAnimationExport(id: UUID, documentURL: URL) async throws
}

// MARK: - Exactly-once session

/// Production lifecycle helper used by the Present pane. It keeps the sink
/// optional, begins before any renderer call, and finalises the SAME id once.
/// The cleanup closure runs before `finish` so the durable record reports the
/// post-cleanup outcome, including a real temporary-file cleanup failure.
@MainActor
public final class CADAnimationExportRecoverySession {
    private let sink: any CADAnimationExportRecoverySink
    public let request: CADAnimationExportRecoveryRequest
    public private(set) var id: UUID?
    public private(set) var didFinish = false
    private var beginAttempted = false

    public init(sink: any CADAnimationExportRecoverySink,
                request: CADAnimationExportRecoveryRequest) {
        self.sink = sink
        self.request = request
    }

    public var isStarted: Bool { id != nil }

    /// Saves the request before the caller creates any renderer/output. A
    /// repeated call after success is a no-op; a repeated call while the first
    /// save is still awaiting is refused rather than creating a second record.
    public func begin() async throws {
        guard !beginAttempted else {
            if id != nil { return }
            throw CADAnimationExportRecoveryError.beginInProgress
        }
        beginAttempted = true
        do {
            id = try await sink.beginAnimationExport(request)
        } catch {
            // The sink rolled its in-memory index back; allow an explicit
            // retry, but never start a renderer from this failed attempt.
            beginAttempted = false
            throw error
        }
    }

    /// Finalise once, after cleanup. `cleanup` returns a human-readable note
    /// only when temporary artifacts could not be removed; the guard makes a
    /// late status callback harmless.
    public func finish(outcome: CADAnimationExportRecoveryOutcome,
                       detail: String?,
                       cleanup: (@MainActor () -> String?)? = nil) async {
        guard !didFinish, let id else { return }
        didFinish = true
        let cleanupNote = cleanup?()
        var parts: [String] = []
        if let detail, !detail.isEmpty { parts.append(detail) }
        if let cleanupNote, !cleanupNote.isEmpty { parts.append(cleanupNote) }
        let message = parts.isEmpty ? nil : parts.joined(separator: " ")
        await sink.finishAnimationExport(id: id, outcome: outcome, detail: message)
    }
}
