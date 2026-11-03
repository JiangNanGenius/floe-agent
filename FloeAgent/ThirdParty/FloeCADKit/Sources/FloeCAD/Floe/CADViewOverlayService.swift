//
//  CADViewOverlayService.swift
//  FloeCADKit
//
//  X22-R2 — the model/agent surface for the persisted section cut and saved
//  measurement guides. This is NOT a second scene or permission system: every
//  mutation calls the existing `FloeCADDocument+ViewOverlay` API, which writes
//  the ONE additive `sceneSettings` record through
//  `SetSceneSettingsDataCommand`. Revision, read-only/closed ownership, undo
//  and save/CAS therefore remain the document's existing rules.
//
//  The `cad.document` tool exposes this service as its existing `scene`
//  action. The tool, not this service, supplies the call's task authority.
//

import Foundation
import CoreFoundation
import simd

@MainActor
public final class CADViewOverlayService {
    public static let actions: [String] = [
        "get", "setSection", "setSectionEnabled", "flipSection",
        "removeSection", "setMeasurementsVisible", "addMeasurement",
        "removeMeasurement", "clearMeasurements", "undo", "redo",
    ] + CADSceneObjectService.reads.sorted() + CADSceneObjectService.mutations.sorted()

    /// Actions that write the document. `get` and the no-op success paths are
    /// read-only. Kept here so the host/tool can pre-classify without parsing
    /// the service implementation.
    public static let mutationActions: Set<String> = Set([
        "setSection", "setSectionEnabled", "flipSection", "removeSection",
        "setMeasurementsVisible", "addMeasurement", "removeMeasurement",
        "clearMeasurements", "undo", "redo",
    ]).union(CADSceneObjectService.mutations)

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    // MARK: - Router

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        guard !document.isClosed else {
            return Self.fail("document_closed",
                             "This document is closed; reopen it before changing "
                                + "the section or measurement guides.")
        }
        if let refusal = CADServiceOperations.readOnlyRefusal(
            document: document, kind: "scene", action: action) {
            return refusal
        }
        if let failure = revisionPinFailure(args) { return failure }
        if CADSceneObjectService.reads.contains(action) || CADSceneObjectService.mutations.contains(action) {
            return CADSceneObjectService(document: document).handle(action: action, args: args)
        }
        switch action {
        case "get": return get(args)
        case "setSection": return setSection(args)
        case "setSectionEnabled": return setSectionEnabled(args)
        case "flipSection": return flipSection(args)
        case "removeSection": return removeSection(args)
        case "setMeasurementsVisible": return setMeasurementsVisible(args)
        case "addMeasurement": return addMeasurement(args)
        case "removeMeasurement": return removeMeasurement(args)
        case "clearMeasurements": return clearMeasurements(args)
        case "undo": return undo(args)
        case "redo": return redo(args)
        default:
            return Self.fail(
                "unknown_action",
                "Unknown scene action '\(action)'. Use "
                    + Self.actions.joined(separator: ", ") + ".")
        }
    }

    /// Optional revision pin. EVERY supplied `revision`/`expected_revision`
    /// is validated with the same strict rule as `CADDatumService.integer`:
    /// finite, integral, non-boolean, in range. A fractional pin must never be
    /// truncated onto the real revision, and a second contradictory pin must
    /// not be silently ignored. `get` is read-only, but an invalid pin is
    /// still reported instead of being dropped.
    private func revisionPinFailure(_ args: [String: Any]) -> [String: Any]? {
        var pinned: Int64?
        for key in ["revision", "expected_revision"] where args[key] != nil {
            guard let raw = args[key], let value = Self.revisionPin(raw) else {
                return Self.fail(
                    "bad_revision",
                    "revision and expected_revision must be finite whole numbers; "
                        + "fractions, booleans and text that is not an integer are refused.")
            }
            if let pinned, pinned != value {
                return Self.fail(
                    "revision_mismatch",
                    "revision and expected_revision disagree (\(pinned) vs \(value)); "
                        + "re-read the document before changing its view overlay.")
            }
            pinned = value
        }
        guard let pinned else { return nil }
        guard pinned == Int64(document.revision) else {
            return Self.fail(
                "revision_mismatch",
                "The document is at revision \(document.revision), not the requested "
                    + "\(pinned). Re-read the document before changing its view overlay.")
        }
        return nil
    }

    /// Same acceptance rule as `CADDatumService.integer` (NSNumber first so a
    /// bridged `Bool` is recognized as CFBoolean, then an exact integer
    /// string). `NSNumber.int64Value` is never used to truncate a fraction.
    private static func revisionPin(_ value: Any) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(Int64.min),
                  number.doubleValue < Double(Int64.max) else { return nil }
            return number.int64Value
        }
        return (value as? String).flatMap { Int64($0) }
    }

    // MARK: - Reads

    private func get(_ args: [String: Any]) -> [String: Any] {
        let overlay = document.viewOverlayState
        return Self.ok([
            "action": "get",
            "view_overlay": overlay.summaryJSON,
            "section": overlay.activeSection?.summaryJSON ?? NSNull(),
            "measurement_count": overlay.measurements.count,
            "visible_measurement_count": overlay.visibleMeasurements.count,
            "has_view_only_content": overlay.hasViewOnlyContent,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
            "note": "Section and measurement guides are view-only. Raster/video outputs "
                + "include the cut and guide lines; numeric values are not baked into "
                + "the pixels. STEP/IGES/GLB/USDZ/OBJ/STL/3MF outputs contain model "
                + "geometry only.",
        ])
    }

    // MARK: - Mutations

    private func setSection(_ args: [String: Any]) -> [String: Any] {
        guard let origin = Self.vector(args["origin"] ?? args["origin_mm"]) else {
            return Self.fail("invalid_section",
                             "setSection requires origin [x,y,z] in model millimetres.")
        }
        var section: CADSectionView
        if let xAxis = Self.vector(args["x_axis"] ?? args["xAxis"]),
           let yAxis = Self.vector(args["y_axis"] ?? args["yAxis"]) {
            section = CADSectionView(origin: origin, xAxis: xAxis, yAxis: yAxis)
        } else if let normal = Self.vector(args["normal"] ?? args["normal_mm"]),
                  simd_length(normal) > 1e-9 {
            let n = simd_normalize(normal)
            // Stable tangent frame whose cross product is the requested
            // keep-normal; the cut semantics only depend on that normal.
            let pick: SIMD3<Double> = abs(n.x) < 0.9
                ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let x = simd_normalize(pick - simd_dot(pick, n) * n)
            let y = simd_normalize(simd_cross(n, x))
            section = CADSectionView(origin: origin, xAxis: x, yAxis: y)
        } else {
            return Self.fail(
                "invalid_section",
                "setSection requires either x_axis/y_axis or a non-zero normal.")
        }
        if let enabled = Self.bool(args["enabled"]) { section.enabled = enabled }
        if let flipped = Self.bool(args["flip"] ?? args["flipped"]) {
            section.flipped = flipped
        }
        if let size = Self.number(args["size_mm"] ?? args["size"]), size.isFinite {
            section.sizeMM = min(max(size, CADSectionView.minimumSizeMM),
                                 CADSectionView.maximumSizeMM)
        }
        guard section.sanitized != nil else {
            return Self.fail("invalid_section",
                             "The section frame is degenerate; supply a non-parallel x_axis/y_axis or a normal.")
        }
        let beforeChange = document.liveChangeCount
        guard document.setSectionView(section) else {
            return refusalForWriteFailure()
        }
        return mutationReply(action: "setSection", beforeChange: beforeChange)
    }

    private func setSectionEnabled(_ args: [String: Any]) -> [String: Any] {
        guard let enabled = Self.bool(args["enabled"]) else {
            return Self.fail("missing_enabled", "setSectionEnabled requires enabled:true|false.")
        }
        guard document.viewOverlayState.section != nil else {
            return Self.fail("no_section", "This document has no authored section.")
        }
        let beforeChange = document.liveChangeCount
        guard document.setSectionEnabled(enabled) else {
            return refusalForWriteFailure()
        }
        return mutationReply(action: "setSectionEnabled", beforeChange: beforeChange)
    }

    private func flipSection(_ args: [String: Any]) -> [String: Any] {
        guard document.viewOverlayState.section != nil else {
            return Self.fail("no_section", "This document has no authored section.")
        }
        let beforeChange = document.liveChangeCount
        guard document.flipSectionView() else {
            return refusalForWriteFailure()
        }
        return mutationReply(action: "flipSection", beforeChange: beforeChange)
    }

    private func removeSection(_ args: [String: Any]) -> [String: Any] {
        let beforeChange = document.liveChangeCount
        guard document.removeSectionView() else {
            return refusalForWriteFailure()
        }
        return mutationReply(action: "removeSection", beforeChange: beforeChange)
    }

    private func setMeasurementsVisible(_ args: [String: Any]) -> [String: Any] {
        guard let visible = Self.bool(args["visible"] ?? args["enabled"]) else {
            return Self.fail("missing_visible", "setMeasurementsVisible requires visible:true|false.")
        }
        let beforeChange = document.liveChangeCount
        guard document.setMeasurementGuidesVisible(visible) else {
            return refusalForWriteFailure()
        }
        return mutationReply(action: "setMeasurementsVisible", beforeChange: beforeChange)
    }

    private func addMeasurement(_ args: [String: Any]) -> [String: Any] {
        guard let start = Self.vector(args["start"] ?? args["start_mm"]),
              let end = Self.vector(args["end"] ?? args["end_mm"]) else {
            return Self.fail("invalid_measurement",
                             "addMeasurement requires start and end [x,y,z] in model millimetres.")
        }
        let beforeChange = document.liveChangeCount
        do {
            let annotation = try document.addMeasurementAnnotation(from: start, to: end)
            var reply = mutationReply(action: "addMeasurement",
                                      beforeChange: beforeChange)
            reply["measurement"] = annotation.summaryJSON
            return reply
        } catch let error as CADViewOverlayError {
            switch error {
            case .readOnly, .closed:
                return refusalForWriteFailure(error)
            case .limitReached(let maximum):
                return Self.fail("measurement_limit",
                                 "This document already has the maximum of \(maximum) measurement guides.")
            case .invalidMeasurement:
                return Self.fail("invalid_measurement",
                                 "A measurement needs two finite, distinct points.")
            case .blocked(let message):
                return Self.fail("document_blocked", message)
            case .encodeFailed:
                return Self.fail("encode_failed",
                                 "The measurement settings could not be encoded; nothing changed.")
            }
        } catch {
            return Self.fail("measurement_failed", error.localizedDescription)
        }
    }

    private func removeMeasurement(_ args: [String: Any]) -> [String: Any] {
        guard let raw = args["id"] as? String,
              let id = UUID(uuidString: raw) else {
            return Self.fail("missing_measurement_id",
                             "removeMeasurement requires id (UUID from get).")
        }
        let beforeChange = document.liveChangeCount
        guard document.removeMeasurementAnnotation(id: id) else {
            return refusalForWriteFailure()
        }
        return mutationReply(action: "removeMeasurement", beforeChange: beforeChange)
    }

    private func clearMeasurements(_ args: [String: Any]) -> [String: Any] {
        let beforeChange = document.liveChangeCount
        guard document.clearMeasurementAnnotations() else {
            return refusalForWriteFailure()
        }
        return mutationReply(action: "clearMeasurements", beforeChange: beforeChange)
    }

    private func undo(_ args: [String: Any]) -> [String: Any] {
        guard document.session.undoStack.canUndo else {
            return Self.fail("nothing_to_undo", "The document undo stack is empty.")
        }
        let beforeChange = document.liveChangeCount
        document.session.undo()
        return mutationReply(action: "undo", beforeChange: beforeChange)
    }

    private func redo(_ args: [String: Any]) -> [String: Any] {
        guard document.session.undoStack.canRedo else {
            return Self.fail("nothing_to_redo", "The document redo stack is empty.")
        }
        let beforeChange = document.liveChangeCount
        document.session.redo()
        return mutationReply(action: "redo", beforeChange: beforeChange)
    }

    // MARK: - Reply helpers

    private func mutationReply(action: String, beforeChange: Int) -> [String: Any] {
        let overlay = document.viewOverlayState
        return Self.ok([
            "action": action,
            "mutated": document.liveChangeCount != beforeChange,
            "view_overlay": overlay.summaryJSON,
            "section": overlay.activeSection?.summaryJSON ?? NSNull(),
            "measurement_count": overlay.measurements.count,
            "visible_measurement_count": overlay.visibleMeasurements.count,
            "has_view_only_content": overlay.hasViewOnlyContent,
            "revision": document.revision,
            "change_count": document.liveChangeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    private func refusalForWriteFailure(_ error: CADViewOverlayError? = nil) -> [String: Any] {
        if let error {
            switch error {
            case .closed:
                return Self.fail("document_closed",
                                 "This document is closed; reopen it before changing the overlay.")
            case .readOnly:
                return Self.fail("read_only",
                                 "This document is read-only; its section and measurement guides can't be changed.")
            case .blocked(let message):
                return Self.fail("document_blocked", message)
            default:
                break
            }
        }
        if document.isClosed {
            return Self.fail("document_closed",
                             "This document is closed; reopen it before changing the overlay.")
        }
        if document.isReadOnly {
            return Self.fail("read_only",
                             "This document is read-only; its section and measurement guides can't be changed.")
        }
        if let block = document.session.writeBlock {
            return Self.fail("document_blocked", block.message)
        }
        return Self.fail("overlay_not_applied",
                         "The overlay change was refused or did not change the document.")
    }

    private static func ok(_ object: [String: Any]) -> [String: Any] {
        var reply = object
        reply["ok"] = true
        return reply
    }

    private static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func vector(_ value: Any?) -> SIMD3<Double>? {
        let numbers: [Double]
        if let values = value as? [Double] {
            numbers = values
        } else if let values = value as? [NSNumber] {
            numbers = values.map(\.doubleValue)
        } else if let values = value as? [Any] {
            var parsed: [Double] = []
            for element in values {
                guard let number = number(element), number.isFinite else { return nil }
                parsed.append(number)
            }
            numbers = parsed
        } else {
            return nil
        }
        guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }
}
