// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Acoustic identity is confined to one original recording. Provider label
/// numbers and identities belonging to another recording are never inputs.
public struct RecordingSpeakerIdentity: Sendable, Codable {
    public let meeting: MeetingID
    public let original: CaptureSessionID
    private struct Track: Sendable, Codable {
        let id: UUID
        var centroid: [Float]
        var weight: Double
    }
    private var tracks: [Track] = []

    public init(meeting: MeetingID, original: CaptureSessionID) {
        self.meeting = meeting; self.original = original
    }

    /// Conservative, one-to-one matching of actual model embeddings. Gray
    /// area/ambiguous matches remain unknown; they are not called speaker 1.
    public mutating func resolve(centroids: [Int: [Float]], speechSeconds: [Int: Double]) -> [Int: UUID] {
        var result: [Int: UUID] = [:], used: Set<UUID> = []
        for label in centroids.keys.sorted() {
            guard let vector = Self.normalized(centroids[label] ?? []),
                  let seconds = speechSeconds[label], seconds.isFinite, seconds >= 0.8 else { continue }
            let candidates = tracks.indices.compactMap { index -> (Int, Double)? in
                guard tracks[index].centroid.count == vector.count else { return nil }
                return (index, Self.distance(vector, tracks[index].centroid))
            }.sorted { $0.1 < $1.1 }
            if let best = candidates.first, best.1 <= 0.22 {
                let track = tracks[best.0]
                guard !used.contains(track.id), candidates.count < 2 || candidates[1].1 - best.1 >= 0.06 else { continue }
                result[label] = track.id; used.insert(track.id)
                let oldWeight = min(track.weight, 30), newWeight = min(seconds, 10)
                let mixed = zip(track.centroid, vector).map { Float((Double($0.0) * oldWeight + Double($0.1) * newWeight) / (oldWeight + newWeight)) }
                if let normalized = Self.normalized(mixed) { tracks[best.0].centroid = normalized }
                tracks[best.0].weight = min(60, oldWeight + newWeight)
            } else if candidates.first.map({ $0.1 >= 0.35 }) ?? true, tracks.count < 64 {
                let id = UUID()
                tracks.append(Track(id: id, centroid: vector, weight: min(seconds, 10)))
                result[label] = id; used.insert(id)
            }
        }
        return result
    }
    private static func normalized(_ value: [Float]) -> [Float]? {
        guard (16...4096).contains(value.count), value.allSatisfy(\.isFinite) else { return nil }
        let length = sqrt(value.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard length.isFinite, length > 0.00001 else { return nil }
        return value.map { Float(Double($0) / length) }
    }
    private static func distance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        max(0, min(2, 1 - zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }))
    }
}

/// Real native diarization bounds, in the original recording's time domain.
public struct RecordingSpeakerSpan: Sendable, Codable {
    public let range: MediaTimeRange
    public let speaker: SpeakerID
    public init(range: MediaTimeRange, speaker: SpeakerID) { self.range = range; self.speaker = speaker }

    /// Mixed/poorly covered passages keep their existing attribution. This
    /// never divides words proportionally or fabricates a person's identity.
    public static func unambiguousSpeaker(for range: MediaTimeRange, spans: [Self]) -> SpeakerID? {
        var coverage: [SpeakerID: Double] = [:]
        for span in spans {
            let overlap = max(0, min(range.end, span.range.end) - max(range.start, span.range.start))
            if overlap > 0 { coverage[span.speaker, default: 0] += overlap }
        }
        let ordered = coverage.sorted { $0.value > $1.value }
        guard let first = ordered.first, first.value >= max(0.2, range.duration * 0.55),
              ordered.count < 2 || ordered[1].value <= first.value * 0.15 else { return nil }
        return first.key
    }
}
