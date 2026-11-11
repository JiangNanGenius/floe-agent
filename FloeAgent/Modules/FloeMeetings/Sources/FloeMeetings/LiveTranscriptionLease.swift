// SPDX-License-Identifier: MPL-2.0
import Foundation

// MARK: - Continuous live-recognition lease
//
// A lease is the trusted ingestion domain that lets ONE continuous live-ASR
// coordinator commit per-utterance finals for ONE live capture. It is the
// narrow answer to the stop-tail fence: ordinary `appendFinal` stays closed
// for stopped captures, while a lease verified on the MeetingService actor
// (the same actor that owns every capture-state transition) may commit the
// genuine finish tail of ITS OWN capture after a normal stop, and is revoked
// on cancel/failure, on epoch bumps, and when a new lease replaces it.

/// Opaque registration of one continuous-live ASR domain for one capture.
public struct LiveTranscriptionLease: Sendable, Hashable {
    public let id: UUID
    public let meeting: MeetingID
    public let session: CaptureSessionID

    public init(id: UUID = UUID(), meeting: MeetingID, session: CaptureSessionID) {
        self.id = id
        self.meeting = meeting
        self.session = session
    }
}

public enum LiveTranscriptionError: Error, Sendable, Hashable {
    /// The lease id is unknown or was already closed.
    case unknownLease
    /// The lease was revoked (cancel/failure/epoch bump/replacement). Late
    /// writes from an old generation or a cancelled capture never land.
    case leaseRevoked
    /// The session is not an active live capture of this meeting.
    case invalidSession
    /// The committed range overlaps rows that already exist (live or file).
    /// Only the actual persisted rows count as coverage of that range.
    case duplicateRange
    /// The supplied media range is not finite/positive.
    case invalidRange
}

/// Service-owned authority for one lease generation. The final synchronous
/// database transaction and revocation hold the same lock: either the whole
/// transaction commits before revoke returns, or it cannot begin. No actor
/// await or test barrier may run while this lock is held.
///
/// The lease value is public identification, never write authority; only
/// MeetingService mints and retains this internal permit for its epoch.
final class LiveTranscriptionCommitPermit: @unchecked Sendable {
    let lease: LiveTranscriptionLease
    let epoch: Int
    private let lock = NSLock()
    private var revoked = false

    init(lease: LiveTranscriptionLease, epoch: Int) {
        self.lease = lease
        self.epoch = epoch
    }

    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        revoked = true
    }

    func withCommit<T>(
        meeting: MeetingID,
        session: CaptureSessionID,
        _ transaction: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, lease.meeting == meeting, lease.session == session else {
            throw LiveTranscriptionError.leaseRevoked
        }
        return try transaction()
    }
}

// MARK: - Committed-interval coverage
//
// Live finals commit only the utterance spans the provider actually returned.
// The map is the shared vocabulary between the live coordinator and the file
// fallback queue: it records exactly which media ranges are durable, so the
// fallback transcribes only real gaps and never produces a second copy.

/// Ordered, coalesced set of committed media intervals for one capture
/// timeline. Pure value type; the 1 ms epsilon only affects boundary
/// adjacency (a file segment abutting a live utterance is not a duplicate).
public struct MeetingCoverageMap: Sendable, Hashable {
    /// Two ranges closer than this are treated as one continuous covered span.
    public static let adjacencyEpsilon = 0.001

    public private(set) var intervals: [MediaTimeRange]

    public init() {
        intervals = []
    }

    public var coveredThrough: Double? { intervals.last?.end }
    public var isEmpty: Bool { intervals.isEmpty }

    /// Validate and merge a newly committed span. Overlapping or adjacent
    /// spans coalesce; the map stays sorted and non-overlapping.
    public mutating func commit(_ range: MediaTimeRange) throws {
        _ = try MediaTimeRange(start: range.start, end: range.end)
        var next: [MediaTimeRange] = []
        var pending = range
        for existing in intervals {
            let gapBefore = pending.start - existing.end
            let gapAfter = existing.start - pending.end
            if gapBefore > Self.adjacencyEpsilon || gapAfter > Self.adjacencyEpsilon {
                next.append(existing)
            } else {
                let start = min(existing.start, pending.start)
                let end = max(existing.end, pending.end)
                pending = try MediaTimeRange(start: start, end: end)
            }
        }
        next.append(pending)
        intervals = next.sorted { $0.start < $1.start }
    }

