// FloeApp — S5 C3 system AlarmKit alarm/timer shared models.
//
// SPDX-License-Identifier: MPL-2.0
//
// Shared value types for the `apple.alarm.*` tools: the trusted ownership
// identity, the AlarmKit metadata/presentation, authorization and error
// surfaces, and the stable app-owned alarm-id derivation. Everything here is
// pure model code (no native mutation) so it is directly unit-testable.

#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import SwiftUI
import FloeCore
import FloeTools
import FloePersistence
import AlarmKit

// MARK: - Trusted ownership identity

/// Runtime-trusted provenance of one system-alarm call. Every field comes
/// from the ToolContext the runtime issued for this exact approved call —
/// never from model-authored owner/run identities, title/text equality or
/// the current time. A conversation-backed run owns by its durable task id;
/// a conversation-less run falls back to its run id. A delegated child keeps
/// the provenance the runtime stamped on its context, so a child cannot
/// cancel or claim the parent task's alarms and vice versa.
struct SystemAlarmOwner: Sendable, Equatable {
    var taskID: UUID?
    var runID: UUID
    /// Provider tool-call id of the approved call (the operation identity).
    var operationID: String
    /// Provider idempotency key of the approved call.
    var idempotencyKey: String

    init(context: ToolContext) {
        self.taskID = context.conversationID
        self.runID = context.runID
        self.operationID = context.toolCallID ?? ""
        self.idempotencyKey = context.toolIdempotencyKey
    }

    /// Reconstruct the owner from a durable, already-verified ledger row.
    /// Used ONLY by surfaces that proved the record belongs to the current
    /// task through `timerStatus` (a forged or foreign record never reaches
    /// this initializer). The provenance stays the runtime-stamped one
    /// recorded at schedule time — never a model-authored identity.
    init(record: SystemAlarmRecord) {
        self.taskID = record.ownerTaskID
        self.runID = record.ownerRunID
        self.operationID = record.operationID
        self.idempotencyKey = record.idempotencyKey
    }

    /// Two owners are the same task iff they share the durable conversation,
    /// or (conversation-less) the same run. The per-call identity is NOT
    /// part of owner equality — one task legitimately makes many calls; it is
    /// the dedup input, not the ownership boundary.
    func sameTask(as other: SystemAlarmOwner) -> Bool {
        sameTask(taskID: other.taskID, runID: other.runID)
    }

    /// Compare a durable ledger row without manufacturing another call's
    /// trusted operation identity.
    func sameTask(taskID otherTaskID: UUID?, runID otherRunID: UUID) -> Bool {
        if let lhs = taskID, let rhs = otherTaskID { return lhs == rhs }
        guard taskID == nil, otherTaskID == nil else { return false }
        return runID == otherRunID
    }

    /// Log-safe owner descriptor (no raw title/PII).
    var logDescription: String {
        "task=\(taskID?.uuidString ?? "run") run=\(runID.uuidString)"
    }
}

// MARK: - Canonical date representation

