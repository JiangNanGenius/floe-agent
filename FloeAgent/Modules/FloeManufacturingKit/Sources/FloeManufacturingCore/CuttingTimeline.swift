// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Single-spindle turning speed/feed schedule for nominal cutting time.
///
/// These values describe a spindle speed law and a feed law only. They are not
/// C-axis positioning, not a five-axis angular rate and not a real spindle
/// phase. Formulas (local derivation, cross-checked against published metric
/// turning formulas with Dm = 2r):
///   fixed RPM:  n = min(spindleRPM, maxSpindleRPM)
///   CSS:        n(r) = min(maxSpindleRPM, 1000 * surfaceSpeedMPerMinute / (2πr)), r in mm
///   per-rev:    F = feedMMPerRevolution * n   (mm/min)
///   per-minute: F = legacy turning feed       (mm/min)
public struct TurningCuttingParameters: Codable, Equatable, Sendable {
    public enum SpindleMode: String, Codable, Sendable, CaseIterable {
        case fixedRPM, constantSurfaceSpeed
    }
    public enum FeedMode: String, Codable, Sendable, CaseIterable {
        case mmPerMinute, mmPerRevolution
    }
    public var formatVersion = 1
    public var spindleMode: SpindleMode
    public var feedMode: FeedMode
    public var spindleRPM: Double
    public var surfaceSpeedMPerMinute: Double
    public var maxSpindleRPM: Double
    public var feedMMPerRevolution: Double
    public init(spindleMode: SpindleMode, feedMode: FeedMode,
                spindleRPM: Double, surfaceSpeedMPerMinute: Double,
                maxSpindleRPM: Double, feedMMPerRevolution: Double) {
        self.spindleMode = spindleMode
        self.feedMode = feedMode
        self.spindleRPM = spindleRPM
        self.surfaceSpeedMPerMinute = surfaceSpeedMPerMinute
        self.maxSpindleRPM = maxSpindleRPM
        self.feedMMPerRevolution = feedMMPerRevolution
    }
    /// All fields must be finite and in range regardless of the active mode, so
    /// a stored archive never carries an ambiguous unit/mode combination.
    public func validate() throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("turning cutting: \(reason)") }
        }
        try require([1,2].contains(formatVersion), "unsupported format version")
        try require(spindleRPM.isFinite && spindleRPM > 0 && spindleRPM <= 100_000, "spindle RPM")
        try require(surfaceSpeedMPerMinute.isFinite && surfaceSpeedMPerMinute > 0 && surfaceSpeedMPerMinute <= 10_000, "surface speed")
        try require(maxSpindleRPM.isFinite && maxSpindleRPM > 0 && maxSpindleRPM <= 100_000, "spindle RPM limit")
        try require(feedMMPerRevolution.isFinite && feedMMPerRevolution > 0 && feedMMPerRevolution <= 100, "feed per revolution")
    }
}

