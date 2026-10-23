// SPDX-License-Identifier: MPL-2.0
// FloeApp — shared Office PDF export service for the screen, Print and the
// assistant.
//
// Two entry points share one plan and one result:
//
//  * `export` runs the already-qualified hidden engine export on a SAVED
//    package. XLSX first prepares a private print copy through
//    `OfficePrintCopy` (sheet/workbook scope, exact cell range, page setup),
//    then `OfficeIsolatedPDFExport` opens a read-only engine session on that
//    copy. DOCX/PPTX export their own document settings; when the plan asks
//    for a `paginatedLayout`, the produced pages then go through the guarded
//    `OfficePDFPhysicalLayout` pass (physical paper, orientation and one
//    scaling choice applied to the GENERATED PDF — vector content replayed,
//    the source package never touched).
//  * `finalizeExistingPDF` validates and finalizes a PDF that an ALREADY-OPEN
//    live session produced with the existing native export. That keeps the
//    baseline legacy formats (.xls, .ods, .doc, .odt, .rtf, .ppt, .odp)
//    available without pretending the saved isolated host loads them or
//    mapping them to a qualified format.
//
// Both paths apply the same strict final PDF page selection, measure the
// actual file with PDFKitGate + withPDFExceptionGuard, verify the exact source
// digest before and after, never overwrite an output, never write the source
// and never delete the caller's directory. The caller leases the returned
// file and owns presentation (share sheet, system print panel, assistant
// artifact transport).
//
// One plan flag re-shapes what the ENGINE reads, never what the user owns:
// `plan.includeInk == false` routes every qualified saved format through an
// export-only isolated copy prepared by `OfficeInkOmission` — the workbook
// copy goes through `OfficePrintCopy` first, then the same omission pass;
// `.docx`/`.pptx` get their own ink-omitted copy of the frozen source. Only
// proven freeform ink strokes (see the module header) leave the output;
// typed cells/text, charts, images, preset shapes, gridlines and borders
// stay, the automatic fit bounds shrink with the omitted ink, and the exact
// source bytes — every saved stroke — are verified unchanged around the
// operation. Legacy live-session formats refuse the flag instead of
// silently ignoring it, because their PDF is the engine's own rendering.
//
// This service has no view, no SwiftUI state and no live controller. The UI
// adapter resolves live-only facts (current sheet, pen-up/save fence) before
// calling it. The backend never assumes the first worksheet.
#if canImport(UIKit) && canImport(WebKit) && canImport(FloeOfficeNative)
import Foundation
import CoreGraphics
import PDFKit
import FloeCore
import FloeDocuments
import FloeTools

// MARK: - Request / result

struct OfficePDFExportRequest: Sendable {
    /// Exact saved source the engine may read. Never written.
    var sourceURL: URL
    /// Captured before the export; lowercase 64-character SHA-256 hex.
    var sourceSHA256: String
    /// Actual extension of `sourceURL` (xlsx/docx/pptx, or a legacy format
    /// when the caller is only probing capabilities).
    var formatExtension: String
    var plan: OfficePDFPrintPlan
    /// Caller-owned parent directory. The service creates exactly one
    /// `pdf-export-<UUID>` child inside it and never deletes the parent.
    var ownedDirectory: URL
    var cancellation: CancellationToken?

    init(sourceURL: URL,
         sourceSHA256: String,
         formatExtension: String,
         plan: OfficePDFPrintPlan,
         ownedDirectory: URL,
         cancellation: CancellationToken? = nil) {
        self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256
        self.formatExtension = formatExtension
        self.plan = plan
        self.ownedDirectory = ownedDirectory
        self.cancellation = cancellation
    }
}

/// Finalize a PDF that an already-open live session produced through the
/// existing native export. The PDF is only read; the exact source the engine
/// exported is identified by URL + SHA and re-verified around the operation.
struct OfficePDFFinalizeRequest: Sendable {
    var exportedPDFURL: URL
    var sourceURL: URL
    var sourceSHA256: String
    var formatExtension: String
    var plan: OfficePDFPrintPlan
    var ownedDirectory: URL
    var cancellation: CancellationToken?

    init(exportedPDFURL: URL,
         sourceURL: URL,
         sourceSHA256: String,
         formatExtension: String,
         plan: OfficePDFPrintPlan,
         ownedDirectory: URL,
         cancellation: CancellationToken? = nil) {
        self.exportedPDFURL = exportedPDFURL
        self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256
        self.formatExtension = formatExtension
        self.plan = plan
        self.ownedDirectory = ownedDirectory
        self.cancellation = cancellation
    }
}

