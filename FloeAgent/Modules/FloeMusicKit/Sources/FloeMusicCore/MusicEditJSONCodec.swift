import Foundation

/// Stable, field-specific diagnostics for native music edit JSON. Values and
/// whole input payloads are never copied into an error message.
public struct MusicEditJSONError: Error, Sendable, Equatable, LocalizedError {
    public let code: String
    public let path: String
    public let reason: String
    public let expected: String
    public let recovery: String

    public init(code: String, path: String, reason: String, expected: String,
                recovery: String = "Read studio.read for the current IDs and edit format, then correct this field.") {
        self.code = code
        self.path = path
        self.reason = reason
        self.expected = expected
        self.recovery = recovery
    }

    public var errorDescription: String? {
        "\(code) at \(path): \(reason) Expected \(expected). \(recovery)"
    }
}

/// Strictly plans edits; the existing host session still owns authorization,
/// revision checks, persistence and undo. No storage or audio state is touched.
public enum MusicEditJSONCodec {
    public static let maxJSONBytes = 4 * 1_024 * 1_024
    public static let maxOperations = 128
    public static let maxNotesPerBatch = 20_000
    public static let maxPlannedNotesPerBatch = 200_000

    /// Accepts either the complete native Codable `[MusicEditOp]` format, or
    /// a plain array of documented MIDI clip/pattern commands. The two formats
    /// cannot be mixed. Integers require integer JSON tokens. Nonempty plain
    /// batches containing only unchanged pattern edits return no operations;
    /// the host should skip committing that result.
    public static func decode(_ json: String, document: MusicDocument) throws -> [MusicEditOp] {
        guard json.utf8.count <= maxJSONBytes else {
            throw failure("budget_exceeded", "operations", "JSON exceeds the input budget.", "at most \(maxJSONBytes) UTF-8 bytes")
        }
        let data = Data(json.utf8)
        var parser = MusicJSONParser(bytes: Array(data))
        let root = try parser.parse()
        guard case .array(let commands) = root else {
            throw failure("type_mismatch", "operations", "The edit batch must be an array.", "a nonempty array of operations")
        }
        guard !commands.isEmpty else {
            throw failure("empty_batch", "operations", "The edit batch is empty.", "at least one operation")
        }
        guard commands.count <= maxOperations else {
            throw failure("budget_exceeded", "operations", "Too many operations.", "at most \(maxOperations) operations")
        }
        do { try document.validate() } catch {
            throw failure("invalid_document", "document", "The current music document is invalid.", "a valid current document")
        }
        let plainCount = commands.filter { $0.object?["op"] != nil }.count
        guard plainCount == 0 || plainCount == commands.count else {
            throw failure("mixed_formats", "operations", "Plain commands and native Codable operations cannot be mixed.", "one format for the whole array")
        }
        var draft = document
        if plainCount > 0 {
            var operations: [MusicEditOp] = [], noteCount = 0, plannedCount = 0
            for (index, command) in commands.enumerated() {
                let path = "operations[\(index)]"
                let planned = try plain(command, document: draft, path: path, noteCount: &noteCount)
                let cost = planned.reduce(0) { $0 + plannedNotes($1) }
                guard cost <= maxPlannedNotesPerBatch - plannedCount else {
                    throw failure("budget_exceeded", path, "The planned edits exceed the note processing budget.", "at most \(maxPlannedNotesPerBatch) notes across planned operations")
                }
                plannedCount += cost
                for operation in planned { try apply(operation, to: &draft, path: path) }
                operations += planned
            }
            try validate(draft)
            return operations
        }
        // Use the real JSONDecoder first so native Codable's established
        // wrappers, defaults and data strategy retain their exact behavior.
        let operations: [MusicEditOp]
        do {
            operations = try JSONDecoder().decode([MusicEditOp].self, from: data)
            // A second decoding audit derives allowed keys from the actual
            // model CodingKeys, including enum wrappers and dynamic dictionaries.
            // It also rejects fractional/exponent tokens in integer fields.
            _ = try MusicJSONDecoder(node: root, codingPath: []).read([MusicEditOp].self)
        } catch let error as MusicEditJSONError { throw error }
        catch let error as DecodingError { throw diagnostic(error) }
        catch {
            throw failure("invalid_value", "operations", "A native operation could not be decoded.", "the complete native Codable operation format")
        }
        var noteCount = 0
        for (index, operation) in operations.enumerated() {
            let path = "operations[\(index)]"
            try auditNotes(operation, path: path, count: &noteCount)
            try apply(operation, to: &draft, path: path)
        }
        try validate(draft)
        return operations
    }

