import Foundation

/// DJ performance session state. Independent from the arrangement document:
/// it references the same immutable, versioned `MusicAsset` records and can
/// be saved/loaded beside a project, but never mutates arrangement clips.
///
/// This is pure state + deterministic math for a future runtime to consume.
/// Nothing here produces audio, runs timers or claims audible output.
public struct MusicDJSession: Sendable, Codable, Hashable, Identifiable {
    public static let minRate: Double = 0.25
    public static let maxRate: Double = 4.0
    public static let maxHotcuesPerDeck = 8
    public static let maxLoopBeats = 32

    public enum DeckSlot: String, Sendable, Codable, Hashable {
        case a, b
    }

    /// Which deck feeds the single cue (pre-fader listen) bus.
    public enum CueSource: String, Sendable, Codable, Hashable {
        case deckA, deckB, none
    }

    /// Beat grid anchored to a deck's asset.
    public struct BeatGrid: Sendable, Codable, Hashable {
        public var bpm: Double
        /// Sample position of the first beat within the asset.
        public var firstBeatSample: Int64
        public var beatCount: Int

        public init(bpm: Double, firstBeatSample: Int64, beatCount: Int) throws {
            guard bpm.isFinite, bpm >= 20, bpm <= 999 else {
                throw MusicError.invalidDJ(reason: "bpm \(bpm) outside [20, 999]")
            }
            guard firstBeatSample >= 0 else {
                throw MusicError.invalidDJ(reason: "negative firstBeatSample")
            }
            guard beatCount >= 1, beatCount <= 100_000 else {
                throw MusicError.invalidDJ(reason: "beatCount \(beatCount) outside [1, 100000]")
            }
            self.bpm = bpm
            self.firstBeatSample = firstBeatSample
            self.beatCount = beatCount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let bpm = try c.decode(Double.self, forKey: .bpm)
            let first = try c.decode(Int64.self, forKey: .firstBeatSample)
            let count = try c.decode(Int.self, forKey: .beatCount)
            do {
                try self.init(bpm: bpm, firstBeatSample: first, beatCount: count)
            } catch let error as MusicError {
                throw DecodingError.dataCorruptedError(forKey: .bpm, in: c,
                                                       debugDescription: error.description)
            }
        }

        /// Sample length of one beat at playback rate 1.
        public func beatLengthSamples(sampleRate: Int) -> Double {
            60.0 * Double(sampleRate) / bpm
        }
    }

    public struct CuePoint: Sendable, Codable, Hashable {
        public var sample: Int64
        public var label: String
        public init(sample: Int64, label: String = "") throws {
            guard sample >= 0 else {
                throw MusicError.invalidDJ(reason: "negative cue sample")
            }
            self.sample = sample
            self.label = label
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let sample = try c.decode(Int64.self, forKey: .sample)
            let label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            do { try self.init(sample: sample, label: label) }
            catch let error as MusicError {
                throw DecodingError.dataCorruptedError(forKey: .sample, in: c,
                                                       debugDescription: error.description)
            }
        }
    }

    public struct Hotcue: Sendable, Codable, Hashable, Identifiable {
        public var index: Int
        public var sample: Int64
        public var label: String
        public var id: Int { index }
        public init(index: Int, sample: Int64, label: String = "") throws {
            guard index >= 0, index < MusicDJSession.maxHotcuesPerDeck else {
                throw MusicError.invalidDJ(reason: "hotcue index \(index) outside [0, \(MusicDJSession.maxHotcuesPerDeck))")
            }
            guard sample >= 0 else {
                throw MusicError.invalidDJ(reason: "negative hotcue sample")
            }
            self.index = index
            self.sample = sample
            self.label = label
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let index = try c.decode(Int.self, forKey: .index)
            let sample = try c.decode(Int64.self, forKey: .sample)
            let label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            do { try self.init(index: index, sample: sample, label: label) }
            catch let error as MusicError {
                throw DecodingError.dataCorruptedError(forKey: .index, in: c,
                                                       debugDescription: error.description)
            }
        }
    }

