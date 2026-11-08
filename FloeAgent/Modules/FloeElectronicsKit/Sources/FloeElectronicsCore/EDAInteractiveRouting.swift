// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDARouteAnchor: Hashable, Sendable {
    public let netID: String
    public let position: EDAPoint
    public let objectID: UUID
}

/// Manual 45-degree routing. Uses the actual touched copper and supported DRC
/// checks; this is not an automatic or shove router.
public enum EDAInteractiveRouting {
    public static func anchor(_ project: EDAProject, boardID: UUID, at point: EDAPoint,
                              layer: String, tolerance: Double = 0.6) throws -> EDARouteAnchor? {
        guard point.isValid, tolerance.isFinite, tolerance >= 0, tolerance <= 5,
              let board = project.boards.first(where: { $0.id == boardID }),
              board.layers.contains(where: { $0.id == layer && $0.kind == .copper }) else {
            throw EDAError.invalid("routing position or copper layer")
        }
        let budget = EDADRCBudget(cancelled: { false })
        let cursor = EDADRCShape(outer: .capsule(point, point, 0))
        var candidates: [(EDARouteAnchor, Double)] = []
        func add(net: String?, at position: EDAPoint, id: UUID, distance: Double) {
            guard let net, !net.isEmpty, distance <= tolerance else { return }
            candidates.append((.init(netID: net, position: position, objectID: id), distance))
        }
        for footprint in board.footprints {
            guard let definition = project.footprints.first(where: { $0.id == footprint.definitionID }) else { continue }
            for pad in definition.pads {
                let layers = pad.layers.map { raw in
                    footprint.side == "B.Cu" ? (raw == "F.Cu" ? "B.Cu" : raw == "B.Cu" ? "F.Cu" : raw) : raw
                }
                guard layers.contains(layer), let shape = EDADRCGeometry.pad(pad, in: footprint) else { continue }
                let distance = try EDADRCGeometry.distance(cursor, shape, budget: budget).distance
                add(net: footprint.padNets[pad.number], at: footprint.point(pad.position), id: footprint.id, distance: distance)
            }
        }
        for track in board.tracks where track.layer == layer {
            for (a, b) in zip(track.points, track.points.dropFirst()) {
                let p = EDADRCGeometry.projection(point, a, b)
                add(net: track.netID, at: p, id: track.id, distance: max(0, p.distance(to: point) - track.width / 2))
            }
        }
        let copper = board.layers.filter { $0.kind == .copper }.map(\.id)
        if let selected = copper.firstIndex(of: layer) {
            for via in board.vias {
                guard let a = copper.firstIndex(of: via.startLayer), let b = copper.firstIndex(of: via.endLayer),
                      (min(a, b)...max(a, b)).contains(selected) else { continue }
                add(net: via.netID, at: via.position, id: via.id,
                    distance: max(0, via.position.distance(to: point) - via.diameter / 2))
            }
        }
        let ordered = candidates.sorted { $0.1 < $1.1 }
        guard let first = ordered.first else { return nil }
        if ordered.dropFirst().contains(where: { $0.0.netID != first.0.netID && abs($0.1 - first.1) <= EDAGeometry.tolerance }) {
            throw EDAError.invalid("more than one copper net at routing position")
        }
        return first.0
    }

    public static func track(_ project: EDAProject, boardID: UUID, from point: EDAPoint,
                             to target: EDAPoint, layer: String, width: Double,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws -> EDATrack {
        guard !cancelled() else { throw EDAError.cancelled }
        guard width.isFinite, width > 0, width <= 100, target.isValid,
              let start = try anchor(project, boardID: boardID, at: point, layer: layer) else {
            throw EDAError.invalid("start routing on a connected pad, track or via")
        }
        let end = try anchor(project, boardID: boardID, at: target, layer: layer)
        if let end, end.netID != start.netID { throw EDAError.invalid("routing would join different nets") }
        let finish = end?.position ?? target
        guard start.position.distance(to: finish) > EDAGeometry.tolerance else { throw EDAError.invalid("route has zero length") }
        let delta = finish - start.position, diagonal = min(abs(delta.x), abs(delta.y))
        let elbow = start.position + EDAPoint(delta.x < 0 ? -diagonal : diagonal, delta.y < 0 ? -diagonal : diagonal)
        var points = [start.position]
        if elbow.distance(to: start.position) > EDAGeometry.tolerance && elbow.distance(to: finish) > EDAGeometry.tolerance { points.append(elbow) }
        points.append(finish)
        let track = EDATrack(netID: start.netID, layer: layer, width: width, points: points)
        var candidate = project
        guard let index = candidate.boards.firstIndex(where: { $0.id == boardID }) else { throw EDAError.missing("board") }
        candidate.boards[index].tracks.append(track)
        let report = try EDADRC.check(candidate, boardID: boardID, cancelled: cancelled)
        if let issue = report.issues.first(where: { $0.severity == .error && $0.rule != .unconnectedNet && $0.objects.contains(where: { $0.objectID == track.id }) }) {
            throw EDAError.invalid("route violates " + issue.rule.rawValue + ": " + issue.code)
        }
        return track
    }
}