    private static func plain(_ command: MusicJSONNode, document: MusicDocument, path: String,
                              noteCount: inout Int) throws -> [MusicEditOp] {
        let fields = try object(command, path: path)
        let operation = try string(required(fields, "op", path), path: path + ".op")
        switch operation {
        case "midi.clip.update":
            try keys(fields, allowed: ["op", "clipID", "name", "durationTicks", "notesMode", "notes"], path: path)
            let rawID = try identifier(required(fields, "clipID", path), path: path + ".clipID")
            guard var clip = document.tracks.lazy.flatMap(\.clips).first(where: { $0.id.rawValue == rawID }) else {
                throw failure("unknown_id", path + ".clipID", "The clip does not exist in this document.", "an actual clipID from studio.read")
            }
            guard case .midi(let previous) = clip.body else {
                throw failure("invalid_value", path + ".clipID", "The selected clip is not MIDI.", "the ID of a MIDI clip")
            }
            guard fields["name"] != nil || fields["durationTicks"] != nil || fields["notes"] != nil else {
                throw failure("missing_field", path, "The update contains no editable values.", "name, durationTicks or notes")
            }
            if let name = fields["name"] { clip.name = try string(name, path: path + ".name") }
            let duration = try fields["durationTicks"].map { try positive($0, path: path + ".durationTicks") } ?? previous.durationTicks
            var notes = previous.notes
            if let incoming = fields["notes"] {
                let mode = try string(required(fields, "notesMode", path), path: path + ".notesMode")
                guard mode == "append" || mode == "replace" else {
                    throw failure("invalid_value", path + ".notesMode", "Unknown note update mode.", "append or replace")
                }
                if mode == "replace" { notes = [] }
                notes += try readNotes(incoming, duration: duration, existing: notes, path: path + ".notes", count: &noteCount)
            } else if fields["notesMode"] != nil {
                throw failure("invalid_value", path + ".notesMode", "A note mode requires a notes array.", "notesMode together with notes")
            }
            try noteBounds(notes, duration: duration, path: path + ".durationTicks")
            clip.body = .midi(try MusicMIDIClipPayload(durationTicks: duration, notes: notes,
                                                    controllerPoints: previous.controllerPoints))
            return [.updateClip(clip)]
        case "midi.clip.insert":
            try keys(fields, allowed: ["op", "trackID", "name", "durationTicks", "notes", "offsetSamples"], path: path)
            let rawID = try identifier(required(fields, "trackID", path), path: path + ".trackID")
            guard let track = document.tracks.first(where: { $0.id.rawValue == rawID }), track.kind == .midi else {
                throw failure("unknown_id", path + ".trackID", "An existing MIDI track was not found.", "an actual MIDI trackID from studio.read")
            }
            let name = try string(required(fields, "name", path), path: path + ".name")
            let duration = try positive(required(fields, "durationTicks", path), path: path + ".durationTicks")
            let offset = try fields["offsetSamples"].map { try integer($0, path: path + ".offsetSamples") } ?? 0
            guard offset >= 0 else {
                throw failure("invalid_value", path + ".offsetSamples", "Clip offset is negative.", "an integer sample position >= 0")
            }
            let notes = try readNotes(required(fields, "notes", path), duration: duration, existing: [],
                                      path: path + ".notes", count: &noteCount)
            let payload = try MusicMIDIClipPayload(durationTicks: duration, notes: notes)
            return [.insertClip(try MusicClip(name: name, trackID: track.id,
                                              offset: .init(offset), body: .midi(payload)))]
        case "midi.clip.quantize":
            try keys(fields, allowed: ["op", "clipID", "gridTicks", "strength", "quantizeEnds"], path: path)
            let clipID = try existingMIDIClipID(fields, document: document, path: path)
            let grid = try positive(required(fields, "gridTicks", path), path: path + ".gridTicks")
            let strength = try fields["strength"].map { try number($0, path: path + ".strength") } ?? 1
            guard (0...1).contains(strength) else {
                throw failure("invalid_value", path + ".strength", "Quantize strength is outside its range.", "a finite number in 0...1")
            }
            let ends = try fields["quantizeEnds"].map { try boolean($0, path: path + ".quantizeEnds") } ?? false
            return try pattern(path: path) {
                try MusicPatternTools.quantize(document: document, clipID: clipID,
                    gridTicks: grid, strength: strength, quantizeEnds: ends)
            }
        case "midi.clip.transpose":
            try keys(fields, allowed: ["op", "clipID", "semitones", "outOfRange"], path: path)
            let clipID = try existingMIDIClipID(fields, document: document, path: path)
            let semitones = try integer(required(fields, "semitones", path), path: path + ".semitones")
            let policy = try fields["outOfRange"].map { try string($0, path: path + ".outOfRange") } ?? "reject"
            guard policy == "reject" || policy == "clamp" else {
                throw failure("invalid_value", path + ".outOfRange", "Unknown pitch range policy.", "reject or clamp")
            }
            return try pattern(path: path + ".semitones") {
                try MusicPatternTools.transpose(document: document, clipID: clipID,
                    semitones: Int(semitones), outOfRange: policy == "reject" ? .reject : .clamp)
            }
        case "midi.clip.velocity":
            try keys(fields, allowed: ["op", "clipID", "delta"], path: path)
            let clipID = try existingMIDIClipID(fields, document: document, path: path)
            let delta = try integer(required(fields, "delta", path), path: path + ".delta")
            return try pattern(path: path) {
                try MusicPatternTools.adjustVelocity(document: document, clipID: clipID, delta: Int(delta))
            }
        case "midi.template.insert":
            try keys(fields, allowed: ["op", "trackID", "template", "atTick", "bars", "rootPitch", "velocity", "name"], path: path)
            let rawTrack = try identifier(required(fields, "trackID", path), path: path + ".trackID")
            guard let track = document.tracks.first(where: { $0.id.rawValue == rawTrack }), track.kind == .midi else {
                throw failure("unknown_id", path + ".trackID", "An existing MIDI track was not found.", "an actual MIDI trackID from studio.read")
            }
            let rawTemplate = try string(required(fields, "template", path), path: path + ".template")
            guard let template = MusicPatternTemplate(rawValue: rawTemplate) else {
                throw failure("invalid_value", path + ".template", "Unknown starting pattern.", "drumGroove, chordProgression, arpeggio or bassLine")
            }
            let tick = try integer(required(fields, "atTick", path), path: path + ".atTick")
            guard tick >= 0 else {
                throw failure("invalid_value", path + ".atTick", "Template position is negative.", "an integer project tick >= 0")
            }
            let bars = try fields["bars"].map { try ranged($0, range: 1...64, path: path + ".bars") } ?? 4
            let root = try fields["rootPitch"].map { try ranged($0, range: 0...127, path: path + ".rootPitch") } ?? 60
            let velocity = try fields["velocity"].map { try ranged($0, range: 1...127, path: path + ".velocity") } ?? 96
            let name = try fields["name"].map { try string($0, path: path + ".name") }
            let planned = try pattern(path: path) {
                try MusicPatternTools.insertTemplate(template, document: document, trackID: track.id,
                    atTick: .init(tick), bars: bars, rootPitch: root, velocity: velocity, name: name)
            }
            try addBudget(planned.reduce(0) { $0 + plannedNotes($1) }, to: &noteCount, path: path + ".bars")
            return planned
        default:
            throw failure("unknown_operation", path + ".op", "This plain operation is unsupported.", "a documented midi.clip.* or midi.template.insert operation")
        }
    }