    public struct BeatLoop: Sendable, Codable, Hashable {
        /// First looped beat index (0-based, within the beat grid).
        public var startBeat: Int
        /// Loop length in beats, 1...`maxLoopBeats`.
        public var lengthBeats: Int
        public init(startBeat: Int, lengthBeats: Int) throws {
            guard startBeat >= 0 else {
                throw MusicError.invalidDJ(reason: "negative loop startBeat")
            }
            guard lengthBeats >= 1, lengthBeats <= MusicDJSession.maxLoopBeats else {
                throw MusicError.invalidDJ(reason: "loop length \(lengthBeats) outside [1, \(MusicDJSession.maxLoopBeats)]")
            }
            self.startBeat = startBeat
            self.lengthBeats = lengthBeats
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let start = try c.decode(Int.self, forKey: .startBeat)
            let length = try c.decode(Int.self, forKey: .lengthBeats)
            do { try self.init(startBeat: start, lengthBeats: length) }
            catch let error as MusicError {
                throw DecodingError.dataCorruptedError(forKey: .lengthBeats, in: c,
                                                       debugDescription: error.description)
            }
        }
    }

    public struct Deck: Sendable, Codable, Hashable {
        /// Immutable versioned asset loaded on this deck, if any.
        public var assetID: MusicAssetID?
        /// Source identity bound at load time: content hash and source
        /// revision of the asset above. Cues/hotcues/loops are only valid for
        /// this exact source; validation rejects decks whose cached identity
        /// no longer matches the staged asset.
        public var assetContentHash: String?
        public var assetSourceRevision: Int64?
        /// Cached asset duration for bound checks; 0 when no asset is loaded.
        public var assetDurationSamples: Int64
        public var playheadSamples: Int64
        /// Playback rate multiplier; finite and clamped to [minRate, maxRate].
        public var rate: Double
        public var keyLocked: Bool
        public var beatGrid: BeatGrid?
        public var cue: CuePoint?
        public var hotcues: [Hotcue]
        public var activeLoop: BeatLoop?
        /// Runtime playback flag. Ephemeral: not persisted, always restored
        /// stopped, owned by the future transport/runtime.
        public var playing: Bool

        private enum CodingKeys: String, CodingKey {
            case assetID, assetContentHash, assetSourceRevision
            case assetDurationSamples, playheadSamples, rate, keyLocked
            case beatGrid, cue, hotcues, activeLoop
        }

        public init(assetID: MusicAssetID? = nil, assetContentHash: String? = nil,
                    assetSourceRevision: Int64? = nil, assetDurationSamples: Int64 = 0,
                    playheadSamples: Int64 = 0, rate: Double = 1, keyLocked: Bool = false,
                    beatGrid: BeatGrid? = nil, cue: CuePoint? = nil,
                    hotcues: [Hotcue] = [], activeLoop: BeatLoop? = nil,
                    playing: Bool = false) throws {
            guard assetDurationSamples >= 0, playheadSamples >= 0 else {
                throw MusicError.invalidDJ(reason: "negative duration or playhead")
            }
            guard rate.isFinite else {
                throw MusicError.invalidDJ(reason: "non-finite rate")
            }
            if let hash = assetContentHash {
                guard hash.count == MusicAsset.contentHashLength,
                      hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                    throw MusicError.invalidDJ(reason: "assetContentHash must be 64 lowercase hex characters")
                }
            }
            if let revision = assetSourceRevision {
                guard revision >= 0 else {
                    throw MusicError.invalidDJ(reason: "negative assetSourceRevision")
                }
            }
            self.assetID = assetID
            self.assetContentHash = assetContentHash
            self.assetSourceRevision = assetSourceRevision
            self.assetDurationSamples = assetDurationSamples
            self.playheadSamples = playheadSamples
            self.rate = min(max(rate, MusicDJSession.minRate), MusicDJSession.maxRate)
            self.keyLocked = keyLocked
            self.beatGrid = beatGrid
            self.cue = cue
            self.hotcues = hotcues
            self.activeLoop = activeLoop
            self.playing = playing
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let assetID = try c.decodeIfPresent(MusicAssetID.self, forKey: .assetID)
            let hash = try c.decodeIfPresent(String.self, forKey: .assetContentHash)
            let revision = try c.decodeIfPresent(Int64.self, forKey: .assetSourceRevision)
            let duration = try c.decodeIfPresent(Int64.self, forKey: .assetDurationSamples) ?? 0
            let playhead = try c.decodeIfPresent(Int64.self, forKey: .playheadSamples) ?? 0
            let rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
            let keyLocked = try c.decodeIfPresent(Bool.self, forKey: .keyLocked) ?? false
            let grid = try c.decodeIfPresent(BeatGrid.self, forKey: .beatGrid)
            let cue = try c.decodeIfPresent(CuePoint.self, forKey: .cue)
            let hotcues = try c.decodeIfPresent([Hotcue].self, forKey: .hotcues) ?? []
            let loop = try c.decodeIfPresent(BeatLoop.self, forKey: .activeLoop)
            do {
                // `playing` is intentionally not decoded: restored decks are
                // always stopped.
                try self.init(assetID: assetID, assetContentHash: hash,
                              assetSourceRevision: revision,
                              assetDurationSamples: duration,
                              playheadSamples: playhead, rate: rate, keyLocked: keyLocked,
                              beatGrid: grid, cue: cue, hotcues: hotcues,
                              activeLoop: loop, playing: false)
            } catch let error as MusicError {
                throw DecodingError.dataCorruptedError(forKey: .rate, in: c,
                                                       debugDescription: error.description)
            }
        }

