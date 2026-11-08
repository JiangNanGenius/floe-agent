// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// Display bounds only, never a copper contour or a design-rule approximation.
public struct EDAViewBounds: Hashable, Sendable {
    public var min: EDAPoint
    public var max: EDAPoint
    public init(min: EDAPoint, max: EDAPoint) { self.min = min; self.max = max }
    public init(_ rect: CGRect) { min = .init(rect.minX, rect.minY); max = .init(rect.maxX, rect.maxY) }
    public var rect: CGRect { .init(x: min.x, y: min.y, width: max.x - min.x, height: max.y - min.y) }
    public var center: EDAPoint { (min + max) * 0.5 }
    public var isValid: Bool {
        [min.x, min.y, max.x, max.y].allSatisfy(\.isFinite) && max.x > min.x && max.y > min.y
    }
}

/// Session-only display state. It is not serialized into the engineering original.
public struct EDACanvasViewport: Hashable, Sendable {
    public var bounds: EDAViewBounds
    public var center: EDAPoint
    public var zoom: Double
    public init(bounds: EDAViewBounds, center: EDAPoint, zoom: Double) {
        self.bounds = bounds; self.center = center; self.zoom = zoom
    }
    public var isValid: Bool {
        bounds.isValid && center.x.isFinite && center.y.isFinite && zoom.isFinite && (0.05...50).contains(zoom)
    }
}

public enum EDACrossProbeError: Error, Hashable, Sendable {
    case selectOneComponent, noComponentLink, componentMissing, notSynchronized, noCounterpart
    case unknownVariant, excludedVariant, chooseTarget, invalidTarget, sourceChanged, ownerChanged
    case selectionChanged, noReturnPoint, tooManyTargets, geometryBudget

    public var message: String {
        switch self {
        case .selectOneComponent: edText("请先选择一个元件。", "Select one component first.")
        case .noComponentLink: edText("此封装没有关联的原理图元件。", "This footprint has no linked schematic component.")
        case .componentMissing: edText("关联的元件已不存在，请检查同步状态。", "The linked component is missing. Review synchronization.")
        case .notSynchronized: edText("封装分配尚未同步，请先从原理图更新 PCB。", "The footprint assignment is not synchronized. Update PCB from schematic first.")
        case .noCounterpart: edText("未找到对应实例，请检查图页或 PCB 同步状态。", "No corresponding instance was found. Review the sheets or PCB synchronization.")
        case .unknownVariant: edText("未找到指定的设计变体。", "The requested design variant was not found.")
        case .excludedVariant: edText("此元件不在所选设计变体中。", "This component is excluded from the selected variant.")
        case .chooseTarget: edText("找到多个对应实例，请选择要定位的目标。", "Multiple corresponding instances were found. Choose a target.")
        case .invalidTarget: edText("该目标不属于本次定位结果。", "That target is not part of this cross-probe result.")
        case .sourceChanged: edText("原件已改变，请重新选择元件后定位。", "The original changed. Select the component again before locating it.")
        case .ownerChanged: edText("原编辑会话已结束，请在当前工程重新定位。", "The original editing session ended. Locate the component in the current project.")
        case .selectionChanged: edText("选择已改变，请重新执行定位。", "The selection changed. Locate the component again.")
        case .tooManyTargets: edText("对应实例过多，本次无法定位。", "Too many corresponding instances to locate in one operation.")
        case .geometryBudget: edText("元件图形超出本次定位预算，未改变画面。", "The component drawing exceeds the cross-probe budget. The view was kept.")
        case .noReturnPoint: edText("没有可返回的定位位置。", "There is no cross-probe location to return to.")
        }
    }
}

public struct EDACrossProbeTarget: Hashable, Sendable, Identifiable {
    public let context: EDADocumentContext
    public let objectID: UUID
    public let componentID: UUID
    public let contextName: String
    public let reference: String
    public let unit: Int?
    public let bounds: EDAViewBounds
    public var id: String {
        switch context {
        case .schematic(let id): "sheet/\(id.uuidString)/\(objectID.uuidString)"
        case .board(let id): "board/\(id.uuidString)/\(objectID.uuidString)"
        default: "unsupported/\(objectID.uuidString)"
        }
    }
}

