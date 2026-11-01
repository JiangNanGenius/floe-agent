//
//  FloeCADDocument+ViewOverlay.swift
//  FloeCADKit
//
//  X22 document authority for the persisted section cut and measurement
//  guides. Everything rides in the SAME additive `sceneSettings` record used
//  by environment, saved cameras and the historical scene camera, so undo,
//  autosave, revision pinning, read-only gating and save/reopen keep their
//  existing rules. There is no second display store and no new document type.
//

import Foundation
import simd

// MARK: - Errors

public nonisolated enum CADViewOverlayError: Error, LocalizedError,
                                                     Sendable, Equatable {
    case readOnly
    case closed
    case blocked(String)
    case encodeFailed
    case limitReached(Int)
    case invalidMeasurement

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "This document is read-only; its section and measurement guides cannot be changed."
        case .closed:
            return "This document is closed; reopen it before changing the section or measurement guides."
        case .blocked(let message):
            return message
        case .encodeFailed:
            return "The section and measurement settings could not be encoded; nothing changed."
        case .limitReached(let maximum):
            return "This document already has the maximum of \(maximum) measurement guides."
        case .invalidMeasurement:
            return "A measurement needs two finite, distinct points."
        }
    }
}

// MARK: - Codec

/// Encode/decode the overlay inside `sceneSettings` without disturbing any
/// camera, appearance or legacy field the document already carries.
nonisolated enum CADViewOverlayCodec {
    static func decode(_ data: Data?) -> CADViewOverlayState {
        guard let data,
              let settings = try? JSONDecoder().decode(CADSceneSettings.self, from: data) else {
            return .empty
        }
        return (settings.viewOverlay ?? .empty).sanitized
    }

    static func settings(_ data: Data?) -> CADSceneSettings {
        guard let data,
              let settings = try? JSONDecoder().decode(CADSceneSettings.self, from: data) else {
            return CADSceneSettings()
        }
        return settings
    }

    /// Settings bytes with `overlay` applied. Nil only when encoding fails.
    /// An empty overlay removes the key again so an ordinary document carries
    /// no view-only overlay (the settings schema may advance once).
    static func settingsData(_ data: Data?, applying overlay: CADViewOverlayState) -> Data? {
        var settings = settings(data)
        let clean = overlay.sanitized
        settings.viewOverlay = clean.isEmpty ? nil : clean
        settings.schemaVersion = max(settings.schemaVersion,
                                     CADSceneSettings.currentSchemaVersion)
        return try? JSONEncoder().encode(settings)
    }

    static func settingsData(_ data: Data?,
                             updating: (inout CADViewOverlayState) -> Void) -> Data? {
        var overlay = decode(data)
        updating(&overlay)
        return settingsData(data, applying: overlay)
    }
}

// MARK: - Document API

@MainActor
public extension FloeCADDocument {
    /// The persisted overlay. Invalid/absent records read as `.empty`; they
    /// never fail opening or silently move a section.
    var viewOverlayState: CADViewOverlayState {
        CADViewOverlayCodec.decode(session.document.sceneSettingsData)
    }

    /// Replace the whole overlay as ONE undoable document edit. Returns false
    /// for a read-only/blocked document or an unencodable value; an unchanged
    /// value returns true without pushing an empty history entry.
    @discardableResult
    func applyViewOverlay(_ overlay: CADViewOverlayState) -> Bool {
        guard !isClosed, !isReadOnly, session.writeBlock == nil else { return false }
        // Clearing an already-empty overlay must not push a schema-only undo
        // boundary onto an ordinary document.
        let clean = overlay.sanitized
        if clean.isEmpty, viewOverlayState.isEmpty { return true }
        let before = session.document.sceneSettingsData
        guard let after = CADViewOverlayCodec.settingsData(before, applying: overlay) else {
            return false
        }
        guard after != before else { return true }
        session.perform(SetSceneSettingsDataCommand(before: before, after: after))
        return session.document.sceneSettingsData == after
    }

    /// Persist one section plane (or clear it with nil).
    @discardableResult
    func setSectionView(_ section: CADSectionView?) -> Bool {
        applyViewOverlayMutation { $0.section = section }
    }

