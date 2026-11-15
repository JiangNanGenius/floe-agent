// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

public extension FloeBuildingCADSession {
    /// Publish an independent 2D deliverable set (PDF/SVG/DXF) and a static
    /// native package copy. Nothing is written in place: files are staged,
    /// hash-read-back, then the whole staging directory is moved once.
    func exportCabinetDeliverables(cabinet: FloeBuildingCADCabinetBinding,
                                   sheet: FloeBuildingCADSheetBinding,
                                   to outputDirectory: URL) async throws
        -> FloeBuildingCADDeliveryReceipt {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        guard sheet.cabinetID == cabinet.cabinetID else {
            throw FloeBuildingCADError.invalidBinding("The sheet belongs to another cabinet.")
        }
        guard let sheetCabinet = sheet.sourceCabinetUpdatedAtIdentity,
              sheetCabinet.modelSHA256 == cabinet.updatedAtIdentity.modelSHA256 else {
            throw FloeBuildingCADError.staleBinding(
                "The cabinet geometry changed after this sheet was generated; refresh the sheet before export.")
        }
        let assembly = try CabinetBuilder.build(cabinet.recipe)
        try validateCabinetGeometry(cabinet, assembly: assembly)
        let projectIdentity = try await ensureVerifiedSavedIdentity()
        let pageDocument: FloeCADDocument
        let pageIdentity: FloeBuildingCADNativeIdentity
        let shouldClosePageDocument: Bool
        if sheet.documentScope == "project" {
            pageDocument = document
            pageIdentity = projectIdentity
            shouldClosePageDocument = false
        } else {
            pageDocument = try await openSheetSnapshot(sheet)
            guard let identity = sheet.snapshotIdentity else {
                pageDocument.close()
                throw FloeBuildingCADError.invalidBinding("The snapshot sheet has no verified snapshot identity.")
            }
            pageIdentity = identity
            shouldClosePageDocument = true
        }
        defer { if shouldClosePageDocument { pageDocument.close() } }

        do {
            try await verifyPageForExport(pageDocument, pageID: sheet.pageID,
                                          cabinet: cabinet)
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
                let service = CADDrawingService(document: pageDocument)
                var files: [FloeBuildingCADExportFile] = []
                for format in ["pdf", "svg", "dxf"] {
                    try Task.checkCancellation()
                    let data = try await service.exportDataAsync(pageID: sheet.pageID, format: format)
                    try Task.checkCancellation()
                    try validateExportBytes(data, format: format)
                    let name = "CabinetCombination.\(format)"
                    let fileURL = staging.appendingPathComponent(name)
                    try data.write(to: fileURL, options: .atomic)
                    let digest = FloeBuildingCADGeometry.sha256(data)
                    let readBack = try Data(contentsOf: fileURL)
                    guard readBack.count == data.count,
                          FloeBuildingCADGeometry.sha256(readBack) == digest else {
                        throw FloeBuildingCADError.exportFailed(
                            "The \(format) export did not read back byte-identically.")
                    }
                    files.append(FloeBuildingCADExportFile(
                        role: "cabinet-combination", format: format,
                        relativePath: name, byteCount: data.count,
                        sha256: digest, verified: true,
                        unsupportedLosses: [
                            "2D cabinet combination sheet only; not a manufacturing/CNC release",
                            "This legacy single-page export does not include the independent internal-elevation, assembly or exploded detail pages; use exportCabinetDetailSet for the full set.",
                        ]))
                }
                try Task.checkCancellation()
                let copyURL = staging.appendingPathComponent("Cabinet.native.floecad",
                                                              isDirectory: true)
                try FileManager.default.copyItem(at: pageDocument.url, to: copyURL)
                guard let copyIdentity = await FloeCADDocument.storedIdentity(at: copyURL),
                      copyIdentity.revision == pageIdentity.revision,
                      copyIdentity.contentSHA256 == pageIdentity.contentSHA256,
                      copyIdentity.modelSHA256 == pageIdentity.modelSHA256 else {
                    throw FloeBuildingCADError.exportFailed(
                        "The native package copy did not preserve the verified source identity.")
                }
                let copy = try await FloeCADDocument.open(at: copyURL)
                let sourceSummary = pageDocument.summary()
                let copySummary = copy.summary()
                copy.close()
                guard copySummary.bodyCount == sourceSummary.bodyCount,
                      copySummary.sketchCount == sourceSummary.sketchCount,
                      copySummary.featureCount == sourceSummary.featureCount,
                      copySummary.drawingPageCount == sourceSummary.drawingPageCount else {
                    throw FloeBuildingCADError.exportFailed(
                        "The native package copy reopened with different model counts.")
                }
                let packageBytes = try packageByteCount(copyURL)
                files.append(FloeBuildingCADExportFile(
                    role: "native-copy", format: "floecad-package",
                    relativePath: "Cabinet.native.floecad",
                    byteCount: packageBytes,
                    sha256: pageIdentity.contentSHA256,
                    verified: true,
                    unsupportedLosses: [
                        "Static native package copy; Records/assets are not bundled",
                        "Snapshot pages are not a live in-project page",
                    ]))
                var unsupported = [
                    "Not a manufacturing/CNC release; manufacturingVerified is false",
                    "This legacy single-page export does not include the independent internal-elevation, assembly or exploded detail pages; use exportCabinetDetailSet for the full set.",
                    "Physical fit, clearance and installation are unverified",
                ]
                if sheet.documentScope != "project" {
                    unsupported.append(
                        "The page is an instance-scoped verified snapshot; the minimal in-project sourceInstanceIDs hook is documented in REQUIRED_CORE_HOOKS.patch")
                }
                let receipt = FloeBuildingCADDeliveryReceipt(
                    scope: sheet.documentScope == "project"
                        ? "cabinet-combination:project"
                        : "cabinet-combination:verified-snapshot",
                    pageID: sheet.pageID, pageTitle: sheet.title,
                    units: "mm", sourceIdentity: projectIdentity,
                    pageDocumentIdentity: pageIdentity,
                    files: files, unsupported: unsupported,
                    createdAtISO8601: FloeBuildingCADGeometry.iso8601Now(),
                    outputDirectory: outputDirectory.path,
                    notes: [
                        "Page document identity: revision \(pageIdentity.revision), modelSHA \(pageIdentity.modelSHA256).",
                        "Every file was hash-read-back in staging before the single publish move.",
                    ])
                let receiptData = try FloeBuildingCADGeometry.encodeSorted(receipt)
                try receiptData.write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: staging, to: outputDirectory)
                try await verifyPublished(outputDirectory, receipt: receipt)
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
                if error is CancellationError { throw FloeBuildingCADError.cancelled }
                if let typed = error as? FloeBuildingCADError { throw typed }
                throw FloeBuildingCADError.exportFailed(
                    "\(error.localizedDescription) (recoverable staging: \(staging.path))")
            }
        } catch {
            throw error
        }
    }

    private func verifyPageForExport(_ pageDocument: FloeCADDocument,
                                     pageID: UUID,
                                     cabinet: FloeBuildingCADCabinetBinding) async throws {
        let service = CADDrawingService(document: pageDocument)
        let geometry = await service.pageGeometryAsync(pageID: pageID)
        guard geometry["ok"] as? Bool == true,
              geometry["projectionComplete"] as? Bool == true,
              geometry["outputBlocked"] as? Bool == false,
              let views = geometry["views"] as? [[String: Any]],
              views.count == 5 else {
            throw FloeBuildingCADError.projectionIncomplete(
                geometry["message"] as? String ?? "The cabinet page is not complete.")
        }
        for view in views {
            guard view["instanceCount"] as? Int == cabinet.panelBindings.count,
                  view["projectionComplete"] as? Bool == true,
                  view["outputBlocked"] as? Bool == false,
                  (view["missingInstanceIDs"] as? [String] ?? ["missing"]).isEmpty else {
                throw FloeBuildingCADError.projectionIncomplete(
                    "A cabinet view does not contain exactly the bound panel instances.")
            }
        }
        guard let page = geometry["page"] as? [String: Any],
              let fingerprint = page["sourceFingerprint"] as? [String: Any],
              let instances = fingerprint["instances"] as? [[String: Any]] else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The page has no verified source-instance fingerprint.")
        }
        let actual = Set(instances.compactMap {
            FloeBuildingCADGeometry.uuid($0["instanceID"] ?? $0["id"])
        })
        let expected = Set(cabinet.panelBindings.map(\.instanceID))
        guard actual == expected else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The page source fingerprint contains instances outside this cabinet.")
        }
    }

    private func validateExportBytes(_ data: Data, format: String) throws {
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
            let head = String(decoding: data.prefix(4096), as: UTF8.self)
            guard head.contains("SECTION") else {
                throw FloeBuildingCADError.exportFailed("The DXF export has no SECTION record.")
            }
        default:
            throw FloeBuildingCADError.exportFailed("Unsupported export format \(format).")
        }
    }

    private func packageByteCount(_ url: URL) throws -> Int {
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

    private func verifyPublished(_ directory: URL,
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
        guard let copy = receipt.files.first(where: { $0.format == "floecad-package" }) else {
            throw FloeBuildingCADError.exportFailed("The receipt has no native package copy.")
        }
        let copyURL = directory.appendingPathComponent(copy.relativePath)
        guard let identity = await FloeCADDocument.storedIdentity(at: copyURL),
              identity.contentSHA256 == copy.sha256 else {
            throw FloeBuildingCADError.exportFailed(
                "The published native package copy failed identity read-back.")
        }
        _ = try FloeBuildingCADGeometry.encodeSorted(receipt)
    }
}
#endif
