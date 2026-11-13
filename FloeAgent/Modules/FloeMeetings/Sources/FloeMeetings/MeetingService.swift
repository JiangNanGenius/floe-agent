// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct CaptureSessionOutcome: Sendable {
    public let session: CaptureSessionID
    public let state: CaptureSessionState
    public let stopReason: CaptureStopReason?
}

/// One whole-file ASR observation for the post-record correction pass.
public struct CanonicalTranscriptInput: Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let speakerID: SpeakerID?

    public init(startSeconds: Double, endSeconds: Double, text: String, speakerID: SpeakerID? = nil) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speakerID = speakerID
    }
}

/// Result of adopting a whole-original transcription into the live transcript.
public struct TranscriptReconciliation: Sendable, Equatable {
    /// Engine rows upgraded to the canonical text/speaker.
    public let adopted: Int
    /// Canonical rows with no time-corresponding existing segment.
    public let appended: Int
    /// Existing rows left untouched because the user corrected them.
    public let preserved: Int
}

/// In-progress (not yet finalized) transcript text. Partials live in memory
/// only; they are never persisted and are discarded when their session ends.
public struct PartialTranscript: Sendable, Codable, Identifiable, Hashable {
    public let id: TranscriptSegmentID
    public let meetingID: MeetingID
    public let sessionID: CaptureSessionID
    public var text: String
    public var language: String?
}
/// Facade over the meeting core: capture lifecycle, transcript ordering and
/// revisions, notes/markers, todos, decisions and summary input. All state is
/// persisted through `MeetingDatabase` (GRDB); every finalized mutation is
/// durable before the call returns, so reopening a meeting loses nothing.
public actor MeetingService {
    private let database: MeetingDatabase
    private let capture = MeetingCaptureController()

    /// In-memory partials, keyed by meeting then segment id, insertion order
    /// preserved by `partialOrder`.
    private var partials: [MeetingID: [TranscriptSegmentID: PartialTranscript]] = [:]
    private var partialOrder: [MeetingID: [TranscriptSegmentID]] = [:]
    /// Next per-session insertion ordinal (stable tie-break for ordering).
    private var closedSessions: Set<CaptureSessionID> = []
    private var committingPartials: Set<TranscriptSegmentID> = []
    private var startReservation: (session: CaptureSessionID, meeting: MeetingID)?
    private var startEpoch = 0
    private var pauseRequests: Set<CaptureSessionID> = []
    private var finishingTasks: [CaptureSessionID: Task<Void, Error>] = [:]
    public private(set) var capturePersistenceFailure: MeetingError?
    /// Which meeting owns the active capture session.
    private var activeMeetings: [CaptureSessionID: MeetingID] = [:]
    /// Optional host sink for capture events (UI updates, file bookkeeping).
    private var captureEventHandler: (@Sendable (CaptureEvent) -> Void)?

    public init(database: MeetingDatabase) {
        self.database = database
    }

    // MARK: - Meetings

    @discardableResult
    public func createMeeting(id: MeetingID = MeetingID(), title: String, capabilities: MeetingProcessingCapabilities = .unavailable) async throws -> MeetingID {
        let meeting = MeetingSnapshot(id: id, title: title, capabilities: capabilities)
        try await database.insertMeeting(meeting)
        return meeting.id
    }

    public func meeting(_ id: MeetingID) async throws -> MeetingSnapshot {
        guard let snapshot = try await database.meeting(id) else { throw MeetingError.meetingNotFound(id) }
        return snapshot
    }

    public func meetings() async throws -> [MeetingSnapshot] {
        try await database.meetings()
    }

    // MARK: - Capture lifecycle

    public func setCaptureEventHandler(_ handler: (@Sendable (CaptureEvent) -> Void)?) {
        captureEventHandler = handler
    }

    public var activeCaptureSession: CaptureSessionID? {
        get async { await capture.activeSession }
    }

    /// All capture/import sessions of a meeting.
    public func sessions(meeting: MeetingID) async throws -> [CaptureSessionSnapshot] {
        try await database.sessions(meeting: meeting)
    }

    /// The reservation is established before any database await, so two
    /// concurrent starts cannot create ghost capturing rows.
    @discardableResult
    public func startCapture(
        meeting id: MeetingID,
        backend: any MeetingCaptureBackend,
        configuration: CaptureConfiguration,
        continuingRecording recordingID: UUID? = nil
    ) async throws -> CaptureSessionID {
        if let reserved = startReservation { throw MeetingError.captureAlreadyActive(reserved.session) }
        if let active = activeMeetings.keys.first { throw MeetingError.captureAlreadyActive(active) }
        let session = CaptureSessionSnapshot(meetingID: id, kind: configuration.kind, state: .pending,
                                             directory: configuration.directory, startedAt: Date())
        startReservation = (session.id, id)
        let epoch = startEpoch
        defer { startReservation = nil }
        var inserted = false
        do {
            if let active = await capture.activeSession { throw MeetingError.captureAlreadyActive(active) }
            _ = try await self.meeting(id)
            guard epoch == startEpoch else { throw MeetingError.captureSessionEnded(session.id) }
            if configuration.kind == .liveRecording {
                try await database.insertLiveSession(session, continuing: recordingID)
            } else {
                guard recordingID == nil else { throw MeetingError.captureSessionEnded(session.id) }
                try await database.insertSession(session)
            }
            inserted = true
            activeMeetings[session.id] = id
            guard epoch == startEpoch else { throw MeetingError.captureSessionEnded(session.id) }
            try await capture.start(session: session.id, configuration: configuration, backend: backend) { [weak self] event in
                Task { await self?.handleCaptureEvent(event, meeting: id) }
            }
            guard epoch == startEpoch, !closedSessions.contains(session.id) else {
                throw MeetingError.captureSessionEnded(session.id)
            }
            try await database.activateCapture(session.id, meeting: id)
            return session.id
        } catch {
            if inserted {
                let state: CaptureSessionState = epoch == startEpoch ? .failed : .cancelled
                closedSessions.insert(session.id)
                _ = await capture.cancel()
                try await database.finishCapture(session.id, meeting: id, state: state, reason: nil)
                activeMeetings[session.id] = nil
            }
            throw error
        }
    }

    public func recordingTakes(meeting: MeetingID) async throws -> [MeetingRecordingSnapshot] {
        _ = try await self.meeting(meeting)
        return try await database.recordingTakes(meeting: meeting)
    }

    /// Pause intent is installed on this actor before the physical stop await.
    /// The resulting capture terminal row and paused take commit atomically.
    @discardableResult
    public func pauseCapture() async throws -> CaptureSessionOutcome {
        guard let session = activeMeetings.keys.first, !closedSessions.contains(session) else { throw MeetingError.noActiveCapture }
        pauseRequests.insert(session)
        return try await stopCapture()
    }

    public func recordCapturedDuration(_ seconds: Double, session: CaptureSessionID, meeting: MeetingID) async throws {
        try await database.recordCapturedDuration(seconds, session: session, meeting: meeting)
    }

    public func finishPausedRecording(_ recordingID: UUID, meeting: MeetingID) async throws {
        guard startReservation == nil, activeMeetings.isEmpty else {
            throw MeetingError.captureAlreadyActive(startReservation?.session ?? activeMeetings.keys.first!)
        }
        try await database.finishPausedRecording(recordingID, meeting: meeting)
    }

    @discardableResult
    public func stopCapture() async throws -> CaptureSessionOutcome {
        let outcome = try await capture.stop().get()
        try await persistTerminal(outcome)
        return CaptureSessionOutcome(session: outcome.session, state: outcome.state, stopReason: outcome.stopReason)
    }

    /// Fence old recognizer results before awaiting hardware or persistence.
    @discardableResult
    public func cancelCapture() async throws -> CaptureSessionID? {
        // Fence every issued generation before the epoch changes or the
        // first await, including draining leases when capture.cancel is nil.
        for state in liveLeases.values { state.permit.revoke() }
        startEpoch += 1
        if let reservation = startReservation { closedSessions.insert(reservation.session) }
        for session in activeMeetings.keys { closedSessions.insert(session) }
        let cancelled = await capture.cancel()
        if let session = cancelled {
            try await persistTerminal(.init(session: session, state: .cancelled, stopReason: nil))
        }
        return cancelled
    }

    /// Finalize a live capture row left active by a previous process. A new
    /// MeetingService can never own that old microphone writer; the original
    /// file is preserved and the row becomes an ordinary stopped recording so
    /// playback, retry and full-file transcription remain available. An
    /// actually active capture in THIS process is never recovered.
    @discardableResult
    public func recoverInterruptedLiveCapture(
        _ id: CaptureSessionID,
        meeting: MeetingID,
        originalAvailable: Bool
    ) async throws -> Bool {
        guard startReservation?.session != id, activeMeetings[id] == nil else { return false }
        guard await capture.activeSession != id else { return false }
        let sessions = try await database.sessions(meeting: meeting)
        guard let snapshot = sessions.first(where: { $0.id == id }),
              snapshot.kind == .liveRecording,
              [.pending, .capturing, .stopping].contains(snapshot.state) else { return false }
        // A stale lease cannot exist in a new process, but revoke it if this
        // service did observe one (for example a tool-created service).
        if let leaseID = liveLeaseBySession[id], let state = liveLeases[leaseID] {
            state.permit.revoke()
            clearLivePartial(state)
            liveLeases[leaseID] = nil
            liveLeaseBySession[id] = nil
        }
        try await database.finishCapture(
            id,
            meeting: meeting,
            state: originalAvailable ? .stopped : .failed,
            reason: originalAvailable ? .recovered : nil,
            pauseRecording: originalAvailable)
        return true
    }

    private func persistTerminal(_ outcome: MeetingCaptureController.Outcome) async throws {
        guard let meeting = activeMeetings[outcome.session] else { return }
        closedSessions.insert(outcome.session)
        fenceLiveLeases(forSession: outcome.session, outcome: outcome.state)
        let removed = partials[meeting]?.values.filter { $0.sessionID == outcome.session }.map(\.id) ?? []
        for id in removed { partials[meeting]?[id] = nil }
        partialOrder[meeting]?.removeAll { removed.contains($0) }
        let task: Task<Void, Error>
        if let existing = finishingTasks[outcome.session] { task = existing }
        else {
            let database = self.database
            let pauseRecording = pauseRequests.contains(outcome.session)
            task = Task { try await database.finishCapture(outcome.session, meeting: meeting, state: outcome.state,
                                                         reason: outcome.stopReason, pauseRecording: pauseRecording) }
            finishingTasks[outcome.session] = task
        }
        do {
            try await task.value
            activeMeetings[outcome.session] = nil
            finishingTasks[outcome.session] = nil
            pauseRequests.remove(outcome.session)
            capturePersistenceFailure = nil
        } catch {
            finishingTasks[outcome.session] = nil
            let failure = (error as? MeetingError) ?? .persistenceFailed(String(describing: error))
            capturePersistenceFailure = failure
            throw failure
        }
    }

    private func handleCaptureEvent(_ event: CaptureEvent, meeting: MeetingID) async {
        let outcome: MeetingCaptureController.Outcome?
        switch event {
        case .stopped(let session, let reason): outcome = .init(session: session, state: .stopped, stopReason: reason)
        case .cancelled(let session): outcome = .init(session: session, state: .cancelled, stopReason: nil)
        case .failed(let session, _): outcome = session.map { .init(session: $0, state: .failed, stopReason: nil) }
        case .started, .chunkFinalized: outcome = nil
        }
        if let outcome {
            guard activeMeetings[outcome.session] == meeting else { return }
            do { try await persistTerminal(outcome) }
            catch { return } // Exposed as capturePersistenceFailure; explicit stop retries/throws.
        }
        captureEventHandler?(event)
    }

    /// Register an imported audio/video file as a finished session of the
    /// meeting. `probe` supplies the media duration (AVFoundation probe lives
    /// in FloeMeetingsAV); the session is immediately ready for transcription.
    @discardableResult
    public func importFile(
        meeting id: MeetingID,
        file: URL,
        kind: CaptureKind,
        origin: CaptureSessionID? = nil,
        displayName: String? = nil,
        duration: @Sendable (URL) async throws -> MediaTimeRange
    ) async throws -> CaptureSessionID {
        _ = try await self.meeting(id)
        guard kind != .liveRecording else { throw MeetingError.captureBackendFailed("Choose an audio or video import.") }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw MeetingError.importedFileUnavailable(file.lastPathComponent)
        }
        let range = try await duration(file)
        let session = CaptureSessionSnapshot(
            meetingID: id,
            kind: kind,
            state: .stopped,
            sourceFile: file.path,
            durationSeconds: range.end - range.start,
            startedAt: Date(),
            endedAt: Date(),
            stopReason: .finished,
            displayName: displayName.map { String($0.prefix(256)) }
        )
        try await database.insertSession(session, origin: origin?.description)
        return session.id
    }

    // MARK: - Transcript ingestion (engine seams)

    private func validateIngestion(meeting: MeetingID, session: CaptureSessionID) async throws {
        let sessions = try await database.sessions(meeting: meeting)
        guard let snapshot = sessions.first(where: { $0.id == session }) else { throw MeetingError.sessionNotFound(session) }
        if snapshot.kind == .liveRecording {
            let terminal = await capture.completedOutcome
            guard snapshot.state == .capturing, activeMeetings[session] == meeting, !closedSessions.contains(session),
                  terminal?.session != session else { throw MeetingError.captureSessionEnded(session) }
        } else {
            guard snapshot.state == .stopped else { throw MeetingError.captureSessionEnded(session) }
        }
    }

    /// Engine seam: open a partial result. Partials are in-memory only.
    @discardableResult
    public func beginPartial(meeting: MeetingID, session: CaptureSessionID, text: String, language: String? = nil) async throws -> TranscriptSegmentID {
        try await validateIngestion(meeting: meeting, session: session)
        let partial = PartialTranscript(id: TranscriptSegmentID(), meetingID: meeting, sessionID: session, text: text, language: language)
        partials[meeting, default: [:]][partial.id] = partial
        partialOrder[meeting, default: []].append(partial.id)
        return partial.id
    }

    /// Engine seam: stream updated text for an open partial.
    public func updatePartial(_ id: TranscriptSegmentID, meeting: MeetingID, text: String) async {
        guard !committingPartials.contains(id), let partial = partials[meeting]?[id],
              !closedSessions.contains(partial.sessionID) else { return }
        partials[meeting]?[id]?.text = text
    }

    /// Drop one RAM-only revision when its exact file decode ends, fails or
    /// is cancelled. This never commits text or changes another request.
    public func discardPartial(_ id: TranscriptSegmentID, meeting: MeetingID) {
        guard !committingPartials.contains(id) else { return }
        partials[meeting]?[id] = nil
        partialOrder[meeting]?.removeAll { $0 == id }
    }

    /// Ordered partials for display (transcript order by insertion).
    public func currentPartials(meeting: MeetingID) -> [PartialTranscript] {
        guard let order = partialOrder[meeting], let map = partials[meeting] else { return [] }
        return order.compactMap { map[$0] }
    }

    /// Engine seam: finalize an open partial into a durable final segment.
    @discardableResult
    public func commitPartial(_ id: TranscriptSegmentID, meeting: MeetingID, range: MediaTimeRange, speaker: SpeakerID? = nil) async throws -> TranscriptSegment {
        guard let partial = partials[meeting]?[id] else { throw MeetingError.segmentNotFound(id) }
        guard !committingPartials.contains(id) else { throw MeetingError.segmentNotFound(id) }
        committingPartials.insert(id)
        defer { committingPartials.remove(id) }
        try await validateIngestion(meeting: meeting, session: partial.sessionID)
        let segment = TranscriptSegment(
            id: id,
            meetingID: meeting,
            sessionID: partial.sessionID,
            speakerID: speaker,
            range: range,
            text: partial.text,
            language: partial.language,
            ordinal: 0
        )
        let saved = try await database.insertSegment(segment)
        partials[meeting]?[id] = nil
        partialOrder[meeting]?.removeAll { $0 == id }
        return saved
    }

    /// Engine seam: a final segment produced directly (e.g. file transcription).
    @discardableResult
    public func appendFinal(
        meeting: MeetingID,
        session: CaptureSessionID,
        text: String,
        range: MediaTimeRange,
        speaker: SpeakerID? = nil,
        language: String? = nil
    ) async throws -> TranscriptSegment {
        try await validateIngestion(meeting: meeting, session: session)
        let segment = TranscriptSegment(
            meetingID: meeting,
            sessionID: session,
            speakerID: speaker,
            range: range,
            text: text,
            language: language,
            ordinal: 0
        )
        return try await database.insertSegment(segment)
    }

    // MARK: - Continuous live-recognition lease
    //
    // One lease authorizes one continuous live-ASR coordinator to commit the
    // per-utterance finals of ONE live capture, including the genuine finish
    // tail after a normal stop. This is deliberately not a relaxation of the
    // ordinary fencing: the lease is validated on this actor (which also owns
    // every capture-state transition), is bound to one capture-session id, is
    // revoked by cancel/failure/epoch bumps/replacement. A shared synchronous
    // permit linearizes revocation with the final database transaction,
    // which accepts capturing OR stopped live sessions and fences overlaps.

    private struct LiveLeaseState: Sendable {
        enum Phase: Sendable {
            /// Capture is running: partials and finals are accepted.
            case capturing
            /// Normal stop delivered: only tail finals are accepted, until
            /// the coordinator closes the lease.
            case draining
            /// Terminal: any further commit throws `.leaseRevoked`.
            case closed
        }
        let meeting: MeetingID
        let session: CaptureSessionID
        let epoch: Int
        let permit: LiveTranscriptionCommitPermit
        var phase: Phase
        var partialID: TranscriptSegmentID?
    }

    private var liveLeases: [UUID: LiveLeaseState] = [:]
    private var liveLeaseBySession: [CaptureSessionID: UUID] = [:]

    /// Register the continuous live-ASR domain of one live capture. A second
    /// registration for the same session revokes the previous lease, so a
    /// replaced coordinator generation can never write after its successor
    /// starts. The capture must be actively recording.
    @discardableResult
    public func beginLiveTranscription(
        meeting: MeetingID,
        session: CaptureSessionID
    ) async throws -> LiveTranscriptionLease {
        let epoch = startEpoch
        _ = try await self.meeting(meeting)
        let snapshot = try await database.sessions(meeting: meeting)
            .first(where: { $0.id == session })
        guard let snapshot, snapshot.meetingID == meeting,
              snapshot.kind == .liveRecording, snapshot.state == .capturing,
              activeMeetings[session] == meeting, !closedSessions.contains(session),
              epoch == startEpoch else {
            throw LiveTranscriptionError.invalidSession
        }
        if let previous = liveLeaseBySession[session], let state = liveLeases[previous] {
            state.permit.revoke()
            clearLivePartial(state)
            liveLeases[previous] = nil
        }
        let lease = LiveTranscriptionLease(meeting: meeting, session: session)
        liveLeases[lease.id] = LiveLeaseState(
            meeting: meeting, session: session, epoch: startEpoch,
            permit: LiveTranscriptionCommitPermit(lease: lease, epoch: startEpoch),
            phase: .capturing, partialID: nil)
        liveLeaseBySession[session] = lease.id
        return lease
    }

    /// Create or update the single in-memory partial of a live lease. Empty
    /// text clears it. Updates stop flowing once the capture stops through
    /// the existing partial fencing.
    public func updateLivePartial(
        _ leaseID: LiveTranscriptionLease,
        text: String,
        language: String? = nil
    ) async throws {
        let state = try validatedLease(leaseID, allowDraining: false)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let partialID = state.partialID {
                partials[state.meeting]?[partialID] = nil
                partialOrder[state.meeting]?.removeAll { $0 == partialID }
                liveLeases[leaseID.id]?.partialID = nil
            }
            return
        }
        if let partialID = state.partialID {
            await updatePartial(partialID, meeting: state.meeting, text: trimmed)
        } else {
            let id = try await beginPartial(
                meeting: state.meeting, session: state.session,
                text: trimmed, language: language)
            liveLeases[leaseID.id]?.partialID = id
        }
    }

    /// Commit one finalized utterance of the live domain.
    ///
    /// Actor calls may suspend after validation. The generation's trusted
    /// permit therefore guards the whole final database transaction with the
    /// same synchronous lock used by every revocation; no stale generation
    /// can start a write after it has been revoked.
    /// `utteranceKey` is the stable identity of this utterance inside ONE
    /// trusted request domain (`<scope UUID>|<start ms>|<end ms>`): a
    /// re-commit of the same key ADOPTS revised text/speaker in the same
    /// transaction on fields the user has not corrected; an overlapping range
    /// from a DIFFERENT key returns nil (the utterance was rejected) and
    /// never overwrites anything. Only returned rows prove durable coverage.
    /// Allowed while capturing and during the normal-
    /// stop tail; throws after cancel/failure or lease replacement.
    @discardableResult
    public func commitLiveFinal(
        _ leaseID: LiveTranscriptionLease,
        text: String,
        range: MediaTimeRange,
        speaker: SpeakerID? = nil,
        language: String? = nil,
        utteranceKey: String? = nil
    ) async throws -> TranscriptSegment? {
        let state = try validatedLease(leaseID, allowDraining: true)
        guard range.start.isFinite, range.end.isFinite, range.end > range.start else {
            throw LiveTranscriptionError.invalidRange
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let segment = TranscriptSegment(
            meetingID: state.meeting,
            sessionID: state.session,
            speakerID: speaker,
            range: range,
            text: trimmed,
            language: language,
            ordinal: 0
        )
        let key = utteranceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = try await database.upsertLiveTranscriptSegment(
            segment, liveKey: key?.isEmpty == false ? key : nil, permit: state.permit)
        // A final supersedes the visible partial even when overlap rejects
        // its insertion. Rejection does not imply the whole range is durable.
        lockPartialSupersede(leaseID: leaseID, meeting: state.meeting)
        return outcome.segment
    }

    /// Clearing the lease partial is synchronous in-memory work on this
    /// actor; the committed final replaces the visible partial.
    private func lockPartialSupersede(leaseID: LiveTranscriptionLease, meeting: MeetingID) {
        if let partialID = liveLeases[leaseID.id]?.partialID {
            partials[meeting]?[partialID] = nil
            partialOrder[meeting]?.removeAll { $0 == partialID }
            liveLeases[leaseID.id]?.partialID = nil
        }
    }

    /// Rows already committed for one original's lineage, for the App-side
    /// reserved-range computation (file fallback transcribes only real gaps).
    public func committedSegments(
        meeting: MeetingID,
        original: CaptureSessionID
    ) async throws -> [TranscriptSegment] {
        let lineage = try await database.analysisLineage(meeting: meeting, original: original)
        return try await database.segments(inLineage: meeting, lineage: lineage)
    }

    /// Native, measured attribution. Source/recording ownership and user
    /// correction precedence are checked in the same database transaction.
    @discardableResult
    public func applyRecordingSpeakers(meeting: MeetingID, original: CaptureSessionID,
                                       window: MediaTimeRange, spans: [RecordingSpeakerSpan]) async throws -> Int {
        try await database.applyRecordingSpeakers(meeting: meeting, original: original, window: window, spans: spans)
    }

    /// Close the lease and drop its partial. Idempotent.
    public func endLiveTranscription(_ leaseID: LiveTranscriptionLease) async {
        guard let state = liveLeases[leaseID.id] else { return }
        state.permit.revoke()
        clearLivePartial(state)
        liveLeases[leaseID.id] = nil
        if liveLeaseBySession[state.session] == leaseID.id {
            liveLeaseBySession[state.session] = nil
        }
    }

    private func validatedLease(
        _ leaseID: LiveTranscriptionLease,
        allowDraining: Bool
    ) throws -> LiveLeaseState {
        guard let state = liveLeases[leaseID.id],
              state.meeting == leaseID.meeting, state.session == leaseID.session else {
            throw LiveTranscriptionError.unknownLease
        }
        guard state.epoch == startEpoch, state.permit.epoch == state.epoch else {
            throw LiveTranscriptionError.leaseRevoked
        }
        switch state.phase {
        case .capturing:
            return state
        case .draining:
            if allowDraining { return state }
            throw LiveTranscriptionError.leaseRevoked
        case .closed:
            throw LiveTranscriptionError.leaseRevoked
        }
    }

    private func clearLivePartial(_ state: LiveLeaseState) {
        guard let partialID = state.partialID else { return }
        partials[state.meeting]?[partialID] = nil
        partialOrder[state.meeting]?.removeAll { $0 == partialID }
    }

    /// Terminal capture outcomes fence the leases of that session: a normal
    /// stop keeps them open for the genuine tail (bounded by the coordinator
    /// closing them); cancel/failure revokes immediately.
    private func fenceLiveLeases(forSession session: CaptureSessionID, outcome: CaptureSessionState) {
        guard let leaseID = liveLeaseBySession[session],
              let state = liveLeases[leaseID], state.session == session else { return }
        switch outcome {
        case .stopped:
            if case .capturing = state.phase {
                liveLeases[leaseID]?.phase = .draining
            }
        case .cancelled, .failed:
            state.permit.revoke()
            clearLivePartial(state)
            liveLeases[leaseID]?.phase = .closed
        default:
            break
        }
    }

    /// Final segments by recording session, media time, then insertion.
    public func transcript(meeting: MeetingID) async throws -> [TranscriptSegment] {
        try await database.segments(meeting: meeting)
    }

    /// Resolve note/marker/summary sources, including superseded transcript
    /// history. This is read-only; stale mutation IDs remain rejected.
    public func sourceSegments(meeting: MeetingID, ids: Set<TranscriptSegmentID>) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let values = try await database.sourceSegments(meeting: meeting, ids: ids)
        try Task.checkCancellation()
        return values
    }

    /// User correction of a final segment. Original engine text is kept.
    @discardableResult
    public func correctSegment(_ id: TranscriptSegmentID, meeting: MeetingID, newText: String) async throws -> TranscriptSegment {
        var segment = try await loadSegment(id, meeting: meeting)
        segment.applyUserCorrection(newText)
        try await database.updateSegmentCorrection(segment)
        return segment
    }

    private func loadSegment(_ id: TranscriptSegmentID, meeting: MeetingID) async throws -> TranscriptSegment {
        let all = try await database.segments(meeting: meeting)
        guard let segment = all.first(where: { $0.id == id }) else { throw MeetingError.segmentNotFound(id) }
        return segment
    }

    // MARK: - Speakers

    @discardableResult
    public func addSpeaker(meeting: MeetingID, label: String, userNamed: Bool = false) async throws -> Speaker {
        guard try await database.meeting(meeting) != nil else { throw MeetingError.meetingNotFound(meeting) }
        let speaker = Speaker(label: label, userNamed: userNamed)
        try await database.insertSpeaker(speaker, meeting: meeting)
        return speaker
    }

    public func speakers(meeting: MeetingID) async throws -> [Speaker] {
        try await database.speakers(meeting: meeting)
    }

    /// Rename a speaker. The id is untouched, so every segment referencing it
    /// keeps its source. User renames protect the label from engine relabeling.
    public func renameSpeaker(_ id: SpeakerID, meeting: MeetingID, to label: String, byUser: Bool) async throws {
        var speaker = try await loadSpeaker(id, meeting: meeting)
        speaker.label = label
        if byUser { speaker.userNamed = true }
        try await database.updateSpeaker(speaker, meeting: meeting)
    }

    /// Merge two speakers. Segments keep pointing at the merged id; reads
    /// resolve through the merge chain, preserving their source references.
    /// Engine bindings that pointed at the merged speaker are re-pointed at
    /// the target, so recognition that arrives after the merge still commits
    /// into the merged identity.
    public func mergeSpeaker(_ id: SpeakerID, into target: SpeakerID, meeting: MeetingID) async throws {
        guard id != target else { return }
        var speaker = try await loadSpeaker(id, meeting: meeting)
        let resolved = try await resolveSpeaker(target, meeting: meeting)
        speaker.mergedInto = resolved
        try await database.updateSpeaker(speaker, meeting: meeting)
        try await database.rebindSpeaker(meeting: meeting, from: id, to: resolved)
    }

    /// Map one engine attribution label to a stable meeting speaker. The
    /// mapping is scoped to ONE real recognition request (`scope` identifies
    /// that request): providers restart their speaker numbering on every new
    /// request or reconnect, so a "1" from an independent request is never
    /// assumed to be the same person and is not merged across requests.
    /// The first sight of a label inside a request creates an anonymous
    /// speaker (`Speaker N`, `userNamed == false`); later segments with the
    /// same label in the SAME request reuse it, including after app restarts.
    /// Get-or-create runs in one database transaction, so concurrent
    /// resolutions cannot duplicate speakers for one label. A nil/empty
    /// label returns nil and never fabricates a speaker.
    @discardableResult
    public func resolveEngineSpeaker(
        meeting: MeetingID,
        scope: String,
        label: String?
    ) async throws -> SpeakerID? {
        guard let raw = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard try await database.meeting(meeting) != nil else { throw MeetingError.meetingNotFound(meeting) }
        let bound = try await database.resolveSpeakerBinding(
            meeting: meeting, scope: scope, providerLabel: raw)
        return try await resolveSpeaker(bound, meeting: meeting)
    }

    /// User correction of one segment's speaker attribution. Durable before
    /// return and marked as user-corrected, so the post-record canonical pass
    /// never overwrites it.
    @discardableResult
    public func reassignSegmentSpeaker(
        _ id: TranscriptSegmentID,
        meeting: MeetingID,
        speaker: SpeakerID?
    ) async throws -> TranscriptSegment {
        _ = try await loadSegment(id, meeting: meeting)
        try await database.updateSegmentSpeaker(id, meeting: meeting, speaker: speaker)
        return try await loadSegment(id, meeting: meeting)
    }

    /// Post-record correction pass: adopt the whole-original transcription
    /// into the existing transcript of one original recording by time
    /// correspondence. Engine rows adopt canonical segmentation, retaining
    /// existing identities where they overlap. Superseded rows remain as
    /// reference history; visible output contains one transcript. Manual
    /// corrections anchor their existing segmentation. Runs in one transaction.
    @discardableResult
    public func reconcileCanonicalTranscription(
        meeting: MeetingID,
        analysisSessions: Set<CaptureSessionID>,
        target: CaptureSessionID,
        inputs: [CanonicalTranscriptInput]
    ) async throws -> TranscriptReconciliation {
        try await database.reconcileCanonicalTranscript(
            meeting: meeting,
            analysisSessions: Set(analysisSessions.map(\.description)),
            target: target,
            inputs: inputs)
    }

    /// Resolve a speaker id through merge chains to its current identity.
    public func resolveSpeaker(_ id: SpeakerID, meeting: MeetingID) async throws -> SpeakerID {
        var all = try await database.speakers(meeting: meeting)
        var byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var current = id
        var seen: Set<SpeakerID> = []
        while let next = byID[current]?.mergedInto, !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }

    private func loadSpeaker(_ id: SpeakerID, meeting: MeetingID) async throws -> Speaker {
        let all = try await database.speakers(meeting: meeting)
        guard let speaker = all.first(where: { $0.id == id }) else { throw MeetingError.speakerNotFound(id) }
        return speaker
    }

    // MARK: - Notes & markers

    @discardableResult
    public func addNote(meeting: MeetingID, body: String, author: NoteAuthor = .user, source: SourceReference = .none) async throws -> NoteEntry {
        guard try await database.meeting(meeting) != nil else { throw MeetingError.meetingNotFound(meeting) }
        let note = NoteEntry(meetingID: meeting, body: body, author: author, source: source)
        try await database.insertNote(note)
        return note
    }

    /// Revision-guarded note edit. A stale `expectedRevision` fails with
    /// `MeetingError.staleRevision` instead of overwriting newer content.
    @discardableResult
    public func updateNoteBody(_ id: NoteEntryID, meeting: MeetingID, body: String, expectedRevision: Int) async throws -> NoteEntry {
        var note = try await loadNote(id, meeting: meeting)
        try await database.updateNoteBody(id, meeting: meeting, body: body, expectedRevision: expectedRevision, newRevision: note.revision + 1, updatedAt: Date())
        note.applyEdit(body)
        return note
    }

    public func notes(meeting: MeetingID) async throws -> [NoteEntry] {
        try await database.notes(meeting: meeting)
    }

    @discardableResult
    public func addMarker(meeting: MeetingID, label: String?, source: SourceReference) async throws -> TimeMarker {
        guard try await database.meeting(meeting) != nil else { throw MeetingError.meetingNotFound(meeting) }
        let marker = TimeMarker(meetingID: meeting, label: label, source: source)
        try await database.insertMarker(marker)
        return marker
    }

    public func markers(meeting: MeetingID) async throws -> [TimeMarker] {
        try await database.markers(meeting: meeting)
    }

    private func loadNote(_ id: NoteEntryID, meeting: MeetingID) async throws -> NoteEntry {
        let all = try await database.notes(meeting: meeting)
        guard let note = all.first(where: { $0.id == id }) else { throw MeetingError.noteNotFound(id) }
        return note
    }

    // MARK: - Todos

    /// Add a to-do. Duplicate normalized text returns the existing item
    /// (dedup) instead of creating a second row. AI proposals attach to an
    /// existing item but never overwrite text/status the user modified.
    @discardableResult
    public func addTodo(meeting: MeetingID, text: String, source: SourceReference = .none, origin: TodoOrigin) async throws -> TodoItem {
        guard try await database.meeting(meeting) != nil else { throw MeetingError.meetingNotFound(meeting) }
        let normalized = TodoItem.normalized(text)
        if var existing = try await database.todo(meeting: meeting, normalizedText: normalized) {
            existing.applyProposal(text: text, source: source)
            try await database.updateTodo(existing)
            return existing
        }
        let todo = TodoItem(meetingID: meeting, text: text, origin: origin, source: source)
        try await database.insertTodo(todo)
        return todo
    }

    /// User edit of a to-do; marks it protected against later proposals.
    @discardableResult
    public func updateTodo(_ id: TodoItemID, meeting: MeetingID, text: String? = nil, status: TodoStatus? = nil) async throws -> TodoItem {
        var todo = try await loadTodo(id, meeting: meeting)
        todo.applyUserEdit(text: text, status: status)
        try await database.updateTodo(todo)
        return todo
    }

    public func todos(meeting: MeetingID) async throws -> [TodoItem] {
        try await database.todos(meeting: meeting)
    }

    private func loadTodo(_ id: TodoItemID, meeting: MeetingID) async throws -> TodoItem {
        let all = try await database.todos(meeting: meeting)
        guard let todo = all.first(where: { $0.id == id }) else { throw MeetingError.todoNotFound(id) }
        return todo
    }

    // MARK: - Decisions & summaries

    @discardableResult
    public func recordDecision(meeting: MeetingID, text: String, source: SourceReference = .none) async throws -> MeetingDecision {
        guard try await database.meeting(meeting) != nil else { throw MeetingError.meetingNotFound(meeting) }
        let decision = MeetingDecision(meetingID: meeting, text: text, source: source)
        try await database.insertDecision(decision)
        return decision
    }

    public func decisions(meeting: MeetingID) async throws -> [MeetingDecision] {
        try await database.decisions(meeting: meeting)
    }

    /// Assemble incremental summary input: the last `window` seconds of the
    /// given session plus every decision recorded so far (rolling windows
    /// never drop earlier conclusions).
    public func summaryInput(meeting: MeetingID, session: CaptureSessionID, at: Double, window: Double = 300) async throws -> SummaryInput {
        let segments = try await database.segments(meeting: meeting)
        let decisions = try await database.decisions(meeting: meeting)
        return try SummaryInputBuilder.build(
            meetingID: meeting,
            sessionID: session,
            at: at,
            window: window,
            segments: segments,
            decisions: decisions
        )
    }

    /// Persist a host-generated summary record. This core never runs an LLM.
    @discardableResult
    public func recordSummary(meeting: MeetingID, kind: SummaryKind, text: String, window: MediaTimeRange? = nil) async throws -> SummaryRecord {
        guard try await database.meeting(meeting) != nil else { throw MeetingError.meetingNotFound(meeting) }
        let record = SummaryRecord(meetingID: meeting, kind: kind, text: text, window: window)
        try await database.insertSummary(record)
        return record
    }

    public func summaries(meeting: MeetingID) async throws -> [SummaryRecord] {
        try await database.summaries(meeting: meeting)
    }
}