/// Matches the ledger's ISO-8601 fractional-second representation without
/// reaching into FloePersistence's module-internal row-mapping codec.
enum SystemAlarmDateCoding {
    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Stable app-owned alarm identity

enum SystemAlarmIdentity {
    /// Deterministic, stable app-owned alarm UUID for one approved request.
    ///
    /// Derived ONLY from the trusted per-call identity (operation id +
    /// idempotency key), the owner provenance and the canonical request
    /// payload digest. A crash-and-retry of the SAME approved call therefore
    /// converges on the SAME alarm id (idempotent, never duplicated), while
    /// two different approved calls can never collide. Title/text equality
    /// and the current time are deliberately excluded.
    static func stableAlarmID(
        owner: SystemAlarmOwner,
        payloadDigest: String
    ) -> UUID {
        var bytes: [String] = []
        bytes.append("v1")
        bytes.append("op:\(owner.operationID)")
        bytes.append("idem:\(owner.idempotencyKey)")
        if let taskID = owner.taskID {
            bytes.append("task:\(taskID.uuidString)")
        } else {
            bytes.append("run:\(owner.runID.uuidString)")
        }
        bytes.append("payload:\(payloadDigest)")
        let joined = bytes.joined(separator: "|")
        // UUIDv5-style: SHA-256 over the canonical identity string, taking
        // the first 16 bytes with the RFC 4122 version/variant bits set so
        // the result is a well-formed, reproducible UUID.
        let digest = Array(FloeDigest.sha256Hex(Data(joined.utf8)).utf8)
        var raw = [UInt8]()
        raw.reserveCapacity(32)
        for index in stride(from: 0, to: 32, by: 2) {
            raw.append(UInt8(String(bytes: digest[index...index + 1], encoding: .utf8)!, radix: 16)!)
        }
        raw[6] = (raw[6] & 0x0F) | 0x50 // version 5
        raw[8] = (raw[8] & 0x3F) | 0x80 // RFC 4122 variant
        let hex = raw.prefix(16).map { String(format: "%02x", $0) }.joined()
        // Parse the 32-hex-digit UUID back; guaranteed well-formed.
        let uuid = UUID(uuidString: """
        \(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\
        \(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\
        \(hex.dropFirst(20).prefix(12))
        """)!
        return uuid
    }

    /// Canonical digest of a schedule request's payload, used both as the
    /// identity input and the durable `payload_digest` ledger column.
    static func payloadDigest(
        kind: SystemAlarmKind,
        intendedTimezone: String,
        intendedFireDate: Date?,
        repeatRule: SystemAlarmRepeat,
        timerDuration: TimeInterval?
    ) -> String {
        var parts: [String] = []
        parts.append("kind=\(kind.rawValue)")
        parts.append("tz=\(intendedTimezone)")
        if let intendedFireDate {
            parts.append("fire=\(SystemAlarmDateCoding.encode(intendedFireDate))")
        }
        switch repeatRule {
        case .never: parts.append("repeat=never")
        case .weekly(let days): parts.append("repeat=weekly:\(days.sorted().map(String.init).joined(separator: ","))")
        }
        if let timerDuration {
            parts.append("duration=\(String(format: "%.3f", timerDuration))")
        }
        return FloeDigest.sha256Hex(Data(parts.joined(separator: "|").utf8))
    }

    /// Privacy-safe bounded digest of the user-facing label: the durable
    /// ledger never stores the raw title/PII, only this opaque reference.
    static func labelDigest(_ label: String) -> String {
        FloeDigest.sha256Hex(Data(label.utf8))
    }
}

// MARK: - AlarmKit metadata + presentation

/// The shared AlarmKit metadata/attributes shape lives in FloeCore so the
/// FloeWidgets extension renders the EXACT same attributes type the App
/// schedules with (the system matches them by type identity). See
/// `SystemAlarmActivityAttributes.swift`; the service code keeps the shorter
/// local spelling. Holds only a bounded opaque task reference — never the
/// raw prompt text — so the Live Activity payload stays privacy-safe.
typealias FloeAlarmMetadata = FloeSystemAlarmMetadata

/// Builds the real, useful native alarm/timer presentation: a concise
/// localized label plus only controls AlarmKit genuinely performs — a real
/// Stop action everywhere, and (for timers) native pause/resume. No fake
/// buttons: an unconfigured Repeat or a plain relaunch button is never
/// drawn. The label is bounded and carries an opaque task reference, not the
/// full model prompt.
enum SystemAlarmPresentationBuilder {
    /// Localized fallback title used when the caller supplies no label. The
    /// key is mirrored in the App and widget catalogs so the same resource
    /// resolves bilingually in both processes (the widget renders the
    /// presentation the App authored).
    static let defaultTitleKey = "apple.alarm.default_label"

    /// Bounded, single-line title shown on the alert/countdown. Caller text
    /// renders verbatim; an empty label resolves the localized default.
    static func title(label: String) -> LocalizedStringResource {
        let bounded = String(label
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(64))
        if bounded.isEmpty {
            return LocalizedStringResource(stringLiteral: defaultTitleKey)
        }
        return LocalizedStringResource(stringLiteral: bounded)
    }

