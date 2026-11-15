import Foundation

/// Which face of a wall a finish is applied to. The direction is always the
/// wall's authored centre line from `a` to `b`; left is the counter-clockwise
/// normal and right is its opposite. This is the same convention used by the
/// plan editor and the assistant edit format.
public enum InteriorWallSide: String, Codable, CaseIterable, Sendable, Hashable {
    case left
    case right

    public var opposite: Self { self == .left ? .right : .left }
}

/// Which end of a wall centre line is being moved. Kept separate from the
/// finish side so an endpoint edit cannot be mistaken for a face assignment.
public enum InteriorWallEndpoint: String, Codable, CaseIterable, Sendable, Hashable {
    case start
    case end
}

/// A small, versioned finish catalog. These are editor finishes, not a claim
/// about a manufacturer, product availability or a tested fire/wet rating.
public struct InteriorWallFinish: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let version: String
    public let nameZH: String
    public let nameEN: String
    public let colorHex: String

    public init(id: String, version: String, nameZH: String, nameEN: String, colorHex: String) {
        self.id = id
        self.version = version
        self.nameZH = nameZH
        self.nameEN = nameEN
        self.colorHex = colorHex
    }

    public func name(chinese: Bool) -> String { chinese ? nameZH : nameEN }
}

public enum InteriorWallFinishCatalog {
    public static let all: [InteriorWallFinish] = [
        .init(id: "paint-white", version: "1", nameZH: "白色乳胶漆", nameEN: "White paint", colorHex: "F2F2F0"),
        .init(id: "paint-warm", version: "1", nameZH: "暖灰乳胶漆", nameEN: "Warm grey paint", colorHex: "C9C3B8"),
        .init(id: "plaster", version: "1", nameZH: "石膏抹面", nameEN: "Plaster", colorHex: "D8D3C8"),
        .init(id: "tile-ceramic", version: "1", nameZH: "陶瓷墙砖", nameEN: "Ceramic tile", colorHex: "B7C6C9"),
        .init(id: "tile-porcelain", version: "1", nameZH: "瓷砖大板", nameEN: "Porcelain slab", colorHex: "9FAEB3"),
        .init(id: "wood-oak", version: "1", nameZH: "橡木饰面", nameEN: "Oak veneer", colorHex: "B58B5A"),
        .init(id: "wood-walnut", version: "1", nameZH: "胡桃木饰面", nameEN: "Walnut veneer", colorHex: "7A5136"),
        .init(id: "stone-marble", version: "1", nameZH: "大理石", nameEN: "Marble", colorHex: "D8D6D0"),
        .init(id: "wallpaper-linen", version: "1", nameZH: "亚麻墙布", nameEN: "Linen wallcovering", colorHex: "CBBFA8"),
        .init(id: "acoustic-felt", version: "1", nameZH: "吸音毛毡", nameEN: "Acoustic felt", colorHex: "8D918C"),
    ]

    public static func finish(id: String) -> InteriorWallFinish? {
        all.first { $0.id == id }
    }

    public static func isSupported(id: String) -> Bool {
        finish(id: id) != nil
    }
}

/// Project-level finish assignments keyed by the stable native wall ID. The
/// native CAD element remains authoritative for geometry; this record supplies
/// the two face finishes without inventing a second wall model.
public struct InteriorWallFinishAssignment: Codable, Hashable, Sendable {
    public var wallID: UUID
    public var left: String?
    public var right: String?

    public init(wallID: UUID, left: String? = nil, right: String? = nil) {
        self.wallID = wallID
        self.left = left
        self.right = right
    }

    public func finishID(for side: InteriorWallSide) -> String? {
        side == .left ? left : right
    }

    public mutating func set(_ finishID: String?, for side: InteriorWallSide) {
        if side == .left { left = finishID } else { right = finishID }
    }

    public mutating func swapSides() {
        (left, right) = (right, left)
    }

    public var isEmpty: Bool { left == nil && right == nil }

    /// Validate against the actual catalog and return a normalized assignment
    /// (nil values for unknown IDs). Callers must not silently accept an
    /// unsupported finish ID as if it were a real material.
    public func validated() throws -> InteriorWallFinishAssignment {
        var value = self
        for (side, id) in [(InteriorWallSide.left, left), (.right, right)] {
            guard let id else { continue }
            guard let finish = InteriorWallFinishCatalog.finish(id: id) else {
                throw InteriorWallFinishError.unknownFinish(id)
            }
            guard finish.version == "1" else {
                throw InteriorWallFinishError.unsupportedVersion(finish.version)
            }
            value.set(id, for: side)
        }
        return value
    }
}

public enum InteriorWallFinishError: Error, LocalizedError, Equatable, Sendable {
    case unknownFinish(String)
    case unsupportedVersion(String)
    case duplicateWall(UUID)
    case staleWall(UUID)

    public var errorDescription: String? {
        switch self {
        case .unknownFinish(let id): return "Unknown wall finish: \(id)"
        case .unsupportedVersion(let version): return "Unsupported wall finish version: \(version)"
        case .duplicateWall(let id): return "A wall has more than one finish assignment: \(id)"
        case .staleWall(let id): return "The finish refers to a wall that no longer exists: \(id)"
        }
    }
}

/// One straight wall's centre line and thickness. This intentionally mirrors
/// only the values the plan editor needs, so the geometry helpers can be tested
/// without a CAD document.
public struct InteriorWallPlanSegment: Equatable, Sendable {
    public var a: [Double]
    public var b: [Double]
    public var thicknessMM: Double

