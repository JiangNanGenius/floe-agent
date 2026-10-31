import CoreGraphics
import Foundation

/// Deterministic screen-space collision resolution for sketch dimension
/// badges.
///
/// The overlay projects every badge from world geometry, so two dimensions that
/// annotate the same arc/circle share one anchor exactly. Actual83 drew R25 mm
/// and R40 mm on top of each other and the pair read like "R2405mm". This type
/// moves only badge CENTERS: world anchors, dimension values, solver state,
/// leader endpoints and undo are untouched.
///
/// Placement is order-preserving and deterministic: badges are considered in
/// the document's label order (never sorted by UUID). A badge whose default
/// frame is clear keeps exactly the projected center. A colliding badge moves
/// by the smallest distance that clears both the already placed badges' touch
/// frames and their rotated text ink. Authored/dragged badges (`isFixed`) never
/// move; automatic badges avoid them.
enum SketchBadgeCollisionLayout {
    struct Item {
        /// Stable label identity; only used to key the result.
        let id: String
        /// The projected, un-displaced badge center.
        let center: CGPoint
        /// Axis-aligned frame SwiftUI positions. This is also the frame UIKit
        /// exposes to accessibility/hit testing and XCUITest reads.
        let hitSize: CGSize
        /// Unrotated ink extent of the visible badge (text plus its own
        /// padding). `rotation` turns it into the on-screen text rectangle.
        let inkSize: CGSize
        /// Ink rotation in radians. Zero for unrotated caption badges.
        let rotation: Double
        /// Authored/dragged placement: keep it, and make others avoid it.
        let isFixed: Bool
    }

    struct Placement {
        let center: CGPoint
        let isDisplaced: Bool
    }

    /// Clear space required between two touch frames and between two rotated
    /// text inks.
    static let gap: CGFloat = 6
    /// Search resolution. Bounded: 23 distances x 6 directions per axis set.
    static let step: CGFloat = 8
    static let minimumDistance: CGFloat = 44
    static let maximumDistance: CGFloat = 220

    static func placements(for items: [Item], in bounds: CGRect) -> [String: Placement] {
        var placed: [(item: Item, center: CGPoint)] = []
        var result: [String: Placement] = [:]

        // Manual placements are anchors, not candidates: they keep their
        // authored center even when another manual badge overlaps them.
        for item in items where item.isFixed {
            result[item.id] = Placement(center: item.center, isDisplaced: false)
            placed.append((item, item.center))
        }

        for item in items where !item.isFixed {
            if !placed.contains(where: {
                collides(item, at: item.center, with: $0.item, at: $0.center)
            }) {
                result[item.id] = Placement(center: item.center, isDisplaced: false)
                placed.append((item, item.center))
                continue
            }
            let center = bestPlacement(for: item, avoiding: placed, in: bounds)
            result[item.id] = Placement(center: center, isDisplaced: center != item.center)
            placed.append((item, center))
        }
        return result
    }

    /// True when two badges would draw or tap into each other. Internal so the
    /// source-only layout tests assert the same predicate the overlay uses.
    static func collides(_ first: Item, at firstCenter: CGPoint,
                         with second: Item, at secondCenter: CGPoint) -> Bool {
        let firstHit = hitRect(first, at: firstCenter).insetBy(dx: -gap / 2, dy: -gap / 2)
        let secondHit = hitRect(second, at: secondCenter).insetBy(dx: -gap / 2, dy: -gap / 2)
        if firstHit.intersects(secondHit) { return true }
        return inkOverlaps(first, at: firstCenter, second, at: secondCenter, padding: gap)
    }

    // MARK: - Search

