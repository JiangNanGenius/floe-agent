import Foundation

public struct MusicMIDIFileImport: Sendable {
    public let tempoMap: MusicTempoMap
    public let tracks: [MusicTrack]
    /// Unsupported events remain in the original immutable SMF asset, never
    /// represented as if the editable projection had retained them.
    public let originalOnlyEventCount: Int
    public let sourceFormat: Int
}

/// Bounded SMF 0/1 interchange for the same editable MusicDocument. No audio
/// runtime, external process or implicit instrument/network installation.
public enum MusicMIDIFileExchange {
    public static let maximumBytes = 64 * 1_048_576
    public static let maximumEvents = 1_000_000

    public static func read(_ data: Data, sampleRate: Int = 48_000, ticksPerQuarter target: Int? = nil) throws -> MusicMIDIFileImport {
        guard data.count <= maximumBytes else { throw invalid("SMF size limit") }
        var file = Cursor(data)
        guard try file.bytes(4) == Array("MThd".utf8) else { throw invalid("missing MThd") }
        let headerLength = try file.integer(4)
        guard headerLength >= 6, headerLength <= 1024 else { throw invalid("SMF header") }
        let format = try file.integer(2), trackCount = try file.integer(2), division = try file.integer(2)
        guard (0...1).contains(format), trackCount > 0, trackCount <= 1024, format != 0 || trackCount == 1,
              division > 0, division & 0x8000 == 0 else { throw invalid("only PPQ SMF type 0/1 is editable; original source is unchanged") }
        _ = try file.bytes(headerLength - 6)
        let ppq = target ?? division
        guard (MusicTempoMap.minTicksPerQuarter...MusicTempoMap.maxTicksPerQuarter).contains(ppq) else { throw invalid("unsupported SMF timebase") }
        func scaled(_ tick: Int64) throws -> Int64 {
            let (product, overflow) = tick.multipliedReportingOverflow(by: Int64(ppq))
            guard !overflow, product <= Int64.max - Int64(division / 2) else { throw invalid("SMF tick overflow") }
            return (product + Int64(division / 2)) / Int64(division)
        }
        struct TempoChange { let tick: Int64; let bpm: Double?; let numerator: Int?; let denominator: Int? }
        var tempoChanges: [TempoChange] = []
        var tracks: [MusicTrack] = []
        var eventCount = 0, originalOnly = 0
        for trackIndex in 0..<trackCount {
            try Task.checkCancellation()
            guard try file.bytes(4) == Array("MTrk".utf8) else { throw invalid("missing MTrk") }
            let count = try file.integer(4)
            var input = Cursor(Data(try file.bytes(count)))
            var tick: Int64 = 0
            var running: UInt8?
            var name: String?
            var notes: [MusicMIDINote] = []
            var controllers: [String: MusicMIDIControllerPoint] = [:]
            var programs: [String: MusicMIDIProgramChange] = [:]
            var held: [Int: [(Int64, Int)]] = [:]
            var ended = false
            while input.remaining > 0 {
                eventCount += 1
                guard eventCount <= maximumEvents else { throw invalid("SMF event limit") }
                if eventCount.isMultiple(of: 256) { try Task.checkCancellation() }
                let (sum, overflow) = tick.addingReportingOverflow(try input.variable())
                guard !overflow else { throw invalid("SMF tick overflow") }; tick = sum
                var status = try input.byte()
                var first: UInt8?
                if status < 0x80 { first = status; guard let previous = running else { throw invalid("SMF running status") }; status = previous }
                if status == 0xFF {
                    running = nil
                    let type = try input.byte(), length = try input.variable()
                    guard length <= Int64(input.remaining) else { throw invalid("SMF meta length") }
                    let body = try input.bytes(Int(length))
                    switch type {
                    case 0x2F:
                        guard body.isEmpty, input.remaining == 0 else { throw invalid("SMF end-of-track") }; ended = true
                    case 0x03:
                        guard body.count <= 4096 else { throw invalid("SMF track name limit") }
                        name = String(bytes: body, encoding: .utf8) ?? String(bytes: body, encoding: .isoLatin1)
                    case 0x51:
                        guard body.count == 3 else { throw invalid("SMF tempo") }
                        let microseconds = body.reduce(0) { ($0 << 8) | Int($1) }
                        guard microseconds > 0 else { throw invalid("SMF tempo zero") }
                        tempoChanges.append(TempoChange(tick: try scaled(tick), bpm: 60_000_000 / Double(microseconds), numerator: nil, denominator: nil))
                    case 0x58:
                        guard body.count == 4, body[1] <= 4 else { throw invalid("unsupported SMF meter") }
                        tempoChanges.append(TempoChange(tick: try scaled(tick), bpm: nil, numerator: Int(body[0]), denominator: 1 << Int(body[1])))
                    default: originalOnly += 1
                    }
                    if ended { break }; continue
                }
                if status == 0xF0 || status == 0xF7 {
                    running = nil
                    let length = try input.variable()
                    guard length <= Int64(input.remaining) else { throw invalid("SMF SysEx length") }
                    _ = try input.bytes(Int(length)); originalOnly += 1; continue
                }
                guard (0x80...0xEF).contains(status) else { throw invalid("SMF channel status") }
                running = status
                let a = try first ?? input.byte()
                let op = status & 0xF0, channel = Int(status & 0x0F)
                let b: UInt8 = (op == 0xC0 || op == 0xD0) ? 0 : try input.byte()
                guard a < 128, b < 128 else { throw invalid("SMF channel data") }
                let key = channel * 128 + Int(a)
                let position = try scaled(tick)
                switch op {
                case 0x90 where b > 0: held[key, default: []].append((position, Int(b)))
                case 0x80, 0x90:
                    if var pending = held[key], !pending.isEmpty {
                        let on = pending.removeFirst(); held[key] = pending
                        notes.append(try MusicMIDINote(pitch: Int(a), startTick: .init(on.0), durationTicks: max(1, position - on.0), velocity: on.1, channel: channel))
                    } else { originalOnly += 1 }
                case 0xB0:
                    let point = try MusicMIDIControllerPoint(controller: Int(a), tick: .init(position), value: Int(b), channel: channel)
                    controllers["\(a):\(channel):\(position)"] = point
                case 0xC0: programs["\(channel):\(position)"] = try .init(tick: .init(position), channel: channel, program: Int(a))
                case 0xE0: controllers["128:\(channel):\(position)"] = try .init(controller: 128, tick: .init(position), value: Int(a) | Int(b) << 7, channel: channel)
                default: originalOnly += 1 // pressure remains byte-exact in the original asset.
                }
            }
            guard ended else { throw invalid("SMF track has no end marker") }
            let finalTick = max(1, try scaled(tick))
            for (key, pending) in held {
                for on in pending {
                    notes.append(try .init(pitch: key % 128, startTick: .init(on.0), durationTicks: max(1, finalTick - on.0), velocity: on.1, channel: key / 128))
                    originalOnly += 1 // Unclosed notes are bounded at the track end.
                }
            }
            guard !notes.isEmpty || !controllers.isEmpty || !programs.isEmpty else { continue }
            let length = max(finalTick, notes.map { $0.startTick.value + $0.durationTicks }.max() ?? 1)
            let points = controllers.values.sorted { ($0.controller, $0.channel, $0.tick.value) < ($1.controller, $1.channel, $1.tick.value) }
            let changes = programs.values.sorted { ($0.channel, $0.tick.value) < ($1.channel, $1.tick.value) }
            let id = MusicTrackID()
            let trackName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = notes.allSatisfy { $0.channel == 9 } && !notes.isEmpty ? "Drums" : "MIDI \(trackIndex + 1)"
            let title = (trackName?.isEmpty == false ? trackName! : fallback)
            let payload = try MusicMIDIClipPayload(durationTicks: length, notes: notes.sorted { ($0.startTick.value, $0.pitch) < ($1.startTick.value, $1.pitch) }, controllerPoints: points, programChanges: changes)
            let clip = try MusicClip(name: title, trackID: id, offset: .init(0), body: .midi(payload))
            tracks.append(try MusicTrack(id: id, name: title, kind: .midi, clips: [clip], instrument: MusicPluginState(pluginID: "floe.synth")))
        }
        guard file.remaining == 0, !tracks.isEmpty else { throw invalid("SMF contains no editable channel events or has trailing chunks") }
        var bpm = 120.0, numerator = 4, denominator = 4
        var segments: [MusicTempoSegment] = []
        let ticks = Set(tempoChanges.map(\.tick)).union([0]).sorted()
        for tick in ticks {
            for event in tempoChanges where event.tick == tick {
                if let value = event.bpm { bpm = value }
                if let value = event.numerator { numerator = value }
                if let value = event.denominator { denominator = value }
            }
            segments.append(try .init(startTick: .init(tick), bpm: bpm, beatsPerBar: numerator, beatUnit: denominator))
        }
        return MusicMIDIFileImport(tempoMap: try MusicTempoMap(ticksPerQuarter: ppq, sampleRate: sampleRate, segments: segments),
                                   tracks: tracks, originalOnlyEventCount: originalOnly, sourceFormat: format)
    }

