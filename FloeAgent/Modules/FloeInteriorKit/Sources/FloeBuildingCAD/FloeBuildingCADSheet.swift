// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

// MARK: - Public sheet API

public extension FloeBuildingCADSession {
    /// Create the five-view front/top/side/section/iso cabinet combination
    /// page. When the project assembly contains any non-cabinet instance, the
    /// page is built in a verified, instance-scoped native snapshot instead of
    /// an unfiltered assembly page.
    func makeCombinationSheet(cabinet: FloeBuildingCADCabinetBinding,
                              options: FloeBuildingCADSheetOptions = .init()) async throws
        -> FloeBuildingCADSheetBinding {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let assembly = try CabinetBuilder.build(cabinet.recipe)
        try validateCabinetGeometry(cabinet, assembly: assembly)
        let extra = try extraAssemblyInstanceIDs(cabinet: cabinet)
        let existingSheet = manifest.sheet(cabinetID: cabinet.cabinetID)
        if extra.isEmpty {
            if existingSheet != nil {
                throw FloeBuildingCADError.duplicateBinding(
                    "a sheet already exists for cabinet \(cabinet.cabinetID.uuidString); refresh it instead.")
            }
            var detailSet = FloeBuildingCADSession.DetailSheetSet(sheets: [], files: [])
            if options.includeDetailSheets {
                try beginExclusiveOperation()
                do {
                    let sourceIdentity = try await ensureVerifiedSavedIdentity()
                    detailSet = try await makeDetailSheetSet(
                        cabinet: cabinet, assembly: assembly, options: options,
                        sourceIdentity: sourceIdentity, previous: [])
                } catch {
                    endExclusiveOperation()
                    throw error
                }
                endExclusiveOperation()
            }
            let builder = FloeBuildingCADSheetBuilder(
                document: document, cabinet: cabinet, assembly: assembly,
                options: options)
            do {
                return try await withMutationRollback { lease in
                    let page = try withOwnedWrite(lease) {
                        try builder.createNewPage(includeNotes: true, previousLayout: [:])
                    }
                    try testMutationCheckpoint("sheet.project.afterPage")
                    try lease.verifyOwnership()
                    let identity = try await saveUnlocked()
                    try lease.verifyOwnership()
                    let sheet = page.binding(
                        cabinet: cabinet, createdAt: identity, updatedAt: identity,
                        documentScope: "project", snapshotPath: nil,
                        sourceIdentity: nil, snapshotIdentity: nil,
                        excludedInstanceIDs: [],
                        sourceCabinetIdentity: cabinet.updatedAtIdentity,
                        manualNotes: options.manualNotes,
                        detailSheets: detailSet.sheets.isEmpty ? nil : detailSet.sheets)
                    putSheet(sheet)
                    return sheet
                }
            } catch {
                removeDetailFiles(detailSet.files)
                throw error
            }
        }
        if let existingSheet, existingSheet.documentScope != "project" {
            throw FloeBuildingCADError.duplicateBinding(
                "a verified snapshot sheet already exists for cabinet \(cabinet.cabinetID.uuidString).")
        }
        // Mixed project: capture a static, verified copy, remove every
        // non-cabinet assembly instance in the copy, then build the page with
        // only this cabinet's panel instances. The project is not mutated. If
        // an old project-scoped page exists, the manifest switches to this
        // snapshot page; the old page is left unreferenced for later cleanup.
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        let sourceIdentity = try await ensureVerifiedSavedIdentity()
        var effectiveOptions = options
        var migrated = MigratedAnnotations(migrated: [], orphaned: [])
        if let existingSheet {
            effectiveOptions.manualNotes = mergeManualNotes(
                existingSheet.manualNotes, options.manualNotes)
            migrated = captureAnnotations(in: document, sheet: existingSheet)
        }
        var detailSet = FloeBuildingCADSession.DetailSheetSet(sheets: [], files: [])
        var snapshot: FloeBuildingCADSheetBinding
        do {
            if effectiveOptions.includeDetailSheets {
                detailSet = try await makeDetailSheetSet(
                    cabinet: cabinet, assembly: assembly, options: effectiveOptions,
                    sourceIdentity: sourceIdentity, previous: [])
            }
            snapshot = try await makeSnapshotSheet(
                cabinet: cabinet, assembly: assembly, options: effectiveOptions,
                previousLayout: [:],
                migratedAnnotations: migrated.migrated,
                sourceIdentity: sourceIdentity)
        } catch {
            removeDetailFiles(detailSet.files)
            throw error
        }
        snapshot.annotationBindings.append(contentsOf: migrated.orphaned)
        snapshot.manualNotes = effectiveOptions.manualNotes
        snapshot.detailSheets = detailSet.sheets.isEmpty ? nil : detailSet.sheets
        putSheet(snapshot)
        return snapshot
    }

    private func mergeManualNotes(_ first: [CabinetManualSheetNote],
                                  _ second: [CabinetManualSheetNote])
        -> [CabinetManualSheetNote] {
        var seen = Set<UUID>()
        return (first + second).filter { seen.insert($0.id).inserted }
    }

