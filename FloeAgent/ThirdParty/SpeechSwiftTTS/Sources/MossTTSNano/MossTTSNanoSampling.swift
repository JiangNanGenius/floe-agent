import Foundation

/// PCG64 with NumPy-compatible SeedSequence initialization for UInt64 seeds.
struct MossTTSNanoSampler {
    private var state: UInt128 = 0
    private let increment: UInt128
    private static let multiplier = (UInt128(0x2360ed051fc65da4) << 64) | UInt128(0x4385df649fccf645)

    init(state seed: UInt64) {
        var entropy = [UInt32(truncatingIfNeeded: seed)]
        if seed >> 32 != 0 { entropy.append(UInt32(seed >> 32)) }
        var hash: UInt32 = 0x43b0d7e5
        func hashMix(_ input: UInt32) -> UInt32 {
            var value = input ^ hash
            hash = hash &* 0x931e8875
            value = value &* hash
            return value ^ (value >> 16)
        }
        func mix(_ x: UInt32, _ y: UInt32) -> UInt32 {
            let value = (0xca01f9dd &* x) &- (0x4973f715 &* y)
            return value ^ (value >> 16)
        }
        var pool = (0..<4).map { hashMix($0 < entropy.count ? entropy[$0] : 0) }
        for source in 0..<4 {
            for destination in 0..<4 where source != destination {
                pool[destination] = mix(pool[destination], hashMix(pool[source]))
            }
        }
        hash = 0x8b51f9dd
        var words: [UInt32] = []
        for index in 0..<8 {
            var value = pool[index % 4] ^ hash
            hash = hash &* 0x58f38ded
            value = value &* hash
            words.append(value ^ (value >> 16))
        }
        let values = (0..<4).map { UInt64(words[$0 * 2]) | (UInt64(words[$0 * 2 + 1]) << 32) }
        let initial = (UInt128(values[0]) << 64) | UInt128(values[1])
        increment = (((UInt128(values[2]) << 64) | UInt128(values[3])) &<< 1) | 1
        step(); state = state &+ initial; step()
    }

    private mutating func step() { state = (state &* Self.multiplier) &+ increment }

    mutating func uniform() -> Double {
        step()
        let mixed = UInt64(truncatingIfNeeded: (state >> 64) ^ state)
        let rotation = Int(state >> 122)
        let value = (mixed >> rotation) | (mixed &<< ((64 - rotation) & 63))
        return Double(value >> 11) / 9007199254740992
    }

    mutating func sample(_ logits: [Float], temperature: Double = 1,
                         topK: Int = 0, topP: Double = 1,
                         seen: Set<Int> = [], penalty: Double = 1, greedy: Bool = false) throws -> Int {
        guard !logits.isEmpty, logits.allSatisfy(\.isFinite), temperature.isFinite, temperature > 0,
              topK >= 0, topP.isFinite, topP > 0, topP <= 1, penalty.isFinite, penalty > 0,
              seen.allSatisfy({ logits.indices.contains($0) }) else {
            throw MossTTSNanoError.invalidOutput("non-finite logits or invalid sampling parameters")
        }
        var scores = logits.map(Double.init)
        for id in seen { scores[id] = scores[id] < 0 ? scores[id] * penalty : scores[id] / penalty }
        guard scores.allSatisfy(\.isFinite) else { throw MossTTSNanoError.invalidOutput("sampling score overflow") }
        var candidates = scores.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        if greedy { return candidates[0] }
        if topK > 0 { candidates = Array(candidates.prefix(topK)) }
        let scaled = candidates.map { scores[$0] / temperature }
        let maximum = scaled[0]
        let weights = scaled.map { exp($0 - maximum) }
        let total = weights.reduce(0, +)
        var count = 0, retained = 0.0
        // Keep the first candidate crossing the nucleus threshold.
        repeat { retained += weights[count]; count += 1 } while count < weights.count && retained / total < topP
        let target = uniform() * retained
        var cumulative = 0.0
        for index in 0..<count {
            cumulative += weights[index]
            if target < cumulative { return candidates[index] }
        }
        return candidates[count - 1]
    }
}