    /// The alert (alarm/timer fire) presentation with a real stop action,
    /// and — only for countdown timers — honest pause/resume presentations.
    ///
    /// Stop is real on every OS version:
    ///   * iOS 26.0 only has the app-supplied `stopButton`; the system
    ///     performs the native stop when it is tapped (deprecated at 26.1
    ///     but still functional on 26.0, where the modern initializer does
    ///     not exist).
    ///   * iOS 26.1+ provides the stop control itself, so only
    ///     `init(title:secondaryButton:secondaryButtonBehavior:)` is used and
    ///     no second button is fabricated: `.countdown` would be a Repeat
    ///     action (needs a configured post-alert interval this tool does not
    ///     set) and `.custom` would merely relaunch the app.
    ///
    /// Pause/resume are the system-native countdown controls: with a
    /// `pauseButton` on the countdown and a `resumeButton` on the paused
    /// presentation, AlarmKit pauses/resumes the timer itself.
    static func presentation(
        label: String,
        includesCountdown: Bool
    ) -> AlarmPresentation {
        let title = Self.title(label: label)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmButton(
                    text: LocalizedStringResource(stringLiteral: "apple.alarm.stop"),
                    textColor: .white,
                    systemImageName: "stop.fill"
                )
            )
        }
        guard includesCountdown else {
            return AlarmPresentation(alert: alert)
        }
        let countdown = AlarmPresentation.Countdown(
            title: title,
            pauseButton: AlarmButton(
                text: LocalizedStringResource(stringLiteral: "apple.alarm.pause"),
                textColor: .white,
                systemImageName: "pause.fill"
            )
        )
        let paused = AlarmPresentation.Paused(
            title: title,
            resumeButton: AlarmButton(
                text: LocalizedStringResource(stringLiteral: "apple.alarm.resume"),
                textColor: .white,
                systemImageName: "play.fill"
            )
        )
        return AlarmPresentation(alert: alert, countdown: countdown, paused: paused)
    }
}

// MARK: - Authorization

/// Distinct OS authorization outcomes for an alarm/timer call. A
/// `requestAuthorization` result is NEVER reported as a scheduled alarm.
enum SystemAlarmAuthorization: String, Sendable, CaseIterable {
    /// Not yet requested; the system prompt may be shown on the next call.
    case notDetermined
    /// The user granted AlarmKit authorization.
    case authorized
    /// The user denied AlarmKit authorization.
    case denied
    /// AlarmKit is unavailable on this device/runtime.
    case unavailable
    /// The call needs the app in the foreground (system prompt cannot show
    /// for a backgrounded app); resurface in the foreground.
    case foregroundRequired

    var canSchedule: Bool { self == .authorized }
}

// MARK: - Errors

/// Typed, observable alarm errors. Cancelled-before-commit and
/// cancelled-after-commit are distinct from a real native failure, and a
/// thrown schedule error is never silently reported as success.
enum SystemAlarmError: Error, Sendable, Equatable {
    /// Arguments failed validation before any native mutation.
    case invalidRequest(String)
    /// The task/owner provenance could not be established.
    case missingOwner
    case operationInProgress
    /// OS authorization denied/unavailable/foreground-required.
    case authorization(SystemAlarmAuthorization)
    /// The AlarmKit mutation itself threw.
    case native(String)
    /// The operation was cancelled before the native mutation committed.
    case cancelledBeforeCommit
    /// The durable intent row could not be persisted before the mutation.
    case intentPersistenceFailed
    /// A timer control carried an expected revision that no longer matches
    /// the durable/native state (the timer changed after the UI read it).
    /// The caller must re-read `timerStatus` and retry from fresh state.
    case staleControlRevision

    var exitStatus: Int32 {
        switch self {
        case .invalidRequest: return 65
        case .missingOwner: return 77
        case .operationInProgress: return 75
        case .authorization: return 77
        case .native: return 1
        case .cancelledBeforeCommit: return 130
        case .intentPersistenceFailed: return 1
        case .staleControlRevision: return 78
        }
    }
}

