// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Complete typed commands shared by the native deck controls and AI. No
/// command opens paths or changes the arrangement's immutable source assets.
public struct MusicDJEditCommand: Sendable, Codable, Hashable {
    public enum Action: String, Sendable, Codable, CaseIterable {
        case load, eject, seek, rate, keyLock, playing, beatGrid, cue, jumpCue
        case hotcue, jumpHotcue, clearCue, removeHotcue, loop, exitLoop, sync, crossfader, masterGain, cueSource, cueGain
    }
    public var action: Action
    public var deck: MusicDJSession.DeckSlot?
    public var assetID: MusicAssetID?
    public var sample: Int64?
    public var value: Double?
    public var enabled: Bool?
    public var index: Int?
    public var firstBeatSample: Int64?
    public var beatCount: Int?
    public var startBeat: Int?
    public var lengthBeats: Int?
    public var otherDeck: MusicDJSession.DeckSlot?
    public var cueSource: MusicDJSession.CueSource?
    public var label: String?

    public init(action: Action, deck: MusicDJSession.DeckSlot? = nil, assetID: MusicAssetID? = nil,
                sample: Int64? = nil, value: Double? = nil, enabled: Bool? = nil, index: Int? = nil,
                firstBeatSample: Int64? = nil, beatCount: Int? = nil, startBeat: Int? = nil,
                lengthBeats: Int? = nil, otherDeck: MusicDJSession.DeckSlot? = nil,
                cueSource: MusicDJSession.CueSource? = nil, label: String? = nil) {
        self.action = action; self.deck = deck; self.assetID = assetID; self.sample = sample
        self.value = value; self.enabled = enabled; self.index = index; self.firstBeatSample = firstBeatSample
        self.beatCount = beatCount; self.startBeat = startBeat; self.lengthBeats = lengthBeats
        self.otherDeck = otherDeck; self.cueSource = cueSource
        self.label = label
    }
    public func apply(to session: inout MusicDJSession, currentAssets: [MusicAsset]) throws {
        func required<T>(_ value: T?, _ field: String) throws -> T {
            guard let value else { throw MusicError.invalidDJ(reason: "DJ '\(action.rawValue)' requires '\(field)'") }
            return value
        }
        switch action {
        case .load:
            let id = try required(assetID, "assetID")
            guard let asset = currentAssets.first(where: { $0.id == id }) else {
                throw MusicError.invalidDJ(reason: "DJ load assetID does not belong to this project")
            }
            try session.loadDeck(required(deck, "deck"), asset: asset)
        case .eject: try session.ejectDeck(required(deck, "deck"))
        case .seek: try session.seek(required(deck, "deck"), sample: required(sample, "sample"))
        case .rate: try session.setRate(required(deck, "deck"), rate: required(value, "value"))
        case .keyLock: try session.setKeyLocked(required(deck, "deck"), required(enabled, "enabled"))
        case .playing: try session.setPlaying(required(deck, "deck"), required(enabled, "enabled"))
        case .beatGrid:
            try session.setBeatGrid(required(deck, "deck"), bpm: required(value, "value"),
                firstBeatSample: required(firstBeatSample, "firstBeatSample"), beatCount: required(beatCount, "beatCount"))
        case .cue: try session.setCue(required(deck, "deck"), sample: required(sample, "sample"), label: label ?? "")
        case .jumpCue: try session.jumpToCue(required(deck, "deck"))
        case .hotcue: try session.setHotcue(required(deck, "deck"), index: required(index, "index"), sample: required(sample, "sample"), label: label ?? "")
        case .jumpHotcue: try session.jumpToHotcue(required(deck, "deck"), index: required(index, "index"))
        case .clearCue: try session.clearCue(required(deck, "deck"))
        case .removeHotcue: try session.removeHotcue(required(deck, "deck"), index: required(index, "index"))
        case .loop: try session.setLoop(required(deck, "deck"), startBeat: required(startBeat, "startBeat"), lengthBeats: required(lengthBeats, "lengthBeats"))
        case .exitLoop: try session.exitLoop(required(deck, "deck"))
        case .sync:
            let slot = try required(deck, "deck")
            try session.syncDeck(slot, to: otherDeck ?? (slot == .a ? .b : .a))
        case .crossfader: try session.setCrossfader(required(value, "value"))
        case .masterGain: try session.setMasterGain(required(value, "value"))
        case .cueSource: try session.setCueSource(required(cueSource, "cueSource"))
        case .cueGain: try session.setCueGain(required(value, "value"))
        }
    }
}