/// Everything the caller may present is measured from the actual final PDF.
struct OfficePDFExportResult: Sendable {
    var pdfURL: URL
    var pdfSHA256: String
    var byteCount: Int
    var pageCount: Int
    /// PDF points, cropBox, one entry per final page. With a physical
    /// paginated layout these are the MEASURED laid-out paper boxes — the
    /// applied result is proven from the real file, never restated from the
    /// request.
    var pageSizes: [CGSize]
    var sourceSHA256: String
    var sourceFormatExtension: String
    var plan: OfficePDFPrintPlan
    /// Non-nil only when this export prepared an XLSX print copy.
    var appliedPrintPlan: OfficePrintCopyPlan?
    /// nil = every page of the produced PDF; otherwise the exact final order.
    var appliedPageRange: [Int]?
    /// Set only when the output was rendered from an ink-omitted export copy:
    /// the exact number of proven freeform shapes removed from that copy.
    /// Never a restatement of the request.
    var omittedInkShapeCount: Int? = nil
    /// Non-nil only when the generated PDF pages were physically re-laid
    /// through the guarded `OfficePDFPhysicalLayout` pass for this plan's
    /// `paginatedLayout`. The measured `pageSizes` above describe the real
    /// result; this records which request produced it.
    var appliedPaginatedLayout: OfficePDFPaginatedLayout? = nil
    /// Pages whose explicitly scaled content exceeds the paper box for the
    /// applied layout (nil without a layout; 0 for any whole-page fit).
    var layoutExceedingPages: Int? = nil
    var notes: [OfficePDFExportNote]
}

/// Typed, root-localizable facts about what the export actually did.
enum OfficePDFExportNote: String, Codable, Sendable, Equatable {
    case documentSettingsPreserved
    case otherSheetsSuppressed
    case printAreasCleared
    case documentPrintAreaPreserved
    case printTitlesPreserved
    case finalPageSelectionApplied
    case legacyFormatFinalized
    /// The prepared output was rendered from an export-only isolated copy
    /// whose proven freeform ink strokes were removed
    /// (`plan.includeInk == false`). Typed text, charts, images, gridlines,
    /// borders and the source package are untouched.
    case handwritingOmitted
    /// The generated Word/Presentation PDF pages were physically re-laid on
    /// the requested paper through the guarded layout pass. The measured
    /// result (page boxes, count and digest) always describes the laid-out
    /// file — this note records that the layout route actually ran.
    case physicalLayoutApplied
    /// An explicit `actualSize`/`percent` scaling left content larger than
    /// the paper on at least one page. The preview shows exactly this and
    /// the count is in the result; a whole-page fit never reports it.
    case physicalLayoutContentExceedsPaper
}

enum OfficePDFExportError: LocalizedError, Sendable, Equatable {
    case invalidSourceIdentity
    case staleSource
    case sourceChangedDuringExport
    case savedExportUnavailable(format: String, reason: String)
    case outputDirectoryUnavailable
    case outputAlreadyExists(String)
    case invalidPDF(reason: String)
    case pageSelectionFailed(reason: String)
    case physicalLayoutFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceIdentity:
            "The document identity supplied for export is not a validated digest."
        case .staleSource:
            "The document changed since it was read; no PDF was produced."
        case .sourceChangedDuringExport:
            "The document changed while the PDF was being produced; no PDF was returned."
        case .savedExportUnavailable(let format, let reason):
            "A background PDF export is not available for .\(format): \(reason)"
        case .outputDirectoryUnavailable:
            "The export output directory could not be prepared."
        case .outputAlreadyExists(let path):
            "The export output already exists and is never overwritten: \(path)"
        case .invalidPDF(let reason):
            "The exported PDF failed validation (\(reason))."
        case .pageSelectionFailed(let reason):
            "The PDF page selection failed (\(reason))."
        case .physicalLayoutFailed(let reason):
            "The requested physical print layout was not applied (\(reason)); the original document was preserved."
        }
    }
}

