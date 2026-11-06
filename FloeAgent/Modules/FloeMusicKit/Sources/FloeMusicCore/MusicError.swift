/// Errors thrown by music core validation, editing and decoding.
public enum MusicError: Error, Equatable, CustomStringConvertible {
    case invalidSampleTime(reason: String)
    case invalidTempoMap(reason: String)
    case invalidClip(reason: String)
    case invalidTrack(reason: String)
    case invalidMixer(reason: String)
    case invalidAsset(reason: String)
    case invalidMIDI(reason: String)
    case invalidAutomation(reason: String)
    case invalidBatch(reason: String)
    case invalidDJ(reason: String)
    case invalidPerformance(reason: String)
    case staleRevision(expected: Int64, actual: Int64)
    case staleOwner(session: String)
    case sessionClosed(session: String)
    case boundsExceeded(field: String, limit: Int)
    case encodingFailed(reason: String)

    public var description: String {
        switch self {
        case .invalidSampleTime(let r): return "invalidSampleTime: \(r)"
        case .invalidTempoMap(let r): return "invalidTempoMap: \(r)"
        case .invalidClip(let r): return "invalidClip: \(r)"
        case .invalidTrack(let r): return "invalidTrack: \(r)"
        case .invalidMixer(let r): return "invalidMixer: \(r)"
        case .invalidAsset(let r): return "invalidAsset: \(r)"
        case .invalidMIDI(let r): return "invalidMIDI: \(r)"
        case .invalidAutomation(let r): return "invalidAutomation: \(r)"
        case .invalidBatch(let r): return "invalidBatch: \(r)"
        case .invalidDJ(let r): return "invalidDJ: \(r)"
        case .invalidPerformance(let r): return "invalidPerformance: \(r)"
        case .staleRevision(let e, let a): return "staleRevision: expected \(e), actual \(a)"
        case .staleOwner(let s): return "staleOwner: session \(s)"
        case .sessionClosed(let s): return "sessionClosed: session \(s)"
        case .boundsExceeded(let f, let l): return "boundsExceeded: \(f) limit \(l)"
        case .encodingFailed(let r): return "encodingFailed: \(r)"
        }
    }
}