/// Nominal cutting time over the already existing linear cutting paths.
///
/// Time is integrated along the supplied polylines only: there are no implicit
/// links between paths, no rapid traverse, no acceleration, no spindle
/// transients, no tool changes and no A/C motion time. Paths that are not
/// timeable turning/milling cuts are listed in `excludedPathIndices` instead
/// of being assigned fabricated time.
public struct CuttingTimeline: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public var pathIndex: Int
        public var startPointIndex: Int
        public var startMM: Double
        public var endMM: Double
        public var lengthMM: Double
        public var startSeconds: Double
        public var durationSeconds: Double
        public var startRPM: Double?
        public var endRPM: Double?
        public var startFeedMMPerMinute: Double?
        public var endFeedMMPerMinute: Double?
        public var spindleLimited: Bool
        /// Exact 3D endpoints of this segment (the timeline stays replayable
        /// after archival without the original path arrays).
        public var startPointMM: [Double]
        public var endPointMM: [Double]
        // Turning speed-law reconstruction parameters (nil for milling-slot).
        public var radiusStartMM: Double?
        public var radiusEndMM: Double?
        public var spindleMode: TurningCuttingParameters.SpindleMode?
        public var feedMode: TurningCuttingParameters.FeedMode?
        public var surfaceSpeedMPerMinute: Double?
        public var maxSpindleRPM: Double?
        /// Commanded (uncapped) fixed RPM; nil for CSS and milling. Storing it
        /// keeps the `spindleLimited` flag independently verifiable.
        public var commandedRPM: Double?
        public var feedMMPerRevolution: Double?
        /// Explicit stationary CAM dwell; omitted in legacy timelines.
        public var dwellSeconds: Double?
        public init(pathIndex: Int, startPointIndex: Int,
                    startMM: Double, endMM: Double, lengthMM: Double,
                    startSeconds: Double, durationSeconds: Double,
                    startRPM: Double?, endRPM: Double?,
                    startFeedMMPerMinute: Double?, endFeedMMPerMinute: Double?,
                    spindleLimited: Bool,
                    startPointMM: [Double], endPointMM: [Double],
                    radiusStartMM: Double?, radiusEndMM: Double?,
                    spindleMode: TurningCuttingParameters.SpindleMode?,
                    feedMode: TurningCuttingParameters.FeedMode?,
                    surfaceSpeedMPerMinute: Double?, maxSpindleRPM: Double?,
                    commandedRPM: Double?,
                    feedMMPerRevolution: Double?) {
            self.pathIndex = pathIndex
            self.startPointIndex = startPointIndex
            self.startMM = startMM
            self.endMM = endMM
            self.lengthMM = lengthMM
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
            self.startRPM = startRPM
            self.endRPM = endRPM
            self.startFeedMMPerMinute = startFeedMMPerMinute
            self.endFeedMMPerMinute = endFeedMMPerMinute
            self.spindleLimited = spindleLimited
            self.startPointMM = startPointMM
            self.endPointMM = endPointMM
            self.radiusStartMM = radiusStartMM
            self.radiusEndMM = radiusEndMM
            self.spindleMode = spindleMode
            self.feedMode = feedMode
            self.surfaceSpeedMPerMinute = surfaceSpeedMPerMinute
            self.maxSpindleRPM = maxSpindleRPM
            self.commandedRPM = commandedRPM
            self.feedMMPerRevolution = feedMMPerRevolution
        }
    }
    public struct Sample: Codable, Equatable, Sendable {
        public var pointMM: [Double]
        public var pathIndex: Int
        public var segmentIndex: Int
        public var rpm: Double?
        public var feedMMPerMinute: Double
        public init(pointMM: [Double], pathIndex: Int, segmentIndex: Int,
                    rpm: Double?, feedMMPerMinute: Double) {
            self.pointMM = pointMM
            self.pathIndex = pathIndex
            self.segmentIndex = segmentIndex
            self.rpm = rpm
            self.feedMMPerMinute = feedMMPerMinute
        }
    }
    public var formatVersion = 1
    public var segments: [Segment]
    public var totalSeconds: Double
    public var totalDistanceMM: Double
    public var excludedPathIndices: [Int]
    public init(formatVersion: Int = 1, segments: [Segment],
                totalSeconds: Double, totalDistanceMM: Double,
                excludedPathIndices: [Int]) {
        self.formatVersion = formatVersion
        self.segments = segments
        self.totalSeconds = totalSeconds
        self.totalDistanceMM = totalDistanceMM
        self.excludedPathIndices = excludedPathIndices
    }

    private static let acceptedTurningKinds: Set<String> = ["turning-face", "turning-rough", "turning-profile"]
    private static let maxCoordinate = 100_000.0
    private static let maxFeed = 1_000_000.0
    private static let axisYTolerance = 1e-6
    private static let maxSpansBudget = 12_000
    private static let geometryTolerance = 1e-9

    // MARK: - Speed law helpers

    /// K = 1000 * Vc / (2π): n = K / r for CSS with r in mm.
    private static func surfaceConstant(_ turning: TurningCuttingParameters) -> Double {
        turning.surfaceSpeedMPerMinute * 1000 / (2 * Double.pi)
    }
    /// r = 0 resolves to the finite RPM limit; never divide by zero.
    private static func rpm(atRadius radius: Double, turning: TurningCuttingParameters) -> Double {
        switch turning.spindleMode {
        case .fixedRPM: return min(turning.spindleRPM, turning.maxSpindleRPM)
        case .constantSurfaceSpeed:
            guard radius > 0 else { return turning.maxSpindleRPM }
            return min(turning.maxSpindleRPM, surfaceConstant(turning) / radius)
        }
    }
    private static func feed(atRadius radius: Double, turning: TurningCuttingParameters, legacyFeed: Double) -> Double {
        switch turning.feedMode {
        case .mmPerMinute: return legacyFeed
        case .mmPerRevolution: return turning.feedMMPerRevolution * rpm(atRadius: radius, turning: turning)
        }
    }

    // MARK: - Planning

    /// Build the nominal cutting timeline for the supplied native paths.
    public static func plan(paths: [ManufacturingResult.Path],
                            turning: TurningCuttingParameters?,
                            legacyTurningFeed: Double,
                            maxSegments: Int,
                            includeCAM: Bool = false,
                            useTurningPathFeeds: Bool = false,
                            checkCancellation: () throws -> Void = {}) throws -> CuttingTimeline {
        try turning?.validate()
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("cutting timeline: \(reason)") }
        }
        try require(maxSegments >= 1 && maxSegments <= maxSpansBudget, "segment budget")
        try require(paths.count <= maxSpansBudget && paths.reduce(0, { $0 + $1.points.count }) <= 100_000, "input path/point budget")
        if turning?.feedMode == .mmPerMinute {
            try require(legacyTurningFeed.isFinite && legacyTurningFeed > 0 && legacyTurningFeed <= maxFeed, "legacy turning feed per minute")
        }
        var segments: [Segment] = []
        var excluded: [Int] = []
        var distanceMM = 0.0
        var seconds = 0.0
        try checkCancellation()
        for (pathIndex, path) in paths.enumerated() {
            try checkCancellation()
            let kind = path.kind.lowercased()
            if Self.acceptedTurningKinds.contains(kind), let turning {
                let perMinuteFeed = useTurningPathFeeds ? (path.feedMMPerMinute ?? legacyTurningFeed) : legacyTurningFeed
                if turning.feedMode == .mmPerMinute { try require(perMinuteFeed.isFinite && perMinuteFeed > 0 && perMinuteFeed <= maxFeed,"turning path feed") }
                let points = try validatedTurningPoints(path, pathIndex: pathIndex)
                let pieces = timeablePieces(points)
                if pieces.isEmpty { excluded.append(pathIndex); continue }
                for piece in pieces {
                    try checkCancellation()
                    for span in turningSpans(turning: turning, r0: piece.r0, r1: piece.r1) {
                        let segment = try makeTurningSegment(turning: turning, legacyFeed: perMinuteFeed,
                                                             pathIndex: pathIndex, piece: piece, span: span,
                                                             distanceMM: &distanceMM, seconds: &seconds)
                        segments.append(segment)
                        try require(segments.count <= maxSegments, "segment budget exceeded")
                    }
                }
            } else if includeCAM && kind == "cam-dwell" {
                guard let dwell = path.dwellSeconds, dwell.isFinite, dwell > 0, dwell <= 100_000,
                      let point = path.points.first, path.points.allSatisfy({ $0 == point }),
                      point.count == 3, point.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else {
                    throw ManufacturingError.invalid("cutting timeline: invalid stationary CAM dwell")
                }
                var segment = Segment(pathIndex:pathIndex,startPointIndex:0,startMM:distanceMM,endMM:distanceMM,lengthMM:0,
                    startSeconds:seconds,durationSeconds:dwell,startRPM:nil,endRPM:nil,
                    startFeedMMPerMinute:0,endFeedMMPerMinute:0,spindleLimited:false,
                    startPointMM:point,endPointMM:point,radiusStartMM:nil,radiusEndMM:nil,
                    spindleMode:nil,feedMode:nil,surfaceSpeedMPerMinute:nil,maxSpindleRPM:nil,commandedRPM:nil,feedMMPerRevolution:nil)
                segment.dwellSeconds = dwell
                segments.append(segment); seconds += dwell
                try require(segments.count <= maxSegments,"segment budget exceeded")
            } else if kind == "milling-slot" || (includeCAM && ["cam-cut","cam-plunge","cam-rapid","cam-retract"].contains(kind)) ||
                        (includeCAM && Self.acceptedTurningKinds.contains(kind) && turning == nil) {
                guard let feed = path.feedMMPerMinute,
                      feed.isFinite, feed > 0, feed <= maxFeed else {
                    excluded.append(pathIndex)
                    continue
                }
                let points = try validatedMillingPoints(path, pathIndex: pathIndex)
                let pieces = timeablePieces(points)
                if pieces.isEmpty { excluded.append(pathIndex); continue }
                for piece in pieces {
                    try checkCancellation()
                    let segment = makeMillingSegment(feed: feed, pathIndex: pathIndex, piece: piece,
                                                     distanceMM: &distanceMM, seconds: &seconds)
                    segments.append(segment)
                    try require(segments.count <= maxSegments, "segment budget exceeded")
                }
            } else {
                excluded.append(pathIndex)
            }
        }
        try require(!segments.isEmpty, "no timeable cutting paths (empty, zero-length or unsupported kinds)")
        let timeline = CuttingTimeline(formatVersion:includeCAM ? 2 : 1,segments: segments, totalSeconds: seconds,
                                       totalDistanceMM: distanceMM, excludedPathIndices: excluded)
        try timeline.validate(paths: paths)
        return timeline
    }

    private struct TurnPoint { var xyz: [Double]; var radius: Double }
    private struct Piece { var startIndex: Int; var p0: TurnPoint; var p1: TurnPoint; var length: Double
                           var r0: Double { p0.radius }; var r1: Double { p1.radius } }
    private struct Span { var mu0: Double; var mu1: Double; var limited: Bool }

    private static func validatedTurningPoints(_ path: ManufacturingResult.Path, pathIndex: Int) throws -> [TurnPoint] {
        try path.points.map { point in
            guard point.count == 3 else { throw ManufacturingError.invalid("cutting timeline: turning path \(pathIndex) point requires [radius, 0, z]") }
            let (x, y, z) = (point[0], point[1], point[2])
            guard x.isFinite, y.isFinite, z.isFinite else { throw ManufacturingError.invalid("cutting timeline: turning path \(pathIndex) non-finite point") }
            guard abs(x) <= maxCoordinate, abs(y) <= maxCoordinate, abs(z) <= maxCoordinate else {
                throw ManufacturingError.invalid("cutting timeline: turning path \(pathIndex) coordinate magnitude")
            }
            guard y.magnitude <= axisYTolerance else {
                throw ManufacturingError.invalid("cutting timeline: turning path \(pathIndex) off-axis Y; only [radius, 0, z] is timeable")
            }
            guard x >= 0 else { throw ManufacturingError.invalid("cutting timeline: turning path \(pathIndex) negative radius") }
            return TurnPoint(xyz: point, radius: x)
        }
    }
    private static func validatedMillingPoints(_ path: ManufacturingResult.Path, pathIndex: Int) throws -> [TurnPoint] {
        try path.points.map { point in
            guard point.count == 3, point.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else {
                throw ManufacturingError.invalid("cutting timeline: milling path \(pathIndex) point requires finite [x, y, z]")
            }
            return TurnPoint(xyz: point, radius: 0)
        }
    }
    /// Consecutive distinct points only; repeated zero-length pieces are
    /// skipped. Length is the real 3D distance (turning Y is separately held
    /// at zero, so no milling XY motion is dropped here).
    private static func timeablePieces(_ points: [TurnPoint]) -> [Piece] {
        guard points.count > 1 else { return [] }
        var pieces: [Piece] = []
        var start = 0
        for index in 1..<points.count {
            let dx = points[index].xyz[0] - points[start].xyz[0]
            let dy = points[index].xyz[1] - points[start].xyz[1]
            let dz = points[index].xyz[2] - points[start].xyz[2]
            let length = (dx * dx + dy * dy + dz * dz).squareRoot()
            if length > 0 {
                pieces.append(Piece(startIndex: start, p0: points[start], p1: points[index], length: length))
            }
            start = index
        }
        return pieces
    }
    /// Split one polyline piece at the CSS limiting radius r* = K/nMax so each
    /// span carries a single exact speed regime. A span is spindle-limited iff
    /// its minimum radius lies below r* (endpoint touches included); both
    /// regimes agree bit-for-bit at an endpoint that sits exactly at r*.
    private static func turningSpans(turning: TurningCuttingParameters, r0: Double, r1: Double) -> [Span] {
        if turning.spindleMode == .fixedRPM {
            return [Span(mu0: 0, mu1: 1, limited: turning.spindleRPM > turning.maxSpindleRPM)]
        }
        let rStar = surfaceConstant(turning) / turning.maxSpindleRPM
        if max(r0, r1) <= rStar { return [Span(mu0: 0, mu1: 1, limited: true)] }
        if min(r0, r1) >= rStar { return [Span(mu0: 0, mu1: 1, limited: false)] }
        let lambda = (rStar - r0) / (r1 - r0)
        if lambda <= 0 || lambda >= 1 {
            // Endpoint sits exactly at r* with the other end strictly outside.
            return [Span(mu0: 0, mu1: 1, limited: min(r0, r1) < rStar)]
        }
        if r0 < r1 { return [Span(mu0: 0, mu1: lambda, limited: true), Span(mu0: lambda, mu1: 1, limited: false)] }
        return [Span(mu0: 0, mu1: lambda, limited: false), Span(mu0: lambda, mu1: 1, limited: true)]
    }
    private static func interpolated(_ a: [Double], _ b: [Double], _ mu: Double) -> [Double] {
        [a[0] + (b[0] - a[0]) * mu, a[1] + (b[1] - a[1]) * mu, a[2] + (b[2] - a[2]) * mu]
    }
    private static func makeTurningSegment(turning: TurningCuttingParameters, legacyFeed: Double,
                                           pathIndex: Int, piece: Piece, span: Span,
                                           distanceMM: inout Double, seconds: inout Double) throws -> Segment {
        // Whole spans store the source points directly; interior split points
        // use the same interpolation expression that validation recomputes.
        let r0 = span.mu0 == 0 ? piece.r0 : piece.r0 + (piece.r1 - piece.r0) * span.mu0
        let r1 = span.mu1 == 1 ? piece.r1 : piece.r0 + (piece.r1 - piece.r0) * span.mu1
        let start = span.mu0 == 0 ? piece.p0.xyz : interpolated(piece.p0.xyz, piece.p1.xyz, span.mu0)
        let end = span.mu1 == 1 ? piece.p1.xyz : interpolated(piece.p0.xyz, piece.p1.xyz, span.mu1)
        let length = piece.length * (span.mu1 - span.mu0)
        let secondsInSpan: Double
        switch turning.feedMode {
        case .mmPerMinute:
            secondsInSpan = 60 * length / legacyFeed
        case .mmPerRevolution:
            let fixed = min(turning.spindleRPM, turning.maxSpindleRPM)
            switch turning.spindleMode {
            case .fixedRPM:
                secondsInSpan = 60 * length / (turning.feedMMPerRevolution * fixed)
            case .constantSurfaceSpeed:
                if span.limited {
                    secondsInSpan = 60 * length / (turning.feedMMPerRevolution * turning.maxSpindleRPM)
                } else {
                    secondsInSpan = 60 * length * (r0 + r1) / 2 / (turning.feedMMPerRevolution * surfaceConstant(turning))
                }
            }
        }
        guard length.isFinite, length > 0, secondsInSpan.isFinite, secondsInSpan > 0 else {
            throw ManufacturingError.invalid("cutting timeline: non-finite or non-positive turning span")
        }
        let segment = Segment(pathIndex: pathIndex, startPointIndex: piece.startIndex,
                              startMM: distanceMM, endMM: distanceMM + length, lengthMM: length,
                              startSeconds: seconds, durationSeconds: secondsInSpan,
                              startRPM: rpm(atRadius: r0, turning: turning),
                              endRPM: rpm(atRadius: r1, turning: turning),
                              startFeedMMPerMinute: feed(atRadius: r0, turning: turning, legacyFeed: legacyFeed),
                              endFeedMMPerMinute: feed(atRadius: r1, turning: turning, legacyFeed: legacyFeed),
                              spindleLimited: span.limited,
                              startPointMM: start, endPointMM: end,
                              radiusStartMM: r0, radiusEndMM: r1,
                              spindleMode: turning.spindleMode, feedMode: turning.feedMode,
                              surfaceSpeedMPerMinute: turning.spindleMode == .constantSurfaceSpeed ? turning.surfaceSpeedMPerMinute : nil,
                              maxSpindleRPM: turning.maxSpindleRPM,
                              commandedRPM: turning.spindleMode == .fixedRPM ? turning.spindleRPM : nil,
                              feedMMPerRevolution: turning.feedMode == .mmPerRevolution ? turning.feedMMPerRevolution : nil)
        distanceMM += length
        seconds += secondsInSpan
        return segment
    }
    private static func makeMillingSegment(feed: Double, pathIndex: Int, piece: Piece,
                                           distanceMM: inout Double, seconds: inout Double) -> Segment {
        let length = piece.length
        let duration = 60 * length / feed
        let segment = Segment(pathIndex: pathIndex, startPointIndex: piece.startIndex,
                              startMM: distanceMM, endMM: distanceMM + length, lengthMM: length,
                              startSeconds: seconds, durationSeconds: duration,
                              startRPM: nil, endRPM: nil,
                              startFeedMMPerMinute: feed, endFeedMMPerMinute: feed,
                              spindleLimited: false,
                              startPointMM: piece.p0.xyz, endPointMM: piece.p1.xyz,
                              radiusStartMM: nil, radiusEndMM: nil,
                              spindleMode: nil, feedMode: nil,
                              surfaceSpeedMPerMinute: nil, maxSpindleRPM: nil,
                              commandedRPM: nil, feedMMPerRevolution: nil)
        distanceMM += length
        seconds += duration
        return segment
    }

    // MARK: - Replay

    /// Seconds from a segment start to local fraction `tau` in [0, 1], using the
    /// same exact integrals as planning (never an average-speed shortcut).
    private func localSeconds(_ segment: Segment, _ tau: Double) throws -> Double {
        let length = segment.lengthMM
        if let dwell = segment.dwellSeconds { return dwell * tau }
        if let mode = segment.spindleMode, let feedMode = segment.feedMode {
            switch feedMode {
            case .mmPerMinute:
                guard let feed = segment.startFeedMMPerMinute else {
                    throw ManufacturingError.invalid("cutting timeline sample: incomplete turning law")
                }
                return 60 * length * tau / feed
            case .mmPerRevolution:
                guard let f = segment.feedMMPerRevolution, let startRPM = segment.startRPM else {
                    throw ManufacturingError.invalid("cutting timeline sample: incomplete turning law")
                }
                if mode == .fixedRPM { return 60 * length * tau / (f * startRPM) }
                guard let vc = segment.surfaceSpeedMPerMinute,
                      let nMax = segment.maxSpindleRPM,
                      let r0 = segment.radiusStartMM, let r1 = segment.radiusEndMM else {
                    throw ManufacturingError.invalid("cutting timeline sample: incomplete css law")
                }
                if segment.spindleLimited { return 60 * length * tau / (f * nMax) }
                let k = vc * 1000 / (2 * Double.pi)
                let radius = r0 + (r1 - r0) * tau
                return 60 * length / (f * k) * ((r0 + radius) / 2) * tau
            }
        }
        guard let feed = segment.startFeedMMPerMinute else {
            throw ManufacturingError.invalid("cutting timeline sample: incomplete milling segment")
        }
        return 60 * length * tau / feed
    }
    /// RPM/feed at local fraction `tau`, following the stored speed law.
    private func localState(_ segment: Segment, _ tau: Double) throws -> (rpm: Double?, feed: Double) {
        if segment.dwellSeconds != nil { return (nil,0) }
        if let mode = segment.spindleMode, let feedMode = segment.feedMode {
            switch feedMode {
            case .mmPerMinute:
                guard let feed = segment.startFeedMMPerMinute, let rpm = segment.startRPM else {
                    throw ManufacturingError.invalid("cutting timeline sample: incomplete turning law")
                }
                if mode == .constantSurfaceSpeed {
                    guard let vc = segment.surfaceSpeedMPerMinute, let nMax = segment.maxSpindleRPM,
                          let r0 = segment.radiusStartMM, let r1 = segment.radiusEndMM else {
                        throw ManufacturingError.invalid("cutting timeline sample: incomplete css law")
                    }
                    let radius = r0+(r1-r0)*tau
                    return (radius > 0 ? min(nMax,vc*1000/(2 * .pi)/radius) : nMax,feed)
                }
                return (rpm,feed)
            case .mmPerRevolution:
                guard let f = segment.feedMMPerRevolution else {
                    throw ManufacturingError.invalid("cutting timeline sample: incomplete turning law")
                }
                let n: Double
                switch mode {
                case .fixedRPM:
                    guard let rpm = segment.startRPM else {
                        throw ManufacturingError.invalid("cutting timeline sample: incomplete turning law")
                    }
                    n = rpm
                case .constantSurfaceSpeed:
                    guard let vc = segment.surfaceSpeedMPerMinute, let nMax = segment.maxSpindleRPM,
                          let r0 = segment.radiusStartMM, let r1 = segment.radiusEndMM else {
                        throw ManufacturingError.invalid("cutting timeline sample: incomplete css law")
                    }
                    let radius = r0 + (r1 - r0) * tau
                    n = radius > 0 ? min(nMax, vc * 1000 / (2 * Double.pi) / radius) : nMax
                }
                return (n, f * n)
            }
        }
        guard let feed = segment.startFeedMMPerMinute else {
            throw ManufacturingError.invalid("cutting timeline sample: incomplete milling segment")
        }
        return (nil, feed)
    }
    /// Reconstruct the tool position at a nominal time. NaN/±infinity reject;
    /// out-of-range times clamp to the endpoints (including t = totalSeconds).
    /// Inversion is a bounded bisection on the exact time integral — never
    /// point-count or average speed. Throws, never traps, on malformed data.
    public func sample(atSeconds seconds: Double) throws -> Sample {
        guard seconds.isFinite else { throw ManufacturingError.invalid("cutting timeline sample: seconds must be finite") }
        try requireSampleReady()
        let time = min(max(seconds, 0), totalSeconds)
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].startSeconds <= time { lo = mid } else { hi = mid - 1 }
        }
        let segment = segments[lo]
        // Structural checks on the selected segment keep every subscript and
        // unwrap below total; corrupted archives error out instead of trapping.
        try checkSegmentStructure(segment, index: lo)
        let target = min(segment.durationSeconds,max(0,time-segment.startSeconds))
        var a = 0.0
        var b = 1.0
        for _ in 0..<64 {
            let mid = (a + b) / 2
            if try localSeconds(segment, mid) < target { a = mid } else { b = mid }
        }
        let tau = target <= 0 ? 0 : target >= segment.durationSeconds ? 1 : (a+b)/2
        let point = tau == 0 ? segment.startPointMM : tau == 1 ? segment.endPointMM : [segment.startPointMM[0] + (segment.endPointMM[0] - segment.startPointMM[0]) * tau,
                     segment.startPointMM[1] + (segment.endPointMM[1] - segment.startPointMM[1]) * tau,
                     segment.startPointMM[2] + (segment.endPointMM[2] - segment.startPointMM[2]) * tau]
        let state = try localState(segment, tau)
        return Sample(pointMM: point, pathIndex: segment.pathIndex, segmentIndex: lo,
                      rpm: state.rpm, feedMMPerMinute: state.feed)
    }
    private func requireSampleReady() throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("cutting timeline sample: \(reason)") }
        }
        try require([1,2].contains(formatVersion), "unsupported format version")
        try require(!segments.isEmpty, "empty timeline")
        try require(segments.count <= Self.maxSpansBudget, "segment count")
        try require(totalSeconds.isFinite && totalSeconds > 0 && totalSeconds <= 1e12, "total seconds budget")
        try require(totalDistanceMM.isFinite && (totalDistanceMM > 0 || (formatVersion == 2 && totalDistanceMM == 0)), "total distance")
    }

    // MARK: - Validation

    /// Recompute from the same inputs and require bit-for-bit equality, then run
    /// the structural checks: a decoded, editable archive is verified by rebuild
    /// and compare, never trusted blindly.
    public func validate(paths: [ManufacturingResult.Path],
                         turning: TurningCuttingParameters,
                         legacyTurningFeed: Double,
                         maxSegments: Int) throws {
        let expected = try Self.plan(paths: paths, turning: turning,
                                     legacyTurningFeed: legacyTurningFeed,
                                     maxSegments: maxSegments)
        guard expected == self else {
            throw ManufacturingError.invalid("cutting timeline: archived timeline does not match the recomputed plan")
        }
        try validate(paths: paths)
    }

    /// Structural and cross-checks against the paths that produced this timeline.
    public func validate(paths: [ManufacturingResult.Path]) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("cutting timeline: \(reason)") }
        }
        try require([1,2].contains(formatVersion), "unsupported format version")
        try require(!segments.isEmpty, "no segments")
        try require(totalSeconds.isFinite && totalSeconds > 0 && totalSeconds <= 1e12, "total seconds budget")
        try require(totalDistanceMM.isFinite && (totalDistanceMM > 0 || (formatVersion == 2 && totalDistanceMM == 0)), "total distance")
        try require(segments.count <= Self.maxSpansBudget, "segment count")
        try require(excludedPathIndices == excludedPathIndices.sorted() && Set(excludedPathIndices).count == excludedPathIndices.count, "excluded indices unordered or duplicated")
        try require(excludedPathIndices.allSatisfy { paths.indices.contains($0) }, "excluded index out of range")
        var coveredPaths = Set<Int>()
        var distance = 0.0
        var seconds = 0.0
        for (index, segment) in segments.enumerated() {
            try checkSegmentStructure(segment, index: index)
            try require(segment.startMM == distance && segment.startSeconds == seconds, "broken cumulative order at segment \(index)")
            try require(!excludedPathIndices.contains(segment.pathIndex), "segment \(index) uses an excluded path")
            try require(segment.endMM == segment.startMM + segment.lengthMM, "segment \(index) distance mismatch")
            try require(segment.pathIndex < paths.count, "segment \(index) path index out of range")
            try checkSegmentAgainstPath(segment, path: paths[segment.pathIndex])
            coveredPaths.insert(segment.pathIndex)
            distance = segment.endMM
            seconds = segment.startSeconds + segment.durationSeconds
        }
        try require(distance == totalDistanceMM, "total distance mismatch")
        try require(seconds == totalSeconds, "total seconds mismatch")
        for pathIndex in paths.indices where !excludedPathIndices.contains(pathIndex) {
            try require(coveredPaths.contains(pathIndex), "path \(pathIndex) neither timed nor excluded")
        }
    }
    private func checkSegmentStructure(_ segment: Segment, index: Int) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("cutting timeline: segment \(index) \(reason)") }
        }
        try require(segment.pathIndex >= 0 && segment.startPointIndex >= 0, "negative index")
        try require(segment.startMM.isFinite && segment.endMM.isFinite && segment.lengthMM.isFinite, "non-finite distance")
        try require(segment.startSeconds.isFinite && segment.durationSeconds.isFinite, "non-finite time")
        try require(segment.durationSeconds > 0 && (segment.lengthMM > 0 || (formatVersion == 2 && segment.dwellSeconds != nil && segment.lengthMM == 0)), "non-positive length or duration")
        if let dwell = segment.dwellSeconds {
            try require(formatVersion == 2 && dwell.isFinite && dwell > 0 && dwell <= 100_000 && dwell == segment.durationSeconds &&
                segment.startPointMM == segment.endPointMM && segment.lengthMM == 0 && segment.startFeedMMPerMinute == 0 && segment.endFeedMMPerMinute == 0,"stationary dwell")
        }
        try require(segment.startMM >= 0 && segment.startSeconds >= 0, "negative start")
        try require(segment.startPointMM.count == 3 && segment.endPointMM.count == 3, "endpoint dimension")
        try require(segment.startPointMM.allSatisfy(\.isFinite) && segment.endPointMM.allSatisfy(\.isFinite), "non-finite endpoint")
        try require((segment.startPointMM+segment.endPointMM).allSatisfy { abs($0) <= Self.maxCoordinate },"endpoint bounds")
        try require((segment.spindleMode == nil) == (segment.feedMode == nil),"incomplete mode pair")
        try require(segment.startFeedMMPerMinute?.isFinite == true && segment.endFeedMMPerMinute?.isFinite == true,"non-finite feed")
        let turning = segment.spindleMode != nil && segment.feedMode != nil
        if turning {
            try require(segment.radiusStartMM != nil && segment.radiusEndMM != nil, "missing radii")
            try require(segment.radiusStartMM!.isFinite && segment.radiusEndMM!.isFinite, "non-finite radius")
            try require(segment.radiusStartMM! >= 0 && segment.radiusEndMM! >= 0, "negative radius")
            try require(segment.radiusStartMM! == segment.startPointMM[0] && segment.radiusEndMM! == segment.endPointMM[0], "radius/endpoint mismatch")
            try require(abs(segment.startPointMM[1]) <= Self.axisYTolerance && abs(segment.endPointMM[1]) <= Self.axisYTolerance, "turning endpoint off-axis")
            try require(segment.maxSpindleRPM != nil && segment.maxSpindleRPM!.isFinite
                        && segment.maxSpindleRPM! > 0 && segment.maxSpindleRPM! <= 100_000, "rpm limit range")
            try require(segment.startRPM != nil && segment.endRPM != nil, "missing rpm")
            try require(segment.startRPM!.isFinite && segment.endRPM!.isFinite,"non-finite rpm")
            try require(segment.startRPM! > 0 && segment.endRPM! > 0, "non-positive rpm")
            try require(segment.startFeedMMPerMinute != nil && segment.endFeedMMPerMinute != nil, "missing feed")
            try require(segment.startFeedMMPerMinute! > 0 && segment.endFeedMMPerMinute! > 0, "non-positive feed")
            try require(segment.startFeedMMPerMinute! <= Self.maxFeed && segment.endFeedMMPerMinute! <= Self.maxFeed, "feed range")
            // Speed law consistency (exact: same expressions as planning).
            switch segment.spindleMode! {
            case .fixedRPM:
                try require(segment.surfaceSpeedMPerMinute == nil, "fixed rpm segment carries surface speed")
                try require(segment.commandedRPM != nil && segment.commandedRPM!.isFinite
                            && segment.commandedRPM! > 0 && segment.commandedRPM! <= 100_000, "commanded rpm range")
                try require(segment.startRPM! == min(segment.commandedRPM!, segment.maxSpindleRPM!), "fixed rpm law mismatch")
                try require(segment.startRPM! == segment.endRPM!, "fixed rpm must be constant")
                try require(segment.spindleLimited == (segment.commandedRPM! > segment.maxSpindleRPM!), "fixed rpm limit flag")
            case .constantSurfaceSpeed:
                try require(segment.commandedRPM == nil, "css segment carries commanded rpm")
                try require(segment.surfaceSpeedMPerMinute != nil && segment.surfaceSpeedMPerMinute!.isFinite
                            && segment.surfaceSpeedMPerMinute! > 0 && segment.surfaceSpeedMPerMinute! <= 10_000, "surface speed range")
                let k = segment.surfaceSpeedMPerMinute! * 1000 / (2 * Double.pi)
                let rStar = k / segment.maxSpindleRPM!
                let band = Self.geometryTolerance * max(1,rStar)
                try require(segment.spindleLimited
                    ? max(segment.radiusStartMM!,segment.radiusEndMM!) <= rStar+band
                    : min(segment.radiusStartMM!,segment.radiusEndMM!) >= rStar-band,"unsplit CSS limit crossing")
                try require(segment.startRPM! == min(segment.maxSpindleRPM!, segment.radiusStartMM! > 0 ? k / segment.radiusStartMM! : segment.maxSpindleRPM!), "css start rpm mismatch")
                try require(segment.endRPM! == min(segment.maxSpindleRPM!, segment.radiusEndMM! > 0 ? k / segment.radiusEndMM! : segment.maxSpindleRPM!), "css end rpm mismatch")
            }
            switch segment.feedMode! {
            case .mmPerMinute:
                try require(segment.startFeedMMPerMinute! == segment.endFeedMMPerMinute!, "per-minute feed must be constant")
            case .mmPerRevolution:
                try require(segment.feedMMPerRevolution != nil && segment.feedMMPerRevolution!.isFinite
                            && segment.feedMMPerRevolution! > 0 && segment.feedMMPerRevolution! <= 100, "feed per rev")
                try require(segment.startFeedMMPerMinute! == segment.feedMMPerRevolution! * segment.startRPM!, "per-rev start feed mismatch")
                try require(segment.endFeedMMPerMinute! == segment.feedMMPerRevolution! * segment.endRPM!, "per-rev end feed mismatch")
            }
        } else {
            try require(segment.radiusStartMM == nil && segment.radiusEndMM == nil && segment.surfaceSpeedMPerMinute == nil
                        && segment.maxSpindleRPM == nil && segment.feedMMPerRevolution == nil && segment.commandedRPM == nil,
                        "milling segment carries turning law")
            try require(segment.startRPM == nil && segment.endRPM == nil, "milling segment carries rpm")
            try require(segment.startFeedMMPerMinute != nil && segment.startFeedMMPerMinute == segment.endFeedMMPerMinute, "milling feed")
            try require((segment.dwellSeconds != nil && segment.startFeedMMPerMinute == 0) || segment.startFeedMMPerMinute! > 0, "milling feed positive")
            try require(!segment.spindleLimited, "milling segment spindle flag")
        }
        let delta = zip(segment.startPointMM,segment.endPointMM).map { $1-$0 }
        let geometricLength = sqrt(delta.reduce(0) { $0+$1*$1 })
        try require(abs(geometricLength-segment.lengthMM) <= Self.geometryTolerance * max(1,segment.lengthMM),"geometric length mismatch")
        let duration = try localSeconds(segment,1)
        try require(duration.isFinite && abs(duration-segment.durationSeconds) <= 1e-10 * max(1,duration),"duration/speed mismatch")
        try require(segment.startSeconds+segment.durationSeconds > segment.startSeconds,"time below numeric resolution")
    }
    private func checkSegmentAgainstPath(_ segment: Segment, path: ManufacturingResult.Path) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("cutting timeline: path \(segment.pathIndex) \(reason)") }
        }
        let kind = path.kind.lowercased()
        let points = path.points
        if let dwell = segment.dwellSeconds {
            try require(formatVersion == 2 && kind == "cam-dwell" && path.moveType == "dwell" && path.dwellSeconds == dwell &&
                !points.isEmpty && points.allSatisfy { $0 == segment.startPointMM },"dwell/path mismatch")
            return
        }
        guard segment.startPointIndex >= 0 && points.count >= 2 && segment.startPointIndex < points.count-1 else {
            throw ManufacturingError.invalid("cutting timeline: path \(segment.pathIndex) point index out of range")
        }
        let a = points[segment.startPointIndex]
        let b = points[segment.startPointIndex + 1]
        if segment.spindleMode != nil {
            try require(Self.acceptedTurningKinds.contains(kind), "turning segment on non-turning path")
            try require(a.count == 3 && b.count == 3, "point dimension")
            let ra = a[0], rb = b[0]
            let lo = min(ra, rb), hi = max(ra, rb)
            try require(segment.radiusStartMM! >= lo && segment.radiusStartMM! <= hi
                        && segment.radiusEndMM! >= lo && segment.radiusEndMM! <= hi, "span radii outside source piece")
            if ra != rb {
                let mu0 = (segment.radiusStartMM! - ra) / (rb - ra)
                let mu1 = (segment.radiusEndMM! - ra) / (rb - ra)
                try require(mu0 >= -Self.geometryTolerance && mu0 <= 1 + Self.geometryTolerance
                            && mu1 >= -Self.geometryTolerance && mu1 <= 1 + Self.geometryTolerance
                            && mu0 < mu1 + Self.geometryTolerance, "span fractions out of range")
                let expectedStart = mu0 == 0 ? a : Self.interpolated(a, b, mu0)
                let expectedEnd = mu1 == 1 ? b : Self.interpolated(a, b, mu1)
                try require(close(expectedStart, segment.startPointMM) && close(expectedEnd, segment.endPointMM), "span endpoints do not lie on the source polyline")
            } else {
                try require(segment.radiusStartMM! == ra && segment.radiusEndMM! == rb, "axial span radius mismatch")
                try require(close(a, segment.startPointMM) && close(b, segment.endPointMM), "axial endpoints mismatch")
            }
        } else {
            try require(kind == "milling-slot" || (formatVersion == 2 && (["cam-cut","cam-plunge","cam-rapid","cam-retract"].contains(kind) || Self.acceptedTurningKinds.contains(kind))), "linear segment on non-linear path")
            try require(close(a, segment.startPointMM) && close(b, segment.endPointMM), "milling endpoints mismatch")
            try require(path.feedMMPerMinute == segment.startFeedMMPerMinute, "milling feed mismatch")
        }
    }
    private func close(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        zip(lhs, rhs).allSatisfy { abs($0.0 - $0.1) <= Self.geometryTolerance * max(1, abs($0.0), abs($0.1)) }
    }
}

public extension CuttingTimeline {
    static func plan(paths:[ManufacturingResult.Path],study:ManufacturingStudy,checkCancellation:() throws -> Void = {}) throws -> CuttingTimeline {
        try plan(paths:paths,turning:study.turning.enabled ? study.turningCutting : nil,
            legacyTurningFeed:study.turning.feedMMPerMinute,maxSegments:study.budget.maxPoses,
            includeCAM:!(study.cam?.enabledOperations.isEmpty ?? true),useTurningPathFeeds:study.turningSetup != nil,
            checkCancellation:checkCancellation)
    }
}