/// Truthful discovery for the UI and assistant. No control should be shown
/// when its capability is false.
struct OfficePDFExportCapability: Codable, Sendable, Equatable {
    var formatExtension: String
    var savedIsolatedExport: Bool
    var liveSessionFinalize: Bool
    var sheetScope: Bool
    var selectedSheetsScope: Bool
    var printAreaScope: Bool
    var customPageSetup: Bool
    var exactScale: Bool
    var fitPageCount: Bool
    /// Explicit printed-gridlines choice: the shared backend writes only the
    /// private copy's `printOptions@gridLines`, never cell borders and never
    /// the source package. False for every non-XLSX format.
    var printGridlines: Bool
    var finalPageRange: Bool
    /// Explicit handwriting choice honored through an export-only isolated
    /// copy: the prepared copy's proven freeform ink strokes are removed by
    /// `OfficeInkOmission` while typed cells/text, charts, images, printed
    /// gridlines, cell borders and the source package all stay untouched.
    /// True exactly where the saved isolated export host is qualified
    /// (`.xlsx`, `.docx`, `.pptx`); false for the legacy live-session
    /// formats, which cannot re-render without ink and refuse the choice.
    var inkOmission: Bool
    /// Physical print layout of the GENERATED PDF (paper, orientation and one
    /// scaling choice) is applied for `.docx`/`.pptx` through the guarded
    /// `OfficePDFPhysicalLayout` pass. This is re-laid print output, never a
    /// claim to reflow the source; false for `.xlsx` (which writes real OOXML
    /// page setup instead) and for the legacy live-session formats.
    var physicalPageLayout: Bool
    /// Exact `OfficePDFScale` percent and actual-size scaling for a physical
    /// layout request — true exactly where `physicalPageLayout` is true.
    var physicalExactScale: Bool

    static func resolve(forExtension ext: String) -> OfficePDFExportCapability? {
        guard let support = OfficePDFFormatSupport.resolve(forExtension: ext) else {
            return nil
        }
        return OfficePDFExportCapability(
            formatExtension: ext.lowercased(),
            savedIsolatedExport: support.supportsSavedIsolatedExport,
            liveSessionFinalize: true,
            sheetScope: support.supportsSheetScope,
            selectedSheetsScope: support.supportsSelectedSheetsScope,
            printAreaScope: support.supportsPrintAreaScope,
            customPageSetup: support.supportsCustomPageSetup,
            exactScale: support.supportsExactScale,
            fitPageCount: support.supportsFitPageCount,
            printGridlines: support.supportsPrintGridlines,
            finalPageRange: support.supportsFinalPageRange,
            inkOmission: support.supportsSavedIsolatedExport,
            physicalPageLayout: support.supportsPhysicalPageLayout,
            physicalExactScale: support.supportsPhysicalExactScale)
    }
}

// MARK: - Service

enum OfficePDFExportService {
    /// The existing native host writes at most 64 MiB per PDF and its
    /// `exportPDF` path already rejects a larger file. Keep the shared
    /// validator on the same bound instead of inventing a smaller one.
    static let maximumPDFBytes = 64 * 1_024 * 1_024
    /// Geometry arrays are bounded separately; an export is never truncated.
    static let maximumResultPages = 20_000
    private static let maximumSourceBytes = 128 * 1_024 * 1_024

