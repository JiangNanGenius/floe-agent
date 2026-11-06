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

    func insertSession(_ session: CaptureSessionSnapshot) throws {
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
                    stopReason: session.stopReason?.rawValue
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
                    language: saved.language, sourceJSON: MeetingRecordCodec.json(saved.source)).insert(db)
                return saved
            }
        } catch let error as MeetingError { throw error }
        catch { throw MeetingError.persistenceFailed(String(describing: error)) }
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

    func segments(meeting: MeetingID) throws -> [TranscriptSegment] {
        do {
            return try pool.read { db in
                try TranscriptSegmentRecord.fetchAll(db, sql: """
                    SELECT transcript_segments.* FROM transcript_segments
                    JOIN capture_sessions ON capture_sessions.id = transcript_segments.sessionID
                    WHERE transcript_segments.meetingID = ?
                    ORDER BY capture_sessions.startedAt, capture_sessions.rowid,
                             transcript_segments.startSeconds, transcript_segments.ordinal
                    """, arguments: [meeting.description])
                    .map { row in
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
                        .applyingStored(originalText: row.originalText, correctedBy: row.correctedBy.flatMap(CorrectionAuthor.init(rawValue:)))
                    }
            }
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
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
    func applyingStored(originalText: String?, correctedBy: CorrectionAuthor?) -> TranscriptSegment {
        var copy = self
        if let originalText { copy.setStored(originalText: originalText, correctedBy: correctedBy) }
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