    public init(a: [Double], b: [Double], thicknessMM: Double) {
        self.a = a
        self.b = b
        self.thicknessMM = thicknessMM
    }

    public var lengthMM: Double {
        guard a.count == 2, b.count == 2 else { return .nan }
        return hypot(b[0] - a[0], b[1] - a[1])
    }
}

/// Pure plan-edit geometry used by the wall editor and unit-tested on macOS.
/// Points are `[u, v]` millimetres; no drawing unit is guessed.
public enum InteriorWallPlanGeometry {
    public static func exactEndpoint(start: [Double], lengthMM: Double, angleDegrees: Double) -> [Double]? {
        guard start.count == 2, start.allSatisfy(\.isFinite),
              lengthMM.isFinite, lengthMM >= 1, lengthMM <= 1_000_000,
              angleDegrees.isFinite else { return nil }
        let radians = angleDegrees * .pi / 180
        return [start[0] + lengthMM * cos(radians), start[1] + lengthMM * sin(radians)]
    }

    /// Snap to an existing endpoint first, then to a wall axis, then to the
    /// grid. This order keeps a chain connected instead of rounding a corner
    /// away from a nearby wall.
    public static func snapped(
        _ point: [Double],
        segments: [InteriorWallPlanSegment],
        gridMM: Double,
        endpointToleranceMM: Double = 240,
        axisToleranceMM: Double = 180
    ) -> [Double] {
        guard point.count == 2, point.allSatisfy(\.isFinite) else { return [0, 0] }
        var best: (distance: Double, value: [Double])?
        for segment in segments {
            for end in [segment.a, segment.b] where end.count == 2 {
                let distance = hypot(end[0] - point[0], end[1] - point[1])
                guard distance <= endpointToleranceMM else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, end)
                }
            }
        }
        if let best { return best.value.map { rounded($0) } }
        for segment in segments {
            if let projection = projection(of: point, on: segment),
               hypot(projection[0] - point[0], projection[1] - point[1]) <= axisToleranceMM {
                return projection.map { rounded($0) }
            }
        }
        guard gridMM.isFinite, gridMM > 0, gridMM <= 10_000 else { return point }
        return point.map { ($0 / gridMM).rounded() * gridMM }
    }

    public static func projection(of point: [Double], on segment: InteriorWallPlanSegment) -> [Double]? {
        guard point.count == 2, segment.a.count == 2, segment.b.count == 2 else { return nil }
        let dx = segment.b[0] - segment.a[0], dy = segment.b[1] - segment.a[1]
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.000_001 else { return nil }
        let t = max(0, min(1, ((point[0] - segment.a[0]) * dx + (point[1] - segment.a[1]) * dy) / lengthSquared))
        return [segment.a[0] + t * dx, segment.a[1] + t * dy]
    }

    /// Returns the index of the closest wall whose half thickness plus a small
    /// touch tolerance contains the point.
    public static func hitTest(
        _ point: [Double],
        segments: [InteriorWallPlanSegment],
        minimumToleranceMM: Double = 220
    ) -> Int? {
        guard point.count == 2, point.allSatisfy(\.isFinite) else { return nil }
        var best: (index: Int, distance: Double)?
        for (index, segment) in segments.enumerated() {
            guard let projection = projection(of: point, on: segment) else { continue }
            let distance = hypot(projection[0] - point[0], projection[1] - point[1])
            let tolerance = max(minimumToleranceMM, segment.thicknessMM / 2)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    public static func movedEndpoint(
        _ segment: InteriorWallPlanSegment,
        end: InteriorWallEndpoint,
        to point: [Double]
    ) -> ([Double], [Double])? {
        guard point.count == 2, point.allSatisfy(\.isFinite) else { return nil }
        let a = end == .start ? point : segment.a
        let b = end == .start ? segment.b : point
        guard a.count == 2, b.count == 2 else { return nil }
        let length = hypot(b[0] - a[0], b[1] - a[1])
        guard length >= 1, length <= 1_000_000 else { return nil }
        return (a, b)
    }

    /// Unit left normal for the authored direction a→b.
    public static func leftNormal(_ segment: InteriorWallPlanSegment) -> [Double]? {
        let length = segment.lengthMM
        guard length.isFinite, length > 0.000_001 else { return nil }
        let dx = (segment.b[0] - segment.a[0]) / length
        let dy = (segment.b[1] - segment.a[1]) / length
        return [-dy, dx]
    }

    public static func offsetSegment(_ segment: InteriorWallPlanSegment, by offsetMM: Double) -> InteriorWallPlanSegment? {
        guard let normal = leftNormal(segment) else { return nil }
        return InteriorWallPlanSegment(
            a: [segment.a[0] + normal[0] * offsetMM, segment.a[1] + normal[1] * offsetMM],
            b: [segment.b[0] + normal[0] * offsetMM, segment.b[1] + normal[1] * offsetMM],
            thicknessMM: segment.thicknessMM
        )
    }

    /// Move the chain's first/last point while preserving a sensible 50 mm
    /// snap. Kept as a helper so UI and tests share one rule.
    public static func chainPoint(_ point: [Double], gridMM: Double = 50) -> [Double] {
        guard point.count == 2, point.allSatisfy(\.isFinite) else { return [0, 0] }
        return point.map { ($0 / gridMM).rounded() * gridMM }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