    /// True when every point of `range` lies inside the committed union.
    public func isCovered(_ range: MediaTimeRange) -> Bool {
        guard !intervals.isEmpty else { return false }
        var cursor = range.start
        let limit = range.end
        for interval in intervals {
            if interval.end + Self.adjacencyEpsilon < cursor { continue }
            if interval.start > cursor + Self.adjacencyEpsilon { return false }
            cursor = max(cursor, interval.end)
            if cursor + Self.adjacencyEpsilon >= limit { return true }
        }
        return false
    }

    /// True when any committed span overlaps `range` (beyond adjacency).
    public func overlaps(_ range: MediaTimeRange) -> Bool {
        intervals.contains { interval in
            interval.start < range.end - Self.adjacencyEpsilon
                && interval.end > range.start + Self.adjacencyEpsilon
        }
    }

    /// The sub-ranges of `range` that are not yet covered. Empty when fully
    /// covered. Used by diagnostics and by future incremental fallback.
    public func uncoveredSubranges(of range: MediaTimeRange) -> [MediaTimeRange] {
        var uncovered: [MediaTimeRange] = []
        var cursor = range.start
        for interval in intervals {
            guard interval.end > cursor else { continue }
            if interval.start > cursor,
               let piece = try? MediaTimeRange(start: cursor, end: min(interval.start, range.end)) {
                uncovered.append(piece)
            }
            cursor = max(cursor, interval.end)
            if cursor >= range.end { break }
        }
        if cursor < range.end, let tail = try? MediaTimeRange(start: cursor, end: range.end) {
            uncovered.append(tail)
        }
        return uncovered
    }
}

// MARK: - Request-domain accounting
//
// One continuous live-ASR connection is ONE provider request domain: the
// engine's speaker numbering is only meaningful inside it. The coordinator
// rotates domains at the wire byte budget, on buffer overflow, or on failure;
// every rotation mints a fresh scope and a fresh `MeetingLiveASRDomain` whose
// `startFrame` is the exact original-frame index of its first fed frame, so
// media time stays continuous across reconnects while speaker identity never
// leaks across domains. Invariant: within one domain EVERY accepted frame is
// fed (overflow seals the domain and discards the buffered tail instead of
// dropping mid-domain), so wire time has no holes and wire offsets map to
// media time by a pure shift.

/// Wire-time accounting of one continuous live-recognition request domain.
public struct MeetingLiveASRDomain: Sendable, Hashable {
    /// Speaker-binding scope for this request (also the live turn id).
    public let scope: UUID
    /// Original capture sample rate (frames per media second).
    public let sourceSampleRate: Double
    /// Original-frame index of the first frame fed in this domain.
    public let startFrame: Int64
    /// Wire byte budget for this domain; the coordinator seals BEFORE
    /// exceeding it (adapters reject over-budget feeds).
    public let wireLimitBytes: Int64
    public private(set) var framesFed: Int64 = 0
    public private(set) var wireBytes: Int64 = 0

    public init(
        scope: UUID = UUID(),
        sourceSampleRate: Double,
        startFrame: Int64,
        wireLimitBytes: Int64
    ) {
        self.scope = scope
        self.sourceSampleRate = sourceSampleRate
        self.startFrame = startFrame
        self.wireLimitBytes = max(1_024, wireLimitBytes)
    }

    public var startMediaSeconds: Double {
        Double(startFrame) / sourceSampleRate
    }

    public var fedMediaSeconds: Double {
        Double(framesFed) / sourceSampleRate
    }

    public var fedWireSeconds: Double {
        Double(wireBytes) / (2 * 16_000)
    }

    /// Account one accepted frame batch after resampling to 16 kHz PCM16.
    /// A resampler flush adds wire bytes with zero additional source frames.
    public mutating func account(frameCount: Int, wireBytes bytes: Int) {
        guard frameCount >= 0, bytes > 0 else { return }
        framesFed += Int64(frameCount)
        wireBytes += Int64(bytes)
    }

    /// True when feeding `bytes` more would meet or exceed the budget.
    public func willExceed(wireBytes bytes: Int) -> Bool {
        wireBytes + Int64(max(0, bytes)) >= wireLimitBytes
    }

    /// Map a provider utterance offset (milliseconds from this request's fed
    /// audio) onto the capture media timeline. Offsets beyond what was fed are
    /// clamped to the fed span so a provider over-report cannot write future
    /// rows.
    public func mediaSeconds(wireMilliseconds: Double) -> Double {
        guard wireMilliseconds.isFinite, wireMilliseconds > 0 else { return startMediaSeconds }
        let wireSeconds = min(wireMilliseconds / 1_000, fedWireSeconds)
        return startMediaSeconds + wireSeconds
    }
}