// MARK: - Native timer binding (immutable inline-card identity)

/// The immutable identity binding between an inline assistant-body timer
/// card and the exact durable/native alarm that produced it. Created by the
/// trusted `apple.alarm.schedule` tool ONLY after the schedule was confirmed
/// by a real native readback (`record.state == .created`). It binds the
/// artifact to the ledger row (timer id, owner task/run, producer call,
/// creation receipt, incarnation) and freezes the creation-time display
/// facts (label, total duration). It NEVER carries mutable remaining/state —
/// live time always comes from the native service at display time, and the
/// card fails closed when the binding does not match the durable ledger.
struct NativeTimerBinding: Codable, Sendable, Equatable {
    /// Schema version of the binding JSON.
    static let currentVersion = 1
    /// Exact MIME the allowlisted catalog and receipt checks require.
    static let mimeType = "application/vnd.floe.native-timer+json"
    /// Artifact path shape: `TimerArtifacts/<runUUID>/<artifactUUID>.timer.json`.
    static let artifactDirectory = "TimerArtifacts"
    static let artifactSuffix = ".timer.json"
    /// Byte ceiling for the small binding JSON.
    static let maximumBytes = 16 * 1_024

    var version: Int
    /// The stable app-owned native alarm id (also the ledger row id).
    var timerID: UUID
    /// Durable conversation that owns the timer.
    var ownerTaskID: UUID?
    /// Run that produced the timer.
    var producerRunID: UUID
    /// Provider tool-call id of the exact approved schedule call.
    var producerCallID: String
    /// Durable operation receipt of the schedule mutation.
    var creationReceiptID: UUID
    /// `sha256("v1|<timerID>|<payloadDigest>")`, prefix-24 — re-derived and
    /// compared at card resolve time so a tampered or stale artifact cannot
    /// bind to a different ledger row.
    var incarnation: String
    /// Bounded display label frozen at creation.
    var label: String
    /// Total authored countdown duration (immutable).
    var duration: TimeInterval

    static func incarnation(timerID: UUID, payloadDigest: String) -> String {
        String(FloeDigest.sha256Hex(Data("v1|\(timerID.uuidString)|\(payloadDigest)".utf8)).prefix(24))
    }

    init?(record: SystemAlarmRecord, label: String, duration: TimeInterval) {
        guard record.kind == .timer, record.state == .created else { return nil }
        self.version = Self.currentVersion
        self.timerID = record.id
        self.ownerTaskID = record.ownerTaskID
        self.producerRunID = record.ownerRunID
        self.producerCallID = record.operationID
        self.creationReceiptID = record.operationReceiptID
        self.incarnation = Self.incarnation(timerID: record.id, payloadDigest: record.payloadDigest)
        self.label = String(label.prefix(64))
        self.duration = duration
    }
}

// MARK: - Native abstraction (fakeable)

/// The AlarmKit surface the service uses. A fake implements this in tests so
/// no real alarm ever rings, no permission is requested and no Live Activity
/// is created; the store and service run their real production paths.
protocol SystemAlarmNativeManaging: Sendable {
    var isAvailable: Bool { get }
    var authorization: SystemAlarmAuthorization { get async }
    func requestAuthorization() async throws -> SystemAlarmAuthorization
    /// All alarms currently scheduled for this app (throws on readback error).
    func alarms() async throws -> [SystemAlarmNativeSnapshot]
    /// Schedule a native alarm/timer with the exact app-owned id; returns the
    /// native snapshot. A returned value is not ring evidence — readback
    /// still confirms it below.
    func schedule(
        id: UUID,
        kind: SystemAlarmKind,
        intendedFireDate: Date?,
        repeatRule: SystemAlarmRepeat,
        timerDuration: TimeInterval?,
        label: String,
        metadataOwnerReference: String
    ) async throws -> SystemAlarmNativeSnapshot
    /// Cancel the native alarm with the exact app-owned id. A cancel that
    /// addresses an id this app never scheduled must surface an error, not be
    /// adopted silently.
    func cancel(id: UUID) async throws
    /// Pause a counting-down timer natively. Addressing an id this app never
    /// scheduled (or one not in countdown) surfaces an error.
    func pause(id: UUID) async throws
    /// Resume a paused timer natively.
    func resume(id: UUID) async throws
    /// Observe native alarm-set changes (service-owned, bounded). Emits for
    /// AlarmKit alarm changes AND for Live Activity timeline (mode) changes,
    /// so a countdown that starts later than the initial manager snapshot
    /// still converges instead of staying unverified indefinitely.
    var alarmUpdates: AsyncStream<[SystemAlarmNativeSnapshot]> { get async }
}