    /// Show/hide the authored section without deleting its plane.
    @discardableResult
    func setSectionEnabled(_ enabled: Bool) -> Bool {
        guard var current = viewOverlayState.section else { return false }
        current.enabled = enabled
        return applyViewOverlayMutation { $0.section = current }
    }

    /// Flip which side of the authored section stays visible.
    @discardableResult
    func flipSectionView() -> Bool {
        guard let current = viewOverlayState.section else { return false }
        var copy = current
        copy.flipped.toggle()
        return applyViewOverlayMutation { $0.section = copy }
    }

    /// Remove the section entirely (its plane is not retained).
    @discardableResult
    func removeSectionView() -> Bool {
        applyViewOverlayMutation { $0.section = nil }
    }

    @discardableResult
    func setMeasurementGuidesVisible(_ visible: Bool) -> Bool {
        guard viewOverlayState.showsMeasurements != visible else { return true }
        return applyViewOverlayMutation { $0.showsMeasurements = visible }
    }

    /// Save the current measure tool's two picked points as one annotation.
    /// The caller owns the points; this API only validates/commits them.
    @discardableResult
    func addMeasurementAnnotation(from start: SIMD3<Double>,
                                  to end: SIMD3<Double>) throws -> CADMeasurementAnnotation {
        try addMeasurementAnnotation(CADMeasurementAnnotation(start: start, end: end))
    }

    /// Save one annotation (id and creation time preserved). Refuses before
    /// mutation when the document is read-only, the point data is invalid or
    /// the bounded list is full.
    @discardableResult
    func addMeasurementAnnotation(_ annotation: CADMeasurementAnnotation) throws
    -> CADMeasurementAnnotation {
        if isClosed { throw CADViewOverlayError.closed }
        if isReadOnly { throw CADViewOverlayError.readOnly }
        if let block = session.writeBlock { throw CADViewOverlayError.blocked(block.message) }
        guard let clean = annotation.sanitized else {
            throw CADViewOverlayError.invalidMeasurement
        }
        var overlay = viewOverlayState
        guard overlay.measurements.count < CADMeasurementAnnotation.maximumCount else {
            throw CADViewOverlayError.limitReached(CADMeasurementAnnotation.maximumCount)
        }
        guard !overlay.measurements.contains(where: { $0.id == clean.id }) else {
            return clean
        }
        overlay.measurements.append(clean)
        overlay.showsMeasurements = true
        guard applyViewOverlay(overlay) else {
            if isClosed { throw CADViewOverlayError.closed }
            if isReadOnly { throw CADViewOverlayError.readOnly }
            if let block = session.writeBlock {
                throw CADViewOverlayError.blocked(block.message)
            }
            throw CADViewOverlayError.encodeFailed
        }
        return clean
    }

    /// Delete exactly one saved guide. Missing ids are a no-op success.
    @discardableResult
    func removeMeasurementAnnotation(id: UUID) -> Bool {
        guard viewOverlayState.measurements.contains(where: { $0.id == id }) else {
            return true
        }
        return applyViewOverlayMutation { overlay in
            overlay.measurements.removeAll { $0.id == id }
        }
    }

    @discardableResult
    func clearMeasurementAnnotations() -> Bool {
        guard !viewOverlayState.measurements.isEmpty else { return true }
        return applyViewOverlayMutation { $0.measurements.removeAll() }
    }

    /// Bounded JSON for `query kind=scene` and the assistant. Reads only.
    func viewOverlaySummaryJSON() -> [String: Any] {
        viewOverlayState.summaryJSON
    }
}

// MARK: - Helpers

@MainActor
private extension FloeCADDocument {
    @discardableResult
    func applyViewOverlayMutation(_ update: (inout CADViewOverlayState) -> Void) -> Bool {
        if isClosed || isReadOnly { return false }
        if session.writeBlock != nil { return false }
        let before = session.document.sceneSettingsData
        guard let after = CADViewOverlayCodec.settingsData(before, updating: update) else {
            return false
        }
        guard after != before else { return true }
        session.perform(SetSceneSettingsDataCommand(before: before, after: after))
        return session.document.sceneSettingsData == after
    }
}