    private static func existingMIDIClipID(_ fields: [String: MusicJSONNode], document: MusicDocument,
                                           path: String) throws -> MusicClipID {
        let rawID = try identifier(required(fields, "clipID", path), path: path + ".clipID")
        guard let clip = document.tracks.lazy.flatMap(\.clips).first(where: { $0.id.rawValue == rawID }) else {
            throw failure("unknown_id", path + ".clipID", "The clip does not exist in this document.", "an actual clipID from studio.read")
        }
        guard case .midi = clip.body else {
            throw failure("invalid_value", path + ".clipID", "The selected clip is not MIDI.", "the ID of a MIDI clip")
        }
        return clip.id
    }

    private static func pattern(path: String, _ plan: () throws -> [MusicEditOp]) throws -> [MusicEditOp] {
        do { return try plan() } catch {
            throw failure("invalid_value", path, "The pattern edit does not fit the current clip or tempo map.", "valid MIDI pitches, clip bounds and a template span without a meter change")
        }
    }

    private static func plannedNotes(_ operation: MusicEditOp) -> Int {
        func count(_ clip: MusicClip) -> Int { if case .midi(let payload) = clip.body { payload.notes.count } else { 0 } }
        switch operation {
        case .insertClip(let clip), .updateClip(let clip): return count(clip)
        case .insertTrack(let track): return track.clips.reduce(0) { $0 + count($1) }
        default: return 0
        }
    }