    /// Refresh a page after a cabinet update. Project pages are edited in
    /// place. A verified snapshot is normally updated in the SAME document,
    /// preserving view/annotation ids; if that is unsafe, a new verified
    /// snapshot migrates ordinary unbound annotations by view role and keeps
    /// the old snapshot file. Manual dimension text positions/overrides and
    /// Core manual notes are carried across.
    internal func refreshCombinationSheetCore(cabinet: FloeBuildingCADCabinetBinding,
                                              sheet: FloeBuildingCADSheetBinding,
                                              manualNotes: [CabinetManualSheetNote]? = nil) async throws
        -> FloeBuildingCADSheetBinding {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let assembly = try CabinetBuilder.build(cabinet.recipe)
        try validateCabinetGeometry(cabinet, assembly: assembly)
        guard sheet.cabinetID == cabinet.cabinetID else {
            throw FloeBuildingCADError.invalidBinding("The sheet belongs to another cabinet.")
        }
        var workingSheet = sheet
        workingSheet.manualNotes = manualNotes ?? sheet.manualNotes
        let extra = try extraAssemblyInstanceIDs(cabinet: cabinet)
        if sheet.documentScope == "project" && !extra.isEmpty {
            // The project assembly gained another object after the project
            // page was authored. Switch the binding to an instance-scoped
            // verified snapshot; do not refresh the unfiltered project page.
            try beginExclusiveOperation()
            defer { endExclusiveOperation() }
            let sourceIdentity = try await ensureVerifiedSavedIdentity()
            let fallback = Dictionary(uniqueKeysWithValues: sheet.dimensionBindings.map {
                ($0.role, FloeBuildingCADDimensionLayout(
                    textPosition: $0.textPosition, textOverride: $0.textOverride))
            })
            let options = FloeBuildingCADSheetOptions(
                paper: sheet.paper, title: sheet.title,
                includeClearanceDimensions: true, includeThicknessDimensions: true,
                includeCarcassDepthDimension: true,
                manualNotes: workingSheet.manualNotes)
            let builder = FloeBuildingCADSheetBuilder(
                document: document, cabinet: cabinet, assembly: assembly, options: options)
            let layout = (try? builder.captureLayout(pageID: sheet.pageID, sheet: workingSheet)) ?? fallback
            let migrated = captureAnnotations(in: document, sheet: workingSheet)
            var snapshot = try await makeSnapshotSheet(
                cabinet: cabinet, assembly: assembly, options: options,
                previousLayout: layout.isEmpty ? fallback : layout,
                migratedAnnotations: migrated.migrated,
                sourceIdentity: sourceIdentity)
            snapshot.annotationBindings.append(contentsOf: migrated.orphaned)
            snapshot.manualNotes = workingSheet.manualNotes
            putSheet(snapshot)
            return snapshot
        }
        if sheet.documentScope == "project" {
            return try await withMutationRollback { lease in
                let refreshed = try withOwnedWrite(lease) {
                    try refreshProjectSheet(cabinet: cabinet, sheet: workingSheet)
                }
                try testMutationCheckpoint("sheet.project.afterRefresh")
                try lease.verifyOwnership()
                let identity = try await saveUnlocked()
                try lease.verifyOwnership()
                var final = refreshed
                final.updatedAtIdentity = identity
                final.sourceCabinetUpdatedAtIdentity = cabinet.updatedAtIdentity
                putSheet(final)
                return final
            }
        }
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        let sourceIdentity = try await ensureVerifiedSavedIdentity()
        // Preferred route: update the SAME verified snapshot in place. The
        // page, views, dimensions, annotations and their native ids stay
        // stable; only the cabinet geometry and dimension values change.
        if let oldBinding = sheet.snapshotCabinetBinding,
           let path = sheet.snapshotRelativePath,
           let url = try? snapshotURL(for: path),
           FileManager.default.fileExists(atPath: url.path) {
            do {
                let snapshot = try await openSnapshotForRefresh(sheet)
                defer { snapshot.close() }
                let snapshotSession = FloeBuildingCADSession(document: snapshot)
                var synthetic = workingSheet
                synthetic.documentScope = "project"
                synthetic.sourceCabinetUpdatedAtIdentity = oldBinding.updatedAtIdentity
                try snapshotSession.installManifest(FloeBuildingCADManifest(
                    documentName: snapshot.name,
                    documentIdentity: nil,
                    cabinets: [oldBinding],
                    sheets: [synthetic],
                    updatedAtISO8601: FloeBuildingCADGeometry.iso8601Now()))
                let result = try await snapshotSession.updateCabinet(
                    recipe: cabinet.recipe, binding: oldBinding, refreshSheet: true)
                guard let stored = await FloeCADDocument.storedIdentity(at: url),
                      stored.revision == result.cabinet.updatedAtIdentity.revision,
                      stored.contentSHA256 == result.cabinet.updatedAtIdentity.contentSHA256,
                      stored.modelSHA256 == result.cabinet.updatedAtIdentity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed(
                        "The in-place snapshot update failed its identity read-back.")
                }
                if let refreshed = result.sheet {
                    var final = refreshed
                    final.documentScope = "verified-snapshot"
                    final.snapshotRelativePath = sheet.snapshotRelativePath
                    final.sourceIdentity = sourceIdentity
                    final.snapshotIdentity = result.cabinet.updatedAtIdentity
                    final.excludedAssemblyInstanceIDs = sheet.excludedAssemblyInstanceIDs
                    // The sheet represents the PROJECT cabinet geometry; the
                    // snapshot identity is recorded separately above/below.
                    final.sourceCabinetUpdatedAtIdentity = cabinet.updatedAtIdentity
                    final.snapshotCabinetBinding = result.cabinet
                    final.createdAtIdentity = sheet.createdAtIdentity
                    final.updatedAtIdentity = result.cabinet.updatedAtIdentity
                    final.manualNotes = workingSheet.manualNotes
                    final.annotationBindings = workingSheet.annotationBindings
                    putSheet(final)
                    return final
                }
            } catch {
                // The old snapshot may have been edited outside the bridge or
                // is otherwise not safely updatable. Fall through to a new
                // verified snapshot; the old file is retained.
            }
        }
        let layout = await captureSnapshotLayout(workingSheet)
        let migrated = await captureSnapshotAnnotations(workingSheet)
        let options = FloeBuildingCADSheetOptions(
            paper: sheet.paper, title: sheet.title,
            includeClearanceDimensions: true, includeThicknessDimensions: true,
            includeCarcassDepthDimension: true,
            manualNotes: workingSheet.manualNotes)
        var snapshot = try await makeSnapshotSheet(
            cabinet: cabinet, assembly: assembly, options: options,
            previousLayout: layout,
            migratedAnnotations: migrated.migrated,
            sourceIdentity: sourceIdentity)
        snapshot.annotationBindings.append(contentsOf: migrated.orphaned)
        snapshot.manualNotes = workingSheet.manualNotes
        // Do not delete the original snapshot: its manual content remains
        // recoverable even if a note could not be remapped.
        putSheet(snapshot)
        return snapshot
    }

    /// Refresh the five-view combination page and then rebuild the independent
    /// detail pages (internal elevation, assembly, exploded) from the same
    /// verified cabinet. Detail snapshots are new verified files; the previous
    /// detail snapshots are retained as recovery evidence.
    func refreshCombinationSheet(cabinet: FloeBuildingCADCabinetBinding,
                                 sheet: FloeBuildingCADSheetBinding,
                                 manualNotes: [CabinetManualSheetNote]? = nil,
                                 includeDetailSheets: Bool = true) async throws
        -> FloeBuildingCADSheetBinding {
        var refreshed = try await refreshCombinationSheetCore(
            cabinet: cabinet, sheet: sheet, manualNotes: manualNotes)
        if refreshed.detailSheets == nil {
            refreshed.detailSheets = sheet.detailSheets
        }
        if includeDetailSheets || !(refreshed.detailSheets ?? []).isEmpty {
            let details = try await refreshDetailSheets(cabinet: cabinet, sheet: refreshed)
            refreshed.detailSheets = details.isEmpty ? nil : details
        } else {
            refreshed.detailSheets = nil
        }
        putSheet(refreshed)
        return refreshed
    }

    /// Open the snapshot document that owns a snapshot page. The caller owns
    /// the returned document and must close it.
    func openSheetSnapshot(_ sheet: FloeBuildingCADSheetBinding) async throws -> FloeCADDocument {
        guard sheet.documentScope == "verified-snapshot",
              let path = sheet.snapshotRelativePath else {
            throw FloeBuildingCADError.invalidBinding("This page is stored in the project document, not a snapshot.")
        }
        let url = try snapshotURL(for: path)
        guard let stored = await FloeCADDocument.storedIdentity(at: url) else {
            throw FloeBuildingCADError.invalidBinding("The sheet snapshot package is missing or corrupt.")
        }
        if let expected = sheet.snapshotIdentity {
            guard stored.revision == expected.revision,
                  stored.contentSHA256 == expected.contentSHA256,
                  stored.modelSHA256 == expected.modelSHA256 else {
                throw FloeBuildingCADError.staleBinding("The sheet snapshot identity does not match the binding.")
            }
        }
        return try await FloeCADDocument.open(at: url)
    }

    /// Open a snapshot for refresh without requiring the stored identity to
    /// equal the old binding. A user may have saved page annotations; those
    /// must be preserved. The page/view identity and the bound panel geometry
    /// are still validated before the in-place update is accepted.
    private func openSnapshotForRefresh(_ sheet: FloeBuildingCADSheetBinding) async throws
        -> FloeCADDocument {
        guard sheet.documentScope == "verified-snapshot",
              let path = sheet.snapshotRelativePath else {
            throw FloeBuildingCADError.invalidBinding("This page is not a verified snapshot.")
        }
        let url = try snapshotURL(for: path)
        let stored = await FloeCADDocument.storedIdentity(at: url)
        guard stored != nil else {
            throw FloeBuildingCADError.invalidBinding("The sheet snapshot package is missing or corrupt.")
        }
        let document = try await FloeCADDocument.open(at: url)
        let geometry = CADDrawingService(document: document).pageGeometry(pageID: sheet.pageID)
        guard geometry["ok"] as? Bool == true,
              let views = geometry["views"] as? [[String: Any]],
              Set(views.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) })
                == Set(sheet.viewIDs.values) else {
            document.close()
            throw FloeBuildingCADError.invalidBinding(
                "The snapshot page or its view identities changed; refresh cannot preserve its manual content.")
        }
        return document
    }

    private func openSnapshotRaw(_ sheet: FloeBuildingCADSheetBinding) async throws
        -> FloeCADDocument {
        guard sheet.documentScope == "verified-snapshot",
              let path = sheet.snapshotRelativePath else {
            throw FloeBuildingCADError.invalidBinding("This page is not a verified snapshot.")
        }
        let url = try snapshotURL(for: path)
        let stored = await FloeCADDocument.storedIdentity(at: url)
        guard stored != nil else {
            throw FloeBuildingCADError.invalidBinding("The sheet snapshot package is missing or corrupt.")
        }
        return try await FloeCADDocument.open(at: url)
    }

    // MARK: Internal project refresh (no save; called inside updateCabinet)

    func refreshProjectSheet(cabinet: FloeBuildingCADCabinetBinding,
                             sheet: FloeBuildingCADSheetBinding) throws
        -> FloeBuildingCADSheetBinding {
        let assembly = try CabinetBuilder.build(cabinet.recipe)
        let options = FloeBuildingCADSheetOptions(
            paper: sheet.paper, title: sheet.title,
            includeClearanceDimensions: true, includeThicknessDimensions: true,
            includeCarcassDepthDimension: true,
            manualNotes: sheet.manualNotes)
        let builder = FloeBuildingCADSheetBuilder(
            document: document, cabinet: cabinet, assembly: assembly,
            options: options)
        let page = try builder.refreshExistingPage(sheet: sheet)
        return page.binding(
            cabinet: cabinet, createdAt: sheet.createdAtIdentity,
            updatedAt: sheet.updatedAtIdentity,
            documentScope: "project", snapshotPath: nil,
            sourceIdentity: nil, snapshotIdentity: nil,
            excludedInstanceIDs: [],
            sourceCabinetIdentity: cabinet.updatedAtIdentity,
            manualNotes: sheet.manualNotes,
            snapshotCabinetBinding: sheet.snapshotCabinetBinding,
            detailSheets: sheet.detailSheets)
    }

    // MARK: Snapshot plumbing

    func snapshotURL(for relativePath: String) throws -> URL {
        let parent = document.url.deletingLastPathComponent().standardizedFileURL
        let url = URL(fileURLWithPath: relativePath, relativeTo: parent).standardizedFileURL
        guard url.path.hasPrefix(parent.path + "/") else {
            throw FloeBuildingCADError.invalidInput("The sheet snapshot path escapes the project directory.")
        }
        return url
    }

    func relativeSnapshotPath(for url: URL) throws -> String {
        let parent = document.url.deletingLastPathComponent().standardizedFileURL
        let value = url.standardizedFileURL
        guard value.path.hasPrefix(parent.path + "/") else {
            throw FloeBuildingCADError.invalidInput("The sheet snapshot directory must be inside the project directory.")
        }
        return String(value.path.dropFirst(parent.path.count + 1))
    }



    private func makeSnapshotSheet(cabinet: FloeBuildingCADCabinetBinding,
                                   assembly: CabinetAssembly,
                                   options: FloeBuildingCADSheetOptions,
                                   previousLayout: [String: FloeBuildingCADDimensionLayout],
                                   migratedAnnotations: [FloeBuildingCADMigratedAnnotation] = [],
                                   sourceIdentity: FloeBuildingCADNativeIdentity) async throws
        -> FloeBuildingCADSheetBinding {
        let parent = document.url.deletingLastPathComponent().standardizedFileURL
        let snapshots = snapshotDirectory.standardizedFileURL
        guard snapshots.path.hasPrefix(parent.path + "/") else {
            throw FloeBuildingCADError.invalidInput(
                "The snapshot directory must be inside the project document's parent directory.")
        }
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let unique = UUID().uuidString
        let staging = snapshots.appendingPathComponent(".staging-\(unique).floecad", isDirectory: true)
        let final = snapshots.appendingPathComponent(
            "Cabinet-\(cabinet.cabinetID.uuidString)-\(unique).floecad", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: document.url, to: staging)
            guard let copiedIdentity = await FloeCADDocument.storedIdentity(at: staging),
                  copiedIdentity.revision == sourceIdentity.revision,
                  copiedIdentity.contentSHA256 == sourceIdentity.contentSHA256,
                  copiedIdentity.modelSHA256 == sourceIdentity.modelSHA256 else {
                throw FloeBuildingCADError.staleBinding("The copied project bytes no longer match the verified source.")
            }
            let copy = try await FloeCADDocument.open(at: staging)
            do {
                let copySession = FloeBuildingCADSession(document: copy)
                let panelInstances = Set(cabinet.panelBindings.map(\.instanceID))
                let service = CADAssemblyService(document: copy)
                var removedInstanceIDs: [UUID] = []
                var loop = 0
                while true {
                    loop += 1
                    guard loop <= 8 else {
                        throw FloeBuildingCADError.unsupportedFeature(
                            "The snapshot still contains non-cabinet assembly instances after removal.")
                    }
                    let reply = service.handle(action: "instances", args: [:])
                    guard reply["ok"] as? Bool == true,
                          let rows = reply["instances"] as? [[String: Any]] else {
                        throw FloeBuildingCADError.invalidNativeState("The snapshot assembly instances could not be read.")
                    }
                    let roots = rows.filter { row in
                        let parentRaw = row["parentID"]
                        let isRoot = parentRaw == nil || parentRaw is NSNull
                        guard isRoot, let id = FloeBuildingCADGeometry.uuid(row["id"]) else { return false }
                        return !panelInstances.contains(id)
                    }
                    if roots.isEmpty { break }
                    for row in roots {
                        guard let id = FloeBuildingCADGeometry.uuid(row["id"]) else { continue }
                        removedInstanceIDs.append(id)
                        let removed = service.handle(action: "removeInstance",
                                                     args: ["id": id.uuidString])
                        guard removed["ok"] as? Bool == true else {
                            throw FloeBuildingCADError.invalidNativeState(
                                removed["message"] as? String ?? "A non-cabinet snapshot instance could not be removed.")
                        }
                    }
                }
                let after = service.handle(action: "instances", args: [:])
                guard after["ok"] as? Bool == true,
                      let remaining = after["instances"] as? [[String: Any]] else {
                    throw FloeBuildingCADError.invalidNativeState("The snapshot assembly could not be re-read.")
                }
                let remainingIDs = Set(remaining.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) })
                guard remainingIDs == panelInstances else {
                    throw FloeBuildingCADError.unsupportedFeature(
                        "The snapshot contains a nested non-cabinet instance or is missing a cabinet panel.")
                }
                try copySession.validateCabinetBinding(cabinet)
                let builder = FloeBuildingCADSheetBuilder(
                    document: copy, cabinet: cabinet, assembly: assembly,
                    options: options)
                let page = try builder.createNewPage(
                    includeNotes: true, previousLayout: previousLayout,
                    migratedAnnotations: migratedAnnotations)
                let saved = await copy.save()
                guard saved.succeeded, !saved.modelSHA256.isEmpty else {
                    throw FloeBuildingCADError.exportFailed(
                        saved.error ?? "The sheet snapshot could not be saved with a verified identity.")
                }
                let snapshotIdentity = FloeBuildingCADNativeIdentity(
                    revision: saved.revision, contentSHA256: saved.contentSHA256,
                    modelSHA256: saved.modelSHA256)
                copy.close()
                try FileManager.default.moveItem(at: staging, to: final)
                guard let readBack = await FloeCADDocument.storedIdentity(at: final),
                      readBack.revision == snapshotIdentity.revision,
                      readBack.contentSHA256 == snapshotIdentity.contentSHA256,
                      readBack.modelSHA256 == snapshotIdentity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed("The published sheet snapshot failed read-back verification.")
                }
                let relative = try relativeSnapshotPath(for: final)
                return page.binding(
                    cabinet: cabinet, createdAt: snapshotIdentity,
                    updatedAt: snapshotIdentity,
                    documentScope: "verified-snapshot",
                    snapshotPath: relative,
                    sourceIdentity: sourceIdentity,
                    snapshotIdentity: snapshotIdentity,
                    excludedInstanceIDs: removedInstanceIDs,
                    sourceCabinetIdentity: cabinet.updatedAtIdentity,
                    manualNotes: options.manualNotes,
                    snapshotCabinetBinding: cabinet)
            } catch {
                copy.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: final)
            throw error
        }
    }

    func extraAssemblyInstanceIDs(cabinet: FloeBuildingCADCabinetBinding) throws -> [UUID] {
        let state = try nativeState()
        let panelIDs = Set(cabinet.panelBindings.map(\.instanceID))
        return state.instances.keys
            .filter { !panelIDs.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private struct MigratedAnnotations {
        var migrated: [FloeBuildingCADMigratedAnnotation]
        var orphaned: [FloeBuildingCADAnnotationBinding]
    }

    private func captureSnapshotAnnotations(_ sheet: FloeBuildingCADSheetBinding) async
        -> MigratedAnnotations {
        guard sheet.documentScope == "verified-snapshot" else {
            return MigratedAnnotations(migrated: [], orphaned: [])
        }
        guard let snapshot = try? await openSnapshotRaw(sheet) else {
            return MigratedAnnotations(migrated: [], orphaned: [])
        }
        defer { snapshot.close() }
        return captureAnnotations(in: snapshot, sheet: sheet)
    }

    private func captureAnnotations(in document: FloeCADDocument,
                                    sheet: FloeBuildingCADSheetBinding)
        -> MigratedAnnotations {
        let service = CADDrawingService(document: document)
        let geometry = service.pageGeometry(pageID: sheet.pageID)
        let rows = geometry["annotations"] as? [[String: Any]] ?? []
        let views = (geometry["views"] as? [[String: Any]] ?? [])
        var offsetByView: [UUID: [Double]] = [:]
        for row in views {
            if let id = FloeBuildingCADGeometry.uuid(row["id"]),
               let offset = FloeBuildingCADGeometry.doubleArray(row["offset"]) {
                offsetByView[id] = offset
            }
        }
        let roleByView = Dictionary(uniqueKeysWithValues: sheet.viewIDs.map { ($0.value, $0.key) })
        var migrated: [FloeBuildingCADMigratedAnnotation] = []
        var orphaned: [FloeBuildingCADAnnotationBinding] = []
        for row in rows {
            guard let stableID = FloeBuildingCADGeometry.uuid(row["id"]),
                  let text = row["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let binding = row["binding"] as? [String: Any] ?? [:]
            let bound = binding["bound"] as? Bool ?? false
            let viewID = FloeBuildingCADGeometry.uuid(row["viewID"])
            let role = viewID.flatMap { roleByView[$0] }
            var local = FloeBuildingCADGeometry.doubleArray(row["localPosition"])
            if local == nil, let sheetPosition = FloeBuildingCADGeometry.doubleArray(row["position"]) {
                if let viewID, let offset = offsetByView[viewID], sheetPosition.count == 2 {
                    local = [sheetPosition[0] - offset[0], sheetPosition[1] - offset[1]]
                } else {
                    local = sheetPosition
                }
            }
            guard !bound,
                  let role,
                  !trimmed.isEmpty, trimmed.count <= 500,
                  let position = local,
                  position.count == 2, position.allSatisfy(\.isFinite) else {
                orphaned.append(FloeBuildingCADAnnotationBinding(
                    stableID: stableID, currentID: nil, viewRole: role,
                    text: trimmed, localPosition: local ?? [], orphaned: true))
                continue
            }
            let height = FloeBuildingCADGeometry.number(row["heightMM"]) ?? 3.5
            migrated.append(FloeBuildingCADMigratedAnnotation(
                stableID: stableID, text: trimmed, localPosition: position,
                heightMM: height, viewRole: role))
        }
        return MigratedAnnotations(migrated: migrated, orphaned: orphaned)
    }

    private func captureSnapshotLayout(_ sheet: FloeBuildingCADSheetBinding) async
        -> [String: FloeBuildingCADDimensionLayout] {
        let fallback = Dictionary(uniqueKeysWithValues: sheet.dimensionBindings.map {
            ($0.role, FloeBuildingCADDimensionLayout(
                textPosition: $0.textPosition, textOverride: $0.textOverride))
        })
        guard let document = try? await openSnapshotForRefresh(sheet) else {
            return fallback
        }
        defer { document.close() }
        let builder = FloeBuildingCADSheetBuilder(
            document: document, cabinet: nil, assembly: nil, options: .init())
        let captured = (try? builder.captureLayout(pageID: sheet.pageID, sheet: sheet)) ?? [:]
        return captured.isEmpty ? fallback : captured
    }
}

// MARK: - Dimension layout

struct FloeBuildingCADDimensionLayout: Equatable {
    var textPosition: [Double]
    var textOverride: String?
}

struct FloeBuildingCADMigratedAnnotation {
    var stableID: UUID
    var text: String
    var localPosition: [Double]
    var heightMM: Double
    var viewRole: String?
}

// MARK: - Page builder

@MainActor
struct FloeBuildingCADSheetBuilder {
    let document: FloeCADDocument
    let cabinet: FloeBuildingCADCabinetBinding?
    let assembly: CabinetAssembly?
    let options: FloeBuildingCADSheetOptions

    struct PageResult {
        var pageID: UUID
        var viewIDs: [String: UUID]
        var dimensionBindings: [FloeBuildingCADDimensionBinding]
        var annotationBindings: [FloeBuildingCADAnnotationBinding]
        var paper: String
        var title: String

        func binding(cabinet: FloeBuildingCADCabinetBinding,
                     createdAt: FloeBuildingCADNativeIdentity,
                     updatedAt: FloeBuildingCADNativeIdentity,
                     documentScope: String,
                     snapshotPath: String?,
                     sourceIdentity: FloeBuildingCADNativeIdentity?,
                     snapshotIdentity: FloeBuildingCADNativeIdentity?,
                     excludedInstanceIDs: [UUID],
                     sourceCabinetIdentity: FloeBuildingCADNativeIdentity?,
                     manualNotes: [CabinetManualSheetNote] = [],
                     snapshotCabinetBinding: FloeBuildingCADCabinetBinding? = nil,
                     detailSheets: [FloeBuildingCADDetailSheet]? = nil)
            -> FloeBuildingCADSheetBinding {
            FloeBuildingCADSheetBinding(
                cabinetID: cabinet.cabinetID, pageID: pageID,
                viewIDs: viewIDs, dimensionBindings: dimensionBindings,
                paper: paper, title: title, documentScope: documentScope,
                snapshotRelativePath: snapshotPath,
                sourceIdentity: sourceIdentity,
                snapshotIdentity: snapshotIdentity,
                excludedAssemblyInstanceIDs: excludedInstanceIDs,
                sourceCabinetUpdatedAtIdentity: sourceCabinetIdentity,
                manualNotes: manualNotes,
                annotationBindings: annotationBindings,
                snapshotCabinetBinding: snapshotCabinetBinding,
                detailSheets: detailSheets,
                createdAtIdentity: createdAt, updatedAtIdentity: updatedAt)
        }
    }

    static func paperSpec(_ name: String) -> (width: Double, height: Double)? {
        switch name.lowercased() {
        case "a0": return (1189, 841)
        case "a1": return (841, 594)
        case "a2": return (594, 420)
        case "a3": return (420, 297)
        case "a4": return (297, 210)
        default: return nil
        }
    }

    func createNewPage(includeNotes: Bool,
                       previousLayout: [String: FloeBuildingCADDimensionLayout],
                       migratedAnnotations: [FloeBuildingCADMigratedAnnotation] = []) throws
        -> PageResult {
        guard let cabinet, let assembly else {
            throw FloeBuildingCADError.invalidBinding("A new page needs the cabinet binding and assembly.")
        }
        let paperName = options.paper.lowercased()
        guard let paper = Self.paperSpec(paperName) else {
            throw FloeBuildingCADError.invalidInput("Unsupported paper \(options.paper).")
        }
        let title = options.title ?? "\(cabinet.name) — Cabinet combination"
        let planner = try CabinetSheetPlanner.make(
            assembly, paperWidthMM: paper.width, paperHeightMM: paper.height,
            maximumNativeSources: 64)
        let views = planner.views.filter { $0.kind != .internalElevation }
        guard views.count == 5 else {
            throw FloeBuildingCADError.invalidInput("The cabinet sheet plan did not produce five formal views.")
        }
        let service = CADDrawingService(document: document)
        guard let first = views.first else {
            throw FloeBuildingCADError.invalidInput("The cabinet sheet plan has no views.")
        }
        var pageArgs: [String: Any] = [
            "kind": kindName(first.kind),
            "title": title,
            "paper": paperName,
            "scale": 1 / first.scaleDenominator,
            "assemblyMode": true,
            "showDimensions": true,
        ]
        pageArgs.merge(axes(first)) { _, new in new }
        let created = try checked(service.handle(action: "addPage", args: pageArgs), "addPage")
        guard let pageObject = created["page"] as? [String: Any],
              let pageID = FloeBuildingCADGeometry.uuid(pageObject["id"]),
              let pageViews = pageObject["views"] as? [[String: Any]],
              let firstID = pageViews.first.flatMap({ FloeBuildingCADGeometry.uuid($0["id"]) }) else {
            throw FloeBuildingCADError.invalidNativeState("addPage returned no page/view id.")
        }
        var viewIDs: [String: UUID] = [first.kind.rawValue: firstID]
        for view in views.dropFirst() {
            var input: [String: Any] = [
                "pageID": pageID.uuidString,
                "kind": kindName(view.kind),
                "name": view.kind.rawValue,
                "scale": 1 / view.scaleDenominator,
                "alignmentPlacement": "free",
            ]
            input.merge(axes(view)) { _, new in new }
            if view.kind == .section {
                let frame = try InteriorDrawingFrame(
                    view: .sideSection,
                    originMM: .init(assembly.recipe.widthMM / 2,
                                    assembly.recipe.carcassDepthMM / 2,
                                    assembly.recipe.heightMM / 2))
                input["sectionOrigin"] = frame.nativeOriginMM.values
                input["sectionNormal"] = frame.nativeNormal.values
            }
            let reply = try checked(service.handle(action: "addView", args: input), "addView")
            guard let row = reply["view"] as? [String: Any],
                  let id = FloeBuildingCADGeometry.uuid(row["id"]) else {
                throw FloeBuildingCADError.invalidNativeState("addView returned no view id.")
            }
            viewIDs[view.kind.rawValue] = id
        }
        try project(service, pageID: pageID)
        try placeViews(service, pageID: pageID, views: views, viewIDs: viewIDs)
        try project(service, pageID: pageID)
        let specs = try dimensionSpecs(
            cabinet: cabinet, assembly: assembly, viewIDs: viewIDs,
            viewScales: try actualViewScales(service, pageID: pageID, viewIDs: viewIDs))
        let dimensions = try addDimensions(
            service, pageID: pageID, specs: specs, viewIDs: viewIDs,
            previousLayout: previousLayout, removing: [])
        let annotationBindings = try addMigratedAnnotations(
            service, pageID: pageID, viewIDs: viewIDs, migrated: migratedAnnotations)
        if includeNotes, !options.manualNotes.isEmpty {
            try addManualNotes(service, pageID: pageID, viewIDs: viewIDs)
        }
        try project(service, pageID: pageID)
        try verify(service, pageID: pageID, cabinet: cabinet,
                   assembly: assembly, viewIDs: viewIDs, specs: specs)
        return PageResult(pageID: pageID, viewIDs: viewIDs,
                          dimensionBindings: dimensions,
                          annotationBindings: annotationBindings,
                          paper: paperName, title: title)
    }

    func refreshExistingPage(sheet: FloeBuildingCADSheetBinding) throws -> PageResult {
        guard let cabinet, let assembly else {
            throw FloeBuildingCADError.invalidBinding("A page refresh needs the cabinet binding and assembly.")
        }
        guard sheet.documentScope == "project" else {
            throw FloeBuildingCADError.invalidBinding("refreshExistingPage is only for a project-scoped page.")
        }
        let service = CADDrawingService(document: document)
        let geometry = try pageGeometry(service, pageID: sheet.pageID)
        guard let views = geometry["views"] as? [[String: Any]],
              views.count == 5 else {
            throw FloeBuildingCADError.invalidBinding("The project cabinet page no longer has its five views.")
        }
        let liveIDs = Set(views.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) })
        guard liveIDs == Set(sheet.viewIDs.values) else {
            throw FloeBuildingCADError.invalidBinding("The project cabinet page views were replaced or removed.")
        }
        let layout = try captureLayout(pageID: sheet.pageID, sheet: sheet)
        let specs = try dimensionSpecs(
            cabinet: cabinet, assembly: assembly, viewIDs: sheet.viewIDs,
            viewScales: try actualViewScales(service, pageID: sheet.pageID, viewIDs: sheet.viewIDs))
        let dimensions = try addDimensions(
            service, pageID: sheet.pageID, specs: specs, viewIDs: sheet.viewIDs,
            previousLayout: layout,
            removing: sheet.dimensionBindings.map(\.dimensionID))
        if !options.manualNotes.isEmpty {
            try addManualNotes(service, pageID: sheet.pageID, viewIDs: sheet.viewIDs)
        }
        try project(service, pageID: sheet.pageID)
        try verify(service, pageID: sheet.pageID, cabinet: cabinet,
                   assembly: assembly, viewIDs: sheet.viewIDs, specs: specs)
        return PageResult(pageID: sheet.pageID, viewIDs: sheet.viewIDs,
                          dimensionBindings: dimensions,
                          annotationBindings: sheet.annotationBindings,
                          paper: sheet.paper, title: sheet.title)
    }

    func captureLayout(pageID: UUID,
                       sheet: FloeBuildingCADSheetBinding) throws
        -> [String: FloeBuildingCADDimensionLayout] {
        let service = CADDrawingService(document: document)
        let geometry = try pageGeometry(service, pageID: pageID)
        let rows = geometry["manualDimensions"] as? [[String: Any]] ?? []
        var byID: [UUID: [String: Any]] = [:]
        for row in rows {
            if let id = FloeBuildingCADGeometry.uuid(row["id"]) { byID[id] = row }
        }
        var result: [String: FloeBuildingCADDimensionLayout] = [:]
        for binding in sheet.dimensionBindings {
            if let row = byID[binding.dimensionID],
               let position = FloeBuildingCADGeometry.doubleArray(row["localTextPosition"]) {
                result[binding.role] = FloeBuildingCADDimensionLayout(
                    textPosition: position,
                    textOverride: row["textOverride"] as? String ?? binding.textOverride)
            } else {
                result[binding.role] = FloeBuildingCADDimensionLayout(
                    textPosition: binding.textPosition, textOverride: binding.textOverride)
            }
        }
        return result
    }

    // MARK: Page primitives

    private func kindName(_ kind: CabinetTechnicalView) -> String {
        switch kind {
        case .front: return "front"
        case .side: return "side"
        case .top: return "top"
        case .section: return "section"
        case .isometric: return "iso"
        case .internalElevation: return "front"
        }
    }

    private func axes(_ view: CabinetSheetViewSpec) -> [String: Any] {
        let horizontal = view.horizontalInBuilding
        let vertical = view.verticalInBuilding
        let normal = InteriorVector3(
            horizontal.y * vertical.z - horizontal.z * vertical.y,
            horizontal.z * vertical.x - horizontal.x * vertical.z,
            horizontal.x * vertical.y - horizontal.y * vertical.x)
        return [
            "viewNormal": FloeBuildingCADGeometry.values(
                FloeBuildingCADGeometry.nativeVector(normal.values)),
            "viewUp": FloeBuildingCADGeometry.values(
                FloeBuildingCADGeometry.nativeVector(horizontal.values)),
        ]
    }

    private func checked(_ reply: [String: Any], _ context: String) throws -> [String: Any] {
        guard reply["ok"] as? Bool == true else {
            throw FloeBuildingCADError.invalidNativeState(
                "\(context) was refused: \(reply["message"] as? String ?? "unknown")")
        }
        return reply
    }

    private func project(_ service: CADDrawingService, pageID: UUID) throws {
        let reply = service.handle(action: "project", args: ["pageID": pageID.uuidString])
        guard reply["ok"] as? Bool == true,
              reply["projectionComplete"] as? Bool == true,
              reply["outputBlocked"] as? Bool == false else {
            throw FloeBuildingCADError.projectionIncomplete(
                reply["message"] as? String ?? "The native projection is incomplete or blocked.")
        }
    }

    private func pageGeometry(_ service: CADDrawingService, pageID: UUID) throws -> [String: Any] {
        let payload = service.pageGeometry(pageID: pageID)
        guard payload["ok"] as? Bool == true else {
            throw FloeBuildingCADError.invalidNativeState(
                payload["message"] as? String ?? "The page geometry could not be read.")
        }
        return payload
    }

    private func placeViews(_ service: CADDrawingService, pageID: UUID,
                            views: [CabinetSheetViewSpec],
                            viewIDs: [String: UUID]) throws {
        let geometry = try pageGeometry(service, pageID: pageID)
        guard let rows = geometry["views"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState("The projected page has no views.")
        }
        for view in views {
            guard let id = viewIDs[view.kind.rawValue],
                  let row = rows.first(where: { FloeBuildingCADGeometry.uuid($0["id"]) == id }),
                  let boundsRows = row["localBounds"] as? [[Any]],
                  boundsRows.count == 2 else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The \(view.kind.rawValue) view has no local bounds.")
            }
            let minimum = boundsRows[0].compactMap { FloeBuildingCADGeometry.number($0) }
            let maximum = boundsRows[1].compactMap { FloeBuildingCADGeometry.number($0) }
            guard minimum.count == 2, maximum.count == 2 else {
                throw FloeBuildingCADError.invalidNativeState("The view bounds are not two-dimensional.")
            }
            let offset = [
                view.centreOnPaperMM.x - (minimum[0] + maximum[0]) / 2,
                view.centreOnPaperMM.y - (minimum[1] + maximum[1]) / 2,
            ]
            let reply = service.handle(action: "updateView", args: [
                "pageID": pageID.uuidString,
                "viewID": id.uuidString,
                "alignmentPlacement": "free",
                "offset": offset,
            ])
            _ = try checked(reply, "updateView")
        }
    }

    private func actualViewScales(_ service: CADDrawingService, pageID: UUID,
                                  viewIDs: [String: UUID]) throws -> [String: Double] {
        let geometry = try pageGeometry(service, pageID: pageID)
        let rows = geometry["views"] as? [[String: Any]] ?? []
        var result: [String: Double] = [:]
        for (role, id) in viewIDs {
            if let row = rows.first(where: { FloeBuildingCADGeometry.uuid($0["id"]) == id }),
               let scale = FloeBuildingCADGeometry.number(row["scale"]) {
                result[role] = scale
            }
        }
        return result
    }

    // MARK: Dimensions

    private struct DimensionSpec {
        var role: String
        var viewRole: String
        var instanceID: UUID?
        var modelPoints: [[Double]]?
        var drawingPoints: [[Double]]?
        var expectedValue: Double
        var defaultTextPosition: [Double]
    }

    private func dimensionSpecs(cabinet: FloeBuildingCADCabinetBinding,
                                assembly: CabinetAssembly,
                                viewIDs: [String: UUID],
                                viewScales: [String: Double]) throws -> [DimensionSpec] {
        let recipe = assembly.recipe
        let h = recipe.heightMM
        let d = recipe.carcassDepthMM
        let t = recipe.carcassMaterial.thicknessMM
        guard let left = assembly.panels.first(where: { $0.role == .leftSide }),
              let leftBinding = cabinet.panelBinding(left.id),
              let sideScale = viewScales["side"],
              let frontScale = viewScales["front"],
              let sectionScale = viewScales["section"] else {
            throw FloeBuildingCADError.invalidBinding("The cabinet has no left side panel or view scale.")
        }
        var specs: [DimensionSpec] = []
        if options.includeCarcassDepthDimension {
            specs.append(DimensionSpec(
                role: "carcass-depth", viewRole: "side",
                instanceID: leftBinding.instanceID,
                modelPoints: [[t / 2, h / 2, 0], [t / 2, h / 2, -d]],
                drawingPoints: nil, expectedValue: d,
                defaultTextPosition: [d * sideScale + 8, h * 0.5 * sideScale]))
        }
        if options.includeThicknessDimensions {
            specs.append(DimensionSpec(
                role: "panel-thickness", viewRole: "front",
                instanceID: leftBinding.instanceID,
                modelPoints: [[0, h / 2, -d / 2], [t, h / 2, -d / 2]],
                drawingPoints: nil, expectedValue: t,
                defaultTextPosition: [t * frontScale + 8, h * 0.2 * frontScale]))
            if let shelf = assembly.panels.first(where: { $0.role == .shelf }),
               let shelfBinding = cabinet.panelBinding(shelf.id) {
                let localX = shelf.originMM.x + shelf.sizeMM.x / 2
                let localZ = -shelf.originMM.y - shelf.sizeMM.y / 2
                specs.append(DimensionSpec(
                    role: "shelf-thickness", viewRole: "section",
                    instanceID: shelfBinding.instanceID,
                    modelPoints: [[localX, 0, localZ], [localX, t, localZ]],
                    drawingPoints: nil, expectedValue: t,
                    defaultTextPosition: [
                        (shelf.originMM.y + shelf.sizeMM.y / 2) * sectionScale + 8,
                        (shelf.originMM.z + t) * sectionScale + 5,
                    ]))
            }
        }
        if options.includeClearanceDimensions {
            for bay in recipe.bays {
                let shelves = assembly.panels
                    .filter { $0.bayID == bay.id && $0.role == .shelf }
                    .sorted { $0.originMM.z < $1.originMM.z }
                for opening in 0...shelves.count {
                    let lower = opening == 0 ? t : shelves[opening - 1].originMM.z + shelves[opening - 1].sizeMM.z
                    let upper = opening == shelves.count ? recipe.heightMM - t : shelves[opening].originMM.z
                    guard upper - lower > 1 else { continue }
                    let x = recipe.carcassDepthMM * 0.5 * sectionScale
                    specs.append(DimensionSpec(
                        role: "clear-opening-\(bay.id.uuidString.lowercased())-\(opening)",
                        viewRole: "section",
                        instanceID: nil, modelPoints: nil,
                        drawingPoints: [[x, lower * sectionScale], [x, upper * sectionScale]],
                        expectedValue: upper - lower,
                        defaultTextPosition: [x + 8, (lower + upper) * 0.5 * sectionScale]))
                }
            }
        }
        return specs
    }

    private func addDimensions(_ service: CADDrawingService, pageID: UUID,
                               specs: [DimensionSpec],
                               viewIDs: [String: UUID],
                               previousLayout: [String: FloeBuildingCADDimensionLayout],
                               removing oldIDs: [UUID]) throws
        -> [FloeBuildingCADDimensionBinding] {
        for id in oldIDs {
            let reply = service.handle(action: "removeDimension", args: [
                "pageID": pageID.uuidString, "dimensionID": id.uuidString,
            ])
            if reply["ok"] as? Bool == true { continue }
            if reply["error"] as? String == "unknown_dimension" { continue }
            throw FloeBuildingCADError.invalidNativeState(
                "Removing a cabinet dimension was refused: \(reply["message"] as? String ?? "unknown")")
        }
        var result: [FloeBuildingCADDimensionBinding] = []
        for spec in specs {
            let layout = previousLayout[spec.role]
            let position = layout?.textPosition ?? spec.defaultTextPosition
            guard position.count == 2, position.allSatisfy(\.isFinite) else {
                throw FloeBuildingCADError.invalidNativeState("A cabinet dimension text position is invalid.")
            }
            guard let viewID = viewIDs[spec.viewRole] else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The \(spec.viewRole) view id is unavailable.")
            }
            var args: [String: Any] = [
                "pageID": pageID.uuidString,
                "viewID": viewID.uuidString,
                "kind": "length",
                "textPosition": position,
            ]
            if let instanceID = spec.instanceID, let points = spec.modelPoints {
                args["instanceID"] = instanceID.uuidString
                args["modelPoints"] = points
            } else if let points = spec.drawingPoints {
                args["drawingPoints"] = points
            } else {
                throw FloeBuildingCADError.invalidNativeState("A cabinet dimension has no geometry anchor.")
            }
            if let override = layout?.textOverride { args["text"] = override }
            let reply = try checked(service.handle(action: "addDimension", args: args), "addDimension")
            guard let row = reply["dimension"] as? [String: Any],
                  let dimensionID = FloeBuildingCADGeometry.uuid(row["id"]),
                  let value = FloeBuildingCADGeometry.number(row["value"]),
                  abs(value - spec.expectedValue) <= 0.01 else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The cabinet dimension \(spec.role) did not produce its expected value \(spec.expectedValue).")
            }
            let stored = FloeBuildingCADGeometry.doubleArray(row["localTextPosition"]) ?? position
            result.append(FloeBuildingCADDimensionBinding(
                role: spec.role, dimensionID: dimensionID, viewID: viewID,
                textPosition: stored,
                textOverride: row["textOverride"] as? String ?? layout?.textOverride))
        }
        return result
    }



    // MARK: Notes and verification

    private func addMigratedAnnotations(_ service: CADDrawingService,
                                        pageID: UUID,
                                        viewIDs: [String: UUID],
                                        migrated: [FloeBuildingCADMigratedAnnotation]) throws
        -> [FloeBuildingCADAnnotationBinding] {
        var result: [FloeBuildingCADAnnotationBinding] = []
        for item in migrated {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let role = item.viewRole,
                  let viewID = viewIDs[role],
                  !text.isEmpty, text.count <= 500,
                  item.localPosition.count == 2,
                  item.localPosition.allSatisfy(\.isFinite) else {
                result.append(FloeBuildingCADAnnotationBinding(
                    stableID: item.stableID, currentID: nil, viewRole: item.viewRole,
                    text: item.text, localPosition: item.localPosition, orphaned: true))
                continue
            }
            let height = item.heightMM.isFinite ? min(max(item.heightMM, 0.5), 50) : 3.5
            let reply = service.handle(action: "addAnnotation", args: [
                "pageID": pageID.uuidString,
                "viewID": viewID.uuidString,
                "text": text,
                "position": item.localPosition,
                "heightMM": height,
            ])
            guard reply["ok"] as? Bool == true,
                  let row = reply["annotation"] as? [String: Any],
                  let id = FloeBuildingCADGeometry.uuid(row["id"]) else {
                result.append(FloeBuildingCADAnnotationBinding(
                    stableID: item.stableID, currentID: nil, viewRole: role,
                    text: text, localPosition: item.localPosition, orphaned: true))
                continue
            }
            result.append(FloeBuildingCADAnnotationBinding(
                stableID: item.stableID, currentID: id, viewRole: role,
                text: text, localPosition: item.localPosition, orphaned: false))
        }
        return result
    }

    private func addManualNotes(_ service: CADDrawingService, pageID: UUID,
                                viewIDs: [String: UUID]) throws {
        guard let frontID = viewIDs["front"] else { return }
        let geometry = try pageGeometry(service, pageID: pageID)
        let rows = geometry["views"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { FloeBuildingCADGeometry.uuid($0["id"]) == frontID }),
              let offset = FloeBuildingCADGeometry.doubleArray(row["offset"]),
              offset.count == 2 else { return }
        let existing = (geometry["annotations"] as? [[String: Any]] ?? []).compactMap { row -> (String, [Double])? in
            guard let text = row["text"] as? String,
                  let position = FloeBuildingCADGeometry.doubleArray(row["position"]) else { return nil }
            return (text, position)
        }
        for note in options.manualNotes {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 500 else { continue }
            if existing.contains(where: { $0.0 == text }) { continue }
            let local = [note.positionMM.x - offset[0], note.positionMM.y - offset[1]]
            let reply = service.handle(action: "addAnnotation", args: [
                "pageID": pageID.uuidString,
                "viewID": frontID.uuidString,
                "text": text,
                "position": local,
                "heightMM": 3.5,
            ])
            if reply["ok"] as? Bool != true {
                throw FloeBuildingCADError.invalidNativeState(
                    "The manual sheet note could not be added: \(reply["message"] as? String ?? "unknown")")
            }
        }
    }

    private func verify(_ service: CADDrawingService, pageID: UUID,
                        cabinet: FloeBuildingCADCabinetBinding,
                        assembly: CabinetAssembly,
                        viewIDs: [String: UUID],
                        specs: [DimensionSpec]) throws {
        let geometry = try pageGeometry(service, pageID: pageID)
        guard geometry["projectionComplete"] as? Bool == true,
              geometry["outputBlocked"] as? Bool == false,
              let views = geometry["views"] as? [[String: Any]],
              views.count == 5 else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The five-view cabinet page did not project completely.")
        }
        let expectedInstances = Set(cabinet.panelBindings.map(\.instanceID))
        for row in views {
            guard row["instanceCount"] as? Int == cabinet.panelBindings.count,
                  row["projectionComplete"] as? Bool == true,
                  row["outputBlocked"] as? Bool == false,
                  (row["missingInstanceIDs"] as? [String] ?? ["missing"]).isEmpty else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "A cabinet view did not project all \(cabinet.panelBindings.count) panel instances.")
            }
        }
        if let page = geometry["page"] as? [String: Any],
           let fingerprint = page["sourceFingerprint"] as? [String: Any],
           let instances = fingerprint["instances"] as? [[String: Any]] {
            let actual = Set(instances.compactMap {
                FloeBuildingCADGeometry.uuid($0["instanceID"] ?? $0["id"])
            })
            guard actual == expectedInstances else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "The cabinet page source fingerprint includes instances outside this cabinet.")
            }
        } else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The cabinet page has no verified source-instance fingerprint.")
        }
        let autoValues = (geometry["dimensions"] as? [[String: Any]] ?? [])
            .compactMap { FloeBuildingCADGeometry.number($0["value"]) }
        let height = assembly.recipe.heightMM
        let minY = assembly.panels.map(\.originMM.y).min() ?? 0
        let maxY = assembly.panels.map { $0.originMM.y + $0.sizeMM.y }.max() ?? assembly.recipe.carcassDepthMM
        for expected in [assembly.recipe.widthMM, height, maxY - minY] {
            guard autoValues.contains(where: { abs($0 - expected) <= 0.5 }) else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "The cabinet page is missing an automatic overall dimension \(expected) mm.")
            }
        }
        let manual = geometry["manualDimensions"] as? [[String: Any]] ?? []
        var manualByID: [UUID: Double] = [:]
        for row in manual {
            if let id = FloeBuildingCADGeometry.uuid(row["id"]),
               let value = FloeBuildingCADGeometry.number(row["value"]) {
                manualByID[id] = value
            }
        }
        let bindings = manual.count
        guard bindings >= specs.count else {
            throw FloeBuildingCADError.invalidNativeState(
                "The cabinet page is missing its formal manual dimensions.")
        }
        for spec in specs {
            guard manualByID.values.contains(where: { abs($0 - spec.expectedValue) <= 0.05 }) else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The formal dimension \(spec.role) is missing or has the wrong value.")
            }
        }
    }
}
#endif