public struct MusicDJEditBatch: Sendable, Codable, Hashable {
    public let workspace: String
    public let expectedDJRevision: Int64
    public let commands: [MusicDJEditCommand]
    public init(expectedDJRevision: Int64, commands: [MusicDJEditCommand]) throws {
        guard expectedDJRevision >= 0, !commands.isEmpty, commands.count <= 100 else {
            throw MusicError.invalidDJ(reason: "DJ edits require expectedDJRevision and 1...100 commands")
        }
        workspace = "dj"; self.expectedDJRevision = expectedDJRevision; self.commands = commands
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 131_072 else { throw MusicError.invalidDJ(reason: "DJ edit JSON exceeds 128 KiB") }
        let value: Self
        do {
            var normalized = data
            if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard Set(object.keys).isSubset(of: ["workspace", "expectedDJRevision", "commands"]) else {
                    throw MusicEditJSONError(code: "unknownField", path: "$", reason: "Unexpected DJ batch field.", expected: "workspace, expectedDJRevision, commands")
                }
                let commandKeys: Set<String> = ["action", "deck", "assetID", "sample", "value", "enabled", "index", "firstBeatSample", "beatCount", "startBeat", "lengthBeats", "otherDeck", "cueSource", "label"]
                var commands = object["commands"] as? [[String: Any]] ?? []
                for (index, command) in commands.enumerated() {
                    guard Set(command.keys).isSubset(of: commandKeys) else {
                        throw MusicEditJSONError(code: "unknownField", path: "$.commands[\(index)]", reason: "Unexpected DJ command field.", expected: "the fields returned by the DJ command contract")
                    }
                    if let string = command["assetID"] as? String {
                        guard !string.isEmpty else {
                            throw MusicEditJSONError(code: "invalidAssetID", path: "$.commands[\(index)].assetID",
                                reason: "The asset ID is empty.", expected: "a current asset ID string or {rawValue:string}")
                        }
                        commands[index]["assetID"] = ["rawValue": string]
                    }
                }
                if object["commands"] is [[String: Any]] { object["commands"] = commands }
                normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            }
            value = try JSONDecoder().decode(Self.self, from: normalized)
        } catch let error as DecodingError {
            let path: [any CodingKey]
            switch error {
            case .keyNotFound(let key, let context): path = context.codingPath + [key]
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
            @unknown default: path = []
            }
            throw MusicEditJSONError(code: "invalidDJField", path: "$" + path.map { "." + $0.stringValue }.joined(),
                reason: "Missing, incorrectly typed or unsupported DJ field.", expected: "a typed DJ batch with workspace:'dj', expectedDJRevision and commands")
        }
        guard value.workspace == "dj" else { throw MusicError.invalidDJ(reason: "Use workspace:'dj' for deck edits") }
        return try Self(expectedDJRevision: value.expectedDJRevision, commands: value.commands)
    }
}

public extension MusicDJSession {
    mutating func clearCue(_ slot: DeckSlot) throws {
        var draft = self
        if slot == .a { draft.deckA.cue = nil } else { draft.deckB.cue = nil }
        try draft.validate(); self = draft
    }
    mutating func removeHotcue(_ slot: DeckSlot, index: Int) throws {
        guard (0..<Self.maxHotcuesPerDeck).contains(index) else { throw MusicError.invalidDJ(reason: "invalid hotcue index") }
        var draft = self
        if slot == .a { draft.deckA.hotcues.removeAll { $0.index == index } }
        else { draft.deckB.hotcues.removeAll { $0.index == index } }
        try draft.validate(); self = draft
    }
}

