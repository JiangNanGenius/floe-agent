//
//  FloeCADDocument+SavedCameras.swift
//  FloeCADKit
//
//  X21 document authority for named presentation cameras.
//
//  Saved cameras live in the SAME additive `sceneSettings` record used by the
//  environment and the historical single scene camera. Every mutation is one
//  undoable `SetSceneSettingsDataCommand`, so undo/redo, autosave, the normal
//  save/reopen path, revision pinning and the read-only gate remain the
//  document's existing rules. There is no second scene store: orbiting,
//  zooming, fitting or observing never writes; only an explicit save/update/
//  rename/delete/select changes the package.
//

import Foundation
import simd

// MARK: - Errors

public nonisolated enum CADCameraBookmarkError: Error, LocalizedError,
                                                       Sendable, Equatable {
    case readOnly
    case blocked(String)
    case emptyName
    case nameTooLong(Int)
    case duplicateName(String)
    case limitReached(Int)
    case notFound(UUID)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return FloeCADStrings.text(
                "cad.present.camera.error.readOnly",
                "This document is read-only; its views cannot be changed.")
        case .blocked(let message):
            return message
        case .emptyName:
            return FloeCADStrings.text(
                "cad.present.camera.error.name",
                "Enter a name for this view.")
        case .nameTooLong(let maximum):
            return FloeCADStrings.format(
                "cad.present.camera.error.nameTooLong",
                "Keep the name to %d characters or fewer.", maximum)
        case .duplicateName(let name):
            return FloeCADStrings.format(
                "cad.present.camera.error.duplicate",
                "A view named “%@” already exists.", name)
        case .limitReached(let maximum):
            return FloeCADStrings.format(
                "cad.present.camera.error.limit",
                "You can save up to %d views.", maximum)
        case .notFound:
            return FloeCADStrings.text(
                "cad.present.camera.error.notFound",
                "That saved view no longer exists.")
        case .invalidValue:
            return FloeCADStrings.text(
                "cad.present.camera.error.invalid",
                "This view has values that can’t be saved.")
        }
    }
}

// MARK: - Document authority

@MainActor
public extension FloeCADDocument {
    /// Valid saved views in authored order. A malformed entry is ignored on
    /// read; the next camera edit writes only the valid list.
    var savedCameras: [CADSavedCamera] { savedCameraState().saved }

    /// The selected saved view's id, or nil for the free view.
    var activeSavedCameraID: UUID? { savedCameraState().active?.id }

    /// The selected saved view, or nil when nothing is selected (or the id no
    /// longer resolves).
    var activeSavedCamera: CADSavedCamera? { savedCameraState().active }

    /// The projection the document currently presents. The active saved view
    /// wins; otherwise the historical scene camera's projection; otherwise
    /// perspective. Never reads a transient orbit.
    var effectiveCameraProjection: CADCameraProjection {
        if let active = activeSavedCamera { return active.projection }
        if cameraSceneSettings().camera?.isOrthographic == true {
            return .orthographic
        }
        return .perspective
    }

    /// The framing angle the active saved view uses, when one is selected.
    var effectiveCameraFovYDegrees: Double? {
        activeSavedCamera?.fovYDegrees
    }

    func savedCamera(named name: String) -> CADSavedCamera? {
        guard let normalized = CADSavedCamera.normalizedName(name)?.lowercased() else {
            return nil
        }
        return savedCameras.first { $0.name.lowercased() == normalized }
    }

    /// Persist the current view as a new named camera and select it. The name
    /// is trimmed/collapsed and must be unique (case-insensitive). Refuses a
    /// read-only document, a full list, an invalid pose and a duplicate name
    /// BEFORE any mutation.
    @discardableResult
    func saveCamera(_ camera: CADSavedCamera) throws -> CADSavedCamera {
        try requireCameraWritable()
        guard let clean = camera.sanitized else {
            throw CADCameraBookmarkError.invalidValue("pose")
        }
        let state = savedCameraState()
        guard state.saved.count < CADSavedCamera.maximumCount else {
            throw CADCameraBookmarkError.limitReached(CADSavedCamera.maximumCount)
        }
        guard !state.saved.contains(where: { $0.id == clean.id }) else {
            throw CADCameraBookmarkError.invalidValue("id")
        }
        guard !state.saved.contains(where: {
            $0.name.lowercased() == clean.name.lowercased()
        }) else {
            throw CADCameraBookmarkError.duplicateName(clean.name)
        }
        var settings = cameraSceneSettings()
        settings.savedCameras = state.saved + [clean]
        settings.activeCameraID = clean.id
        settings.schemaVersion = max(settings.schemaVersion,
                                     CADSceneSettings.currentSchemaVersion)
        try commitCameraSettings(settings)
        return clean
    }