        /// Clamp an arbitrary sample position into the loaded asset bounds.
        public func clampedSample(_ sample: Int64) -> Int64 {
            max(0, min(sample, assetDurationSamples))
        }

        /// Revalidate deck state against public mutation (used by session ops).
        func revalidated() throws -> Deck {
            var deck = try Deck(assetID: assetID, assetContentHash: assetContentHash,
                                assetSourceRevision: assetSourceRevision,
                                assetDurationSamples: assetDurationSamples,
                                playheadSamples: playheadSamples, rate: rate, keyLocked: keyLocked,
                                beatGrid: beatGrid, cue: cue, hotcues: hotcues,
                                activeLoop: activeLoop, playing: playing)
            deck.playheadSamples = clampedSample(deck.playheadSamples)
            if let grid = deck.beatGrid {
                _ = try BeatGrid(bpm: grid.bpm, firstBeatSample: grid.firstBeatSample,
                                 beatCount: grid.beatCount)
            }
            if let loop = deck.activeLoop {
                _ = try BeatLoop(startBeat: loop.startBeat, lengthBeats: loop.lengthBeats)
            }
            return deck
        }
    }

    public var id: MusicDJSessionID
    /// Immutable versioned assets this session may reference.
    public private(set) var assets: [MusicAsset]
    public var deckA: Deck
    public var deckB: Deck
    /// Crossfader position 0 (deck A) ... 1 (deck B).
    public private(set) var crossfader: Double
    public var cueSource: CueSource
    public var cueGain: Double
    public var masterGain: Double
    /// True while SYNC links deck B as tempo/phase slave to deck A.
    public var syncEnabled: Bool
    public var sampleRate: Int

    public init(id: MusicDJSessionID = MusicDJSessionID(), assets: [MusicAsset] = [],
                deckA: Deck = try! Deck(), deckB: Deck = try! Deck(),
                crossfader: Double = 0.5, cueSource: CueSource = .none,
                cueGain: Double = 1, masterGain: Double = 1,
                syncEnabled: Bool = false, sampleRate: Int = 48_000) throws {
        guard crossfader.isFinite else {
            throw MusicError.invalidDJ(reason: "non-finite crossfader")
        }
        guard cueGain.isFinite, cueGain >= 0, cueGain <= 4 else {
            throw MusicError.invalidDJ(reason: "cueGain \(cueGain) outside [0, 4]")
        }
        guard masterGain.isFinite, masterGain >= 0, masterGain <= 4 else {
            throw MusicError.invalidDJ(reason: "masterGain \(masterGain) outside [0, 4]")
        }
        guard sampleRate >= MusicTempoMap.minSampleRate, sampleRate <= MusicTempoMap.maxSampleRate else {
            throw MusicError.invalidDJ(reason: "sampleRate \(sampleRate) outside supported range")
        }
        self.id = id
        self.assets = assets
        self.deckA = deckA
        self.deckB = deckB
        self.crossfader = min(max(crossfader, 0), 1)
        self.cueSource = cueSource
        self.cueGain = cueGain
        self.masterGain = masterGain
        self.syncEnabled = syncEnabled
        self.sampleRate = sampleRate
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(MusicDJSessionID.self, forKey: .id)
        let assets = try c.decodeIfPresent([MusicAsset].self, forKey: .assets) ?? []
        let deckA = try c.decodeIfPresent(Deck.self, forKey: .deckA) ?? (try! Deck())
        let deckB = try c.decodeIfPresent(Deck.self, forKey: .deckB) ?? (try! Deck())
        let crossfader = try c.decodeIfPresent(Double.self, forKey: .crossfader) ?? 0.5
        let cueSource = try c.decodeIfPresent(CueSource.self, forKey: .cueSource) ?? .none
        let cueGain = try c.decodeIfPresent(Double.self, forKey: .cueGain) ?? 1
        let masterGain = try c.decodeIfPresent(Double.self, forKey: .masterGain) ?? 1
        let sync = try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        let rate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48_000
        do {
            try self.init(id: id, assets: assets, deckA: deckA, deckB: deckB,
                          crossfader: crossfader, cueSource: cueSource, cueGain: cueGain,
                          masterGain: masterGain, syncEnabled: sync, sampleRate: rate)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .crossfader, in: c,
                                                   debugDescription: error.description)
        }
    }

    /// Cross-field validation: deck assets must come from `assets`, loops
    /// must sit inside their beat grid and inside the asset duration.
    public func validate() throws {
        guard cueGain.isFinite, (0...4).contains(cueGain), masterGain.isFinite, (0...4).contains(masterGain),
              (MusicTempoMap.minSampleRate...MusicTempoMap.maxSampleRate).contains(sampleRate) else {
            throw MusicError.invalidDJ(reason: "invalid session gain or sample rate")
        }
        var seen = Set<MusicAssetID>()
        for asset in assets {
            guard seen.insert(asset.id).inserted else {
                throw MusicError.invalidDJ(reason: "duplicate asset \(asset.id)")
            }
            _ = try MusicAsset(id: asset.id, sourceLocator: asset.sourceLocator,
                               contentHashAlgorithm: asset.contentHashAlgorithm,
                               contentHash: asset.contentHash,
                               sourceRevision: asset.sourceRevision, kind: asset.kind,
                               durationSamples: asset.durationSamples, name: asset.name,
                               provenance: asset.provenance)
        }
        for deck in [deckA, deckB] {
            let d = try deck.revalidated()
            guard deck.rate >= Self.minRate, deck.rate <= Self.maxRate,
                  deck.playheadSamples <= deck.assetDurationSamples else { throw MusicError.invalidDJ(reason: "invalid deck position or rate") }
            if let assetID = d.assetID {
                guard let asset = assets.first(where: { $0.id == assetID }) else {
                    throw MusicError.invalidDJ(reason: "deck references unknown asset \(assetID)")
                }
                // Source identity must match exactly; replaced content can
                // never reuse this deck's cues/hotcues/loop.
                guard d.assetContentHash == asset.contentHash,
                      d.assetSourceRevision == asset.sourceRevision else {
                    throw MusicError.invalidDJ(
                        reason: "deck source identity no longer matches asset \(assetID)")
                }
                if asset.durationSamples.value > 0, d.assetDurationSamples != asset.durationSamples.value {
                    throw MusicError.invalidDJ(reason: "deck duration does not match asset \(assetID)")
                }
            } else if d.assetDurationSamples != 0 || d.playheadSamples != 0 || d.cue != nil || !d.hotcues.isEmpty || d.beatGrid != nil || d.activeLoop != nil || d.playing {
                throw MusicError.invalidDJ(reason: "unloaded deck contains source-bound state")
            }
            if let cue = d.cue {
                guard cue.sample >= 0, cue.sample <= d.assetDurationSamples else { throw MusicError.invalidDJ(reason: "cue exceeds source") }
            }
            var hotcueIndices = Set<Int>()
            for cue in d.hotcues {
                _ = try Hotcue(index: cue.index, sample: cue.sample, label: cue.label)
                guard cue.sample <= d.assetDurationSamples, hotcueIndices.insert(cue.index).inserted else { throw MusicError.invalidDJ(reason: "invalid source-bound hotcue") }
            }
            if let grid = d.beatGrid, let loop = d.activeLoop {
                let (lastBeat, overflow) = loop.startBeat.addingReportingOverflow(loop.lengthBeats)
                guard !overflow, lastBeat <= grid.beatCount else {
                    throw MusicError.invalidDJ(reason: "loop exceeds beat grid")
                }
                let end = Double(grid.firstBeatSample) + Double(lastBeat) * grid.beatLengthSamples(sampleRate: sampleRate)
                guard end.isFinite, end <= Double(d.assetDurationSamples) else { throw MusicError.invalidDJ(reason: "loop exceeds source duration") }
            } else if d.activeLoop != nil {
                throw MusicError.invalidDJ(reason: "loop requires beat grid")
            }
        }
        guard crossfader.isFinite, crossfader >= 0, crossfader <= 1 else {
            throw MusicError.invalidDJ(reason: "crossfader \(crossfader) outside [0, 1]")
        }
    }

    // MARK: - Deck operations (state only; a runtime consumes the results)

    public mutating func loadDeck(_ slot: DeckSlot, asset: MusicAsset) throws {
        guard assets.contains(where: { $0.id == asset.id }) else {
            throw MusicError.invalidDJ(reason: "asset \(asset.id) is not staged in this session")
        }
        guard asset.kind != .midiFile else {
            throw MusicError.invalidDJ(reason: "MIDI assets cannot load on a DJ deck")
        }
        // Bind the deck to the immutable source identity so cues/hotcues can
        // never be silently reused for replaced content.
        let deck = try Deck(assetID: asset.id,
                            assetContentHash: asset.contentHash,
                            assetSourceRevision: asset.sourceRevision,
                            assetDurationSamples: asset.durationSamples.value)
        try setDeck(slot, deck)
    }

    public mutating func ejectDeck(_ slot: DeckSlot) throws {
        try setDeck(slot, try Deck())
    }

    public mutating func seek(_ slot: DeckSlot, sample: Int64) throws {
        guard sample >= 0 else {
            throw MusicError.invalidDJ(reason: "negative seek position")
        }
        var deck = try deckFor(slot).revalidated()
        deck.playheadSamples = deck.clampedSample(sample)
        try setDeck(slot, deck)
    }

    /// Set playback rate. Non-finite values throw; finite values outside
    /// [minRate, maxRate] clamp to the nearest bound.
    public mutating func setRate(_ slot: DeckSlot, rate: Double) throws {
        guard rate.isFinite else {
            throw MusicError.invalidDJ(reason: "non-finite rate")
        }
        var deck = try deckFor(slot).revalidated()
        deck.rate = min(max(rate, Self.minRate), Self.maxRate)
        try setDeck(slot, deck)
    }

    public mutating func setKeyLocked(_ slot: DeckSlot, _ locked: Bool) throws {
        var deck = try deckFor(slot).revalidated()
        deck.keyLocked = locked
        try setDeck(slot, deck)
    }

    public mutating func setPlaying(_ slot: DeckSlot, _ playing: Bool) throws {
        var deck = try deckFor(slot).revalidated()
        deck.playing = playing
        try setDeck(slot, deck)
    }

    public mutating func setBeatGrid(_ slot: DeckSlot, bpm: Double,
                                     firstBeatSample: Int64, beatCount: Int) throws {
        var deck = try deckFor(slot).revalidated()
        deck.beatGrid = try BeatGrid(bpm: bpm, firstBeatSample: firstBeatSample, beatCount: beatCount)
        try setDeck(slot, deck)
    }

    public mutating func setCue(_ slot: DeckSlot, sample: Int64, label: String = "") throws {
        guard sample >= 0 else {
            throw MusicError.invalidDJ(reason: "negative cue sample")
        }
        var deck = try deckFor(slot).revalidated()
        guard deck.assetID != nil else { throw MusicError.invalidDJ(reason: "cue requires a loaded asset") }
        deck.cue = try CuePoint(sample: deck.clampedSample(sample), label: label)
        try setDeck(slot, deck)
    }

    public mutating func jumpToCue(_ slot: DeckSlot) throws {
        var deck = try deckFor(slot).revalidated()
        guard let cue = deck.cue else {
            throw MusicError.invalidDJ(reason: "no cue set")
        }
        deck.playheadSamples = deck.clampedSample(cue.sample)
        try setDeck(slot, deck)
    }

    public mutating func setHotcue(_ slot: DeckSlot, index: Int, sample: Int64,
                                   label: String = "") throws {
        guard sample >= 0 else {
            throw MusicError.invalidDJ(reason: "negative hotcue sample")
        }
        var deck = try deckFor(slot).revalidated()
        let hotcue = try Hotcue(index: index, sample: deck.clampedSample(sample), label: label)
        deck.hotcues.removeAll { $0.index == index }
        deck.hotcues.append(hotcue)
        deck.hotcues.sort { $0.index < $1.index }
        try setDeck(slot, deck)
    }

    public mutating func jumpToHotcue(_ slot: DeckSlot, index: Int) throws {
        guard index >= 0, index < Self.maxHotcuesPerDeck else {
            throw MusicError.invalidDJ(reason: "hotcue index \(index) out of range")
        }
        var deck = try deckFor(slot).revalidated()
        guard let hotcue = deck.hotcues.first(where: { $0.index == index }) else {
            throw MusicError.invalidDJ(reason: "hotcue \(index) is empty")
        }
        deck.playheadSamples = deck.clampedSample(hotcue.sample)
        try setDeck(slot, deck)
    }

    /// Engage a beat loop. The loop must fit inside the beat grid and the
    /// loaded asset; otherwise the op throws and state is unchanged.
    public mutating func setLoop(_ slot: DeckSlot, startBeat: Int, lengthBeats: Int) throws {
        var deck = try deckFor(slot).revalidated()
        guard let grid = deck.beatGrid else {
            throw MusicError.invalidDJ(reason: "no beat grid on deck")
        }
        let loop = try BeatLoop(startBeat: startBeat, lengthBeats: lengthBeats)
        let (lastBeat, overflow) = loop.startBeat.addingReportingOverflow(loop.lengthBeats)
        guard !overflow, lastBeat <= grid.beatCount else {
            throw MusicError.invalidDJ(reason: "loop exceeds beat grid of \(grid.beatCount) beats")
        }
        let end = (Double(grid.firstBeatSample)
            + Double(lastBeat) * grid.beatLengthSamples(sampleRate: sampleRate)).rounded(.toNearestOrAwayFromZero)
        guard end.isFinite, end >= 0, end < Double(Int64.max) else {
            throw MusicError.invalidDJ(reason: "loop sample position overflow")
        }
        let loopEndSample = Int64(end)
        guard deck.assetDurationSamples == 0 || loopEndSample <= deck.assetDurationSamples else {
            throw MusicError.invalidDJ(reason: "loop exceeds asset duration")
        }
        deck.activeLoop = loop
        try setDeck(slot, deck)
    }

    public mutating func exitLoop(_ slot: DeckSlot) throws {
        var deck = try deckFor(slot).revalidated()
        deck.activeLoop = nil
        try setDeck(slot, deck)
    }

    // MARK: - Sync

    /// Tempo + phase sync of the slave deck to the master deck.
    ///
    /// Tempo: slave rate is set so the slave's effective BPM equals the
    /// master's (master rate preserved). Phase: the slave playhead is shifted
    /// by the fractional-beat difference so both decks' downbeats align.
    /// All mutations are validated and atomic; on error the session is
    /// unchanged.
    public mutating func syncDeck(_ slave: DeckSlot, to master: DeckSlot) throws {
        let masterDeck = try deckFor(master).revalidated()
        var slaveDeck = try deckFor(slave).revalidated()
        guard let masterGrid = masterDeck.beatGrid, let slaveGrid = slaveDeck.beatGrid else {
            throw MusicError.invalidDJ(reason: "sync requires beat grids on both decks")
        }
        // Tempo: effective bpm = bpm * rate. Solve slave rate.
        let targetSlaveRate = masterDeck.rate * (masterGrid.bpm / slaveGrid.bpm)
        guard targetSlaveRate.isFinite, targetSlaveRate >= Self.minRate, targetSlaveRate <= Self.maxRate else {
            throw MusicError.invalidDJ(reason: "sync target is outside supported playback rates")
        }
        slaveDeck.rate = min(max(targetSlaveRate, Self.minRate), Self.maxRate)

        // Phase: fractional beat position of each deck relative to its grid.
        let masterBeatLength = masterGrid.beatLengthSamples(sampleRate: sampleRate)
        let slaveBeatLength = slaveGrid.beatLengthSamples(sampleRate: sampleRate)
        let masterPhase = phase(of: masterDeck, beatLength: masterBeatLength, grid: masterGrid)
        let slavePhase = phase(of: slaveDeck, beatLength: slaveBeatLength, grid: slaveGrid)
        var phaseError = masterPhase - slavePhase
        if phaseError > 0.5 { phaseError -= 1 }
        if phaseError <= -0.5 { phaseError += 1 }
        let shift = Int64((phaseError * slaveBeatLength).rounded(.toNearestOrAwayFromZero))
        let (shifted, overflow) = slaveDeck.playheadSamples.addingReportingOverflow(shift)
        if overflow {
            throw MusicError.invalidSampleTime(reason: "sync playhead overflow")
        }
        slaveDeck.playheadSamples = slaveDeck.clampedSample(shifted)
        guard slave != master else { throw MusicError.invalidDJ(reason: "sync requires two decks") }
        try setDeck(slave, slaveDeck)
    }

    private func phase(of deck: Deck, beatLength: Double, grid: BeatGrid) -> Double {
        guard beatLength > 0 else { return 0 }
        let position = Double(deck.playheadSamples - grid.firstBeatSample)
        let beats = position / beatLength
        let phase = beats - beats.rounded(.towardZero)
        return phase < 0 ? phase + 1 : phase
    }

    // MARK: - Crossfader and channel map

    /// Equal-power crossfade: gainA = cos(p·π/2), gainB = sin(p·π/2), so
    /// gainA² + gainB² = 1 across the whole travel and both full ends reach
    /// unity exactly. Finite positions outside [0, 1] clamp.
    public mutating func setCrossfader(_ position: Double) throws {
        guard position.isFinite else {
            throw MusicError.invalidDJ(reason: "non-finite crossfader")
        }
        crossfader = min(max(position, 0), 1)
        try validate()
    }

    public struct ChannelGains: Sendable, Hashable {
        /// Deck contribution to the master (post-crossfader) bus.
        public var deckAMaster: Double
        public var deckBMaster: Double
        /// Deck contribution to the single cue bus (pre-fader).
        public var deckACue: Double
        public var deckBCue: Double
        public var cueBusGain: Double
        public var masterBusGain: Double
    }

    /// Channel map for a runtime mixer. One stereo output honestly exposes a
    /// single cue bus: cueing deck A pre-fades deck B out of the cue bus and
    /// vice versa; simultaneous independent stereo cues are NOT modelled.
    public func channelGains() -> ChannelGains {
        let p = min(max(crossfader, 0), 1)
        let angle = p * Double.pi / 2
        let gainA = cos(angle) * masterGain
        let gainB = sin(angle) * masterGain
        let cueA = cueSource == .deckA ? cueGain : 0
        let cueB = cueSource == .deckB ? cueGain : 0
        return ChannelGains(deckAMaster: gainA, deckBMaster: gainB,
                            deckACue: cueA, deckBCue: cueB,
                            cueBusGain: cueGain, masterBusGain: masterGain)
    }

    public mutating func setCueSource(_ source: CueSource) throws {
        cueSource = source
        try validate()
    }

    public mutating func setCueGain(_ gain: Double) throws {
        guard gain.isFinite, gain >= 0, gain <= 4 else {
            throw MusicError.invalidDJ(reason: "cueGain \(gain) outside [0, 4]")
        }
        cueGain = gain
        try validate()
    }

    public mutating func setMasterGain(_ gain: Double) throws {
        guard gain.isFinite, gain >= 0, gain <= 4 else {
            throw MusicError.invalidDJ(reason: "masterGain \(gain) outside [0, 4]")
        }
        masterGain = gain
        try validate()
    }

    // MARK: - Internals

    private func deckFor(_ slot: DeckSlot) -> Deck {
        switch slot {
        case .a: return deckA
        case .b: return deckB
        }
    }

    private mutating func setDeck(_ slot: DeckSlot, _ deck: Deck) throws {
        try deck.validateDeckOnly()
        var draft = self
        switch slot {
        case .a: draft.deckA = deck
        case .b: draft.deckB = deck
        }
        try draft.validate()
        self = draft
    }
}

extension MusicDJSession.Deck {
    /// Deck-local validation (session-level cross checks live in the session).
    func validateDeckOnly() throws {
        _ = try revalidated()
    }
}