public struct EDACrossProbeResolution: Hashable, Sendable {
    public let projectID: UUID
    public let revision: UInt64
    public let componentID: UUID
    public let sourcePosition: EDAPoint
    /// nil means the unfiltered physical design, not an invented active variant.
    public let variant: String?
    public let excludedVariants: Set<String>
    public let targets: [EDACrossProbeTarget]
}

/// Immutable read-only navigation proposal. Only the creating session may adopt
/// it, and only while both its selection and saved original still match.
public struct EDACrossProbeRequest: Sendable, Identifiable {
    public let id = UUID()
    public let resolution: EDACrossProbeResolution
    let ownerID: UUID
    let source: EDAProject
    let digest: String
    let selection: EDASelection
}

struct EDACrossProbeReturn: Sendable {
    let id = UUID()
    let source: EDAProject
    let digest: String
    let selection: EDASelection
    let viewport: EDACanvasViewport?
    let position: EDAPoint
}

public enum EDACrossProbe {
    public static let maximumTargets = 1_000
    public static let maximumDisplayPoints = 200_000
    static func fittingViewport(_ bounds: EDAViewBounds, size: CGSize) -> EDACanvasViewport {
        // EDAProjection has a base-scale floor. Compensate through its existing
        // zoom input so even large valid geometry fits the actual canvas.
        let base = EDAProjection(bounds: bounds.rect, size: size).scale
        let desired = min(max(1, size.width - 40) / bounds.rect.width,
                          max(1, size.height - 40) / bounds.rect.height)
        return .init(bounds: bounds, center: bounds.center, zoom: max(0.05, min(1, desired / base)))
    }
    public static func isComponentSelection(_ project: EDAProject, selection: EDASelection) -> Bool {
        guard selection.objectIDs.count == 1, let id = selection.objectIDs.first else { return false }
        switch selection.context {
        case .schematic(let sheet): return project.sheets.first(where: { $0.id == sheet })?.symbols.contains(where: { $0.id == id }) == true
        case .board(let board): return project.boards.first(where: { $0.id == board })?.footprints.contains(where: { $0.id == id }) == true
        default: return false
        }
    }
    /// UUID identity is authoritative. Display references never establish a link.
    /// Every matching board instance or symbol unit is returned; no first-match
    /// fallback chooses a board, sheet, repeated placement, or unit.
    public static func resolve(_ project: EDAProject, selection: EDASelection,
                               variant: String? = nil) throws -> EDACrossProbeResolution {
        guard selection.objectIDs.count == 1, let id = selection.objectIDs.first else {
            throw EDACrossProbeError.selectOneComponent
        }
        let componentID: UUID
        let sourcePosition: EDAPoint
        let sourceFootprint: EDAFootprint?
        let toBoard: Bool
        switch selection.context {
        case .schematic(let sheetID):
            guard let sheet = project.sheets.first(where: { $0.id == sheetID }),
                  let symbol = sheet.symbols.first(where: { $0.id == id }) else {
                throw EDACrossProbeError.selectOneComponent
            }
            componentID = symbol.componentID; sourcePosition = symbol.position; sourceFootprint = nil; toBoard = true
        case .board(let boardID):
            guard let board = project.boards.first(where: { $0.id == boardID }),
                  let footprint = board.footprints.first(where: { $0.id == id }) else {
                throw EDACrossProbeError.selectOneComponent
            }
            guard let linked = footprint.componentID else { throw EDACrossProbeError.noComponentLink }
            componentID = linked; sourcePosition = footprint.position; sourceFootprint = footprint; toBoard = false
        default: throw EDACrossProbeError.selectOneComponent
        }
        guard let component = project.components.first(where: { $0.id == componentID }),
              let symbolDefinition = project.symbols.first(where: { $0.id == component.symbolID }) else {
            throw EDACrossProbeError.componentMissing
        }
        if let variant {
            guard project.variants.contains(variant) else { throw EDACrossProbeError.unknownVariant }
            guard !component.excludedVariants.contains(variant) else { throw EDACrossProbeError.excludedVariant }
        }
        guard let definitionID = component.footprintID,
              let footprintDefinition = project.footprints.first(where: { $0.id == definitionID }) else {
            throw EDACrossProbeError.notSynchronized
        }
        if let sourceFootprint, sourceFootprint.definitionID != definitionID {
            throw EDACrossProbeError.notSynchronized
        }
        let count = toBoard
            ? project.boards.reduce(0) { $0 + $1.footprints.filter { $0.componentID == componentID }.count }
            : project.sheets.reduce(0) { $0 + $1.symbols.filter { $0.componentID == componentID }.count }
        guard count <= maximumTargets else { throw EDACrossProbeError.tooManyTargets }
        let padPoints = footprintDefinition.pads.reduce(0) { $0 + ($1.shape == .polygon ? ($1.polygon?.count ?? 0) : 4) }
        let perTargetPoints = toBoard ? footprintDefinition.graphics.count * 4 + padPoints + 1
            : symbolDefinition.graphics.count * 4 + symbolDefinition.pins.count + 1
        guard perTargetPoints <= maximumDisplayPoints / max(1, count) else { throw EDACrossProbeError.geometryBudget }
        var targets: [EDACrossProbeTarget] = []
        if toBoard {
            for board in project.boards {
                for instance in board.footprints where instance.componentID == componentID {
                    guard instance.definitionID == definitionID else { throw EDACrossProbeError.notSynchronized }
                    var points = graphicExtent(footprintDefinition.graphics).map(instance.point)
                    for pad in footprintDefinition.pads {
                        if pad.shape == .polygon {
                            guard let vertices = EDAPolygonPadGeometry.vertices(pad,in:instance) else { throw EDACrossProbeError.sourceChanged }
                            points += vertices
                        } else {
                            let half = pad.size * 0.5
                            points += corners(min: half * -1, max: half).map {
                                instance.point($0.transformed(origin: pad.position, angle: pad.angle))
                            }
                        }
                    }
                    targets.append(.init(context: .board(boardID: board.id), objectID: instance.id,
                        componentID: componentID, contextName: board.name, reference: component.reference, unit: nil,
                        bounds: viewBounds(points + [instance.position])))
                }
            }
        } else {
            for sheet in project.sheets {
                for instance in sheet.symbols where instance.componentID == componentID {
                    let points = graphicExtent(symbolDefinition.graphics)
                        + symbolDefinition.pins.filter { $0.unit == 0 || $0.unit == instance.unit }.map(\.position)
                    let world = points.map { $0.transformed(origin: instance.position, angle: instance.angle, mirrored: instance.mirrored) }
                    targets.append(.init(context: .schematic(sheetID: sheet.id), objectID: instance.id,
                        componentID: componentID, contextName: sheet.name, reference: component.reference, unit: instance.unit,
                        bounds: viewBounds(world + [instance.position])))
                }
            }
        }
        guard !targets.isEmpty else { throw EDACrossProbeError.noCounterpart }
        return .init(projectID: project.id, revision: project.revision, componentID: componentID, sourcePosition: sourcePosition,
            variant: variant, excludedVariants: component.excludedVariants, targets: targets)
    }