    /// Saved-file isolated export. Qualified formats: .xlsx, .docx, .pptx.
    static func export(_ request: OfficePDFExportRequest) async throws -> OfficePDFExportResult {
        try checkCancellation(request.cancellation)
        let ext = request.formatExtension.lowercased()
        guard ext == request.sourceURL.pathExtension.lowercased() else {
            throw OfficePDFExportError.invalidSourceIdentity
        }
        guard let support = OfficePDFFormatSupport.resolve(forExtension: ext) else {
            throw OfficePDFPlanError.unsupportedFormat(ext)
        }
        guard support.supportsSavedIsolatedExport else {
            throw OfficePDFExportError.savedExportUnavailable(
                format: ext,
                reason: "the isolated export host is qualified for .xlsx, .docx and .pptx; export the open document and finalize that PDF")
        }
        try request.plan.validate(forExtension: ext)
        guard let isolatedFormat = OfficeDocumentFormat(fileExtension: ext) else {
            throw OfficePDFPlanError.unsupportedFormat(ext)
        }
        let sourceSHA = try verifySource(request.sourceURL,
                                         expectedSHA256: request.sourceSHA256,
                                         maximumBytes: maximumSourceBytes)
        try prepareOwnedDirectory(request.ownedDirectory)
        try checkCancellation(request.cancellation)

        let child = request.ownedDirectory.appendingPathComponent(
            "pdf-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        } catch {
            throw OfficePDFExportError.outputDirectoryUnavailable
        }

        let wasQuarantined = await OfficeAutomaticExecutionGate.shared.isQuarantined
        do {
            var copyPlan: OfficePrintCopyPlan?
            var inkOutcome: OfficeInkOmissionOutcome?
            var preparedCopies: [URL] = []
            let exportSource: URL
            if support == .workbook, request.plan.requiresPrintCopy {
                let copyURL = child.appendingPathComponent("print-copy.xlsx")
                copyPlan = try OfficePrintCopy.prepare(
                    sourceURL: request.sourceURL,
                    destinationURL: copyURL,
                    expectedSHA256: request.sourceSHA256,
                    plan: request.plan)
                preparedCopies.append(copyURL)
                if request.plan.includeInk {
                    exportSource = copyURL
                } else {
                    // Omit the proven ink strokes from the ALREADY private
                    // print copy only. The source keeps every stroke; the
                    // engine prints from this second, export-only copy. The
                    // engine derives its automatic print bounds at print time
                    // from THIS copy, so the omitted ink is already gone from
                    // the bounds input — no extent is computed from the
                    // un-omitted copy anywhere in this pipeline.
                    let strippedURL = child.appendingPathComponent(
                        "print-copy-ink-omitted.xlsx")
                    inkOutcome = try OfficeInkOmission.prepareOmittedCopy(
                        sourceURL: copyURL,
                        destinationURL: strippedURL,
                        expectedSHA256: copyPlan?.copySHA256)
                    preparedCopies.append(strippedURL)
                    if let inkOutcome {
                        // Receipt truth: the applied plan must describe the
                        // file the engine ACTUALLY rendered, and an omission
                        // that rewrote drawing members means those members
                        // are no longer byte-preserved in the rendered copy.
                        if !inkOutcome.changedParts.isEmpty {
                            copyPlan?.drawingPartsPreserved = false
                        }
                        copyPlan?.copySHA256 = inkOutcome.copySHA256
                    }
                    exportSource = strippedURL
                }
            } else if !request.plan.includeInk {
                // Only `.docx`/`.pptx` reach here: a workbook that omits ink
                // always requires the print copy above (`requiresPrintCopy`).
                let omittedURL = child.appendingPathComponent("ink-omitted.\(ext)")
                inkOutcome = try OfficeInkOmission.prepareOmittedCopy(
                    sourceURL: request.sourceURL,
                    destinationURL: omittedURL,
                    expectedSHA256: request.sourceSHA256)
                preparedCopies.append(omittedURL)
                exportSource = omittedURL
            } else {
                exportSource = request.sourceURL
            }
            try checkCancellation(request.cancellation)
            let exported = try await OfficeIsolatedPDFExport.run(
                sourceURL: exportSource,
                format: isolatedFormat,
                ownedDirectory: child,
                cancellation: request.cancellation)
            try checkCancellation(request.cancellation)
            // The isolated export writes `region.pdf`; never treat that
            // private filename as the final output.
            guard exported.lastPathComponent == "region.pdf" else {
                throw OfficePDFExportError.invalidPDF(reason: "unexpected-engine-output")
            }
            let result = try finalizeProducedPDF(
                exportedPDFURL: exported,
                child: child,
                sourceURL: request.sourceURL,
                sourceSHA256: sourceSHA,
                sourceFormatExtension: ext,
                plan: request.plan,
                appliedPrintPlan: copyPlan,
                omittedInkShapeCount: inkOutcome?.omittedInkDrawings,
                baseNotes: notes(for: request.plan, copyPlan: copyPlan, legacy: false),
                cancellation: request.cancellation)
            // The private preparation copies are no longer needed once the
            // PDF is final; the engine's own staging directory is removed by
            // OfficeIsolatedPDFExport on its safe path.
            for copy in preparedCopies {
                try? FileManager.default.removeItem(at: copy)
            }
            return result
        } catch {
            let isQuarantined = await OfficeAutomaticExecutionGate.shared.isQuarantined
            let unsafe = (error as? any UnsafeResourceStateError)?.isUnsafeResourceState == true
            let retainedByEngine = unsafe || (!wasQuarantined && isQuarantined)
            if !retainedByEngine {
                try? FileManager.default.removeItem(at: child)
            }
            throw error
        }
    }