/// Read-only native alarm snapshot used by the service and fakes.
///
/// `id`/`state` are the long-standing identity fields; every timeline field
/// is optional with a default so existing fakes keep compiling and a manager
/// without Live Activity data produces the same id/state-only snapshot it
/// always did. Timeline values come ONLY from the real
/// `Activity<FloeSystemAlarmActivityAttributes>` content state — never from
/// a createdAt+duration computation.
struct SystemAlarmNativeSnapshot: Sendable, Equatable {
    var id: UUID
    var state: String
    /// User-facing label resolved from the activity presentation (best
    /// effort; nil when no Live Activity data is available yet).
    var title: String? = nil
    /// Countdown/Paused mode: total authored countdown duration.
    var totalDuration: TimeInterval? = nil
    /// Countdown/Paused mode: elapsed duration before the current segment.
    var previousElapsed: TimeInterval? = nil
    /// Countdown mode: when the current countdown segment started.
    var startDate: Date? = nil
    /// Countdown mode: the absolute fire instant (nil while paused).
    var fireDate: Date? = nil
    /// Digest of the timeline payload; changes whenever any timeline field
    /// changes. Input to the optimistic control revision.
    var timelineFingerprint: String? = nil
}

// MARK: - Timer controls

/// User-facing control actions for one owned countdown timer. Distinct from
/// the schedule/cancel tool arguments: these are trusted UI actions applied
/// to an already-verified owned native alarm.
enum SystemAlarmTimerAction: String, Sendable, Codable, CaseIterable {
    case pause
    case resume
    case cancel
}

/// Authoritative state of one owned timer: the durable ledger record, the
/// optional native timeline snapshot, and the optimistic control revision.
struct SystemAlarmTimerStatus: Sendable, Equatable {
    var record: SystemAlarmRecord
    var snapshot: SystemAlarmNativeSnapshot?
    /// Fingerprint of (record state, native state, timeline) at read time.
    /// `controlTimer` rejects an action whose expected revision no longer
    /// matches, so a control based on stale UI state is refused instead of
    /// landing on a silently changed timer.
    var revision: UInt64
}

/// Deterministic optimistic-revision fingerprint for timer controls. Derived
/// purely from durable/native facts — never from wall-clock reads — so the
/// same state always fingerprints the same way across processes.
enum SystemAlarmControlRevision {
    static func fingerprint(
        record: SystemAlarmRecord,
        snapshot: SystemAlarmNativeSnapshot?
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a offset basis
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            hash ^= 0xff // field separator
            hash &*= 0x0000_0100_0000_01b3
        }
        mix(record.id.uuidString)
        mix(record.operationReceiptID.uuidString)
        mix(record.payloadDigest)
        mix(record.state.rawValue)
        mix(record.nativeState ?? "")
        mix(snapshot?.state ?? "")
        mix(snapshot?.timelineFingerprint ?? "")
        mix(snapshot?.fireDate.map { $0.timeIntervalSince1970.exactString } ?? "")
        return hash
    }
}

extension TimeInterval {
    /// Exact decimal rendering (no locale, no rounding drift) for fingerprint
    /// mixing; stored dates already carry fixed-precision codecs.
    fileprivate var exactString: String { String(format: "%.6f", self) }
}
#endif