    private static func corners(min a: EDAPoint, max b: EDAPoint) -> [EDAPoint] {
        [a, .init(b.x, a.y), b, .init(a.x, b.y)]
    }
    private static func viewBounds(_ points: [EDAPoint]) -> EDAViewBounds {
        let xs = points.map(\.x), ys = points.map(\.y)
        // A small neighbourhood keeps an empty definition or single pin visible.
        let lo = EDAPoint(xs.min() ?? 0, ys.min() ?? 0), hi = EDAPoint(xs.max() ?? 0, ys.max() ?? 0)
        let center = (lo + hi) * 0.5, half = EDAPoint(max(4, (hi.x - lo.x) * 0.7), max(4, (hi.y - lo.y) * 0.7))
        return .init(min: center - half, max: center + half)
    }
    private static func graphicExtent(_ graphics: [EDAGraphic]) -> [EDAPoint] {
        graphics.flatMap { graphic -> [EDAPoint] in
            switch graphic {
            case .line(let a, let b, let width), .rectangle(let a, let b, let width):
                return corners(min: .init(min(a.x, b.x) - width / 2, min(a.y, b.y) - width / 2),
                               max: .init(max(a.x, b.x) + width / 2, max(a.y, b.y) + width / 2))
            case .circle(let center, let radius, let width), .arc(let center, let radius, _, _, let width):
                let d = EDAPoint(radius + width / 2, radius + width / 2)
                return corners(min: center - d, max: center + d)
            case .dimension(let a, let b, let offset):
                let d = b - a, length = max(d.length, 0.001), normal = EDAPoint(-d.y / length, d.x / length) * offset
                return [a, b, a + normal, b + normal]
            case .text(_, let position, _, _): return [position]
            }
        }
    }
}