    /// Validate and finalize a PDF produced by an already-open live session.
    /// Supports every format the session can export, including the legacy
    /// formats the saved isolated host does not load. Custom sheet/page
    /// setup is refused for non-workbook formats by the plan validator.
    static func finalizeExistingPDF(_ request: OfficePDFFinalizeRequest) async throws
        -> OfficePDFExportResult {
        try checkCancellation(request.cancellation)
        let ext = request.formatExtension.lowercased()
        guard ext == request.sourceURL.pathExtension.lowercased() else {
            throw OfficePDFExportError.invalidSourceIdentity
        }
        guard let support = OfficePDFFormatSupport.resolve(forExtension: ext) else {
            throw OfficePDFPlanError.unsupportedFormat(ext)
        }
        try request.plan.validate(forExtension: ext)
        // A PDF that already exists cannot be re-scoped, re-paginated or
        // physically re-laid by this path: it is the already-open session's
        // actual output. Only document settings plus a final page range are
        // truthful here. (The editor adapter only reaches this route for the
        // legacy formats, which never carry a physical paginated layout; this
        // guard keeps a hand-built request from silently ignoring one.)
        guard request.plan.scope == .documentSettings,
              !request.plan.pageSetup.hasOverrides,
              request.plan.paginatedLayout?.hasOverrides != true else {
            throw OfficePDFExportError.savedExportUnavailable(
                format: ext,
                reason: "finalizing an existing PDF supports document settings and a final page range only")
        }
        // Omitting handwriting needs an export-only package copy. A
        // live-session PDF is the engine's own rendering of the open
        // document, so the choice is refused truthfully instead of being
        // silently ignored — the UI never offers it for this route.
        guard request.plan.includeInk else {
            throw OfficePDFExportError.savedExportUnavailable(
                format: ext,
                reason: "omitting handwriting is available only through the prepared export copy route")
        }
        let sourceSHA = try verifySource(request.sourceURL,
                                         expectedSHA256: request.sourceSHA256,
                                         maximumBytes: nil)
        guard request.exportedPDFURL.standardizedFileURL.path
                != request.sourceURL.standardizedFileURL.path else {
            throw OfficePDFExportError.invalidPDF(reason: "source-is-pdf")
        }
        try validatePDFFile(request.exportedPDFURL)
        try checkCancellation(request.cancellation)
        try prepareOwnedDirectory(request.ownedDirectory)

        let child = request.ownedDirectory.appendingPathComponent(
            "pdf-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        } catch {
            throw OfficePDFExportError.outputDirectoryUnavailable
        }
        do {
            let enginePDFSHA = try FloeDigest.sha256Hex(ofFileAt: request.exportedPDFURL)
            // Hidden unique intermediate name, so it can never collide with
            // the user-facing `<source-stem>.pdf` final name.
            let copyURL = child.appendingPathComponent(
                ".floe-session-\(UUID().uuidString).pdf")
            try FileManager.default.copyItem(at: request.exportedPDFURL, to: copyURL)
            guard try FloeDigest.sha256Hex(ofFileAt: copyURL) == enginePDFSHA else {
                throw OfficePDFExportError.invalidPDF(reason: "copy-digest-mismatch")
            }
            try checkCancellation(request.cancellation)
            let notes = notes(for: request.plan, copyPlan: nil, legacy: support == .documentSettingsOnly)
            return try finalizeProducedPDF(
                exportedPDFURL: copyURL,
                child: child,
                sourceURL: request.sourceURL,
                sourceSHA256: sourceSHA,
                sourceFormatExtension: ext,
                plan: request.plan,
                appliedPrintPlan: nil,
                baseNotes: notes,
                cancellation: request.cancellation)
        } catch {
            // No engine session is held by this path; its own child is always
            // safe to remove and the caller's PDF is never touched.
            try? FileManager.default.removeItem(at: child)
            throw error
        }
    }

    static func capability(forExtension ext: String) -> OfficePDFExportCapability? {
        OfficePDFExportCapability.resolve(forExtension: ext)
    }

    /// The cover/thumbnail plan for a saved document.
    ///
    /// A workbook cover is the actual first visible worksheet at its own full
    /// engine content (never a guessed cell range and never a crop of the
    /// user's ink), fitted onto one page with the printed grid visible, so
    /// page 1 of the real PDF — the only page the Notes card rasterizes —
    /// carries everything that sheet prints. Word/Presentation documents keep
    /// their own setup exactly as before. Nothing here writes the source: the
    /// plan only feeds the private print copy.
    static func savedCoverPlan(formatExtension ext: String,
                               firstVisibleSheetName: String?) -> OfficePDFPrintPlan {
        guard OfficePDFFormatSupport.resolve(forExtension: ext)?
                .supportsCustomPageSetup == true else {
            return OfficePDFPrintPlan(scope: .documentSettings)
        }
        guard let firstVisibleSheetName else {
            // No resolved visible tab keeps the previous full-workbook route;
            // the print copy itself refuses a workbook with no visible sheet.
            return OfficePDFPrintPlan(scope: .allVisibleSheets)
        }
        return OfficePDFPrintPlan(
            scope: .sheet(name: firstVisibleSheetName, cellRange: nil),
            pageSetup: OfficePDFPageSetup(fit: .fitToOnePage, printGridlines: true))
    }

    // MARK: - Finalization

