// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

// MARK: - Detail deliverable set

public extension FloeBuildingCADSession {
    /// Export the complete cabinet deliverable set:
    ///
    /// * the five-view combination page (PDF/SVG/DXF);
    /// * the internal-elevation page with the door panels explicitly excluded;
    /// * the assembly page;
    /// * the named-exploded page;
    /// * an independently editable native 2D `.floecad` document;
    /// * an independent native 3D `.floecad` copy.
    ///
    /// All files are staged, hash-read-back and published with one directory
    /// move. Cancellation or failure never publishes a partial set.
    func exportCabinetDetailSet(cabinet: FloeBuildingCADCabinetBinding,
                                sheet: FloeBuildingCADSheetBinding,
                                to outputDirectory: URL,
                                options: FloeBuildingCADDetailExportOptions = .init())
        async throws -> FloeBuildingCADDeliveryReceipt {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard sheet.cabinetID == cabinet.cabinetID else {
            throw FloeBuildingCADError.invalidBinding("The sheet belongs to another cabinet.")
        }
        let assembly = try CabinetBuilder.build(cabinet.recipe)
        try validateCabinetGeometry(cabinet, assembly: assembly)
        guard let sourceCabinet = sheet.sourceCabinetUpdatedAtIdentity,
              sourceCabinet.modelSHA256 == cabinet.updatedAtIdentity.modelSHA256,
              sourceCabinet.revision == cabinet.updatedAtIdentity.revision else {
            throw FloeBuildingCADError.staleBinding(
                "The cabinet changed after this sheet was generated; refresh the sheet before exporting.")
        }
        let details = try validatedDetailSheets(sheet: sheet, cabinet: cabinet)
        let formats = try normalizedFormats(options.formats)
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }

        var opened: [FloeCADDocument] = []
        defer { for document in opened { document.close() } }
        let projectIdentity = try await ensureVerifiedSavedIdentity()

        let mainDocument: FloeCADDocument
        let mainIdentity: FloeBuildingCADNativeIdentity
        if sheet.documentScope == "project" {
            mainDocument = document
            mainIdentity = projectIdentity
        } else {
            mainDocument = try await openSheetSnapshot(sheet)
            opened.append(mainDocument)
            mainIdentity = try await verifiedDetailIdentity(
                sheet.snapshotIdentity, path: sheet.snapshotRelativePath,
                context: "main combination snapshot")
        }
        let frontPanels = cabinet.panelBindings.filter {
            $0.role == CabinetPanelRole.front.rawValue
        }
        var sources: [FloeBuildingCADPageSource] = [
            FloeBuildingCADPageSource(
                role: "main", fileBase: "CabinetCombination",
                title: sheet.title, pageID: sheet.pageID,
                document: mainDocument, documentIdentity: mainIdentity,
                documentScope: sheet.documentScope,
                expectedInstanceIDs: Set(cabinet.panelBindings.map(\.instanceID)),
                expectedViewIDs: Set(sheet.viewIDs.values),
                expectedViewCount: 5,
                explodedViewID: nil,
                excludedPanelIDs: [],
                excludedPanelInstanceIDs: [],
                requireFormalDimensions: true),
        ]
        for detail in details {
            guard let path = detail.snapshotRelativePath,
                  let identity = detail.snapshotIdentity else {
                throw FloeBuildingCADError.invalidBinding(
                    "The \(detail.role) detail page has no verified snapshot.")
            }
            let pageDocument = try await openDetailSheetDocument(detail)
            opened.append(pageDocument)
            let verified = try await verifiedDetailIdentity(
                identity, path: path, context: "\(detail.role) snapshot")
            guard let role = detail.typedRole else {
                throw FloeBuildingCADError.unsupportedFeature(
                    "The detail role '\(detail.role)' is not supported by this exporter.")
            }
            let expected: Set<UUID>
            switch role {
            case .internalElevation:
                expected = Set(cabinet.panelBindings
                    .filter { $0.role != CabinetPanelRole.front.rawValue }
                    .map(\.instanceID))
            case .assembly, .exploded:
                expected = Set(cabinet.panelBindings.map(\.instanceID))
            }
            sources.append(FloeBuildingCADPageSource(
                role: detail.role,
                fileBase: role == .internalElevation ? "CabinetInternalElevation"
                    : (role == .assembly ? "CabinetAssembly" : "CabinetExploded"),
                title: detail.title, pageID: detail.pageID,
                document: pageDocument, documentIdentity: verified,
                documentScope: detail.documentScope,
                expectedInstanceIDs: expected,
                expectedViewIDs: Set(detail.viewIDs.values),
                expectedViewCount: detail.viewIDs.count,
                explodedViewID: detail.explodedViewID,
                excludedPanelIDs: detail.excludedPanelIDs,
                excludedPanelInstanceIDs: detail.excludedPanelInstanceIDs,
                requireFormalDimensions: role == .internalElevation))
        }
        guard sources.count == 4 else {
            throw FloeBuildingCADError.invalidBinding(
                "The detailed deliverable needs main, internal-elevation, assembly and exploded pages.")
        }
        for source in sources {
            try await verifyPageSource(source, cabinet: cabinet)
        }
        // The internal page must be honest about the door panels; a page that
        // accidentally projects them is refused rather than relabelled.
        if let internalSource = sources.first(where: { $0.role ==
            FloeBuildingCADDetailSheet.Role.internalElevation.rawValue }) {
            let excluded = Set(internalSource.excludedPanelInstanceIDs)
            guard excluded.isSubset(of: Set(cabinet.panelBindings.map(\.instanceID))),
                  internalSource.expectedInstanceIDs.isDisjoint(with: excluded) else {
                throw FloeBuildingCADError.invalidBinding(
                    "The internal elevation does not list a valid excluded door set.")
            }
        }