    private static func bestPlacement(for item: Item,
                                      avoiding placed: [(item: Item, center: CGPoint)],
                                      in bounds: CGRect) -> CGPoint {
        let normal = item.rotation - .pi / 2
        // Prefer the badge's own normal, then the other normal, then vertical
        // and horizontal. The distance loop is outside the direction loop, so
        // the closest clear position wins regardless of direction.
        let angles: [Double] = [normal, normal + .pi, .pi / 2, -.pi / 2, 0, .pi]
        var best = item.center
        var bestCost = cost(item, at: item.center, avoiding: placed, in: bounds)
        var distance = minimumDistance
        while distance <= maximumDistance {
            for angle in angles {
                let candidate = CGPoint(
                    x: item.center.x + CGFloat(cos(angle)) * distance,
                    y: item.center.y + CGFloat(sin(angle)) * distance)
                guard !placed.contains(where: {
                    collides(item, at: candidate, with: $0.item, at: $0.center)
                }) else { continue }
                guard fits(item, at: candidate, in: bounds) else { continue }
                return candidate
            }
            distance += step
        }
        // No fully clear position exists (very narrow canvas, or an authored
        // obstacle dominates). Pick the least-bad candidate deterministically
        // rather than looping or stacking the badge exactly on top.
        distance = minimumDistance
        while distance <= maximumDistance {
            for angle in angles {
                let candidate = CGPoint(
                    x: item.center.x + CGFloat(cos(angle)) * distance,
                    y: item.center.y + CGFloat(sin(angle)) * distance)
                let candidateCost = cost(item, at: candidate, avoiding: placed, in: bounds)
                if candidateCost < bestCost {
                    bestCost = candidateCost
                    best = candidate
                }
            }
            distance += step
        }
        return best
    }

    private static func fits(_ item: Item, at center: CGPoint, in bounds: CGRect) -> Bool {
        bounds.contains(hitRect(item, at: center)) && bounds.contains(inkBounds(item, at: center))
    }

    // MARK: - Geometry

    private static func hitRect(_ item: Item, at center: CGPoint) -> CGRect {
        CGRect(x: center.x - item.hitSize.width / 2,
               y: center.y - item.hitSize.height / 2,
               width: item.hitSize.width,
               height: item.hitSize.height)
    }

    /// Axis-aligned bounds of the rotated text ink.
    private static func inkBounds(_ item: Item, at center: CGPoint) -> CGRect {
        let c = abs(CGFloat(cos(item.rotation))), s = abs(CGFloat(sin(item.rotation)))
        let width = item.inkSize.width * c + item.inkSize.height * s
        let height = item.inkSize.width * s + item.inkSize.height * c
        return CGRect(x: center.x - width / 2, y: center.y - height / 2,
                      width: width, height: height)
    }

    /// Separating-axis test for the two rotated text rectangles.
    private static func inkOverlaps(_ a: Item, at aCenter: CGPoint,
                                    _ b: Item, at bCenter: CGPoint,
                                    padding: CGFloat) -> Bool {
        let ax = CGPoint(x: CGFloat(cos(a.rotation)), y: CGFloat(sin(a.rotation)))
        let ay = CGPoint(x: -ax.y, y: ax.x)
        let bx = CGPoint(x: CGFloat(cos(b.rotation)), y: CGFloat(sin(b.rotation)))
        let by = CGPoint(x: -bx.y, y: bx.x)
        let dx = bCenter.x - aCenter.x, dy = bCenter.y - aCenter.y
        for axis in [ax, ay, bx, by] {
            let distance = abs(dx * axis.x + dy * axis.y)
            let firstHalf = a.inkSize.width / 2 * abs(ax.x * axis.x + ax.y * axis.y)
                + a.inkSize.height / 2 * abs(ay.x * axis.x + ay.y * axis.y)
            let secondHalf = b.inkSize.width / 2 * abs(bx.x * axis.x + bx.y * axis.y)
                + b.inkSize.height / 2 * abs(by.x * axis.x + by.y * axis.y)
            if distance > firstHalf + secondHalf + padding { return false }
        }
        return true
    }

    // MARK: - Fallback cost

    private static func cost(_ item: Item, at center: CGPoint,
                             avoiding placed: [(item: Item, center: CGPoint)],
                             in bounds: CGRect) -> CGFloat {
        let hit = hitRect(item, at: center).insetBy(dx: -gap / 2, dy: -gap / 2)
        let ink = inkBounds(item, at: center).insetBy(dx: -gap / 2, dy: -gap / 2)
        var total = outsideArea(hit, bounds) + outsideArea(ink, bounds)
        for other in placed {
            let otherHit = hitRect(other.item, at: other.center)
                .insetBy(dx: -gap / 2, dy: -gap / 2)
            let otherInk = inkBounds(other.item, at: other.center)
                .insetBy(dx: -gap / 2, dy: -gap / 2)
            total += area(hit.intersection(otherHit))
            total += area(ink.intersection(otherInk))
        }
        return total
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isInfinite else { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }

    private static func outsideArea(_ rect: CGRect, _ bounds: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isInfinite else { return 0 }
        return max(0, area(rect) - area(rect.intersection(bounds)))
    }
}