    /// Copies/renames the produced PDF into its final name, applies the
    /// optional final page range, validates the actual result and re-checks
    /// the source digest.
    private static func finalizeProducedPDF(
        exportedPDFURL: URL,
        child: URL,
        sourceURL: URL,
        sourceSHA256: String,
        sourceFormatExtension: String,
        plan: OfficePDFPrintPlan,
        appliedPrintPlan: OfficePrintCopyPlan?,
        omittedInkShapeCount: Int? = nil,
        baseNotes: [OfficePDFExportNote],
        cancellation: CancellationToken?
    ) throws -> OfficePDFExportResult {
        try validatePDFFile(exportedPDFURL)
        // Physical print layout of a generated paginated PDF runs BEFORE the
        // final page selection: the guarded pass is 1:1 in page count, so a
        // requested final page number still names the same document page.
        // On failure the partial layout output is removed, the produced engine
        // PDF stays for the caller's own cleanup rules, and the source Office
        // package has already been digest-verified untouched.
        var producedURL = exportedPDFURL
        var appliedPaginatedLayout: OfficePDFPaginatedLayout?
        var layoutExceedingPages: Int?
        if let layout = plan.paginatedLayout, layout.hasOverrides {
            try checkCancellation(cancellation)
            let laidURL = child.appendingPathComponent(
                ".floe-layout-\(UUID().uuidString).pdf")
            do {
                let outcome = try OfficePDFPhysicalLayout.apply(
                    layout: layout, sourceURL: exportedPDFURL, outputURL: laidURL,
                    cancellation: cancellation)
                try checkCancellation(cancellation)
                appliedPaginatedLayout = layout
                layoutExceedingPages = outcome.exceedingPages
                try? FileManager.default.removeItem(at: exportedPDFURL)
                producedURL = laidURL
            } catch let error as OfficePDFPhysicalLayout.LayoutError {
                try? FileManager.default.removeItem(at: laidURL)
                throw OfficePDFExportError.physicalLayoutFailed(
                    reason: error.errorDescription ?? "unknown")
            } catch {
                try? FileManager.default.removeItem(at: laidURL)
                throw error
            }
        }
        let producedFacts = try OfficePDFPageSelection.inspect(producedURL)
        var finalName = outputFileName(for: sourceURL)
        var finalURL = child.appendingPathComponent(finalName)
        // The isolated engine always names its raw output `region.pdf`; make
        // sure that private name can never be the final user-facing name.
        if finalURL.standardizedFileURL.path == producedURL.standardizedFileURL.path {
            finalName = (finalName as NSString).deletingPathExtension + "-export.pdf"
            finalURL = child.appendingPathComponent(finalName)
        }
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw OfficePDFExportError.outputAlreadyExists(finalURL.path)
        }

        var appliedPages: [Int]?
        var pageCount: Int
        var pageSizes: [CGSize]
        if let range = plan.pageRange {
            let selected = try range.validated(pageCount: producedFacts.pageCount)
            let allPages = Array(1...producedFacts.pageCount)
            if selected == allPages {
                try moveItem(from: producedURL, to: finalURL)
                pageCount = producedFacts.pageCount
                pageSizes = producedFacts.pageSizes
            } else {
                let outcome = try OfficePDFPageSelection.select(
                    sourceURL: producedURL, pages: selected, outputURL: finalURL)
                appliedPages = outcome.selectedPages
                pageCount = outcome.pageCount
                pageSizes = outcome.pageSizes
                try? FileManager.default.removeItem(at: producedURL)
            }
        } else {
            try moveItem(from: producedURL, to: finalURL)
            pageCount = producedFacts.pageCount
            pageSizes = producedFacts.pageSizes
        }

        // Validate the final file again (selection may have rewritten it).
        // Report the final measured geometry, not the intermediate values.
        let finalFacts = try OfficePDFPageSelection.inspect(finalURL)
        guard finalFacts.pageCount == pageCount else {
            try? FileManager.default.removeItem(at: finalURL)
            throw OfficePDFExportError.pageSelectionFailed(reason: "final-page-verification-failed")
        }
        pageSizes = finalFacts.pageSizes
        try checkCancellation(cancellation)
        guard try FloeDigest.sha256Hex(ofFileAt: sourceURL) == sourceSHA256 else {
            try? FileManager.default.removeItem(at: finalURL)
            throw OfficePDFExportError.sourceChangedDuringExport
        }
        let values = try finalURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let byteCount = values.fileSize,
              byteCount > 0, byteCount <= maximumPDFBytes else {
            try? FileManager.default.removeItem(at: finalURL)
            throw OfficePDFExportError.invalidPDF(reason: "final-size")
        }
        let pdfSHA = try FloeDigest.sha256Hex(ofFileAt: finalURL)