    public static func write(_ document: MusicDocument) throws -> Data {
        try document.validate()
        struct Event { let tick: Int64; let order: Int; let bytes: [UInt8] }
        func chunk(_ events: [Event], endTick: Int64) throws -> Data {
            guard events.count <= maximumEvents else { throw invalid("SMF event limit") }
            let sorted = events.enumerated().sorted { a, b in (a.element.tick, a.element.order, a.offset) < (b.element.tick, b.element.order, b.offset) }.map(\.element)
            var result = Data(); var previous: Int64 = 0
            for event in sorted {
                guard event.tick >= previous else { throw invalid("SMF negative event time") }
                result.append(contentsOf: try variable(event.tick - previous)); result.append(contentsOf: event.bytes); previous = event.tick
                guard result.count <= maximumBytes else { throw invalid("SMF size limit") }
            }
            result.append(contentsOf: try variable(max(previous, endTick) - previous)); result.append(contentsOf: [0xFF, 0x2F, 0])
            var chunk = Data("MTrk".utf8); chunk.append(contentsOf: integer(result.count, bytes: 4)); chunk.append(result); return chunk
        }
        var conductor: [Event] = []
        for segment in document.tempoMap.segments {
            let microseconds = Int((60_000_000 / segment.bpm).rounded())
            let power = [1, 2, 4, 8, 16].firstIndex(of: segment.beatUnit) ?? 2
            conductor.append(Event(tick: segment.startTick.value, order: 0, bytes: [0xFF, 0x51, 3] + integer(microseconds, bytes: 3)))
            conductor.append(Event(tick: segment.startTick.value, order: 1, bytes: [0xFF, 0x58, 4, UInt8(segment.beatsPerBar), UInt8(power), 24, 8]))
        }
        let midiTracks = document.tracks.filter { $0.kind == .midi }
        guard !midiTracks.isEmpty, midiTracks.count < 65_535 else { throw invalid("no MIDI tracks") }
        var output = Data("MThd".utf8)
        output.append(contentsOf: integer(6, bytes: 4) + integer(1, bytes: 2) + integer(midiTracks.count + 1, bytes: 2) + integer(document.tempoMap.ticksPerQuarter, bytes: 2))
        output.append(try chunk(conductor, endTick: conductor.last?.tick ?? 0))
        for track in midiTracks {
            try Task.checkCancellation()
            let name = Array(track.name.utf8)
            var events = [Event(tick: 0, order: 0, bytes: [0xFF, 0x03] + (try variable(Int64(name.count))) + name)]
            var end: Int64 = 0
            for clip in track.clips {
                guard case .midi(let payload) = clip.body else { continue }
                let offset = try document.tempoMap.tick(atSample: clip.offset).value
                func absolute(_ tick: Int64) throws -> Int64 {
                    let (value, overflow) = offset.addingReportingOverflow(tick)
                    guard !overflow else { throw invalid("SMF tick overflow") }; return value
                }
                end = max(end, try absolute(payload.durationTicks))
                for program in payload.programChanges { events.append(Event(tick: try absolute(program.tick.value), order: 1, bytes: [0xC0 | UInt8(program.channel), UInt8(program.program)])) }
                for point in payload.controllerPoints {
                    let bytes: [UInt8] = point.controller == 128 ? [0xE0 | UInt8(point.channel), UInt8(point.value & 127), UInt8(point.value >> 7)] : [0xB0 | UInt8(point.channel), UInt8(point.controller), UInt8(point.value)]
                    events.append(Event(tick: try absolute(point.tick.value), order: 2, bytes: bytes))
                }
                for note in payload.notes {
                    events.append(Event(tick: try absolute(note.startTick.value), order: 4, bytes: [0x90 | UInt8(note.channel), UInt8(note.pitch), UInt8(note.velocity)]))
                    events.append(Event(tick: try absolute(note.startTick.value + note.durationTicks), order: 3, bytes: [0x80 | UInt8(note.channel), UInt8(note.pitch), 0]))
                }
            }
            output.append(try chunk(events, endTick: end))
            guard output.count <= maximumBytes else { throw invalid("SMF size limit") }
        }
        return output
    }