    private static func readNotes(_ value: MusicJSONNode, duration: Int64, existing: [MusicMIDINote],
                                  path: String, count: inout Int) throws -> [MusicMIDINote] {
        guard case .array(let values) = value else {
            throw failure("type_mismatch", path, "Notes must be an array.", "an array of plain MIDI note objects")
        }
        try addBudget(values.count, to: &count, path: path)
        guard existing.count <= MusicMIDIClipPayload.maxNotesPerClip - values.count else {
            throw failure("budget_exceeded", path, "The resulting clip contains too many notes.", "at most \(MusicMIDIClipPayload.maxNotesPerClip) notes per clip")
        }
        var ids = Set(existing.map(\.id)), notes: [MusicMIDINote] = []
        guard ids.count == existing.count else {
            throw failure("duplicate_id", path, "The existing clip contains duplicate note IDs.", "unique note IDs within a clip")
        }
        for (index, value) in values.enumerated() {
            let notePath = path + "[\(index)]"
            let fields = try object(value, path: notePath)
            try keys(fields, allowed: ["id", "pitch", "startTick", "durationTicks", "velocity", "channel"], path: notePath)
            let id = try fields["id"].map { try identifier($0, path: notePath + ".id") } ?? UUID().uuidString.lowercased()
            guard ids.insert(id).inserted else {
                throw failure("duplicate_id", notePath + ".id", "The note ID is already used in this clip.", "a unique note ID or an omitted id")
            }
            let pitch = try ranged(required(fields, "pitch", notePath), range: 0...127, path: notePath + ".pitch")
            let start = try integer(required(fields, "startTick", notePath), path: notePath + ".startTick")
            guard start >= 0 else {
                throw failure("invalid_value", notePath + ".startTick", "Note start is negative.", "an integer tick >= 0")
            }
            let length = try positive(required(fields, "durationTicks", notePath), path: notePath + ".durationTicks")
            let (end, overflow) = start.addingReportingOverflow(length)
            guard !overflow, end <= duration else {
                throw failure("invalid_value", notePath + ".durationTicks", "The note ends beyond the clip.", "startTick + durationTicks <= clip durationTicks without overflow")
            }
            let velocity = try ranged(required(fields, "velocity", notePath), range: 1...127, path: notePath + ".velocity")
            let channel = try fields["channel"].map { try ranged($0, range: 0...15, path: notePath + ".channel") } ?? 0
            notes.append(try MusicMIDINote(id: id, pitch: pitch, startTick: .init(start),
                                          durationTicks: length, velocity: velocity, channel: channel))
        }
        return notes
    }

    private static func noteBounds(_ notes: [MusicMIDINote], duration: Int64, path: String) throws {
        guard notes.allSatisfy({ note in
            let (end, overflow) = note.startTick.value.addingReportingOverflow(note.durationTicks)
            return !overflow && end <= duration
        }) else {
            throw failure("invalid_value", path, "The new clip length would exclude retained notes.", "a duration that contains all retained notes, or explicit notesMode replace")
        }
    }

    private static func auditNotes(_ operation: MusicEditOp, path: String, count: inout Int) throws {
        func audit(_ clip: MusicClip, path: String, count: inout Int) throws {
            guard case .midi(let payload) = clip.body else { return }
            try addBudget(payload.notes.count, to: &count, path: path)
            var ids = Set<String>()
            for (index, note) in payload.notes.enumerated() where !ids.insert(note.id).inserted {
                throw failure("duplicate_id", path + "[\(index)].id", "The note ID is repeated in this clip.", "unique note IDs within a clip")
            }
        }
        switch operation {
        case .updateClip(let clip): try audit(clip, path: path + ".updateClip._0.body.midi.notes", count: &count)
        case .insertClip(let clip): try audit(clip, path: path + ".insertClip._0.body.midi.notes", count: &count)
        case .insertTrack(let track):
            for (index, clip) in track.clips.enumerated() {
                try audit(clip, path: path + ".insertTrack._0.clips[\(index)].body.midi.notes", count: &count)
            }
        default: break
        }
    }