        var notes = baseNotes
        if appliedPages != nil {
            notes.append(.finalPageSelectionApplied)
        }
        if omittedInkShapeCount != nil {
            notes.append(.handwritingOmitted)
        }
        if appliedPaginatedLayout != nil {
            notes.append(.physicalLayoutApplied)
            if (layoutExceedingPages ?? 0) > 0 {
                notes.append(.physicalLayoutContentExceedsPaper)
            }
        }
        return OfficePDFExportResult(
            pdfURL: finalURL,
            pdfSHA256: pdfSHA,
            byteCount: byteCount,
            pageCount: pageCount,
            pageSizes: pageSizes,
            sourceSHA256: sourceSHA256,
            sourceFormatExtension: sourceFormatExtension,
            plan: plan,
            appliedPrintPlan: appliedPrintPlan,
            appliedPageRange: appliedPages,
            omittedInkShapeCount: omittedInkShapeCount,
            appliedPaginatedLayout: appliedPaginatedLayout,
            layoutExceedingPages: layoutExceedingPages,
            notes: notes)
    }

    private static func notes(for plan: OfficePDFPrintPlan,
                              copyPlan: OfficePrintCopyPlan?,
                              legacy: Bool) -> [OfficePDFExportNote] {
        var notes: [OfficePDFExportNote] = []
        if plan.scope == .documentSettings {
            notes.append(.documentSettingsPreserved)
        }
        if let copyPlan {
            switch plan.scope {
            case .sheet, .sheetWithPrintArea, .sheets:
                if !copyPlan.suppressedSheetNames.isEmpty {
                    notes.append(.otherSheetsSuppressed)
                }
            case .documentSettings, .allVisibleSheets:
                break
            }
            if copyPlan.preservedDocumentPrintArea {
                notes.append(.documentPrintAreaPreserved)
            } else if copyPlan.removedPrintAreas > 0 {
                notes.append(.printAreasCleared)
            }
            if copyPlan.preservedPrintTitles > 0 {
                notes.append(.printTitlesPreserved)
            }
        }
        if legacy {
            notes.append(.legacyFormatFinalized)
        }
        return notes
    }

    // MARK: - Files

    private static func verifySource(_ url: URL,
                                     expectedSHA256: String,
                                     maximumBytes: Int?) throws -> String {
        let expected = expectedSHA256.lowercased()
        guard expected.count == 64,
              expected.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw OfficePDFExportError.invalidSourceIdentity
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw OfficePDFExportError.invalidSourceIdentity
        }
        if let maximumBytes, size > maximumBytes {
            throw OfficePDFExportError.invalidSourceIdentity
        }
        let actual = try FloeDigest.sha256Hex(ofFileAt: url)
        guard actual == expected else { throw OfficePDFExportError.staleSource }
        return actual
    }

    private static func prepareOwnedDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw OfficePDFExportError.outputDirectoryUnavailable
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw OfficePDFExportError.outputDirectoryUnavailable
        }
    }

    private static func validatePDFFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumPDFBytes else {
            throw OfficePDFExportError.invalidPDF(reason: "missing-or-oversized")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 5) ?? Data()
        guard header == Data("%PDF-".utf8) else {
            throw OfficePDFExportError.invalidPDF(reason: "not-a-pdf")
        }
    }

    private static func moveItem(from source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OfficePDFExportError.outputAlreadyExists(destination.path)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw OfficePDFExportError.outputDirectoryUnavailable
        }
    }

    private static func outputFileName(for source: URL) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        var cleaned = ""
        for scalar in stem.unicodeScalars {
            cleaned.append(allowed.contains(scalar) ? Character(String(scalar)) : "-")
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "document" : String(trimmed.prefix(80))
        return base + ".pdf"
    }

    private static func checkCancellation(_ token: CancellationToken?) throws {
        if token?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
    }
}

// MARK: - Final PDF page selection

/// Strict final-PDF page selection. Every PDFKit touch uses `PDFKitGate` and
/// `withPDFExceptionGuard`; a selection is written to a same-directory
/// temporary file, reopened and verified, then atomically moved. There is no
/// partial success and no overwrite.
enum OfficePDFPageSelection {
    struct Facts: Sendable, Equatable {
        var pageCount: Int
        var pageSizes: [CGSize]
    }

    struct Outcome: Sendable, Equatable {
        var pdfURL: URL
        var pageCount: Int
        var pageSizes: [CGSize]
        /// nil when the original PDF already was the requested order.
        var selectedPages: [Int]?
    }

    private static let maximumPagePoints: CGFloat = 200_000