        let parent = outputDirectory.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FloeBuildingCADError.invalidInput(
                "The export parent directory does not exist: \(parent.path)")
        }
        guard !FileManager.default.fileExists(atPath: outputDirectory.path) else {
            throw FloeBuildingCADError.existingOutput(outputDirectory.path)
        }
        let staging = parent.appendingPathComponent(
            ".\(outputDirectory.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            var files: [FloeBuildingCADExportFile] = []
            var receiptPages: [FloeBuildingCADReceiptPage] = []
            for source in sources {
                try Task.checkCancellation()
                var losses: [String] = []
                if !source.excludedPanelIDs.isEmpty {
                    losses.append(
                        "Intentionally excludes \(source.excludedPanelIDs.count) door panel(s): "
                        + source.excludedPanelIDs.joined(separator: ", "))
                }
                if let explodedViewID = source.explodedViewID {
                    losses.append("Uses named native exploded view \(explodedViewID.uuidString).")
                }
                if source.role == "main" || source.role ==
                    FloeBuildingCADDetailSheet.Role.internalElevation.rawValue {
                    losses.append("Formal dimensions are associative native sheet dimensions.")
                }
                if source.role == FloeBuildingCADDetailSheet.Role.exploded.rawValue {
                    losses.append("Exploded placement view only; formal cabinet dimensions stay on the combination and internal-elevation pages.")
                }
                for format in formats {
                    try Task.checkCancellation()
                    let data = try await CADDrawingService(document: source.document)
                        .exportDataAsync(pageID: source.pageID, format: format)
                    try Task.checkCancellation()
                    try validateVectorBytes(data, format: format)
                    let name = "\(source.fileBase).\(format)"
                    let fileURL = staging.appendingPathComponent(name)
                    try data.write(to: fileURL, options: .atomic)
                    let digest = FloeBuildingCADGeometry.sha256(data)
                    let readBack = try Data(contentsOf: fileURL)
                    guard readBack.count == data.count,
                          FloeBuildingCADGeometry.sha256(readBack) == digest else {
                        throw FloeBuildingCADError.exportFailed(
                            "The \(name) export did not read back byte-identically.")
                    }
                    files.append(FloeBuildingCADExportFile(
                        role: source.role, format: format, relativePath: name,
                        byteCount: data.count, sha256: digest, verified: true,
                        unsupportedLosses: losses))
                }
                receiptPages.append(FloeBuildingCADReceiptPage(
                    role: source.role, pageID: source.pageID, title: source.title,
                    documentScope: source.documentScope,
                    documentIdentity: source.documentIdentity,
                    sourceInstanceIDs: source.expectedInstanceIDs
                        .sorted { $0.uuidString < $1.uuidString },
                    excludedPanelIDs: source.excludedPanelIDs,
                    excludedPanelInstanceIDs: source.excludedPanelInstanceIDs,
                    explodedViewID: source.explodedViewID,
                    explodedViewName: details.first { $0.role == source.role }?.explodedViewName,
                    projectionVerified: true))
            }
            try testMutationCheckpoint("detailExport.afterVectorFiles")
            try Task.checkCancellation()

            if options.includeNative3D {
                guard let copySource = sources.first(where: {
                    $0.role == FloeBuildingCADDetailSheet.Role.assembly.rawValue
                }) else {
                    throw FloeBuildingCADError.invalidBinding(
                        "The detail set has no assembly snapshot for the native 3D copy.")
                }
                let name = "Cabinet.native3d.floecad"
                let copyURL = staging.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.copyItem(at: copySource.document.url, to: copyURL)
                guard let copyIdentity = await FloeCADDocument.storedIdentity(at: copyURL),
                      copyIdentity.revision == copySource.documentIdentity.revision,
                      copyIdentity.contentSHA256 == copySource.documentIdentity.contentSHA256,
                      copyIdentity.modelSHA256 == copySource.documentIdentity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed(
                        "The native 3D copy did not preserve its verified source identity.")
                }
                let copy = try await FloeCADDocument.open(at: copyURL)
                let sourceSummary = copySource.document.summary()
                let copySummary = copy.summary()
                copy.close()
                guard copySummary.bodyCount == sourceSummary.bodyCount,
                      copySummary.sketchCount == sourceSummary.sketchCount,
                      copySummary.featureCount == sourceSummary.featureCount,
                      copySummary.drawingPageCount == sourceSummary.drawingPageCount else {
                    throw FloeBuildingCADError.exportFailed(
                        "The native 3D copy reopened with different model counts.")
                }
                files.append(FloeBuildingCADExportFile(
                    role: "native-3d", format: "floecad-package",
                    relativePath: name,
                    byteCount: try directoryByteCount(copyURL),
                    sha256: copyIdentity.contentSHA256, verified: true,
                    unsupportedLosses: [
                        "Static native snapshot scoped to this cabinet's assembly instances; unrelated uninstanced bodies may remain in the copy, and project records/asset blobs are not bundled.",
                        "Editing this copy never writes back to the project source.",
                    ]))
            }

            var native2DReceipt: FloeBuildingCADNative2DReceipt?
            if options.includeNative2D {
                try Task.checkCancellation()
                let name = "Cabinet.native2d.floecad"
                let native2DURL = staging.appendingPathComponent(name, isDirectory: true)
                let receipt = try await createNative2DProject(
                    pageDocument: mainDocument, pageID: sheet.pageID,
                    sourcePageIdentity: mainIdentity,
                    at: native2DURL, options: options.native2D)
                guard let stored2D = await FloeCADDocument.storedIdentity(at: native2DURL),
                      stored2D.revision == receipt.documentIdentity.revision,
                      stored2D.contentSHA256 == receipt.documentIdentity.contentSHA256,
                      stored2D.modelSHA256 == receipt.documentIdentity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed(
                        "The native 2D document failed its published identity read-back.")
                }
                files.append(FloeBuildingCADExportFile(
                    role: "native-2d", format: "floecad-package",
                    relativePath: name,
                    byteCount: try directoryByteCount(native2DURL),
                    sha256: receipt.documentIdentity.contentSHA256, verified: true,
                    unsupportedLosses: receipt.losses))
                native2DReceipt = receipt
            }
            try testMutationCheckpoint("detailExport.beforePublish")
            try Task.checkCancellation()

            var unsupported: [String] = [
                "Not a manufacturing/CNC release; manufacturingVerified is false.",
                "Physical fit, clearance and installation remain unverified.",
            ]
            unsupported.append(contentsOf: native2DReceipt?.losses ?? [])
            let receipt = FloeBuildingCADDeliveryReceipt(
                scope: "cabinet-detail-set",
                pageID: sheet.pageID, pageTitle: sheet.title,
                units: "mm", sourceIdentity: projectIdentity,
                pageDocumentIdentity: mainIdentity,
                files: files, unsupported: unsupported,
                createdAtISO8601: FloeBuildingCADGeometry.iso8601Now(),
                outputDirectory: outputDirectory.path,
                notes: [
                    "The five-view page, internal elevation, assembly page, named exploded page, native 2D document and native 3D copy were produced from the same verified cabinet binding.",
                    "Internal elevation intentionally excludes \(frontPanels.count) door panel(s); the excluded ids are in the receipt pages.",
                    "Every vector file was hash-read-back in staging before the single publish move.",
                ],
                pages: receiptPages,
                native2D: native2DReceipt,
                unsupportedOperations: nil)
            try FloeBuildingCADGeometry.encodeSorted(receipt)
                .write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: outputDirectory)
            try await verifyPublishedDetailSet(outputDirectory, receipt: receipt)
            return receipt
        } catch {
            let marker: [String: Any] = [
                "schemaVersion": 1,
                "error": error.localizedDescription,
                "staging": staging.path,
                "final": outputDirectory.path,
                "createdAt": FloeBuildingCADGeometry.iso8601Now(),
            ]
            if let data = try? FloeBuildingCADGeometry.sortedJSONData(marker) {
                try? data.write(to: staging.appendingPathComponent("INCOMPLETE.json"))
            }
            if FileManager.default.fileExists(atPath: outputDirectory.path) {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
            if Task.isCancelled || error is CancellationError {
                throw FloeBuildingCADError.cancelled
            }
            if let typed = error as? FloeBuildingCADError { throw typed }
            throw FloeBuildingCADError.exportFailed(
                "\(error.localizedDescription) (recoverable staging: \(staging.path))")
        }
    }

    /// Whole-project export. The independent native 3D copy is always built
    /// from the saved project document itself. A whole-project native/vector
    /// drawing needs an explicitly selected project page: without one the
    /// result contains a typed unsupported record and never falls back to a
    /// cabinet page or a bounding box.
    func exportProjectDeliverables(to outputDirectory: URL,
                                   options: FloeBuildingCADDetailExportOptions = .init())
        async throws -> FloeBuildingCADDeliveryReceipt {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let formats = try normalizedFormats(options.formats)
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        let projectIdentity = try await ensureVerifiedSavedIdentity()
        let parent = outputDirectory.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FloeBuildingCADError.invalidInput(
                "The export parent directory does not exist: \(parent.path)")
        }
        guard !FileManager.default.fileExists(atPath: outputDirectory.path) else {
            throw FloeBuildingCADError.existingOutput(outputDirectory.path)
        }

        var unsupportedOperations: [FloeBuildingCADUnsupportedOperation] = []
        var unsupported: [String] = [
            "Not a manufacturing/CNC release; manufacturingVerified is false.",
            "Physical fit, clearance and installation remain unverified.",
        ]
        var selectedPage: (id: UUID, title: String, geometry: [String: Any])?
        if let pageID = options.projectPageID {
            let geometry = await CADDrawingService(document: document)
                .pageGeometryAsync(pageID: pageID)
            guard geometry["ok"] as? Bool == true else {
                throw FloeBuildingCADError.invalidInput(
                    "The selected project page does not exist: \(geometry["message"] as? String ?? pageID.uuidString)")
            }
            guard geometry["projectionComplete"] as? Bool == true,
                  geometry["outputBlocked"] as? Bool == false,
                  geometry["missingExplodedView"] as? Bool != true else {
                throw FloeBuildingCADError.projectionIncomplete(
                    geometry["message"] as? String
                        ?? "The selected project page is incomplete; nothing was exported.")
            }
            let page = geometry["page"] as? [String: Any] ?? [:]
            selectedPage = (pageID, page["title"] as? String ?? document.name, geometry)
        } else {
            if !formats.isEmpty {
                unsupportedOperations.append(FloeBuildingCADUnsupportedOperation(
                    code: "whole_project_vector_requires_page",
                    scope: "whole-project",
                    message: "Whole-project PDF/SVG/DXF needs an explicit project drawing page. Select a page or export the cabinet detail set."))
            }
            if options.includeNative2D {
                unsupportedOperations.append(FloeBuildingCADUnsupportedOperation(
                    code: "whole_project_native2d_requires_page",
                    scope: "whole-project",
                    message: "A whole-project native 2D document needs an explicit project drawing page; no empty sketch, cabinet-only fallback or bounding box was produced."))
            }
        }
        unsupported.append(contentsOf: unsupportedOperations.map(\.message))

        let staging = parent.appendingPathComponent(
            ".\(outputDirectory.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            var files: [FloeBuildingCADExportFile] = []
            var pages: [FloeBuildingCADReceiptPage] = []
            var projectNative2D: FloeBuildingCADNative2DReceipt?
            if options.includeNative3D {
                let name = "Project.native3d.floecad"
                let copyURL = staging.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.copyItem(at: document.url, to: copyURL)
                guard let copyIdentity = await FloeCADDocument.storedIdentity(at: copyURL),
                      copyIdentity.revision == projectIdentity.revision,
                      copyIdentity.contentSHA256 == projectIdentity.contentSHA256,
                      copyIdentity.modelSHA256 == projectIdentity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed(
                        "The whole-project native 3D copy did not preserve the saved project identity.")
                }
                let copy = try await FloeCADDocument.open(at: copyURL)
                let sourceSummary = document.summary()
                let copySummary = copy.summary()
                copy.close()
                guard copySummary.bodyCount == sourceSummary.bodyCount,
                      copySummary.sketchCount == sourceSummary.sketchCount,
                      copySummary.featureCount == sourceSummary.featureCount,
                      copySummary.drawingPageCount == sourceSummary.drawingPageCount else {
                    throw FloeBuildingCADError.exportFailed(
                        "The whole-project native 3D copy reopened with different model counts.")
                }
                files.append(FloeBuildingCADExportFile(
                    role: "whole-project-native-3d", format: "floecad-package",
                    relativePath: name,
                    byteCount: try directoryByteCount(copyURL),
                    sha256: copyIdentity.contentSHA256, verified: true,
                    unsupportedLosses: [
                        "Static native project package; external asset blobs and Records are not bundled.",
                        "Editing the copy never writes back to the project source.",
                    ]))
            }
            if let selectedPage {
                for format in formats {
                    try Task.checkCancellation()
                    let data = try await CADDrawingService(document: document)
                        .exportDataAsync(pageID: selectedPage.id, format: format)
                    try validateVectorBytes(data, format: format)
                    let name = "ProjectPage.\(format)"
                    let url = staging.appendingPathComponent(name)
                    try data.write(to: url, options: .atomic)
                    let digest = FloeBuildingCADGeometry.sha256(data)
                    let readBack = try Data(contentsOf: url)
                    guard readBack.count == data.count,
                          FloeBuildingCADGeometry.sha256(readBack) == digest else {
                        throw FloeBuildingCADError.exportFailed(
                            "The project page \(format) export did not read back byte-identically.")
                    }
                    files.append(FloeBuildingCADExportFile(
                        role: "whole-project-page", format: format,
                        relativePath: name, byteCount: data.count,
                        sha256: digest, verified: true,
                        unsupportedLosses: []))
                }
                pages.append(FloeBuildingCADReceiptPage(
                    role: "whole-project-page", pageID: selectedPage.id,
                    title: selectedPage.title, documentScope: "project",
                    documentIdentity: projectIdentity,
                    projectionVerified: true))
                if options.includeNative2D {
                    let name = "Project.native2d.floecad"
                    let url = staging.appendingPathComponent(name, isDirectory: true)
                    let native2D = try await createNative2DProject(
                        pageDocument: document, pageID: selectedPage.id,
                        sourcePageIdentity: projectIdentity,
                        at: url, options: options.native2D)
                    files.append(FloeBuildingCADExportFile(
                        role: "whole-project-native-2d", format: "floecad-package",
                        relativePath: name,
                        byteCount: try directoryByteCount(url),
                        sha256: native2D.documentIdentity.contentSHA256, verified: true,
                        unsupportedLosses: native2D.losses))
                    unsupported.append(contentsOf: native2D.losses)
                    projectNative2D = native2D
                }
            }
            try Task.checkCancellation()
            let zeroPage = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let receipt = FloeBuildingCADDeliveryReceipt(
                scope: "whole-project",
                pageID: selectedPage?.id ?? zeroPage,
                pageTitle: selectedPage?.title ?? "Whole project",
                units: "mm", sourceIdentity: projectIdentity,
                pageDocumentIdentity: projectIdentity,
                files: files, unsupported: unsupported,
                createdAtISO8601: FloeBuildingCADGeometry.iso8601Now(),
                outputDirectory: outputDirectory.path,
                notes: [
                    "The native 3D artifact is the saved project document itself, verified by storedIdentity and reopened counts.",
                    "No cabinet page, parameter JSON or bounding-box-only artifact substitutes for a whole-project result.",
                ],
                pages: pages,
                native2D: projectNative2D,
                unsupportedOperations: unsupportedOperations.isEmpty ? nil : unsupportedOperations)
            try FloeBuildingCADGeometry.encodeSorted(receipt)
                .write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: outputDirectory)
            try await verifyPublishedProjectSet(outputDirectory, receipt: receipt)
            return receipt
        } catch {
            let marker: [String: Any] = [
                "schemaVersion": 1,
                "error": error.localizedDescription,
                "staging": staging.path,
                "final": outputDirectory.path,
                "createdAt": FloeBuildingCADGeometry.iso8601Now(),
            ]
            if let data = try? FloeBuildingCADGeometry.sortedJSONData(marker) {
                try? data.write(to: staging.appendingPathComponent("INCOMPLETE.json"))
            }
            if FileManager.default.fileExists(atPath: outputDirectory.path) {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
            if Task.isCancelled || error is CancellationError {
                throw FloeBuildingCADError.cancelled
            }
            if let typed = error as? FloeBuildingCADError { throw typed }
            throw FloeBuildingCADError.exportFailed(
                "\(error.localizedDescription) (recoverable staging: \(staging.path))")
        }
    }

    // MARK: Validation

    private func validatedDetailSheets(sheet: FloeBuildingCADSheetBinding,
                                       cabinet: FloeBuildingCADCabinetBinding)
        throws -> [FloeBuildingCADDetailSheet] {
        guard let details = sheet.detailSheets, !details.isEmpty else {
            throw FloeBuildingCADError.staleBinding(
                "The sheet has no internal/assembly/exploded detail pages; refresh it before exporting.")
        }
        let roles = details.map(\.role)
        let expected = FloeBuildingCADDetailSheet.Role.allCases.map(\.rawValue)
        guard Set(roles).count == roles.count,
              Set(roles) == Set(expected) else {
            throw FloeBuildingCADError.invalidBinding(
                "The detail set does not contain exactly internal-elevation, assembly and exploded pages.")
        }
        for detail in details {
            guard detail.cabinetID == cabinet.cabinetID else {
                throw FloeBuildingCADError.invalidBinding(
                    "A detail page belongs to another cabinet.")
            }
            guard let source = detail.sourceCabinetUpdatedAtIdentity,
                  source.modelSHA256 == cabinet.updatedAtIdentity.modelSHA256,
                  source.revision == cabinet.updatedAtIdentity.revision else {
                throw FloeBuildingCADError.staleBinding(
                    "The \(detail.role) detail page is stale; refresh the sheet before exporting.")
            }
            guard detail.documentScope == "verified-snapshot",
                  detail.snapshotRelativePath != nil,
                  detail.snapshotIdentity != nil,
                  detail.viewIDs.count >= 3 else {
                throw FloeBuildingCADError.invalidBinding(
                    "The \(detail.role) detail page has no complete verified snapshot binding.")
            }
        }
        return details
    }

    private func verifiedDetailIdentity(_ expected: FloeBuildingCADNativeIdentity?,
                                        path: String?,
                                        context: String) async throws
        -> FloeBuildingCADNativeIdentity {
        guard let expected, let path else {
            throw FloeBuildingCADError.invalidBinding("The \(context) has no verified identity.")
        }
        let url = try snapshotURL(for: path)
        guard let stored = await FloeCADDocument.storedIdentity(at: url),
              stored.revision == expected.revision,
              stored.contentSHA256 == expected.contentSHA256,
              stored.modelSHA256 == expected.modelSHA256 else {
            throw FloeBuildingCADError.staleBinding(
                "The \(context) identity no longer matches its binding; refresh the sheet.")
        }
        return expected
    }

    private func verifyPageSource(_ source: FloeBuildingCADPageSource,
                                  cabinet: FloeBuildingCADCabinetBinding) async throws {
        let geometry = await CADDrawingService(document: source.document)
            .pageGeometryAsync(pageID: source.pageID)
        guard geometry["ok"] as? Bool == true,
              geometry["projectionComplete"] as? Bool == true,
              geometry["outputBlocked"] as? Bool == false,
              geometry["missingExplodedView"] as? Bool != true,
              let views = geometry["views"] as? [[String: Any]],
              views.count == source.expectedViewCount,
              let page = geometry["page"] as? [String: Any],
              FloeBuildingCADGeometry.uuid(page["id"]) == source.pageID else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The \(source.role) page is not complete; nothing was published.")
        }
        guard Set(views.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) })
                == source.expectedViewIDs else {
            throw FloeBuildingCADError.invalidBinding(
                "The \(source.role) page view identities changed.")
        }
        for view in views {
            guard view["instanceCount"] as? Int == source.expectedInstanceIDs.count,
                  view["projectionComplete"] as? Bool == true,
                  view["outputBlocked"] as? Bool == false,
                  (view["missingInstanceIDs"] as? [String] ?? ["missing"]).isEmpty,
                  (view["missingBodyIDs"] as? [String] ?? ["missing"]).isEmpty else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "A \(source.role) view does not contain exactly the expected instances.")
            }
        }
        guard let fingerprint = page["sourceFingerprint"] as? [String: Any],
              let instances = fingerprint["instances"] as? [[String: Any]] else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The \(source.role) page has no verified source-instance fingerprint.")
        }
        let actual = Set(instances.compactMap {
            FloeBuildingCADGeometry.uuid($0["instanceID"] ?? $0["id"])
        })
        guard actual == source.expectedInstanceIDs else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The \(source.role) page source fingerprint contains instances outside its scope.")
        }
        if let explodedViewID = source.explodedViewID {
            guard let exploded = geometry["explodedView"] as? [String: Any],
                  (exploded["id"] as? String) == explodedViewID.uuidString,
                  exploded["found"] as? Bool == true,
                  instances.allSatisfy({
                      FloeBuildingCADGeometry.uuid($0["explodedViewID"]) == explodedViewID
                  }) else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "The exploded page no longer resolves its named exploded view.")
            }
        }
        if source.requireFormalDimensions {
            let auto = (geometry["dimensions"] as? [[String: Any]] ?? [])
                .compactMap { FloeBuildingCADGeometry.number($0["value"]) }
            let manual = (geometry["manualDimensions"] as? [[String: Any]] ?? [])
                .compactMap { FloeBuildingCADGeometry.number($0["value"]) }
            let recipe = cabinet.recipe
            guard auto.contains(where: { abs($0 - recipe.widthMM) <= 0.5 }),
                  auto.contains(where: { abs($0 - recipe.heightMM) <= 0.5 }) else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "The \(source.role) page is missing its formal overall dimensions.")
            }
            if source.role == FloeBuildingCADDetailSheet.Role.internalElevation.rawValue {
                let t = recipe.carcassMaterial.thicknessMM
                guard manual.contains(where: { abs($0 - t) <= 0.02 }) else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The internal elevation is missing its formal carcass thickness dimension.")
                }
            }
        }
    }

    private func normalizedFormats(_ formats: [String]) throws -> [String] {
        var result: [String] = []
        for raw in formats {
            let value = raw.lowercased()
            guard ["pdf", "svg", "dxf"].contains(value) else {
                throw FloeBuildingCADError.invalidInput(
                    "Unsupported detail deliverable format '\(raw)'; use pdf, svg or dxf.")
            }
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    private func validateVectorBytes(_ data: Data, format: String) throws {
        guard !data.isEmpty else {
            throw FloeBuildingCADError.exportFailed("The \(format) export was empty.")
        }
        switch format {
        case "pdf":
            guard data.starts(with: Data("%PDF".utf8)) else {
                throw FloeBuildingCADError.exportFailed("The PDF export has no PDF header.")
            }
        case "svg":
            guard String(decoding: data, as: UTF8.self).contains("<svg") else {
                throw FloeBuildingCADError.exportFailed("The SVG export has no <svg> root.")
            }
        case "dxf":
            guard String(decoding: data.prefix(4096), as: UTF8.self).contains("SECTION") else {
                throw FloeBuildingCADError.exportFailed("The DXF export has no SECTION record.")
            }
        default:
            throw FloeBuildingCADError.exportFailed("Unsupported vector format \(format).")
        }
    }

    private func directoryByteCount(_ url: URL) throws -> Int {
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])
        var total = 0
        while let file = enumerator?.nextObject() as? URL {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    private func verifyPublishedDetailSet(_ directory: URL,
                                          receipt: FloeBuildingCADDeliveryReceipt) async throws {
        for file in receipt.files where file.format != "floecad-package" {
            let url = directory.appendingPathComponent(file.relativePath)
            let data = try Data(contentsOf: url)
            guard data.count == file.byteCount,
                  FloeBuildingCADGeometry.sha256(data) == file.sha256 else {
                throw FloeBuildingCADError.exportFailed(
                    "The published \(file.relativePath) failed hash read-back.")
            }
        }
        let packages = receipt.files.filter { $0.format == "floecad-package" }
        for file in packages {
            let url = directory.appendingPathComponent(file.relativePath, isDirectory: true)
            guard let identity = await FloeCADDocument.storedIdentity(at: url),
                  identity.contentSHA256 == file.sha256 else {
                throw FloeBuildingCADError.exportFailed(
                    "The published \(file.relativePath) failed identity read-back.")
            }
        }
        _ = try FloeBuildingCADGeometry.encodeSorted(receipt)
    }

    private func verifyPublishedProjectSet(_ directory: URL,
                                           receipt: FloeBuildingCADDeliveryReceipt) async throws {
        for file in receipt.files where file.format != "floecad-package" {
            let url = directory.appendingPathComponent(file.relativePath)
            let data = try Data(contentsOf: url)
            guard data.count == file.byteCount,
                  FloeBuildingCADGeometry.sha256(data) == file.sha256 else {
                throw FloeBuildingCADError.exportFailed(
                    "The published \(file.relativePath) failed hash read-back.")
            }
        }
        for file in receipt.files where file.format == "floecad-package" {
            let url = directory.appendingPathComponent(file.relativePath, isDirectory: true)
            guard let identity = await FloeCADDocument.storedIdentity(at: url),
                  identity.contentSHA256 == file.sha256 else {
                throw FloeBuildingCADError.exportFailed(
                    "The published \(file.relativePath) failed identity read-back.")
            }
        }
        _ = try FloeBuildingCADGeometry.encodeSorted(receipt)
    }
}

private struct FloeBuildingCADPageSource {
    var role: String
    var fileBase: String
    var title: String
    var pageID: UUID
    var document: FloeCADDocument
    var documentIdentity: FloeBuildingCADNativeIdentity
    var documentScope: String
    var expectedInstanceIDs: Set<UUID>
    var expectedViewIDs: Set<UUID>
    var expectedViewCount: Int
    var explodedViewID: UUID?
    var excludedPanelIDs: [String]
    var excludedPanelInstanceIDs: [UUID]
    var requireFormalDimensions: Bool
}
#endif
