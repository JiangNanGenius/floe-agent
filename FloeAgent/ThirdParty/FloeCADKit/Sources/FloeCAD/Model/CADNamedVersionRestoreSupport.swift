//
//  CADNamedVersionRestoreSupport.swift
//  FloeCADKit
//
//  In-memory rollback value for a named-version restore. A restore replaces
//  the persisted record graph and reloads the live document; if the commit is
//  refused/raced/fails, this snapshot puts the EXACT previous record graph and
//  live document state back. The store's atomic commit keeps the package
//  untouched throughout a failed restore.
//

import Foundation

/// Complete value snapshot of the `Project` record graph. Rows are reference
/// types, but a restore never mutates an existing row in place before the
/// commit: it replaces the arrays, so retaining the old row objects is an
/// exact snapshot. `restore(into:)` re-attaches their weak project backrefs.
nonisolated struct CADProjectSnapshot {
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var thumbnail: Data?
    var bodies: [PersistedBody]
    var sketches: [PersistedSketch]
    var planes: [PersistedPlane]
    var axes: [PersistedAxis]
    var datumPoints: [PersistedDatumPoint]
    var images: [PersistedImage]
    var symbols: [PersistedSymbol]
    var features: [PersistedFeature]
    var variables: [PersistedVariable]
    var rollbackIndex: Int?
    var formatVersion: Int
    var hasOpaqueAssociations: Bool
    var hasNamedVersions: Bool
    var recoveryWarning: String?
    var folderID: UUID?
    var itemFoldersData: Data?
    var unitRaw: String?
    var tolerance: Double?
    var assemblyData: Data?
    var drawingsData: Data?
    var scriptsData: Data?
    var sceneSettingsData: Data?
    var materialsData: Data?
    var animationData: Data?

    @MainActor init(_ project: Project) {
        name = project.name
        createdAt = project.createdAt
        modifiedAt = project.modifiedAt
        thumbnail = project.thumbnail
        bodies = project.bodies
        sketches = project.sketches
        planes = project.planes
        axes = project.axes
        datumPoints = project.datumPoints
        images = project.images
        symbols = project.symbols
        features = project.features
        variables = project.variables
        rollbackIndex = project.rollbackIndex
        formatVersion = project.formatVersion
        hasOpaqueAssociations = project.hasOpaqueAssociations
        hasNamedVersions = project.hasNamedVersions
        recoveryWarning = project.recoveryWarning
        folderID = project.folderID
        itemFoldersData = project.itemFoldersData
        unitRaw = project.unitRaw
        tolerance = project.tolerance
        assemblyData = project.assemblyData
        drawingsData = project.drawingsData
        scriptsData = project.scriptsData
        sceneSettingsData = project.sceneSettingsData
        materialsData = project.materialsData
        animationData = project.animationData
    }

    @MainActor func restore(into project: Project) {
        project.name = name
        project.createdAt = createdAt
        project.modifiedAt = modifiedAt
        project.thumbnail = thumbnail
        project.bodies = bodies
        project.sketches = sketches
        project.planes = planes
        project.axes = axes
        project.datumPoints = datumPoints
        project.images = images
        project.symbols = symbols
        project.features = features
        project.variables = variables
        project.rollbackIndex = rollbackIndex
        project.formatVersion = formatVersion
        project.hasOpaqueAssociations = hasOpaqueAssociations
        project.hasNamedVersions = hasNamedVersions
        project.recoveryWarning = recoveryWarning
        project.folderID = folderID
        project.itemFoldersData = itemFoldersData
        project.unitRaw = unitRaw
        project.tolerance = tolerance
        project.assemblyData = assemblyData
        project.drawingsData = drawingsData
        project.scriptsData = scriptsData
        project.sceneSettingsData = sceneSettingsData
        project.materialsData = materialsData
        project.animationData = animationData
        for row in bodies { row.project = project }
        for row in sketches { row.project = project }
        for row in planes { row.project = project }
        for row in axes { row.project = project }
        for row in datumPoints { row.project = project }
        for row in images { row.project = project }
        for row in symbols { row.project = project }
        for row in features { row.project = project }
        for row in variables { row.project = project }
    }
}

extension Project {
    /// Replace every persisted value with another verified package's records.
    /// Only used on the main actor by a named-version restore after the target
    /// checkpoint has already been verified.
    func replaceContentsForNamedVersionRestore(with other: Project) {
        // The live package may already keep versions outside the checkpoint
        // payload; never clear that floor when replacing document content.
        let keepNamedVersions = hasNamedVersions || other.hasNamedVersions
        let keepRecoveryWarning = recoveryWarning ?? other.recoveryWarning
        name = other.name
        createdAt = other.createdAt
        modifiedAt = Date()
        thumbnail = other.thumbnail
        bodies = other.bodies
        sketches = other.sketches
        planes = other.planes
        axes = other.axes
        datumPoints = other.datumPoints
        images = other.images
        symbols = other.symbols
        features = other.features
        variables = other.variables
        rollbackIndex = other.rollbackIndex
        formatVersion = other.formatVersion
        hasOpaqueAssociations = other.hasOpaqueAssociations
        hasNamedVersions = keepNamedVersions
        recoveryWarning = keepRecoveryWarning
        folderID = other.folderID
        itemFoldersData = other.itemFoldersData
        unitRaw = other.unitRaw
        tolerance = other.tolerance
        assemblyData = other.assemblyData
        drawingsData = other.drawingsData
        scriptsData = other.scriptsData
        sceneSettingsData = other.sceneSettingsData
        materialsData = other.materialsData
        animationData = other.animationData
        for row in bodies { row.project = self }
        for row in sketches { row.project = self }
        for row in planes { row.project = self }
        for row in axes { row.project = self }
        for row in datumPoints { row.project = self }
        for row in images { row.project = self }
        for row in symbols { row.project = self }
        for row in features { row.project = self }
        for row in variables { row.project = self }
    }
}