    /// Replace one saved view's pose/projection/framing with the values the
    /// caller captured. The id, name and creation time stay; the selection is
    /// unchanged.
    @discardableResult
    func updateCamera(id: UUID, with camera: CADSavedCamera) throws -> CADSavedCamera {
        try requireCameraWritable()
        guard let clean = camera.sanitized else {
            throw CADCameraBookmarkError.invalidValue("pose")
        }
        let state = savedCameraState()
        guard let index = state.saved.firstIndex(where: { $0.id == id }) else {
            throw CADCameraBookmarkError.notFound(id)
        }
        var updated = clean
        updated.id = id
        updated.name = state.saved[index].name
        updated.createdAt = state.saved[index].createdAt
        var cameras = state.saved
        cameras[index] = updated
        var settings = cameraSceneSettings()
        settings.savedCameras = cameras
        try commitCameraSettings(settings)
        return updated
    }

    /// Rename one saved view. Duplicate names are refused; an empty or
    /// over-long name refuses instead of being truncated.
    @discardableResult
    func renameCamera(id: UUID, to name: String) throws -> CADSavedCamera {
        try requireCameraWritable()
        guard let normalized = CADSavedCamera.normalizedName(name) else {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CADCameraBookmarkError.emptyName
            }
            throw CADCameraBookmarkError.nameTooLong(CADSavedCamera.maximumNameLength)
        }
        let state = savedCameraState()
        guard let index = state.saved.firstIndex(where: { $0.id == id }) else {
            throw CADCameraBookmarkError.notFound(id)
        }
        guard !state.saved.contains(where: {
            $0.id != id && $0.name.lowercased() == normalized.lowercased()
        }) else {
            throw CADCameraBookmarkError.duplicateName(normalized)
        }
        var cameras = state.saved
        cameras[index].name = normalized
        var settings = cameraSceneSettings()
        settings.savedCameras = cameras
        try commitCameraSettings(settings)
        return cameras[index]
    }

    /// Delete one saved view. Deleting the selected view clears the selection;
    /// the live camera is not moved by this document edit.
    func deleteCamera(id: UUID) throws {
        try requireCameraWritable()
        let state = savedCameraState()
        guard state.saved.contains(where: { $0.id == id }) else {
            throw CADCameraBookmarkError.notFound(id)
        }
        var settings = cameraSceneSettings()
        settings.savedCameras = state.saved.filter { $0.id != id }
        if settings.activeCameraID == id { settings.activeCameraID = nil }
        try commitCameraSettings(settings)
    }

    /// Select a saved view (nil = free view). This is an undoable document
    /// edit so the choice survives save/reopen; it does not move the live
    /// camera by itself — the presentation applies the returned value.
    func selectCamera(id: UUID?) throws {
        try requireCameraWritable()
        let state = savedCameraState()
        if let id {
            guard state.saved.contains(where: { $0.id == id }) else {
                throw CADCameraBookmarkError.notFound(id)
            }
        }
        if state.active?.id == id { return }
        var settings = cameraSceneSettings()
        settings.activeCameraID = id
        try commitCameraSettings(settings)
    }

    /// Bounded camera state for `query kind=scene|camera` and assistant state.
    /// This is a read: it never selects, moves or saves a camera.
    func cameraSummaryJSON() -> [String: Any] {
        let state = savedCameraState()
        return [
            "count": state.saved.count,
            "active_id": state.active?.id.uuidString ?? "",
            "active_name": state.active?.name ?? "",
            "active_projection": state.active?.projection.rawValue ?? "",
            "saved": state.saved.map(\.summaryJSON),
            "note": "Saved views belong to this document. Selecting a view is "
                + "an undoable document edit; orbiting, panning, zooming or "
                + "fitting only changes the live view.",
        ]
    }
}

// MARK: - Shared read/write helpers

@MainActor
extension FloeCADDocument {
    /// Decode the current camera state once. Used by the document API, the
    /// scene snapshot and observation so every consumer reports the same
    /// selected projection.
    func savedCameraState() -> (saved: [CADSavedCamera],
                                active: CADSavedCamera?) {
        let settings = cameraSceneSettings()
        return (settings.cleanSavedCameras, settings.activeSavedCameraEntry)
    }

    func cameraSceneSettings() -> CADSceneSettings {
        session.document.sceneSettingsData.flatMap {
            try? JSONDecoder().decode(CADSceneSettings.self, from: $0)
        } ?? CADSceneSettings()
    }

    /// Read-only and write-block gate. Camera edits are ordinary document
    /// edits, so they obey the same authority as every other command.
    private func requireCameraWritable() throws {
        if isReadOnly { throw CADCameraBookmarkError.readOnly }
        if let block = session.writeBlock {
            throw CADCameraBookmarkError.blocked(block.message)
        }
    }

    /// One undoable scene-settings commit. The command is verified after it is
    /// performed: a refused perform (read-only/blocked race) never reports
    /// success.
    private func commitCameraSettings(_ settings: CADSceneSettings) throws {
        let before = session.document.sceneSettingsData
        guard let after = try? JSONEncoder().encode(settings) else {
            throw CADCameraBookmarkError.invalidValue("encode")
        }
        if after == before { return }
        session.perform(SetSceneSettingsDataCommand(before: before, after: after))
        guard session.document.sceneSettingsData == after else {
            if let failure = session.lastSceneObjectFailure { throw CADCameraBookmarkError.blocked(failure.localizedDescription) }
            throw CADCameraBookmarkError.readOnly
        }
    }
}