    private static func addBudget(_ amount: Int, to count: inout Int, path: String) throws {
        guard amount <= maxNotesPerBatch - count else {
            throw failure("budget_exceeded", path, "The batch contains too many supplied or generated notes.", "at most \(maxNotesPerBatch) supplied or generated notes per batch")
        }
        count += amount
    }

    private static func apply(_ operation: MusicEditOp, to draft: inout MusicDocument, path: String) throws {
        do { try draft.apply(operation) } catch {
            throw failure("invalid_batch", path, "The operation cannot be applied to the current document.", "valid object IDs and an applicable operation")
        }
    }

    private static func validate(_ draft: MusicDocument) throws {
        do { try draft.validate() } catch {
            throw failure("invalid_batch", "operations", "The resulting document fails music validation.", "valid note bounds, object ownership, assets, tempo and routing")
        }
    }

    private static func object(_ node: MusicJSONNode, path: String) throws -> [String: MusicJSONNode] {
        guard case .object(let fields) = node else {
            throw failure("type_mismatch", path, "An operation or note must be an object.", "a JSON object")
        }
        return fields
    }

    private static func keys(_ fields: [String: MusicJSONNode], allowed: Set<String>, path: String) throws {
        for key in fields.keys.sorted() where !allowed.contains(key) {
            throw failure("unknown_field", path + "." + key, "The field is not part of this operation.", "only the documented fields")
        }
    }

    private static func required(_ fields: [String: MusicJSONNode], _ key: String, _ path: String) throws -> MusicJSONNode {
        guard let value = fields[key] else {
            throw failure("missing_field", path + "." + key, "A required field is missing.", "the documented \(key) value")
        }
        return value
    }

    private static func string(_ value: MusicJSONNode, path: String) throws -> String {
        guard case .string(let string) = value else {
            throw failure("type_mismatch", path, "The value must be a string.", "a JSON string")
        }
        guard string.utf8.count <= 4_096 else {
            throw failure("budget_exceeded", path, "The string is too long.", "at most 4096 UTF-8 bytes")
        }
        return string
    }

    private static func identifier(_ value: MusicJSONNode, path: String) throws -> String {
        let result = try string(value, path: path)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.utf8.count <= 256 else {
            throw failure("invalid_value", path, "The identifier is empty or too long.", "a nonempty ID of at most 256 UTF-8 bytes")
        }
        return result
    }

    private static func integer(_ value: MusicJSONNode, path: String) throws -> Int64 {
        guard case .number(let token) = value, let integer = Int64(token) else {
            throw failure("type_mismatch", path, "The value is not a signed 64-bit integer token.", "an integer JSON number without a fraction, exponent or overflow")
        }
        return integer
    }

    private static func positive(_ value: MusicJSONNode, path: String) throws -> Int64 {
        let number = try integer(value, path: path)
        guard number > 0 else {
            throw failure("invalid_value", path, "The duration must be positive.", "an integer tick duration > 0")
        }
        return number
    }

    private static func number(_ value: MusicJSONNode, path: String) throws -> Double {
        guard case .number(let token) = value, let number = Double(token), number.isFinite else {
            throw failure("type_mismatch", path, "The value must be a finite number.", "a finite JSON number")
        }
        return number
    }

    private static func boolean(_ value: MusicJSONNode, path: String) throws -> Bool {
        guard case .bool(let boolean) = value else {
            throw failure("type_mismatch", path, "The value must be a boolean.", "true or false")
        }
        return boolean
    }

    private static func ranged(_ value: MusicJSONNode, range: ClosedRange<Int>, path: String) throws -> Int {
        let number = try integer(value, path: path)
        guard number >= range.lowerBound, number <= range.upperBound else {
            throw failure("invalid_value", path, "The integer is outside its allowed range.", "an integer in \(range.lowerBound)...\(range.upperBound)")
        }
        return Int(number)
    }

    fileprivate static func failure(_ code: String, _ path: String, _ reason: String, _ expected: String) -> MusicEditJSONError {
        MusicEditJSONError(code: code, path: path, reason: reason, expected: expected)
    }

