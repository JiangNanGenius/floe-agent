// SPDX-License-Identifier: MPL-2.0
import Foundation

enum MediaAudioProcessingCoding {
    private struct Field: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func requireFields(_ decoder: any Decoder, _ allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy:Field.self)
        if let field = values.allKeys.first(where:{ !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath+[field],debugDescription:"Unknown audio processing field"))
        }
    }
}

public struct PreparedVideoLimiter: Sendable, Codable, Hashable {
    public var ceilingDB: Double
    public var attackTime: Double
    public var decayTime: Double
    public init(ceilingDB: Double = -1, attackTime: Double = 0.001, decayTime: Double = 0.05) {
        self.ceilingDB = ceilingDB; self.attackTime = attackTime; self.decayTime = decayTime
    }
    private enum CodingKeys: String, CodingKey { case ceilingDB, attackTime, decayTime }
    public init(from decoder: any Decoder) throws {
        try MediaAudioProcessingCoding.requireFields(decoder,["ceilingDB","attackTime","decayTime"])
        let values = try decoder.container(keyedBy:CodingKeys.self)
        ceilingDB = try values.decodeIfPresent(Double.self,forKey:.ceilingDB) ?? -1
        attackTime = try values.decodeIfPresent(Double.self,forKey:.attackTime) ?? 0.001
        decayTime = try values.decodeIfPresent(Double.self,forKey:.decayTime) ?? 0.05
    }
    public func validate() throws {
        guard ceilingDB.isFinite,(-24...0).contains(ceilingDB),attackTime.isFinite,(0.001...0.03).contains(attackTime),
              decayTime.isFinite,(0.001...0.06).contains(decayTime) else {
            throw MediaPreparedCoreError.invalidOperation("limiter settings are outside their supported range")
        }
    }
}

public struct MediaAudioProcessing: Sendable, Codable, Hashable {
    public var eqBands: [PreparedVideoEQBand]
    public var dynamics: PreparedVideoDynamics?
    public var limiter: PreparedVideoLimiter?
    public init(eqBands: [PreparedVideoEQBand] = [], dynamics: PreparedVideoDynamics? = nil, limiter: PreparedVideoLimiter? = nil) {
        self.eqBands = eqBands; self.dynamics = dynamics; self.limiter = limiter
    }
    private enum CodingKeys: String, CodingKey { case eqBands, dynamics, limiter }
    public init(from decoder: any Decoder) throws {
        try MediaAudioProcessingCoding.requireFields(decoder,["eqBands","dynamics","limiter"])
        let value = try decoder.container(keyedBy:CodingKeys.self)
        eqBands = try value.decodeIfPresent([PreparedVideoEQBand].self,forKey:.eqBands) ?? []
        dynamics = try value.decodeIfPresent(PreparedVideoDynamics.self,forKey:.dynamics)
        limiter = try value.decodeIfPresent(PreparedVideoLimiter.self,forKey:.limiter)
    }
    public var isEmpty: Bool { eqBands.isEmpty && dynamics == nil && limiter == nil }
    public func validate() throws {
        guard eqBands.count <= 8 else { throw MediaPreparedCoreError.limitsExceeded("audio EQ has at most 8 bands") }
        for band in eqBands {
            guard band.frequency.isFinite,(20...20_000).contains(band.frequency),band.gain.isFinite,(-24...24).contains(band.gain),
                  band.bandwidth.isFinite,(0.05...5).contains(band.bandwidth) else {
                throw MediaPreparedCoreError.invalidOperation("EQ band is outside its supported range")
            }
        }
        if let d = dynamics {
            guard d.threshold.isFinite,(-40...0).contains(d.threshold),d.headRoom.isFinite,(0.1...40).contains(d.headRoom),
                  d.expansionRatio.isFinite,(1...20).contains(d.expansionRatio),d.attackTime.isFinite,(0.000_1...0.2).contains(d.attackTime),
                  d.releaseTime.isFinite,(0.01...3).contains(d.releaseTime),d.masterGain.isFinite,(-24...24).contains(d.masterGain) else {
                throw MediaPreparedCoreError.invalidOperation("compressor settings are outside their supported range")
            }
        }
        try limiter?.validate()
    }
}