    static func inspect(_ url: URL) throws -> Facts {
        try PDFKitGate.run {
            try withPDFExceptionGuard {
                guard let document = PDFDocument(url: url), !document.isLocked else {
                    throw OfficePDFExportError.invalidPDF(reason: "unreadable-or-locked")
                }
                let pageCount = document.pageCount
                guard pageCount > 0 else {
                    throw OfficePDFExportError.invalidPDF(reason: "no-pages")
                }
                guard pageCount <= OfficePDFExportService.maximumResultPages else {
                    throw OfficePDFExportError.invalidPDF(reason: "implausible-page-count")
                }
                var sizes: [CGSize] = []
                sizes.reserveCapacity(pageCount)
                for index in 0..<pageCount {
                    guard let page = document.page(at: index) else {
                        throw OfficePDFExportError.invalidPDF(reason: "missing-page")
                    }
                    let box = page.bounds(for: .cropBox)
                    guard box.width.isFinite, box.height.isFinite,
                          box.width > 0, box.height > 0,
                          box.width <= maximumPagePoints,
                          box.height <= maximumPagePoints else {
                        throw OfficePDFExportError.invalidPDF(reason: "invalid-page-geometry")
                    }
                    sizes.append(CGSize(width: box.width, height: box.height))
                }
                return Facts(pageCount: pageCount, pageSizes: sizes)
            }
        }
    }

    static func select(sourceURL: URL, pages: [Int], outputURL: URL) throws -> Outcome {
        guard sourceURL.standardizedFileURL.path != outputURL.standardizedFileURL.path else {
            throw OfficePDFExportError.pageSelectionFailed(reason: "output-is-source")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw OfficePDFExportError.outputAlreadyExists(outputURL.path)
        }
        return try PDFKitGate.run {
            try withPDFExceptionGuard {
                guard let document = PDFDocument(url: sourceURL), !document.isLocked else {
                    throw OfficePDFExportError.invalidPDF(reason: "unreadable-or-locked")
                }
                let pageCount = document.pageCount
                guard pageCount > 0, pageCount <= OfficePDFExportService.maximumResultPages else {
                    throw OfficePDFExportError.invalidPDF(reason: "implausible-page-count")
                }
                let selected = try OfficePDFPageRange(pages: pages).validated(pageCount: pageCount)
                let sourceSizes = try pageSizes(of: document)
                if selected == Array(1...pageCount) {
                    return Outcome(pdfURL: sourceURL, pageCount: pageCount,
                                   pageSizes: sourceSizes, selectedPages: nil)
                }
                let output = PDFDocument()
                for number in selected {
                    guard let page = document.page(at: number - 1)?.copy() as? PDFPage else {
                        throw OfficePDFExportError.pageSelectionFailed(reason: "missing-source-page")
                    }
                    output.insert(page, at: output.pageCount)
                }
                guard output.pageCount == selected.count else {
                    throw OfficePDFExportError.pageSelectionFailed(reason: "page-count-mismatch")
                }
                let temporary = outputURL.deletingLastPathComponent()
                    .appendingPathComponent(".floe-pdf-pages-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard output.write(to: temporary) else {
                    throw OfficePDFExportError.pageSelectionFailed(reason: "write-failed")
                }
                guard let reopened = PDFDocument(url: temporary), !reopened.isLocked,
                      reopened.pageCount == selected.count else {
                    throw OfficePDFExportError.pageSelectionFailed(reason: "reopen-failed")
                }
                let reopenedSizes = try pageSizes(of: reopened)
                for (offset, number) in selected.enumerated() {
                    let expected = sourceSizes[number - 1]
                    let actual = reopenedSizes[offset]
                    guard abs(actual.width - expected.width) < 0.01,
                          abs(actual.height - expected.height) < 0.01 else {
                        throw OfficePDFExportError.pageSelectionFailed(reason: "geometry-changed")
                    }
                }
                guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                    throw OfficePDFExportError.outputAlreadyExists(outputURL.path)
                }
                do {
                    try FileManager.default.moveItem(at: temporary, to: outputURL)
                } catch {
                    throw OfficePDFExportError.pageSelectionFailed(reason: "move-failed")
                }
                return Outcome(pdfURL: outputURL, pageCount: selected.count,
                               pageSizes: reopenedSizes, selectedPages: selected)
            }
        }
    }

    private static func pageSizes(of document: PDFDocument) throws -> [CGSize] {
        var sizes: [CGSize] = []
        sizes.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw OfficePDFExportError.invalidPDF(reason: "missing-page")
            }
            let box = page.bounds(for: .cropBox)
            guard box.width.isFinite, box.height.isFinite,
                  box.width > 0, box.height > 0,
                  box.width <= maximumPagePoints,
                  box.height <= maximumPagePoints else {
                throw OfficePDFExportError.invalidPDF(reason: "invalid-page-geometry")
            }
            sizes.append(CGSize(width: box.width, height: box.height))
        }
        return sizes
    }
}
#endif