    private static func invalid(_ detail: String) -> MusicError { .invalidMIDI(reason: detail) }
    private static func integer(_ value: Int, bytes: Int) -> [UInt8] { (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private static func variable(_ value: Int64) throws -> [UInt8] {
        guard (0...0x0FFF_FFFF).contains(value) else { throw invalid("SMF delta exceeds 28-bit range") }
        var input = value; var bytes = [UInt8(input & 0x7F)]; input >>= 7
        while input > 0 { bytes.insert(UInt8(input & 0x7F) | 0x80, at: 0); input >>= 7 }; return bytes
    }
    private struct Cursor {
        let data: [UInt8]; var index = 0
        init(_ data: Data) { self.data = Array(data) }
        var remaining: Int { data.count - index }
        mutating func byte() throws -> UInt8 { guard index < data.count else { throw invalid("truncated SMF") }; defer { index += 1 }; return data[index] }
        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= remaining else { throw invalid("truncated SMF chunk") }
            defer { index += count }; return Array(data[index..<(index + count)])
        }
        mutating func integer(_ count: Int) throws -> Int { try bytes(count).reduce(0) { ($0 << 8) | Int($1) } }
        mutating func variable() throws -> Int64 {
            var result: Int64 = 0
            for _ in 0..<4 { let value = try byte(); result = (result << 7) | Int64(value & 0x7F); if value & 0x80 == 0 { return result } }
            throw invalid("SMF variable-length quantity")
        }
    }
}