    fileprivate static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("operations") { result, key in
            key.intValue.map { result + "[\($0)]" } ?? (result + "." + key.stringValue)
        }
    }

    private static func diagnostic(_ error: DecodingError) -> MusicEditJSONError {
        switch error {
        case .keyNotFound(let key, let context):
            failure("missing_field", path(context.codingPath + [key]), "A required native field is missing.", "the complete documented native Codable field")
        case .typeMismatch(let type, let context):
            failure("type_mismatch", path(context.codingPath), "The native field has the wrong JSON type.", String(describing: type))
        case .valueNotFound(let type, let context):
            failure("type_mismatch", path(context.codingPath), "A native value is null or missing.", "a non-null \(String(describing: type))")
        case .dataCorrupted(let context):
            failure("invalid_value", path(context.codingPath), "The native field is malformed or outside its allowed range.", "a valid value in the native Codable format")
        @unknown default:
            failure("invalid_value", "operations", "The native operation could not be decoded.", "the native Codable operation format")
        }
    }
}

/// A bounded JSON syntax tree retains numeric tokens, so integers are never
/// rounded or coerced through Double/NSNumber. Duplicate object keys are errors.
private indirect enum MusicJSONNode {
    case object([String: MusicJSONNode]), array([MusicJSONNode]), string(String)
    case number(String), bool(Bool), null
    var object: [String: MusicJSONNode]? { if case .object(let value) = self { value } else { nil } }
}

private struct MusicJSONParser {
    let bytes: [UInt8]
    var index = 0
    var nodes = 0

    mutating func parse() throws -> MusicJSONNode {
        let root = try value(path: "operations", depth: 0)
        whitespace()
        guard index == bytes.count else { throw syntax("operations") }
        return root
    }

    private mutating func value(path: String, depth: Int) throws -> MusicJSONNode {
        nodes += 1
        guard depth <= 32, nodes <= 300_000 else {
            throw MusicEditJSONCodec.failure("budget_exceeded", path, "JSON nesting or item budget exceeded.", "at most 32 nested levels and 300000 JSON values")
        }
        whitespace()
        guard index < bytes.count else { throw syntax(path) }
        switch bytes[index] {
        case 123:
            index += 1
            var object: [String: MusicJSONNode] = [:]
            whitespace()
            if take(125) { return .object(object) }
            repeat {
                whitespace()
                let key = try string(path)
                guard key.utf8.count <= 256 else {
                    throw MusicEditJSONCodec.failure("budget_exceeded", path, "A JSON field name is too long.", "field names of at most 256 UTF-8 bytes")
                }
                let childPath = path + "." + key
                guard object[key] == nil else {
                    throw MusicEditJSONCodec.failure("duplicate_field", childPath, "The field is specified more than once.", "one value per field")
                }
                whitespace()
                guard take(58) else { throw syntax(childPath) }
                object[key] = try value(path: childPath, depth: depth + 1)
                whitespace()
                if take(125) { return .object(object) }
                guard take(44) else { throw syntax(path) }
            } while true
        case 91:
            index += 1
            var array: [MusicJSONNode] = []
            whitespace()
            if take(93) { return .array(array) }
            repeat {
                array.append(try value(path: path + "[\(array.count)]", depth: depth + 1))
                whitespace()
                if take(93) { return .array(array) }
                guard take(44) else { throw syntax(path) }
            } while true
        case 34: return .string(try string(path))
        case 116: try literal("true", path); return .bool(true)
        case 102: try literal("false", path); return .bool(false)
        case 110: try literal("null", path); return .null
        case 45, 48...57:
            let start = index
            _ = take(45)
            if !take(48) { guard digits() else { throw syntax(path) } }
            if take(46) { guard digits() else { throw syntax(path) } }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                guard digits() else { throw syntax(path) }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        default: throw syntax(path)
        }
    }

    private mutating func string(_ path: String) throws -> String {
        let start = index
        guard take(34) else { throw syntax(path) }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                catch { throw syntax(path) }
            }
            if byte == 92 { index += 1 }
            else if byte < 32 { throw syntax(path) }
        }
        throw syntax(path)
    }

    private mutating func literal(_ literal: String, _ path: String) throws {
        for byte in literal.utf8 { guard take(byte) else { throw syntax(path) } }
    }

    private mutating func digits() -> Bool {
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        return index > start
    }

    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func syntax(_ path: String) -> MusicEditJSONError {
        MusicEditJSONCodec.failure("invalid_json", path, "The JSON syntax is invalid.", "valid JSON with double-quoted keys and finite numbers")
    }
}