/// A versioned sidecar of the same Music project. Legacy raw DJ sessions
/// decode without losing cues; saved sessions always reopen stopped. Missing
/// source bindings remain inspectable and must be explicitly ejected/reloaded.
public struct MusicDJWorkspace: Sendable, Codable, Hashable {
    public let schemaVersion: Int
    public let projectID: MusicProjectID
    public let revision: Int64
    public let session: MusicDJSession

    public init(projectID: MusicProjectID, revision: Int64 = 0, session: MusicDJSession) throws {
        guard revision >= 0 else { throw MusicError.invalidDJ(reason: "negative DJ revision") }
        try session.validate()
        schemaVersion = 1; self.projectID = projectID; self.revision = revision; self.session = session
    }
    public static func decodeSaved(_ data: Data, projectID: MusicProjectID) throws -> Self {
        guard data.count <= 16 * 1_024 * 1_024 else { throw MusicError.invalidDJ(reason: "DJ session exceeds 16 MiB") }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["schemaVersion"] != nil {
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            guard decoded.schemaVersion == 1, decoded.projectID == projectID else {
                throw MusicError.invalidDJ(reason: "DJ session belongs to another project or unsupported format")
            }
            return try Self(projectID: decoded.projectID, revision: decoded.revision, session: decoded.session)
        }
        return try Self(projectID: projectID, session: JSONDecoder().decode(MusicDJSession.self, from: data))
    }

    public func applying(_ batch: MusicDJEditBatch, document: MusicDocument,
                         expectedMusicRevision: Int64, runtime: MusicDJSession? = nil) throws -> Self {
        guard batch.workspace == "dj", !batch.commands.isEmpty, batch.commands.count <= 100 else {
            throw MusicError.invalidDJ(reason: "Use workspace:'dj' with 1...100 commands")
        }
        return try editing(document: document, expectedMusicRevision: expectedMusicRevision,
            expectedDJRevision: batch.expectedDJRevision, runtime: runtime) { value in
                for (index, command) in batch.commands.enumerated() {
                    do { try command.apply(to: &value, currentAssets: document.assets) }
                    catch { throw MusicEditJSONError(code: "invalidDJCommand", path: "$.commands[\(index)]",
                        reason: String(describing: error), expected: "the required fields and current source IDs from the DJ contract") }
                }
            }
    }

    public func editing(document: MusicDocument, expectedMusicRevision: Int64,
                        expectedDJRevision: Int64, runtime: MusicDJSession? = nil,
                        change: (inout MusicDJSession) throws -> Void) throws -> Self {
        guard document.id == projectID else { throw MusicError.invalidDJ(reason: "DJ project ownership changed") }
        guard document.revision == expectedMusicRevision else {
            throw MusicError.staleRevision(expected: expectedMusicRevision, actual: document.revision)
        }
        guard revision == expectedDJRevision else { throw MusicError.staleRevision(expected: expectedDJRevision, actual: revision) }
        guard revision < Int64.max else { throw MusicError.invalidDJ(reason: "DJ revision overflow") }
        let old = runtime ?? session
        guard old.id == session.id else { throw MusicError.invalidDJ(reason: "DJ runtime belongs to another session") }
        // Keep missing source metadata until an explicit eject/load command has
        // repaired the deck; no automatic reset of the user's cue/loop state.
        var merged = session.assets
        for asset in document.assets {
            if let prior = merged.first(where: { $0.id == asset.id }) {
                guard prior == asset else { throw MusicError.invalidDJ(reason: "DJ source identity changed; import as a new asset") }
            } else { merged.append(asset) }
        }
        var draft = try replacing(old, assets: merged, sampleRate: document.tempoMap.sampleRate)
        try change(&draft)
        let final = try replacing(draft, assets: document.assets, sampleRate: document.tempoMap.sampleRate)
        return try Self(projectID: projectID, revision: revision + 1, session: final)
    }
    private func replacing(_ value: MusicDJSession, assets: [MusicAsset], sampleRate: Int) throws -> MusicDJSession {
        try MusicDJSession(id: value.id, assets: assets, deckA: value.deckA, deckB: value.deckB,
            crossfader: value.crossfader, cueSource: value.cueSource, cueGain: value.cueGain,
            masterGain: value.masterGain, syncEnabled: value.syncEnabled, sampleRate: sampleRate)
    }
}
