// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB

extension MeetingDatabase {
    // MARK: - Meetings

    func insertMeeting(_ meeting: MeetingSnapshot) throws {
        do {
            try pool.write { db in
                try MeetingRecord(
                    id: meeting.id.description,
                    title: meeting.title,
                    status: meeting.status.rawValue,
                    capabilitiesJSON: MeetingRecordCodec.json(meeting.capabilities),
                    createdAt: meeting.createdAt,
                    updatedAt: meeting.updatedAt
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func updateMeetingStatus(_ id: MeetingID, status: MeetingStatus, updatedAt: Date) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET status = ?, updatedAt = ? WHERE id = ?",
                    arguments: [status.rawValue, updatedAt, id.description]
                )
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func meeting(_ id: MeetingID) throws -> MeetingSnapshot? {
        do {
            return try pool.read { db in
                guard let row = try MeetingRecord.fetchOne(db, key: id.description) else { return nil }
                return MeetingSnapshot(
                    id: id,
                    title: row.title,
                    status: MeetingStatus(rawValue: row.status) ?? .draft,
                    capabilities: try MeetingRecordCodec.decode(MeetingProcessingCapabilities.self, from: row.capabilitiesJSON),
                    createdAt: row.createdAt,
                    updatedAt: row.updatedAt
                )
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func meetings() throws -> [MeetingSnapshot] {
        do {
            return try pool.read { db in
                try MeetingRecord.fetchAll(db).map { row in
                    MeetingSnapshot(
                        id: MeetingID(UUID(uuidString: row.id) ?? UUID()),
                        title: row.title,
                        status: MeetingStatus(rawValue: row.status) ?? .draft,
                        capabilities: (try? MeetingRecordCodec.decode(MeetingProcessingCapabilities.self, from: row.capabilitiesJSON)) ?? .unavailable,
                        createdAt: row.createdAt,
                        updatedAt: row.updatedAt
                    )
                }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    // MARK: - Capture sessions

    func insertSession(_ session: CaptureSessionSnapshot, origin: String? = nil) throws {
        do {
            try pool.write { db in
                try CaptureSessionRecord(
                    id: session.id.description,
                    meetingID: session.meetingID.description,
                    kind: session.kind.rawValue,
                    state: session.state.rawValue,
                    directory: session.directory?.path,
                    sourceFile: session.sourceFile,
                    durationSeconds: session.durationSeconds,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    stopReason: session.stopReason?.rawValue,
                    originSessionID: origin
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func updateSessionState(_ id: CaptureSessionID, state: CaptureSessionState, endedAt: Date?, stopReason: CaptureStopReason?) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE capture_sessions SET state = ?, endedAt = ?, stopReason = ? WHERE id = ?",
                    arguments: [state.rawValue, endedAt, stopReason?.rawValue, id.description]
                )
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func activateCapture(_ id: CaptureSessionID, meeting: MeetingID) throws {
        do {
            try pool.write { db in
                guard let row = try CaptureSessionRecord.fetchOne(db, key: id.description), row.meetingID == meeting.description else {
                    throw MeetingError.sessionNotFound(id)
                }
                guard row.state == CaptureSessionState.pending.rawValue else { throw MeetingError.captureSessionEnded(id) }
                try db.execute(sql: "UPDATE capture_sessions SET state = ? WHERE id = ?", arguments: [CaptureSessionState.capturing.rawValue, id.description])
                try db.execute(sql: "UPDATE meetings SET status = ?, updatedAt = ? WHERE id = ?", arguments: [MeetingStatus.capturing.rawValue, Date(), meeting.description])
            }
        } catch let error as MeetingError { throw error }
        catch { throw MeetingError.persistenceFailed(String(describing: error)) }
    }

    func finishCapture(_ id: CaptureSessionID, meeting: MeetingID, state: CaptureSessionState, reason: CaptureStopReason?) throws {
        do {
            try pool.write { db in
                guard let row = try CaptureSessionRecord.fetchOne(db, key: id.description), row.meetingID == meeting.description else {
                    throw MeetingError.sessionNotFound(id)
                }
                // Terminal state is immutable, including late failure/stop callbacks.
                guard row.state == CaptureSessionState.pending.rawValue || row.state == CaptureSessionState.capturing.rawValue || row.state == CaptureSessionState.stopping.rawValue else { return }
                let status: MeetingStatus = state == .stopped ? .finished : (state == .cancelled ? .cancelled : .draft)
                try db.execute(sql: "UPDATE capture_sessions SET state = ?, endedAt = ?, stopReason = ? WHERE id = ?", arguments: [state.rawValue, Date(), reason?.rawValue, id.description])
                try db.execute(sql: "UPDATE meetings SET status = ?, updatedAt = ? WHERE id = ? AND NOT EXISTS (SELECT 1 FROM capture_sessions WHERE meetingID = ? AND id != ? AND state IN ('pending', 'capturing', 'stopping'))", arguments: [status.rawValue, Date(), meeting.description, meeting.description, id.description])
            }
        } catch let error as MeetingError { throw error }
        catch { throw MeetingError.persistenceFailed(String(describing: error)) }
    }

    func sessions(meeting: MeetingID) throws -> [CaptureSessionSnapshot] {
        do {
            return try pool.read { db in
                try CaptureSessionRecord
                    .filter(Column("meetingID") == meeting.description)
                    .fetchAll(db)
                    .map { row in
                        CaptureSessionSnapshot(
                            id: CaptureSessionID(UUID(uuidString: row.id) ?? UUID()),
                            meetingID: meeting,
                            kind: CaptureKind(rawValue: row.kind) ?? .liveRecording,
                            state: CaptureSessionState(rawValue: row.state) ?? .pending,
                            directory: row.directory.map(URL.init(fileURLWithPath:)),
                            sourceFile: row.sourceFile,
                            durationSeconds: row.durationSeconds,
                            startedAt: row.startedAt,
                            endedAt: row.endedAt,
                            stopReason: row.stopReason.flatMap(CaptureStopReason.init(rawValue:))
                        )
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    // MARK: - Speakers

    func insertSpeaker(_ speaker: Speaker, meeting: MeetingID) throws {
        do {
            try pool.write { db in
                try SpeakerRecord(
                    id: speaker.id.description,
                    meetingID: meeting.description,
                    label: speaker.label,
                    userNamed: speaker.userNamed,
                    mergedInto: speaker.mergedInto?.description
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func updateSpeaker(_ speaker: Speaker, meeting: MeetingID) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE speakers SET label = ?, userNamed = ?, mergedInto = ? WHERE id = ? AND meetingID = ?",
                    arguments: [speaker.label, speaker.userNamed, speaker.mergedInto?.description, speaker.id.description, meeting.description]
                )
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func speakers(meeting: MeetingID) throws -> [Speaker] {
        do {
            return try pool.read { db in
                try SpeakerRecord
                    .filter(Column("meetingID") == meeting.description)
                    .fetchAll(db)
                    .map { row in
                        Speaker(
                            id: SpeakerID(UUID(uuidString: row.id) ?? UUID()),
                            label: row.label,
                            userNamed: row.userNamed,
                            mergedInto: row.mergedInto.flatMap { UUID(uuidString: $0) }.map(SpeakerID.init)
                        )
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    // MARK: - Speaker bindings (engine-label → stable speaker, per request)

    /// Single-transaction get-or-create: concurrent resolutions of the same
    /// label cannot race a speaker into duplicate anonymous rows or hit the
    /// binding primary key. The anonymous ordinal is the meeting's current
    /// speaker count + 1, computed inside the same write.
    func resolveSpeakerBinding(meeting: MeetingID, scope: String, providerLabel: String) throws -> SpeakerID {
        do {
            return try pool.write { db in
                if let row = try SpeakerBindingRecord
                    .filter(Column("meetingID") == meeting.description
                        && Column("scope") == scope
                        && Column("providerLabel") == providerLabel)
                    .fetchOne(db) {
                    return SpeakerID(UUID(uuidString: row.speakerID) ?? UUID())
                }
                let ordinal = try SpeakerRecord
                    .filter(Column("meetingID") == meeting.description)
                    .fetchCount(db) + 1
                let speaker = Speaker(label: "Speaker \(ordinal)", userNamed: false)
                try SpeakerRecord(
                    id: speaker.id.description,
                    meetingID: meeting.description,
                    label: speaker.label,
                    userNamed: speaker.userNamed,
                    mergedInto: nil
                ).insert(db)
                try SpeakerBindingRecord(
                    meetingID: meeting.description,
                    scope: scope,
                    providerLabel: providerLabel,
                    speakerID: speaker.id.description
                ).insert(db)
                return speaker.id
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    /// After a merge, point every binding that resolved to the merged speaker
    /// at the merge target, so later recognition commits into the target and
    /// the merge survives subsequent transcription.
    func rebindSpeaker(meeting: MeetingID, from source: SpeakerID, to target: SpeakerID) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE speaker_bindings SET speakerID = ? WHERE meetingID = ? AND speakerID = ?",
                    arguments: [target.description, meeting.description, source.description]
                )
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    // MARK: - Transcript

    /// Ownership/state checks and the next ordinal are in the same GRDB write.
    /// Reopening the service cannot reset tie-break ordinals to zero.
    func insertSegment(_ segment: TranscriptSegment) throws -> TranscriptSegment {
        _ = try MediaTimeRange(start: segment.range.start, end: segment.range.end)
        do {
            return try pool.write { db in
                guard let session = try CaptureSessionRecord.fetchOne(db, key: segment.sessionID.description),
                      session.meetingID == segment.meetingID.description else {
                    throw MeetingError.sessionNotFound(segment.sessionID)
                }
                let allowed = session.kind == CaptureKind.liveRecording.rawValue
                    ? session.state == CaptureSessionState.capturing.rawValue
                    : session.state == CaptureSessionState.stopped.rawValue
                guard allowed else { throw MeetingError.captureSessionEnded(segment.sessionID) }
                if let speaker = segment.speakerID {
                    guard let row = try SpeakerRecord.fetchOne(db, key: speaker.description),
                          row.meetingID == segment.meetingID.description else { throw MeetingError.speakerNotFound(speaker) }
                }
                let ordinal = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM transcript_segments WHERE sessionID = ?", arguments: [segment.sessionID.description]) ?? 0
                let saved = TranscriptSegment(id: segment.id, meetingID: segment.meetingID, sessionID: segment.sessionID,
                                              speakerID: segment.speakerID, range: segment.range, text: segment.text,
                                              language: segment.language, ordinal: ordinal)
                try TranscriptSegmentRecord(id: saved.id.description, meetingID: saved.meetingID.description,
                    sessionID: saved.sessionID.description, speakerID: saved.speakerID?.description,
                    ordinal: saved.ordinal, startSeconds: saved.range.start, endSeconds: saved.range.end,
                    text: saved.text, originalText: saved.originalText, correctedBy: saved.correctedBy?.rawValue,
                    speakerCorrected: saved.speakerCorrected,
                    language: saved.language, sourceJSON: MeetingRecordCodec.json(saved.source)).insert(db)
                return saved
            }
        } catch let error as MeetingError { throw error }
        catch { throw MeetingError.persistenceFailed(String(describing: error)) }
    }

    /// Attribution the user established by rename or merge, resolved from
    /// the transaction's current speaker rows. Protect the raw identities at
    /// every link of a merge chain as well as its final target. Shared by
    /// same-key live revisions and canonical adoption.
    private static func userEstablishedSpeakerIDs(in db: Database, meeting: MeetingID) throws -> Set<String> {
        let rows = try SpeakerRecord
            .filter(Column("meetingID") == meeting.description)
            .fetchAll(db)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let mergeTargets = Set(rows.compactMap(\.mergedInto))
        var established: Set<String> = []
        for row in rows {
            var current = row.id
            var seen: Set<String> = []
            while let next = byID[current]?.mergedInto, !seen.contains(current) {
                seen.insert(current)
                current = next
            }
            guard let resolved = byID[current] else { continue }
            if resolved.userNamed || mergeTargets.contains(current) {
                established.insert(row.id)
            }
        }
        return established
    }

    /// Deterministic internal test seam. The barrier is outside both the
    /// permit lock and SQL transaction, so another actor can revoke or stop
    /// the capture while a final is already waiting to commit.
    func setBeforeLiveTranscriptCommit(_ barrier: (@Sendable () async -> Void)?) {
        beforeLiveTranscriptCommit = barrier
    }

    /// Commit one live utterance by its stable request-domain identity. ONE
    /// write transaction: an existing row with the same (meeting, liveKey) is
    /// the same utterance re-committed (provider replay/retry): adopt revised
    /// text/speaker only on fields the user has NOT corrected, keep the
    /// segment id and supersede nothing. When the key is new, rows of the
    /// SAME original's lineage overlapping this range still win (file
    /// fallback or an earlier domain): the insert is skipped and nil is
    /// returned. Nil proves rejection only: an existing row may cover just a
    /// portion of the rejected utterance. Keyless finals use the same atomic
    /// lineage overlap fence, without the revision/adoption branch.
    ///
    /// The service-owned permit guards the whole synchronous transaction,
    /// including its commit. Revocation takes that exact same lock.
    func upsertLiveTranscriptSegment(
        _ segment: TranscriptSegment,
        liveKey: String?,
        permit: LiveTranscriptionCommitPermit
    ) async throws -> (segment: TranscriptSegment?, adopted: Bool) {
        _ = try MediaTimeRange(start: segment.range.start, end: segment.range.end)
        await beforeLiveTranscriptCommit?()
        do {
            return try permit.withCommit(meeting: segment.meetingID, session: segment.sessionID) {
                try pool.write { db in
                    guard let session = try CaptureSessionRecord.fetchOne(db, key: segment.sessionID.description),
                          session.meetingID == segment.meetingID.description else {
                        throw MeetingError.sessionNotFound(segment.sessionID)
                    }
                    guard session.kind == CaptureKind.liveRecording.rawValue else {
                        throw MeetingError.captureSessionEnded(segment.sessionID)
                    }
                    let state = CaptureSessionState(rawValue: session.state)
                    guard state == .capturing || state == .stopped else {
                        throw MeetingError.captureSessionEnded(segment.sessionID)
                    }
                    if let liveKey, let existing = try TranscriptSegmentRecord
                        .filter(Column("meetingID") == segment.meetingID.description && Column("liveKey") == liveKey)
                        .fetchOne(db) {
                        var adoptedText = existing.text
                        var adoptedSpeaker = existing.speakerID
                        var changed = false
                        if existing.correctedBy == nil, existing.text != segment.text {
                            try db.execute(sql: "UPDATE transcript_segments SET text = ? WHERE id = ?",
                                           arguments: [segment.text, existing.id])
                            adoptedText = segment.text
                            changed = true
                        }
                        if !existing.speakerCorrected, existing.speakerID != segment.speakerID?.description,
                           !(try Self.userEstablishedSpeakerIDs(in: db, meeting: segment.meetingID)
                            .contains(existing.speakerID ?? "")) {
                            if let speaker = segment.speakerID {
                                guard let row = try SpeakerRecord.fetchOne(db, key: speaker.description),
                                      row.meetingID == segment.meetingID.description else {
                                    throw MeetingError.speakerNotFound(speaker)
                                }
                            }
                            try db.execute(sql: "UPDATE transcript_segments SET speakerID = ? WHERE id = ?",
                                           arguments: [segment.speakerID?.description, existing.id])
                            adoptedSpeaker = segment.speakerID?.description
                            changed = true
                        }
                        let value = TranscriptSegment(id: TranscriptSegmentID(UUID(uuidString: existing.id) ?? UUID()),
                            meetingID: segment.meetingID,
                            sessionID: CaptureSessionID(UUID(uuidString: existing.sessionID) ?? UUID()),
                            speakerID: adoptedSpeaker.flatMap { UUID(uuidString: $0) }.map(SpeakerID.init),
                            range: MediaTimeRange(uncheckedStart: existing.startSeconds, end: existing.endSeconds),
                            text: adoptedText,
                            language: existing.language, ordinal: existing.ordinal)
                        return (value, changed)
                    }
                    // New/keyless final: resolve the trusted original lineage
                    // INSIDE this transaction, then let its existing rows win.
                    let epsilon = MeetingCoverageMap.adjacencyEpsilon
                    let overlapArguments: [(any DatabaseValueConvertible)?] = [
                        segment.meetingID.description,
                        segment.range.end - epsilon, segment.range.start + epsilon,
                        segment.meetingID.description, segment.sessionID.description, segment.sessionID.description,
                    ]
                    let overlapping = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM transcript_segments
                        WHERE meetingID = ? AND superseded = 0
                          AND startSeconds < ? AND endSeconds > ?
                          AND sessionID IN (
                            SELECT id FROM capture_sessions
                            WHERE meetingID = ? AND (id = ? OR originSessionID = ?)
                          )
                        """, arguments: StatementArguments(overlapArguments)) ?? 0
                    guard overlapping == 0 else { return (nil, false) }
                    if let speaker = segment.speakerID {
                        guard let row = try SpeakerRecord.fetchOne(db, key: speaker.description),
                              row.meetingID == segment.meetingID.description else { throw MeetingError.speakerNotFound(speaker) }
                    }
                    let ordinal = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM transcript_segments WHERE sessionID = ?", arguments: [segment.sessionID.description]) ?? 0
                    let saved = TranscriptSegment(id: segment.id, meetingID: segment.meetingID, sessionID: segment.sessionID,
                                                  speakerID: segment.speakerID, range: segment.range, text: segment.text,
                                                  language: segment.language, ordinal: ordinal)
                    try TranscriptSegmentRecord(id: saved.id.description, meetingID: saved.meetingID.description,
                        sessionID: saved.sessionID.description, speakerID: saved.speakerID?.description,
                        ordinal: saved.ordinal, startSeconds: saved.range.start, endSeconds: saved.range.end,
                        text: saved.text, originalText: saved.originalText, correctedBy: saved.correctedBy?.rawValue,
                        speakerCorrected: saved.speakerCorrected,
                        liveKey: liveKey,
                        language: saved.language, sourceJSON: MeetingRecordCodec.json(saved.source)).insert(db)
                    return (saved, false)
                }
            }
        } catch let error as LiveTranscriptionError { throw error }
        catch let error as MeetingError { throw error }
        catch { throw MeetingError.persistenceFailed(String(describing: error)) }
    }

    /// The trusted lineage of one original capture: the original itself plus
    /// every analysis session imported from it (explicit originSessionID
    /// links). Duplicate detection is scoped to THIS set, so two originals of
    /// one meeting can occupy the same time ranges without ever merging.
    func analysisLineage(meeting: MeetingID, original: CaptureSessionID) throws -> Set<String> {
        do {
            return try pool.read { db in
                var ids: Set<String> = [original.description]
                let rows = try CaptureSessionRecord
                    .filter(Column("meetingID") == meeting.description && Column("originSessionID") == original.description)
                    .fetchAll(db)
                for row in rows { ids.insert(row.id) }
                return ids
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    /// Non-superseded rows inside one lineage, for coverage/reserved-range
    /// computation at the App seam.
    func segments(inLineage meeting: MeetingID, lineage: Set<String>) throws -> [TranscriptSegment] {
        guard !lineage.isEmpty else { return [] }
        do {
            return try pool.read { db in
                let values = lineage.sorted()
                var result: [TranscriptSegment] = []
                for start in stride(from: 0, to: values.count, by: 400) {
                    let batch = Array(values[start..<min(start + 400, values.count)])
                    let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                    let arguments = StatementArguments([meeting.description] + batch)
                    let rows = try TranscriptSegmentRecord.fetchAll(db,
                        sql: """
                            SELECT transcript_segments.* FROM transcript_segments
                            JOIN capture_sessions ON capture_sessions.id = transcript_segments.sessionID
                            WHERE transcript_segments.meetingID = ? AND transcript_segments.superseded = 0
                              AND transcript_segments.sessionID IN (\(placeholders))
                            ORDER BY transcript_segments.startSeconds, transcript_segments.ordinal
                            """,
                        arguments: arguments)
                    result.append(contentsOf: rows.map { Self.segmentValue($0, meeting: meeting) })
                }
                return result
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    /// Non-superseded rows of ONE original's lineage overlapping [start, end)
    /// beyond a 1 ms boundary tolerance. This is the duplicate fence shared
    /// by live tail commits and file fallback: any existing row of the SAME
    /// original — live, chunk or canonical — wins; rows of OTHER originals
    /// are ignored even at identical times. Late arrivals are skipped, never
    /// overwrite user corrections.
    func segmentsOverlapping(meeting: MeetingID, lineage: Set<String>, start: Double, end: Double) throws -> [TranscriptSegment] {
        guard !lineage.isEmpty else { return [] }
        do {
            return try pool.read { db in
                let values = lineage.sorted()
                var result: [TranscriptSegment] = []
                for batchStart in stride(from: 0, to: values.count, by: 400) {
                    let batch = Array(values[batchStart..<min(batchStart + 400, values.count)])
                    let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                    var overlapArguments: [(any DatabaseValueConvertible)?] = [
                        meeting.description,
                        end - MeetingCoverageMap.adjacencyEpsilon,
                        start + MeetingCoverageMap.adjacencyEpsilon,
                    ]
                    overlapArguments.append(contentsOf: batch)
                    let arguments = StatementArguments(overlapArguments)
                    let rows = try TranscriptSegmentRecord.fetchAll(db,
                        sql: """
                            SELECT transcript_segments.* FROM transcript_segments
                            JOIN capture_sessions ON capture_sessions.id = transcript_segments.sessionID
                            WHERE transcript_segments.meetingID = ?
                              AND transcript_segments.superseded = 0
                              AND transcript_segments.startSeconds < ?
                              AND transcript_segments.endSeconds > ?
                              AND transcript_segments.sessionID IN (\(placeholders))
                            ORDER BY transcript_segments.startSeconds, transcript_segments.ordinal
                            """,
                        arguments: arguments)
                    result.append(contentsOf: rows.map { Self.segmentValue($0, meeting: meeting) })
                }
                return result
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func updateSegmentCorrection(_ segment: TranscriptSegment) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET text = ?, originalText = ?, correctedBy = ? WHERE id = ?",
                    arguments: [segment.text, segment.originalText, segment.correctedBy?.rawValue, segment.id.description]
                )
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    /// User speaker correction. A nil speaker clears the attribution; a real
    /// speaker must belong to this meeting. Marks the segment speaker-corrected
    /// so a later canonical pass never overwrites the user's choice. Durable
    /// before return, so the correction survives reopen and retranscription.
    func updateSegmentSpeaker(_ id: TranscriptSegmentID, meeting: MeetingID, speaker: SpeakerID?) throws {
        do {
            try pool.write { db in
                if let speaker {
                    guard let row = try SpeakerRecord.fetchOne(db, key: speaker.description),
                          row.meetingID == meeting.description else {
                        throw MeetingError.speakerNotFound(speaker)
                    }
                }
                try db.execute(
                    sql: "UPDATE transcript_segments SET speakerID = ?, speakerCorrected = 1 WHERE id = ? AND meetingID = ?",
                    arguments: [speaker?.description, id.description, meeting.description]
                )
            }
        } catch let error as MeetingError { throw error }
        catch { throw MeetingError.persistenceFailed(String(describing: error)) }
    }

    // MARK: - Canonical post-record reconciliation

    /// Adopt the whole-original diarization into the existing transcript of
    /// one original recording, inside a single write transaction. Matching is
    /// by overlapping time ranges across that original's analysis sessions.
    /// Canonical splits/merges replace uncorrected visible rows while retaining
    /// superseded rows for existing segment references:
    /// - engine rows adopt the canonical text/speaker (same segment id, so
    ///   notes/markers/todos keep their references);
    /// - user-corrected text or user-corrected speaker is preserved;
    /// - unmatched canonical rows append to `target`.
    /// Rows of other recordings are untouched.
    func reconcileCanonicalTranscript(
        meeting: MeetingID,
        analysisSessions: Set<String>,
        target: CaptureSessionID,
        inputs: [CanonicalTranscriptInput]
    ) throws -> TranscriptReconciliation {
        // Reject invalid provider ranges before opening a transaction. The
        // unchecked restore initializer is never appropriate for fresh input.
        for input in inputs {
            _ = try MediaTimeRange(start: input.startSeconds, end: input.endSeconds)
        }
        guard !inputs.isEmpty else {
            return TranscriptReconciliation(adopted: 0, appended: 0, preserved: 0)
        }
        do {
            return try pool.write { db in
                guard let targetRow = try CaptureSessionRecord.fetchOne(db, key: target.description),
                      targetRow.meetingID == meeting.description,
                      targetRow.state == CaptureSessionState.stopped.rawValue else {
                    throw MeetingError.captureSessionEnded(target)
                }
                var sessions = analysisSessions
                sessions.insert(target.description)
                let rows = try TranscriptSegmentRecord
                    .filter(Column("meetingID") == meeting.description)
                    .filter(Column("superseded") == false)
                    .order(Column("startSeconds"), Column("ordinal"), Column("id"))
                    .fetchAll(db)
                    .filter { sessions.contains($0.sessionID) }
                let canonical = inputs.sorted {
                    $0.startSeconds == $1.startSeconds
                        ? $0.endSeconds < $1.endSeconds : $0.startSeconds < $1.startSeconds
                }
                for input in canonical {
                    if let speaker = input.speakerID {
                        guard let row = try SpeakerRecord.fetchOne(db, key: speaker.description),
                              row.meetingID == meeting.description else {
                            throw MeetingError.speakerNotFound(speaker)
                        }
                    }
                }
                func overlap(_ row: TranscriptSegmentRecord, _ input: CanonicalTranscriptInput) -> Double {
                    max(0, min(row.endSeconds, input.endSeconds) - max(row.startSeconds, input.startSeconds))
                }

                let establishedSpeakers = try Self.userEstablishedSpeakerIDs(in: db, meeting: meeting)

                // Manual corrections anchor their existing segmentation.
                // Expand to the entire overlapping component, so an ASR split
                // or merge cannot append another copy over protected words.
                var protectedRows = Set(rows.indices.filter {
                    rows[$0].correctedBy != nil || rows[$0].speakerCorrected
                        || establishedSpeakers.contains(rows[$0].speakerID ?? "")
                })
                var protectedInputs = Set<Int>()
                var rowQueue = Array(protectedRows), inputQueue: [Int] = []
                var rowCursor = 0, inputCursor = 0
                // Visit each row/input once. Repeated whole-component scans
                // can grow cubically when adjacent ASR boundaries overlap.
                while rowCursor < rowQueue.count || inputCursor < inputQueue.count {
                    while rowCursor < rowQueue.count {
                        let row = rows[rowQueue[rowCursor]]
                        rowCursor += 1
                        for i in canonical.indices where !protectedInputs.contains(i) {
                            if overlap(row, canonical[i]) > 0 {
                                protectedInputs.insert(i)
                                inputQueue.append(i)
                            }
                        }
                    }
                    while inputCursor < inputQueue.count {
                        let input = canonical[inputQueue[inputCursor]]
                        inputCursor += 1
                        for i in rows.indices where !protectedRows.contains(i) {
                            if overlap(rows[i], input) > 0 {
                                protectedRows.insert(i)
                                rowQueue.append(i)
                            }
                        }
                    }
                }
                var adopted = 0, appended = 0, preserved = 0
                for i in protectedRows.sorted() {
                    let row = rows[i]
                    let candidates = canonical.indices.filter { overlap(row, canonical[$0]) > 0 }
                    // Text is adopted only for an unambiguous one-to-one
                    // alignment. A merged/split sentence has no trustworthy
                    // word alignment with which to rewrite user boundaries.
                    let oneToOne = candidates.count == 1 && rows.indices.filter {
                        overlap(rows[$0], canonical[candidates[0]]) > 0
                    }.count == 1
                    let newText = oneToOne && row.correctedBy == nil
                        ? canonical[candidates[0]].text : row.text
                    let labels = Set(candidates.map { canonical[$0].speakerID?.description })
                    let candidateSpeaker: String? = labels.count == 1 ? labels.first ?? nil : row.speakerID
                    let keepSpeaker = row.speakerCorrected || establishedSpeakers.contains(row.speakerID ?? "")
                    let newSpeaker = keepSpeaker ? row.speakerID : candidateSpeaker
                    if newText != row.text || newSpeaker != row.speakerID {
                        try db.execute(sql: "UPDATE transcript_segments SET text = ?, speakerID = ? WHERE id = ?",
                                       arguments: [newText, newSpeaker, row.id])
                        adopted += 1
                    } else { preserved += 1 }
                }

                var used = protectedRows
                for i in canonical.indices where !protectedInputs.contains(i) {
                    let input = canonical[i]
                    let range = try MediaTimeRange(start: input.startSeconds, end: input.endSeconds)
                    let available = rows.indices.filter { !used.contains($0) }
                    let best = available.filter { overlap(rows[$0], input) > 0 }.max {
                        overlap(rows[$0], input) < overlap(rows[$1], input)
                    }
                    if let index = best {
                        let row = rows[index]
                        used.insert(index)
                        if row.text == input.text && row.speakerID == input.speakerID?.description
                            && row.startSeconds == input.startSeconds && row.endSeconds == input.endSeconds {
                            preserved += 1
                            continue
                        }
                        // Retain the segment ID so notes still resolve.
                        // The visible source is normalized to `target` below.
                        guard let sessionID = UUID(uuidString: row.sessionID) else {
                            throw MeetingError.persistenceFailed("Invalid stored capture session identity")
                        }
                        let source = SourceReference.recording(session: CaptureSessionID(sessionID), range: range)
                        try db.execute(sql: """
                            UPDATE transcript_segments
                            SET text = ?, speakerID = ?, startSeconds = ?, endSeconds = ?, sourceJSON = ?
                            WHERE id = ?
                            """, arguments: [input.text, input.speakerID?.description,
                                range.start, range.end, try MeetingRecordCodec.json(source), row.id])
                        adopted += 1
                    } else {
                        let ordinal = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM transcript_segments WHERE sessionID = ?", arguments: [target.description]) ?? 0
                        let segment = TranscriptSegment(meetingID: meeting, sessionID: target,
                            speakerID: input.speakerID, range: range, text: input.text, ordinal: ordinal)
                        try TranscriptSegmentRecord(
                            id: segment.id.description, meetingID: meeting.description,
                            sessionID: target.description, speakerID: input.speakerID?.description,
                            ordinal: ordinal, startSeconds: range.start, endSeconds: range.end,
                            text: input.text, originalText: nil, correctedBy: nil,
                            speakerCorrected: false, language: nil,
                            sourceJSON: try MeetingRecordCodec.json(segment.source)).insert(db)
                        appended += 1
                    }
                }
                for i in rows.indices where !used.contains(i) {
                    // Keep disjoint unmatched audio rather than assuming a
                    // shorter provider result proves that those words vanished.
                    guard canonical.contains(where: { overlap(rows[i], $0) > 0 }) else { continue }
                    try db.execute(sql: "UPDATE transcript_segments SET superseded = 1 WHERE id = ?",
                                   arguments: [rows[i].id])
                }
                // All visible segments now play against the whole-original
                // analysis source. This also keeps newly split rows in media
                // time order instead of grouping them after older chunk rows.
                let active = try TranscriptSegmentRecord
                    .filter(Column("meetingID") == meeting.description)
                    .filter(Column("superseded") == false).fetchAll(db)
                for row in active where sessions.contains(row.sessionID) && row.sessionID != target.description {
                    let range = try MediaTimeRange(start: row.startSeconds, end: row.endSeconds)
                    let source = SourceReference.recording(session: target, range: range)
                    try db.execute(sql: "UPDATE transcript_segments SET sessionID = ?, sourceJSON = ? WHERE id = ?",
                                   arguments: [target.description, try MeetingRecordCodec.json(source), row.id])
                }
                return TranscriptReconciliation(adopted: adopted, appended: appended, preserved: preserved)
            }
        } catch let error as MeetingError { throw error }
        catch { throw MeetingError.persistenceFailed(String(describing: error)) }
    }

    func segments(meeting: MeetingID, includingSuperseded: Bool = false) throws -> [TranscriptSegment] {
        do {
            return try pool.read { db in
                try TranscriptSegmentRecord.fetchAll(db, sql: """
                    SELECT transcript_segments.* FROM transcript_segments
                    JOIN capture_sessions ON capture_sessions.id = transcript_segments.sessionID
                    WHERE transcript_segments.meetingID = ? AND (? OR transcript_segments.superseded = 0)
                    ORDER BY capture_sessions.startedAt, capture_sessions.rowid,
                             transcript_segments.startSeconds, transcript_segments.ordinal
                    """, arguments: [meeting.description, includingSuperseded])
                    .map { Self.segmentValue($0, meeting: meeting) }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    /// Read-only source resolution includes retained historical segments,
    /// fetched by indexed IDs in bounded batches rather than the full history.
    func sourceSegments(meeting: MeetingID, ids: Set<TranscriptSegmentID>) throws -> [TranscriptSegment] {
        guard !ids.isEmpty else { return [] }
        do {
            return try pool.read { db in
                let values = ids.map(\.description).sorted()
                var result: [TranscriptSegment] = []
                for start in stride(from: 0, to: values.count, by: 400) {
                    let batch = Array(values[start..<min(start + 400, values.count)])
                    let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                    let arguments = StatementArguments([meeting.description] + batch)
                    let rows = try TranscriptSegmentRecord.fetchAll(db,
                        sql: "SELECT * FROM transcript_segments WHERE meetingID = ? AND id IN (" + placeholders + ")",
                        arguments: arguments)
                    result.append(contentsOf: rows.map { Self.segmentValue($0, meeting: meeting) })
                }
                return result
            }
        } catch { throw MeetingError.persistenceFailed(String(describing: error)) }
    }

    private nonisolated static func segmentValue(_ row: TranscriptSegmentRecord, meeting: MeetingID) -> TranscriptSegment {
            TranscriptSegment(
                id: TranscriptSegmentID(UUID(uuidString: row.id) ?? UUID()),
                meetingID: meeting,
                sessionID: CaptureSessionID(UUID(uuidString: row.sessionID) ?? UUID()),
                speakerID: row.speakerID.flatMap { UUID(uuidString: $0) }.map(SpeakerID.init),
                range: MediaTimeRange(uncheckedStart: row.startSeconds, end: row.endSeconds),
                text: row.text,
                language: row.language,
                ordinal: row.ordinal
            )
            .applyingStored(originalText: row.originalText,
                            correctedBy: row.correctedBy.flatMap(CorrectionAuthor.init(rawValue:)),
                            speakerCorrected: row.speakerCorrected)
    }

    // MARK: - Notes & markers

    func insertNote(_ note: NoteEntry) throws {
        do {
            try pool.write { db in
                try NoteRecord(
                    id: note.id.description,
                    meetingID: note.meetingID.description,
                    body: note.body,
                    author: note.author.rawValue,
                    sourceJSON: MeetingRecordCodec.json(note.source),
                    revision: note.revision,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    /// Compare-and-swap note body update. Throws `staleRevision` with the
    /// actual stored revision when the expectation no longer matches — user
    /// edits are never silently clobbered by a stale writer.
    func updateNoteBody(_ id: NoteEntryID, meeting: MeetingID, body: String, expectedRevision: Int, newRevision: Int, updatedAt: Date) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE notes SET body = ?, revision = ?, updatedAt = ? WHERE id = ? AND meetingID = ? AND revision = ?",
                    arguments: [body, newRevision, updatedAt, id.description, meeting.description, expectedRevision]
                )
                guard db.changesCount > 0 else {
                    let actual = (try? NoteRecord.fetchOne(db, key: id.description))?.revision ?? -1
                    throw MeetingError.staleRevision(expected: expectedRevision, actual: actual)
                }
            }
        } catch let error as MeetingError {
            throw error
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func notes(meeting: MeetingID) throws -> [NoteEntry] {
        do {
            return try pool.read { db in
                try NoteRecord
                    .filter(Column("meetingID") == meeting.description)
                    .order(Column("createdAt"))
                    .fetchAll(db)
                    .map { row in
                        NoteEntry(
                            id: NoteEntryID(UUID(uuidString: row.id) ?? UUID()),
                            meetingID: meeting,
                            body: row.body,
                            author: NoteAuthor(rawValue: row.author) ?? .user,
                            source: (try? MeetingRecordCodec.decode(SourceReference.self, from: row.sourceJSON)) ?? .none,
                            createdAt: row.createdAt
                        )
                        .applyingStored(revision: row.revision, updatedAt: row.updatedAt)
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func insertMarker(_ marker: TimeMarker) throws {
        do {
            try pool.write { db in
                try MarkerRecord(
                    id: marker.id.description,
                    meetingID: marker.meetingID.description,
                    label: marker.label,
                    sourceJSON: MeetingRecordCodec.json(marker.source),
                    createdAt: marker.createdAt
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func markers(meeting: MeetingID) throws -> [TimeMarker] {
        do {
            return try pool.read { db in
                try MarkerRecord
                    .filter(Column("meetingID") == meeting.description)
                    .order(Column("createdAt"))
                    .fetchAll(db)
                    .map { row in
                        TimeMarker(
                            id: TimeMarkerID(UUID(uuidString: row.id) ?? UUID()),
                            meetingID: meeting,
                            label: row.label,
                            source: (try? MeetingRecordCodec.decode(SourceReference.self, from: row.sourceJSON)) ?? .none,
                            createdAt: row.createdAt
                        )
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    // MARK: - Todos

    func insertTodo(_ todo: TodoItem) throws {
        do {
            try pool.write { db in
                try TodoRecord(
                    id: todo.id.description,
                    meetingID: todo.meetingID.description,
                    text: todo.text,
                    normalizedText: todo.normalizedText,
                    status: todo.status.rawValue,
                    origin: todo.origin.rawValue,
                    userModified: todo.userModified,
                    sourceJSON: MeetingRecordCodec.json(todo.source),
                    createdAt: todo.createdAt,
                    updatedAt: todo.updatedAt
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func updateTodo(_ todo: TodoItem) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE todos SET text = ?, status = ?, origin = ?, userModified = ?, sourceJSON = ?, updatedAt = ? WHERE id = ?",
                    arguments: [
                        todo.text, todo.status.rawValue, todo.origin.rawValue, todo.userModified,
                        MeetingRecordCodec.json(todo.source), todo.updatedAt, todo.id.description
                    ]
                )
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func todo(meeting: MeetingID, normalizedText: String) throws -> TodoItem? {
        do {
            return try pool.read { db in
                guard let row = try TodoRecord
                    .filter(Column("meetingID") == meeting.description && Column("normalizedText") == normalizedText)
                    .fetchOne(db) else { return nil }
                return TodoItem(
                    id: TodoItemID(UUID(uuidString: row.id) ?? UUID()),
                    meetingID: meeting,
                    text: row.text,
                    origin: TodoOrigin(rawValue: row.origin) ?? .user,
                    source: (try? MeetingRecordCodec.decode(SourceReference.self, from: row.sourceJSON)) ?? .none,
                    createdAt: row.createdAt
                )
                .applyingStored(status: TodoStatus(rawValue: row.status) ?? .open, userModified: row.userModified, updatedAt: row.updatedAt)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func todos(meeting: MeetingID) throws -> [TodoItem] {
        do {
            return try pool.read { db in
                try TodoRecord
                    .filter(Column("meetingID") == meeting.description)
                    .order(Column("createdAt"))
                    .fetchAll(db)
                    .map { row in
                        TodoItem(
                            id: TodoItemID(UUID(uuidString: row.id) ?? UUID()),
                            meetingID: meeting,
                            text: row.text,
                            origin: TodoOrigin(rawValue: row.origin) ?? .user,
                            source: (try? MeetingRecordCodec.decode(SourceReference.self, from: row.sourceJSON)) ?? .none,
                            createdAt: row.createdAt
                        )
                        .applyingStored(status: TodoStatus(rawValue: row.status) ?? .open, userModified: row.userModified, updatedAt: row.updatedAt)
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    // MARK: - Decisions & summaries

    func insertDecision(_ decision: MeetingDecision) throws {
        do {
            try pool.write { db in
                try DecisionRecord(
                    id: decision.id.description,
                    meetingID: decision.meetingID.description,
                    text: decision.text,
                    sourceJSON: MeetingRecordCodec.json(decision.source),
                    createdAt: decision.createdAt
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func decisions(meeting: MeetingID) throws -> [MeetingDecision] {
        do {
            return try pool.read { db in
                try DecisionRecord
                    .filter(Column("meetingID") == meeting.description)
                    .order(Column("createdAt"))
                    .fetchAll(db)
                    .map { row in
                        MeetingDecision(
                            id: DecisionID(UUID(uuidString: row.id) ?? UUID()),
                            meetingID: meeting,
                            text: row.text,
                            source: (try? MeetingRecordCodec.decode(SourceReference.self, from: row.sourceJSON)) ?? .none,
                            createdAt: row.createdAt
                        )
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func insertSummary(_ summary: SummaryRecord) throws {
        do {
            try pool.write { db in
                try SummaryRecordRow(
                    id: summary.id.description,
                    meetingID: summary.meetingID.description,
                    kind: summary.kind.rawValue,
                    text: summary.text,
                    windowJSON: summary.window.flatMap { try? MeetingRecordCodec.json($0) },
                    createdAt: summary.createdAt
                ).insert(db)
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    func summaries(meeting: MeetingID) throws -> [SummaryRecord] {
        do {
            return try pool.read { db in
                try SummaryRecordRow
                    .filter(Column("meetingID") == meeting.description)
                    .order(Column("createdAt"))
                    .fetchAll(db)
                    .map { row in
                        SummaryRecord(
                            id: SummaryRecordID(UUID(uuidString: row.id) ?? UUID()),
                            meetingID: meeting,
                            kind: SummaryKind(rawValue: row.kind) ?? .rolling,
                            text: row.text,
                            window: row.windowJSON.flatMap { try? MeetingRecordCodec.decode(MediaTimeRange.self, from: $0) },
                            createdAt: row.createdAt
                        )
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }
}

// Re-apply stored private(set) state after decoding from a row.
extension TranscriptSegment {
    func applyingStored(originalText: String?, correctedBy: CorrectionAuthor?, speakerCorrected: Bool) -> TranscriptSegment {
        var copy = self
        copy.setStored(originalText: originalText, correctedBy: correctedBy, speakerCorrected: speakerCorrected)
        return copy
    }
}

extension NoteEntry {
    func applyingStored(revision: Int, updatedAt: Date) -> NoteEntry {
        var copy = self
        copy.setStored(revision: revision, updatedAt: updatedAt)
        return copy
    }
}

extension TodoItem {
    func applyingStored(status: TodoStatus, userModified: Bool, updatedAt: Date) -> TodoItem {
        var copy = self
        copy.setStored(status: status, userModified: userModified, updatedAt: updatedAt)
        return copy
    }
}