/// Strict audit Decoder. Its CodingKeys checks follow the real model schema;
/// dictionary keys remain dynamic and native Data remains a base64 string.
private struct MusicJSONDecoder: Decoder {
    let node: MusicJSONNode
    var codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func read<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self {
            let string = try singleValueContainer().decode(String.self)
            guard let data = Data(base64Encoded: string) else {
                throw mismatch("a base64 string")
            }
            return data as! T
        }
        return try T(from: self)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let fields) = node else { throw mismatch("a JSON object") }
        for field in fields.keys.sorted() where Key(stringValue: field) == nil {
            throw MusicEditJSONCodec.failure("unknown_field", MusicEditJSONCodec.path(codingPath) + "." + field,
                                             "The native object has an unknown field.", "only fields in the native Codable schema")
        }
        return KeyedDecodingContainer(MusicJSONKeyedContainer<Key>(decoder: self, fields: fields))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let values) = node else { throw mismatch("a JSON array") }
        return MusicJSONUnkeyedContainer(decoder: self, values: values)
    }

    func singleValueContainer() -> any SingleValueDecodingContainer { MusicJSONSingleContainer(decoder: self) }

    func child(_ value: MusicJSONNode, key: any CodingKey) -> MusicJSONDecoder {
        MusicJSONDecoder(node: value, codingPath: codingPath + [key])
    }

    func mismatch(_ expected: String) -> MusicEditJSONError {
        MusicEditJSONCodec.failure("type_mismatch", MusicEditJSONCodec.path(codingPath),
                                  "The native field has the wrong JSON type.", expected)
    }
}

private struct MusicJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init(intValue: Int) { self.intValue = intValue; stringValue = "Index \(intValue)" }
}

private struct MusicJSONKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: MusicJSONDecoder
    let fields: [String: MusicJSONNode]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { fields.keys.compactMap(Key.init(stringValue:)) }
    func contains(_ key: Key) -> Bool { fields[key.stringValue] != nil }
    func child(_ key: Key) throws -> MusicJSONDecoder {
        guard let value = fields[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Required field missing"))
        }
        return decoder.child(value, key: key)
    }
    func decodeNil(forKey key: Key) throws -> Bool { try child(key).singleValueContainer().decodeNil() }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try child(key).read(type) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try child(key).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer { try child(key).unkeyedContainer() }
    func superDecoder() throws -> any Decoder { decoder }
    func superDecoder(forKey key: Key) throws -> any Decoder { try child(key) }
}

private struct MusicJSONUnkeyedContainer: UnkeyedDecodingContainer {
    let decoder: MusicJSONDecoder
    let values: [MusicJSONNode]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { values.count }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= values.count }
    mutating func next() throws -> MusicJSONDecoder {
        guard !isAtEnd else { throw decoder.mismatch("another array element") }
        defer { currentIndex += 1 }
        return decoder.child(values[currentIndex], key: MusicJSONKey(intValue: currentIndex))
    }
    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw decoder.mismatch("another array element") }
        if case .null = values[currentIndex] { currentIndex += 1; return true }
        return false
    }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().read(type) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> { try next().container(keyedBy: type) }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { try next().unkeyedContainer() }
    mutating func superDecoder() throws -> any Decoder { try next() }
}

private struct MusicJSONSingleContainer: SingleValueDecodingContainer {
    let decoder: MusicJSONDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }
    func decodeNil() -> Bool { if case .null = decoder.node { true } else { false } }
    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let value) = decoder.node else { throw decoder.mismatch("a JSON boolean") }
        return value
    }
    func decode(_ type: String.Type) throws -> String {
        guard case .string(let value) = decoder.node else { throw decoder.mismatch("a JSON string") }
        return value
    }
    func decode(_ type: Double.Type) throws -> Double {
        guard case .number(let token) = decoder.node, let value = Double(token), value.isFinite else {
            throw decoder.mismatch("a finite JSON number")
        }
        return value
    }
    func decode(_ type: Float.Type) throws -> Float {
        let value = try Float(decode(Double.self))
        guard value.isFinite else { throw decoder.mismatch("a finite JSON number") }
        return value
    }
    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard case .number(let token) = decoder.node, let value = T(token) else {
            throw decoder.mismatch("an integer JSON number without a fraction, exponent or overflow")
        }
        return value
    }
    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.read(type) }
}
