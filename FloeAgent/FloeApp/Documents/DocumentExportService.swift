// SPDX-License-Identifier: MPL-2.0
// FloeApp — the shared Notes/assistant document export service.
//
// One request/result contract feeds the assistant tools (`notes.export`,
// `notes.read section=exportCapabilities`) and gives the screen/Print UI the
// same Office facts through `OfficePDFExportService`. It owns no SwiftUI
// state: the assistant tool and a view both construct a plain request.
//
// Guarantees:
//  * Only a real renderer is used. A notebook PDF goes through the editor's
//    own page renderer; .floenote goes through NotesArchive; a mind map goes
//    through the Markdown outline renderer; an Office PDF goes through the
//    shared isolated `OfficePDFExportService`; `original` copies the exact
//    saved/committed resource. Nothing is synthesized or relabelled.
//  * An open Office editor with unsaved content is committed through its own
//    production save transaction BEFORE reading the resource. The existing
//    region-tool anchor/fence then proves the same revision/resource/hash and
//    session generation after the render; a concurrent stroke discards the
//    output instead of exporting stale bytes.
//  * A real copied file never overwrites a different existing file. Identical
//    bytes are an idempotent "alreadyExported" success.
//  * The committed file is measured (bytes, lowercase SHA-256, actual
//    MIME/UTI) and published through the existing S3-D
//    `RunOutputSnapshotStore` at the producer boundary. A legacy direct
//    caller without a real runtime binding keeps the truthful path/bytes
//    payload and gets no fabricated receipt.
//  * The Notes original is never modified; the workspace destination is the
//    only written path.

#if canImport(UIKit)
import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import FloeCore
import FloeDocuments
import FloeModels
import FloeNotes
import FloeTools
import FloeWorkspace

// MARK: - Request / capability values

enum DocumentExportFormat: String, Sendable, CaseIterable, Equatable {
    case pdf
    case floenote
    case markdown
    case original
}

/// Format-specific knobs supplied by the model. Structural validation happens
/// in `NotesExportTool`; document-kind and renderer validation happens here so
/// both tool args and a future UI request fail closed on unsupported options.
struct DocumentExportScope: Sendable, Equatable {
    /// Notebook only: exact page IDs in export order (the historical route).
    var pageIDs: [UUID]? = nil
    /// 1-based final page selection for a PDF. Strict `1-3,5` form.
    var pages: String? = nil
    /// Workbook only: exact worksheet tab name.
    var sheet: String? = nil
    /// Workbook only: 0-based tab-order index from real discovery.
    var sheetIndex: Int? = nil
    /// Workbook only: canonical `A1:R37` cell range (requires a sheet).
    var cellRange: String? = nil
    /// Workbook only: print every visible sheet with full content.
    var workbook: Bool? = nil
    /// Workbook only: print exactly the chosen worksheet tabs, each with its
    /// full content, in workbook tab order. Mutually exclusive with
    /// `sheet`/`sheetIndex`/`workbook`/`cellRange`/`usePrintArea`.
    var sheets: [String]? = nil
    /// Workbook only: print the one named sheet's OWN saved print area
    /// (full content when it declares none). Requires `sheet` or
    /// `sheetIndex`, never together with `cellRange`.
    var usePrintArea: Bool? = nil
    /// Workbook page setup overrides. `nil` preserves the document's own value.
    var paper: String? = nil
    var orientation: String? = nil
    var fit: String? = nil
    var margins: String? = nil
    /// Workbook only: exact `pageSetup@scale` percent (10…400). Mutually
    /// exclusive with `fit` and `fitPagesWide`/`fitPagesTall`.
    var scalePercent: Int? = nil
    /// Workbook only: fit-to-pages budget; both must be set together and are
    /// mutually exclusive with `fit` and `scalePercent`.
    var fitPagesWide: Int? = nil
    var fitPagesTall: Int? = nil
}

struct DocumentExportRequest: Sendable, Equatable {
    var documentID: UUID
    var format: DocumentExportFormat
    var scope: DocumentExportScope
    var expectedRevision: Int?
    /// Workspace-relative destination. nil chooses a new `exports/` path.
    var targetPath: String?
}

struct DocumentExportResult: Sendable, Equatable {
    var documentID: UUID
    var revision: Int
    var sourceState: String
    var sourceSHA256: String?
    var format: String
    var displayName: String
    var relativePath: String
    var fileURL: URL
    var mimeType: String
    var uti: String?
    var byteCount: Int
    var sha256: String
    var pageCount: Int?
    var selectedPages: [Int]?
    var verification: String
    var warnings: [String]
    var status: String
    var outputFile: RunOutputFile?
}

struct DocumentExportCapabilities: Encodable, Sendable, Equatable {
    struct FormatInfo: Encodable, Sendable, Equatable {
        var format: String
        var supported: Bool
        var outputExtension: String?
        var reason: String?
    }
    struct SheetInfo: Encodable, Sendable, Equatable {
        var index: Int
        var name: String
        var visible: Bool
    }
    struct PDFInfo: Encodable, Sendable, Equatable {
        var engine: String?
        var pageCount: Int?
        var pagesKnown: Bool
        var pageIDsSupported: Bool
        var finalPageRangeSupported: Bool
        var sheetScopeSupported: Bool
        var workbookScopeSupported: Bool
        /// Workbook only: the `.sheets(names:)` explicit multi-tab selection.
        var selectedSheetsScopeSupported: Bool = false
        /// Workbook only: `.sheetWithPrintArea(name)` — print the tab's own
        /// saved `_xlnm.Print_Area`.
        var printAreaScopeSupported: Bool = false
        var cellRangeSupported: Bool
        var customPageSetupSupported: Bool
        /// Workbook only: exact `pageSetup@scale` percent.
        var exactScaleSupported: Bool = false
        var scalePercentRange: [Int]? = nil
        /// Workbook only: exact `fitToWidth`×`fitToHeight` page budget.
        var fitPageCountSupported: Bool = false
        var fitPagesMaximum: Int? = nil
        var supportedPaper: [String]
        var supportedOrientation: [String]
        var supportedFit: [String]
        var supportedMargins: [String]
        var selectedPagesLimit: Int
        var sheets: [SheetInfo]?
        var layoutNote: String?
    }
    struct LiveEditorInfo: Encodable, Sendable, Equatable {
        var bound: Bool
        var editable: Bool
    }

    var documentID: UUID
    var title: String
    var kind: String
    var revision: Int
    var sourceFileName: String?
    var sourceSHA256: String?
    var formats: [FormatInfo]
    var pdf: PDFInfo?
    var liveEditor: LiveEditorInfo
    var guidance: String
}

/// Internal plan/result bridge kept separate from the model payload so the
/// tool only ever serializes safe, path-relative facts.
private struct RenderedExport {
    var stagedURL: URL
    var displayName: String
    var fileExtension: String
    var pageCount: Int?
    var selectedPages: [Int]?
    var verification: String
    var warnings: [String]
    var sourceSHA256: String?
}

// MARK: - Service

@MainActor
enum DocumentExportService {
    static let maximumResultBytes = RunOutputCaps.standard.perFileBytes

    // MARK: Capabilities

    static func capabilities(documentID: UUID,
                             includeLayout: Bool,
                             store: NotesStore) async throws -> DocumentExportCapabilities {
        let document = try await store.document(documentID)
        var formats: [DocumentExportCapabilities.FormatInfo] = []
        var pdf: DocumentExportCapabilities.PDFInfo?
        var sourceFileName: String?
        var sourceSHA: String?
        let liveBound = NotesOfficeLiveBinding.boundSession(
            documentID: document.id, fileName: document.officeFileName)
        let liveEditor = DocumentExportCapabilities.LiveEditorInfo(
            bound: liveBound != nil,
            editable: liveBound.map { !$0.readOnly } ?? false)

        switch document.kind {
        case .notebook:
            formats.append(.init(format: "pdf", supported: true, outputExtension: "pdf", reason: nil))
            formats.append(.init(format: "floenote", supported: true, outputExtension: "floenote", reason: nil))
            formats.append(.init(format: "markdown", supported: false, outputExtension: "md",
                                 reason: "The Markdown renderer is available for mind maps only."))
            formats.append(.init(format: "original", supported: false, outputExtension: nil,
                                 reason: "Notebooks have no single original file; use pdf or floenote."))
            pdf = DocumentExportCapabilities.PDFInfo(
                engine: "notebookRenderer",
                pageCount: document.pages.count,
                pagesKnown: true,
                pageIDsSupported: true,
                finalPageRangeSupported: true,
                sheetScopeSupported: false,
                workbookScopeSupported: false,
                cellRangeSupported: false,
                customPageSetupSupported: false,
                supportedPaper: [],
                supportedOrientation: [],
                supportedFit: [],
                supportedMargins: [],
                selectedPagesLimit: OfficePDFPageRange.maximumSelectedPages,
                sheets: nil,
                layoutNote: nil)
        case .mindMap:
            formats.append(.init(format: "pdf", supported: false, outputExtension: "pdf",
                                 reason: "No faithful mind-map PDF renderer exists in this build."))
            formats.append(.init(format: "floenote", supported: true, outputExtension: "floenote", reason: nil))
            formats.append(.init(format: "markdown", supported: true, outputExtension: "md", reason: nil))
            formats.append(.init(format: "original", supported: false, outputExtension: nil,
                                 reason: "The Markdown outline is the exact text output; use markdown."))
        case .engineering:
            formats.append(.init(format: "pdf", supported: false, outputExtension: "pdf",
                                 reason: "CAD/engineering sources have no PDF renderer in this build."))
            formats.append(.init(format: "floenote", supported: true, outputExtension: "floenote", reason: nil))
            formats.append(.init(format: "markdown", supported: false, outputExtension: "md",
                                 reason: "Only mind maps export as Markdown."))
            formats.append(.init(format: "original", supported: true,
                                 outputExtension: engineeringExtension(of: document), reason: nil))
            sourceFileName = document.engineeringFileName
            sourceSHA = try await hashResourceIfAvailable(document.engineeringResourceID, store: store)
        case .office:
            let ext = (document.officeFileName.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
            sourceFileName = document.officeFileName
            sourceSHA = try await hashResourceIfAvailable(document.officeResourceID, store: store)
            let support = OfficePDFFormatSupport.resolve(forExtension: ext)
            let canExportPDF = support?.supportsSavedIsolatedExport == true
            formats.append(.init(
                format: "pdf", supported: canExportPDF, outputExtension: "pdf",
                reason: canExportPDF
                    ? nil
                    : "A saved Office PDF export is available for .docx, .xlsx and .pptx. This source is .\(ext); export the open document from its editor or use original/floenote here."))
            formats.append(.init(format: "floenote", supported: true, outputExtension: "floenote", reason: nil))
            formats.append(.init(format: "markdown", supported: false, outputExtension: "md",
                                 reason: "Only mind maps export as Markdown."))
            formats.append(.init(format: "original", supported: true, outputExtension: ext, reason: nil))
            #if canImport(UIKit) && canImport(WebKit) && canImport(FloeOfficeNative)
            if let capability = OfficePDFExportService.capability(forExtension: ext) {
                var sheets: [DocumentExportCapabilities.SheetInfo]?
                var layoutNote: String?
                if includeLayout, canExportPDF, ext == "xlsx",
                   let resourceID = document.officeResourceID {
                    let url = try await store.resourceURL(resourceID)
                    let expected = sourceSHA
                    let located = try await Task.detached(priority: .utility) {
                        try OfficeRegionExport.workbookSheets(sourceURL: url, expectedSHA256: expected)
                    }.value
                    sheets = located.map {
                        .init(index: $0.index, name: $0.name, visible: $0.isVisible)
                    }
                    layoutNote = "Sheet names/indexes come from the saved workbook in tab order. The final PDF page count depends on the chosen scope and page setup; it is measured by the real export."
                } else if includeLayout, ext == "docx" || ext == "pptx" {
                    layoutNote = "The page count of a Word/PowerPoint document is measured from the real exported PDF; it is not inferred locally."
                }
                pdf = DocumentExportCapabilities.PDFInfo(
                    engine: canExportPDF ? "savedIsolatedOfficePDF" : nil,
                    pageCount: nil,
                    pagesKnown: false,
                    pageIDsSupported: false,
                    finalPageRangeSupported: canExportPDF && capability.finalPageRange,
                    sheetScopeSupported: capability.sheetScope,
                    workbookScopeSupported: capability.sheetScope,
                    selectedSheetsScopeSupported: canExportPDF && capability.selectedSheetsScope,
                    printAreaScopeSupported: canExportPDF && capability.printAreaScope,
                    cellRangeSupported: capability.sheetScope,
                    customPageSetupSupported: capability.customPageSetup,
                    exactScaleSupported: canExportPDF && capability.exactScale,
                    scalePercentRange: canExportPDF && capability.exactScale
                        ? [OfficePDFScale.minimumPercent, OfficePDFScale.maximumPercent] : nil,
                    fitPageCountSupported: canExportPDF && capability.fitPageCount,
                    fitPagesMaximum: canExportPDF && capability.fitPageCount
                        ? OfficePDFFitPages.maximum : nil,
                    supportedPaper: capability.customPageSetup ? OfficePDFPaper.allCases.map(\.rawValue) : [],
                    supportedOrientation: capability.customPageSetup ? OfficePDFOrientation.allCases.map(\.rawValue) : [],
                    supportedFit: capability.customPageSetup ? OfficePDFFit.allCases.map(\.rawValue) : [],
                    supportedMargins: capability.customPageSetup ? OfficePDFMargins.allCases.map(\.rawValue) : [],
                    selectedPagesLimit: OfficePDFPageRange.maximumSelectedPages,
                    sheets: sheets,
                    layoutNote: layoutNote)
            }
            #endif
        }

        return DocumentExportCapabilities(
            documentID: document.id,
            title: document.title,
            kind: document.kind.rawValue,
            revision: document.revision,
            sourceFileName: sourceFileName,
            sourceSHA256: sourceSHA,
            formats: formats,
            pdf: pdf,
            liveEditor: liveEditor,
            guidance: guidance(for: document, formats: formats, pdf: pdf, liveEditor: liveEditor))
    }

    // MARK: Export

    static func export(_ request: DocumentExportRequest,
                       store: NotesStore,
                       context: ToolContext,
                       artifactRoot: URL? = nil) async throws -> DocumentExportResult {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "临时对话不会保留导出文件。请在普通任务或手记中导出。",
                "Temporary chats do not keep exported files. Export from an ordinary task or from Notes."))
        }
        guard let conversation = context.conversationID else {
            throw NoteError.invalidOperation(FloeL10n.l("notes.notes_agent_tools.the_task_has_no_notes_scope"))
        }
        guard let root = context.workspaceRootURL else {
            throw NoteError.invalidOperation(FloeL10n.l("notes.notes_agent_tools.the_task_has_no_workspace"))
        }
        // Never export a document this conversation cannot read.
        try await store.authorize(conversationID: conversation, documentID: request.documentID, editing: false)
        var document = try await store.document(request.documentID)
        if let expected = request.expectedRevision, document.revision != expected { throw NoteError.conflict }
        try validate(request: request, document: document)

        // Resolve the destination before rendering so an unsafe/occupied path
        // fails before any engine work starts.
        let (relativePath, destination) = try resolveDestination(
            request: request, document: document, root: root, context: context)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".notes-export-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Live Office commit + quiescence anchor. This mirrors the production
        // region tool: the visible editor's own save chain runs first, then
        // the same exact revision/resource/hash + session identity must hold
        // after the render, or the output is discarded.
        var revision = document.revision
        var sourceState = "savedResource"
        var anchor: NotesReadTool.RegionRenderAnchor?
        var officeResourceID = document.officeResourceID
        var provenSHA: String?
        if document.kind == .office {
            let prepared = try await prepareOfficeSource(document: document, store: store,
                                                         cancellation: context.cancellation)
            document = prepared.document
            revision = prepared.revision
            officeResourceID = prepared.resourceID
            provenSHA = prepared.sha256
            sourceState = prepared.sourceState
            anchor = prepared.anchor
        }

        let rendered: RenderedExport
        do {
            rendered = try await render(request: request, document: document, revision: revision,
                                        officeResourceID: officeResourceID, provenSHA: provenSHA,
                                        staging: staging, store: store, context: context)
        } catch {
            // A produced-but-obsolete output is never committed. The staging
            // file is removed by the defer above.
            throw error
        }
        try context.cancellation.throwIfCancelled()

        // Post-render quiescence revalidation (Office only). A stroke can
        // start during the render without touching the Notes resource.
        if document.kind == .office {
            try await validateOfficeQuiescence(document: document, revision: revision,
                                               resourceID: officeResourceID,
                                               sha256: provenSHA, anchor: anchor,
                                               store: store, cancellation: context.cancellation)
        } else {
            let final = try await store.document(document.id)
            guard final.revision == revision else { throw NoteError.conflict }
        }

        let committed = try await commit(staged: rendered.stagedURL, to: destination,
                                         relativePath: relativePath, context: context)
        let type = typeInfo(forExtension: rendered.fileExtension)
        let result = DocumentExportResult(
            documentID: document.id,
            revision: revision,
            sourceState: sourceState,
            sourceSHA256: rendered.sourceSHA256 ?? provenSHA,
            format: request.format.rawValue,
            displayName: destination.lastPathComponent,
            relativePath: relativePath,
            fileURL: destination,
            mimeType: type.mime,
            uti: type.uti,
            byteCount: committed.byteCount,
            sha256: committed.sha256,
            pageCount: rendered.pageCount,
            selectedPages: rendered.selectedPages,
            verification: rendered.verification,
            warnings: rendered.warnings,
            status: committed.status,
            outputFile: nil)
        return try await publishIfRequired(result, context: context, artifactRoot: artifactRoot)
    }

    // MARK: - Office live source

    private struct PreparedOfficeSource {
        var document: NoteDocument
        var revision: Int
        var resourceID: UUID
        var sha256: String?
        var sourceState: String
        var anchor: NotesReadTool.RegionRenderAnchor?
    }

    private static func prepareOfficeSource(document: NoteDocument,
                                            store: NotesStore,
                                            cancellation: CancellationToken) async throws -> PreparedOfficeSource {
        guard let resourceID = document.officeResourceID else { throw NoteError.resourceUnavailable }
        // The saved resource digest is the fallback truth even when no live
        // editor is bound; it also anchors the post-render scalar proof if a
        // session appears mid-render.
        let savedURL = try await store.resourceURL(resourceID)
        let savedSHA = try await Task.detached(priority: .userInitiated) {
            try FloeDigest.sha256Hex(ofFileAt: savedURL)
        }.value
        var prepared = PreparedOfficeSource(
            document: document, revision: document.revision, resourceID: resourceID,
            sha256: savedSHA, sourceState: "savedResource", anchor: nil)
        guard let bound = NotesOfficeLiveBinding.boundSession(
            documentID: document.id, fileName: document.officeFileName) else {
            return prepared
        }
        if bound.readOnly { return prepared }
        let proof = await bound.requestAutosaveTransaction(reason: "exportStaging")
        try cancellation.throwIfCancelled()
        guard proof.isCommittedState,
              proof.documentID == document.id,
              proof.dirtyAfterTransaction == false,
              let proofRevision = proof.revision,
              let proofResourceID = proof.resourceID,
              let proofSHA = proof.packageSHA256 else {
            let reason = proof.reason ?? "unknown"
            let detail = proof.error.map { " (\($0.prefix(200)))" } ?? ""
            throw NoteError.invalidOperation(OfficeInkText.t(
                "当前 Office 编辑器无法证明本文件已保存且静止（状态=\(proof.outcome.rawValue)，原因=\(reason)）\(detail)。未导出任何文件；请等当前操作完成或抬笔后重试。",
                "The live Office editor could not prove a saved, quiescent state for this exact document (outcome=\(proof.outcome.rawValue), reason=\(reason))\(detail). Nothing was exported; wait for the current operation or lift the pen, then retry."))
        }
        let latest = try await store.document(document.id)
        guard latest.revision == proofRevision, latest.officeResourceID == proofResourceID else {
            throw NoteError.conflict
        }
        let stillBound = NotesOfficeLiveBinding.boundSession(
            documentID: document.id, fileName: document.officeFileName) === bound
        guard stillBound else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "导出期间 Office 编辑器已关闭或切换；未导出任何文件。",
                "The live Office editor closed or switched during the save; nothing was exported."))
        }
        prepared.document = latest
        prepared.revision = proofRevision
        prepared.resourceID = proofResourceID
        prepared.sha256 = proofSHA.lowercased()
        prepared.sourceState = proof.outcome == .saved ? "liveCommitted" : "liveAlreadySaved"
        prepared.anchor = NotesReadTool.RegionRenderAnchor(
            session: bound, documentID: document.id,
            revision: proofRevision, resourceID: proofResourceID,
            sha256: proofSHA.lowercased(),
            sessionIdentity: (proof.sessionGeneration, proof.sessionCorrelationID))
        return prepared
    }

    private static func validateOfficeQuiescence(document: NoteDocument,
                                                 revision: Int,
                                                 resourceID: UUID?,
                                                 sha256: String?,
                                                 anchor: NotesReadTool.RegionRenderAnchor?,
                                                 store: NotesStore,
                                                 cancellation: CancellationToken) async throws {
        guard let resourceID else { throw NoteError.resourceUnavailable }
        if let anchor {
            let stillBound = NotesOfficeLiveBinding.boundSession(
                documentID: document.id, fileName: document.officeFileName) === anchor.session
            guard stillBound else {
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "导出期间 Office 编辑器已关闭或切换；已丢弃本次导出。",
                    "The live Office editor closed or switched during the export; the produced file was discarded."))
            }
            let validation = await anchor.session.requestAutosaveTransaction(reason: "exportValidation")
            try cancellation.throwIfCancelled()
            guard NotesReadTool.regionValidationStillQuiescent(validation, anchor: anchor) else {
                throw NoteError.conflict
            }
        } else if let appeared = NotesOfficeLiveBinding.boundSession(
                    documentID: document.id, fileName: document.officeFileName), !appeared.readOnly {
            // The editor appeared mid-render. The visible state can no longer
            // be proven equal to the saved package; run the same scalar proof.
            let validation = await appeared.requestAutosaveTransaction(reason: "exportValidation")
            try cancellation.throwIfCancelled()
            let scalarAnchor = NotesReadTool.RegionRenderAnchor(
                session: appeared, documentID: document.id, revision: revision,
                resourceID: resourceID, sha256: sha256 ?? "", sessionIdentity: nil)
            guard NotesReadTool.regionValidationStillQuiescent(validation, anchor: scalarAnchor) else {
                throw NoteError.conflict
            }
        }
        let final = try await store.document(document.id)
        guard final.revision == revision, final.officeResourceID == resourceID else {
            throw NoteError.conflict
        }
    }

    // MARK: - Render

    private static func render(request: DocumentExportRequest,
                               document: NoteDocument,
                               revision: Int,
                               officeResourceID: UUID?,
                               provenSHA: String?,
                               staging: URL,
                               store: NotesStore,
                               context: ToolContext) async throws -> RenderedExport {
        switch request.format {
        case .pdf:
            if document.kind == .notebook {
                return try await renderNotebookPDF(request: request, document: document,
                                                   revision: revision, staging: staging, store: store)
            }
            guard document.kind == .office else {
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "此文档没有可用的 PDF 渲染器。",
                    "No PDF renderer exists for this document kind."))
            }
            return try await renderOfficePDF(request: request, document: document,
                                             resourceID: officeResourceID, provenSHA: provenSHA,
                                             staging: staging, store: store, context: context)
        case .floenote:
            try await NotesArchive.export(document: document, store: store, to: staging)
            try context.cancellation.throwIfCancelled()
            let verification = try await NotesExportTool.verifyArchive(staging)
            return RenderedExport(stagedURL: staging, displayName: staging.lastPathComponent,
                                  fileExtension: "floenote", pageCount: nil, selectedPages: nil,
                                  verification: verification, warnings: [], sourceSHA256: nil)
        case .markdown:
            guard document.kind == .mindMap else {
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "只有导图可以导出为 Markdown。",
                    "Only mind maps export as Markdown."))
            }
            let artifact = try await NotesExport.outline(document: document)
            defer {
                try? FileManager.default.removeItem(at: artifact.url.deletingLastPathComponent())
                artifact.lease?.release()
            }
            try context.cancellation.throwIfCancelled()
            try FileManager.default.copyItem(at: artifact.url, to: staging)
            return RenderedExport(stagedURL: staging, displayName: staging.lastPathComponent,
                                  fileExtension: "md", pageCount: nil, selectedPages: nil,
                                  verification: "markdown-outline-rendered", warnings: [],
                                  sourceSHA256: nil)
        case .original:
            return try await renderOriginal(document: document,
                                            resourceID: officeResourceID,
                                            provenSHA: provenSHA, staging: staging,
                                            store: store, context: context)
        }
    }

    private static func renderNotebookPDF(request: DocumentExportRequest,
                                          document: NoteDocument,
                                          revision: Int,
                                          staging: URL,
                                          store: NotesStore) async throws -> RenderedExport {
        let selected: [NotePage]
        var selectedNumbers: [Int]?
        if let pageIDs = request.scope.pageIDs {
            selected = try NoteExportSelection.pages(of: document, pageIDs: pageIDs)
            selectedNumbers = selected.compactMap { page in
                document.pages.firstIndex(where: { $0.id == page.id }).map { $0 + 1 }
            }
        } else if let text = request.scope.pages {
            guard let range = OfficePDFPageRange.parse(text) else {
                throw NoteError.invalidOperation(OfficeInkText.t("页码格式无效。", "The page selection is invalid."))
            }
            let numbers = try range.validated(pageCount: document.pages.count)
            selectedNumbers = numbers
            selected = numbers.map { document.pages[$0 - 1] }
        } else {
            selected = document.pages
        }
        guard !selected.isEmpty else {
            throw NoteError.invalidOperation(OfficeInkText.t("没有可导出的页面。", "There are no pages to export."))
        }
        let artifact = try await NotesExport.pdf(document: document, pages: selected, store: store) { _, _ in }
        defer {
            try? FileManager.default.removeItem(at: artifact.url.deletingLastPathComponent())
            artifact.lease?.release()
        }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: artifact.url, to: staging)
        let pageCount = PDFKitGate.run { CGPDFDocument(staging as CFURL)?.numberOfPages }
        guard pageCount == selected.count else {
            throw NoteError.invalidDocument(FloeL10n.l("notes.notes_agent_tools.the_exported_pdf_could_not_be"))
        }
        return RenderedExport(stagedURL: staging, displayName: staging.lastPathComponent,
                              fileExtension: "pdf", pageCount: pageCount,
                              selectedPages: selectedNumbers,
                              verification: "reopen-verified pageCount=\(selected.count)",
                              warnings: [], sourceSHA256: nil)
    }

    private static func renderOfficePDF(request: DocumentExportRequest,
                                        document: NoteDocument,
                                        resourceID: UUID?,
                                        provenSHA: String?,
                                        staging: URL,
                                        store: NotesStore,
                                        context: ToolContext) async throws -> RenderedExport {
        guard let resourceID else { throw NoteError.resourceUnavailable }
        guard let fileExtension = NotesOfficeResourceStaging.validatedExtension(of: document.officeFileName),
              OfficeDocumentFormat(fileExtension: fileExtension) != nil else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "此 Office 文件的已保存 PDF 导出不可用。请导出原始文件或 .floenote。",
                "A saved PDF export is not available for this Office file. Export the original or a .floenote archive instead."))
        }
        let sourceURL = try await store.resourceURL(resourceID)
        let actualSHA = try await Task.detached(priority: .userInitiated) {
            try FloeDigest.sha256Hex(ofFileAt: sourceURL)
        }.value
        if let provenSHA, actualSHA != provenSHA.lowercased() {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "已验证的包摘要与当前资源不一致；未导出任何文件。",
                "The proven package digest does not match the current resource; nothing was exported."))
        }
        let staged = try NotesOfficeResourceStaging.stage(source: sourceURL, fileExtension: fileExtension)
        defer { NotesOfficeResourceStaging.remove(staged) }
        let stagedSHA = try await Task.detached(priority: .userInitiated) {
            try FloeDigest.sha256Hex(ofFileAt: staged)
        }.value
        guard stagedSHA == actualSHA else { throw NoteError.resourceUnavailable }
        try context.cancellation.throwIfCancelled()

        var plan = OfficePDFPrintPlan()
        if let text = request.scope.pages, !text.isEmpty {
            guard let range = OfficePDFPageRange.parse(text) else {
                throw NoteError.invalidOperation(OfficeInkText.t("页码格式无效。", "The page selection is invalid."))
            }
            plan.pageRange = range
        }
        if let paper = request.scope.paper {
            guard let value = OfficePDFPaper(rawValue: paper) else {
                throw NoteError.invalidOperation(OfficeInkText.t("纸张选项无效。", "The paper option is invalid."))
            }
            plan.pageSetup.paper = value
        }
        if let orientation = request.scope.orientation {
            guard let value = OfficePDFOrientation(rawValue: orientation) else {
                throw NoteError.invalidOperation(OfficeInkText.t("方向选项无效。", "The orientation option is invalid."))
            }
            plan.pageSetup.orientation = value
        }
        if let fit = request.scope.fit {
            guard let value = OfficePDFFit(rawValue: fit) else {
                throw NoteError.invalidOperation(OfficeInkText.t("缩放选项无效。", "The fit option is invalid."))
            }
            plan.pageSetup.fit = value
        }
        if let margins = request.scope.margins {
            guard let value = OfficePDFMargins(rawValue: margins) else {
                throw NoteError.invalidOperation(OfficeInkText.t("页边距选项无效。", "The margin option is invalid."))
            }
            plan.pageSetup.margins = value
        }
        if let scalePercent = request.scope.scalePercent {
            plan.pageSetup.scalePercent = scalePercent
        }
        if (request.scope.fitPagesWide == nil) != (request.scope.fitPagesTall == nil) {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "fitPagesWide 与 fitPagesTall 必须同时提供。",
                "fitPagesWide and fitPagesTall must be provided together."))
        }
        if let wide = request.scope.fitPagesWide, let tall = request.scope.fitPagesTall {
            plan.pageSetup.fitPages = OfficePDFFitPages(width: wide, height: tall)
        }
        // Exactly one scaling control; the pure plan validator also refuses
        // this, but the assistant gets the dedicated sentence before any
        // engine work starts.
        guard plan.pageSetup.scalingControlCount <= 1 else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "fit、scalePercent 与 fitPages 只能选择一种。",
                "Choose only one of fit, scalePercent or fitPages."))
        }
        if fileExtension == "xlsx" {
            let selectedSheets = request.scope.sheets?.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let selectedSheets, !selectedSheets.isEmpty {
                guard request.scope.sheet == nil, request.scope.sheetIndex == nil,
                      request.scope.workbook != true, request.scope.cellRange == nil,
                      request.scope.usePrintArea != true else {
                    throw NoteError.invalidOperation(OfficeInkText.t(
                        "sheets 选择不能与 sheet/sheetIndex/workbook/cellRange/usePrintArea 同时使用。",
                        "sheets cannot be combined with sheet/sheetIndex/workbook/cellRange/usePrintArea."))
                }
                plan.scope = .sheets(names: selectedSheets)
            } else if request.scope.usePrintArea == true {
                // One explicit tab whose OWN saved print area is printed.
                // The tab identity resolution rules are the existing ones:
                // never a silent first-sheet fallback.
                guard request.scope.cellRange == nil, request.scope.sheets == nil else {
                    throw NoteError.invalidOperation(OfficeInkText.t(
                        "usePrintArea 只接受工作表名称或序号，不能搭配单元格区域或 sheets 选择。",
                        "usePrintArea accepts only a sheet name or index, never a cell range or sheets."))
                }
                let resolved = try Self.resolveWorkbookSheetName(
                    scope: request.scope, staged: staged, stagedSHA: stagedSHA)
                plan.scope = .sheetWithPrintArea(name: resolved)
            } else if let index = request.scope.sheetIndex {
                guard request.scope.sheet == nil else {
                    throw NoteError.invalidOperation(OfficeInkText.t(
                        "请只指定工作表名称或序号中的一个。",
                        "Specify either a sheet name or a sheet index, not both."))
                }
                let expected = stagedSHA
                let sheets = try await Task.detached(priority: .userInitiated) {
                    try OfficeRegionExport.workbookSheets(sourceURL: staged, expectedSHA256: expected)
                }.value
                guard sheets.indices.contains(index) else {
                    throw NoteError.invalidOperation(OfficeInkText.t(
                        "工作表序号不存在。请先读取 exportCapabilities 获取真实工作表列表。",
                        "That worksheet index does not exist. Read exportCapabilities first for the real sheet list."))
                }
                plan.scope = .sheet(name: sheets[index].name, cellRange: request.scope.cellRange)
            } else if let sheet = request.scope.sheet {
                plan.scope = .sheet(name: sheet, cellRange: request.scope.cellRange)
            } else if request.scope.workbook == true {
                plan.scope = .allVisibleSheets
            } else if request.scope.cellRange != nil {
                // Never fall back to the first sheet. A range needs an
                // explicit sheet identity.
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "指定单元格区域时还必须指定工作表名称或序号。",
                    "A cell range also requires an explicit worksheet name or index."))
            }
        }
        try plan.validate(forExtension: fileExtension)

        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-notes-pdf-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        do {
            #if canImport(WebKit) && canImport(FloeOfficeNative)
            let serviceResult = try await OfficePDFExportService.export(OfficePDFExportRequest(
                sourceURL: staged, sourceSHA256: stagedSHA, formatExtension: fileExtension,
                plan: plan, ownedDirectory: owned, cancellation: context.cancellation))
            try context.cancellation.throwIfCancelled()
            let exportedSHA = try await Task.detached(priority: .userInitiated) {
                try FloeDigest.sha256Hex(ofFileAt: serviceResult.pdfURL)
            }.value
            guard exportedSHA == serviceResult.pdfSHA256 else { throw NoteError.resourceUnavailable }
            try FileManager.default.copyItem(at: serviceResult.pdfURL, to: staging)
            let stagedPDFSHA = try await Task.detached(priority: .userInitiated) {
                try FloeDigest.sha256Hex(ofFileAt: staging)
            }.value
            guard stagedPDFSHA == serviceResult.pdfSHA256 else { throw NoteError.resourceUnavailable }
            let pageCount = PDFKitGate.run { CGPDFDocument(staging as CFURL)?.numberOfPages }
            guard pageCount == serviceResult.pageCount else {
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "导出的 PDF 页数与服务测量结果不一致；未提交文件。",
                    "The exported PDF page count disagrees with the measured service result; nothing was committed."))
            }
            var verification = "office-engine-pdf reopen-verified pageCount=\(serviceResult.pageCount)"
            if let applied = serviceResult.appliedPrintPlan {
                verification += " scope=\(scopeDescription(applied.scope)) sheets=\(applied.printedSheetNames.count)"
                if let area = applied.printAreaReference { verification += " printArea=\(area)" }
            }
            if let pages = serviceResult.appliedPageRange {
                verification += " finalPages=\(pages.map(String.init).joined(separator: ","))"
            }
            let warnings = serviceResult.notes
                .filter {
                    $0 == .otherSheetsSuppressed || $0 == .printAreasCleared
                        || $0 == .documentPrintAreaPreserved
                }
                .map(\.rawValue)
            await Self.removeOwnedDirectoryUnlessQuarantined(owned)
            return RenderedExport(stagedURL: staging, displayName: staging.lastPathComponent,
                                  fileExtension: "pdf", pageCount: pageCount,
                                  selectedPages: serviceResult.appliedPageRange,
                                  verification: verification, warnings: warnings,
                                  sourceSHA256: stagedSHA)
            #else
            throw NoteError.invalidOperation(OfficeInkText.t(
                "此构建未包含 Office PDF 引擎，无法导出 Office PDF。",
                "This build does not include the Office PDF engine, so Office PDF export is unavailable."))
            #endif
        } catch {
            await Self.removeOwnedDirectoryUnlessQuarantined(owned)
            throw error
        }
    }

    /// Resolves one explicit sheet identity (name xor index — never a silent
    /// first-sheet fallback) against the staged workbook's real tab order.
    private static func resolveWorkbookSheetName(scope: DocumentExportScope,
                                                 staged: URL,
                                                 stagedSHA: String) async throws -> String {
        guard (scope.sheet == nil) != (scope.sheetIndex == nil) else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "usePrintArea 需要且只需要一个工作表名称或序号。",
                "usePrintArea requires exactly one sheet name or index."))
        }
        if let index = scope.sheetIndex {
            let expected = stagedSHA
            let sheets = try await Task.detached(priority: .userInitiated) {
                try OfficeRegionExport.workbookSheets(sourceURL: staged, expectedSHA256: expected)
            }.value
            guard sheets.indices.contains(index) else {
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "工作表序号不存在。请先读取 exportCapabilities 获取真实工作表列表。",
                    "That worksheet index does not exist. Read exportCapabilities first for the real sheet list."))
            }
            return sheets[index].name
        }
        return scope.sheet!
    }

    private static func scopeDescription(_ scope: OfficePDFScope) -> String {
        switch scope {
        case .documentSettings: return "documentSettings"
        case .sheet(let name, let range): return "sheet(\(name)\(range.map { ",\($0)" } ?? ""))"
        case .sheetWithPrintArea(let name): return "sheetPrintArea(\(name))"
        case .sheets(let names): return "sheets(\(names.joined(separator: ",")))"
        case .allVisibleSheets: return "allVisibleSheets"
        }
    }

    private static func renderOriginal(document: NoteDocument,
                                       resourceID: UUID?,
                                       provenSHA: String?,
                                       staging: URL,
                                       store: NotesStore,
                                       context: ToolContext) async throws -> RenderedExport {
        let id: UUID
        let name: String
        switch document.kind {
        case .office:
            guard let officeID = document.officeResourceID, let fileName = document.officeFileName else {
                throw NoteError.resourceUnavailable
            }
            id = officeID
            name = fileName
        case .engineering:
            guard let engineeringID = document.engineeringResourceID,
                  let fileName = document.engineeringFileName else { throw NoteError.resourceUnavailable }
            id = engineeringID
            name = fileName
        default:
            throw NoteError.invalidOperation(OfficeInkText.t(
                "只有 Office 或工程文件可以导出原始文件。",
                "Only Office or engineering documents have an exact original file."))
        }
        guard resourceID == nil || resourceID == id else { throw NoteError.resourceUnavailable }
        let source = try await store.resourceURL(id)
        if let provenSHA {
            let actual = try await Task.detached(priority: .userInitiated) {
                try FloeDigest.sha256Hex(ofFileAt: source)
            }.value
            guard actual == provenSHA.lowercased() else { throw NoteError.resourceUnavailable }
        }
        try context.cancellation.throwIfCancelled()
        try FileManager.default.copyItem(at: source, to: staging)
        let digest = try await Task.detached(priority: .userInitiated) {
            try FloeDigest.sha256Hex(ofFileAt: staging)
        }.value
        let ext = (name as NSString).pathExtension.lowercased()
        return RenderedExport(stagedURL: staging, displayName: name, fileExtension: ext,
                              pageCount: nil, selectedPages: nil,
                              verification: "exact-original-copy sha256=\(digest)",
                              warnings: [], sourceSHA256: digest)
    }

    // MARK: - Validation

    private static func validate(request: DocumentExportRequest, document: NoteDocument) throws {
        let scope = request.scope
        let isPDF = request.format == .pdf
        let hasSheetsSelection = scope.sheets?.isEmpty == false
        let hasSheetScope = scope.sheet != nil || scope.sheetIndex != nil
            || scope.cellRange != nil || scope.workbook == true
            || hasSheetsSelection || scope.usePrintArea == true
        let hasPageSetup = scope.paper != nil || scope.orientation != nil
            || scope.fit != nil || scope.margins != nil
            || scope.scalePercent != nil || scope.fitPagesWide != nil || scope.fitPagesTall != nil
        guard scope.pageIDs == nil || (isPDF && scope.pages == nil) else {
            throw invalidScope()
        }
        guard isPDF || (scope.pages == nil && !hasSheetScope && !hasPageSetup) else {
            throw invalidScope()
        }
        if let pages = scope.pages {
            guard OfficePDFPageRange.parse(pages) != nil else { throw invalidScope() }
        }
        if let sheet = scope.sheet, sheet.utf8.count > 128 { throw invalidScope() }
        if let range = scope.cellRange, range.utf8.count > 24 { throw invalidScope() }
        if let index = scope.sheetIndex, !(0...255).contains(index) { throw invalidScope() }
        if scope.sheet != nil, scope.sheetIndex != nil { throw invalidScope() }
        if scope.workbook == true, scope.sheet != nil || scope.sheetIndex != nil || scope.cellRange != nil {
            throw invalidScope()
        }
        if scope.cellRange != nil, !hasSheetScope { throw invalidScope() }
        if let sheets = scope.sheets {
            guard !sheets.isEmpty,
                  sheets.count <= OfficePDFPrintPlan.maximumSelectedSheets,
                  sheets.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.utf8.count <= 128 }) else { throw invalidScope() }
            guard scope.sheet == nil, scope.sheetIndex == nil, scope.workbook != true,
                  scope.cellRange == nil, scope.usePrintArea != true else { throw invalidScope() }
        }
        if scope.usePrintArea == true {
            guard scope.cellRange == nil, scope.workbook != true,
                  scope.sheet != nil || scope.sheetIndex != nil else { throw invalidScope() }
        }
        if let scalePercent = scope.scalePercent,
           !(OfficePDFScale.minimumPercent...OfficePDFScale.maximumPercent).contains(scalePercent) {
            throw invalidScope()
        }
        if (scope.fitPagesWide == nil) != (scope.fitPagesTall == nil) { throw invalidScope() }
        if let wide = scope.fitPagesWide,
           !(OfficePDFFitPages.minimum...OfficePDFFitPages.maximum).contains(wide) { throw invalidScope() }
        if let tall = scope.fitPagesTall,
           !(OfficePDFFitPages.minimum...OfficePDFFitPages.maximum).contains(tall) { throw invalidScope() }
        guard (scope.fit != nil ? 1 : 0) + (scope.scalePercent != nil ? 1 : 0)
            + ((scope.fitPagesWide != nil || scope.fitPagesTall != nil) ? 1 : 0) <= 1 else {
            throw invalidScope()
        }

        switch request.format {
        case .pdf:
            switch document.kind {
            case .notebook:
                guard !hasSheetScope, !hasPageSetup else { throw invalidScope() }
            case .office:
                guard scope.pageIDs == nil else { throw invalidScope() }
                let ext = (document.officeFileName.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
                let support = OfficePDFFormatSupport.resolve(forExtension: ext)
                guard support?.supportsSavedIsolatedExport == true else {
                    throw NoteError.invalidOperation(OfficeInkText.t(
                        "此 Office 格式没有已保存 PDF 导出（仅支持 .docx、.xlsx、.pptx）。请导出原始文件或 .floenote。",
                        "A saved PDF export is not available for this Office format (only .docx, .xlsx and .pptx support it). Export the original or a .floenote archive instead."))
                }
                if !(support?.supportsSheetScope == true), hasSheetScope || hasPageSetup {
                    throw NoteError.invalidOperation(OfficeInkText.t(
                        "工作表和页面设置选项仅适用于 .xlsx 工作簿。Word/PowerPoint 只支持最终 PDF 页码。",
                        "Sheet and page-setup options apply to .xlsx workbooks only. Word/PowerPoint export supports the final PDF page range only."))
                }
            case .mindMap, .engineering:
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "此文档没有可用的 PDF 渲染器。",
                    "No PDF renderer exists for this document kind."))
            }
        case .floenote:
            guard !hasSheetScope, !hasPageSetup, scope.pages == nil, scope.pageIDs == nil else {
                throw invalidScope()
            }
        case .markdown:
            guard document.kind == .mindMap, !hasSheetScope, !hasPageSetup,
                  scope.pages == nil, scope.pageIDs == nil else {
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "只有导图可以导出为 Markdown。",
                    "Only mind maps export as Markdown."))
            }
        case .original:
            guard document.kind == .office || document.kind == .engineering,
                  !hasSheetScope, !hasPageSetup, scope.pages == nil, scope.pageIDs == nil else {
                throw NoteError.invalidOperation(OfficeInkText.t(
                    "只有 Office 或工程文件可以导出原始文件。",
                    "Only Office or engineering documents have an exact original file."))
            }
        }
    }

    private static func invalidScope() -> NoteError {
        NoteError.invalidOperation(OfficeInkText.t(
            "导出选项不适用于此文档。请先读取 notes.read section=exportCapabilities。",
            "The export options do not apply to this document. Read notes.read section=exportCapabilities first."))
    }

    // MARK: - Commit / publish

    private static func resolveDestination(request: DocumentExportRequest,
                                           document: NoteDocument,
                                           root: URL,
                                           context: ToolContext) throws -> (String, URL) {
        let relative: String
        if let target = request.targetPath, !target.isEmpty {
            try context.authorizeWorkspacePath(target)
            relative = target
        } else {
            let stem = defaultStem(for: request, document: document)
            let ext = defaultExtension(for: request, document: document)
            relative = try uniqueDefaultRelativePath(stem: stem, fileExtension: ext,
                                                     root: root, context: context)
        }
        let expectedExtension = defaultExtension(for: request, document: document)
        let actualExtension = (relative as NSString).pathExtension.lowercased()
        guard actualExtension == expectedExtension else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "目标文件扩展名必须是 .\(expectedExtension)。",
                "The destination extension must be .\(expectedExtension)."))
        }
        try context.authorizeWorkspacePath(relative)
        let destination = try WorkspacePathGuard(rootURL: root).resolve(relative)
        return (relative, destination)
    }

    private static func defaultStem(for request: DocumentExportRequest, document: NoteDocument) -> String {
        if request.format == .original {
            let name = document.officeFileName ?? document.engineeringFileName
            if let name, !name.isEmpty {
                return NotesExport.fileName((name as NSString).deletingPathExtension)
            }
        }
        return NotesExport.fileName(document.title)
    }

    private static func defaultExtension(for request: DocumentExportRequest, document: NoteDocument) -> String {
        switch request.format {
        case .pdf: return "pdf"
        case .floenote: return "floenote"
        case .markdown: return "md"
        case .original:
            let name = document.officeFileName ?? document.engineeringFileName ?? ""
            return (name as NSString).pathExtension.lowercased()
        }
    }

    private static func uniqueDefaultRelativePath(stem: String, fileExtension: String,
                                                  root: URL, context: ToolContext) throws -> String {
        let guarder = WorkspacePathGuard(rootURL: root)
        let safeStem = stem.isEmpty ? "export" : stem
        for index in 1...99 {
            let name = index == 1 ? "\(safeStem).\(fileExtension)" : "\(safeStem)-\(index).\(fileExtension)"
            let relative = "exports/\(name)"
            try context.authorizeWorkspacePath(relative)
            let url = try guarder.resolve(relative)
            if !FileManager.default.fileExists(atPath: url.path) { return relative }
        }
        throw NoteError.invalidOperation(OfficeInkText.t(
            "无法在 exports/ 中创建新文件名。",
            "Could not choose a new filename under exports/."))
    }

    private struct CommitReceipt {
        var byteCount: Int
        var sha256: String
        var status: String
    }

    private static func commit(staged: URL, to destination: URL, relativePath: String,
                               context: ToolContext) async throws -> CommitReceipt {
        let values = try staged.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumResultBytes else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "导出文件为空或超过单文件上限。",
                "The exported file is empty or exceeds the per-file limit."))
        }
        let stagedSHA = try await Task.detached(priority: .utility) {
            try FloeDigest.sha256Hex(ofFileAt: staged)
        }.value
        if FileManager.default.fileExists(atPath: destination.path) {
            let existingSHA = try await Task.detached(priority: .utility) {
                try FloeDigest.sha256Hex(ofFileAt: destination)
            }.value
            if existingSHA == stagedSHA {
                try? FileManager.default.removeItem(at: staged)
                let existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? size
                return CommitReceipt(byteCount: existingSize, sha256: existingSHA, status: "alreadyExported")
            }
            throw NoteError.invalidOperation(OfficeInkText.t(
                "目标位置已有不同内容的文件；导出不会覆盖它。请选择新的文件名。",
                "A different file already exists at \(relativePath); export never overwrites it. Choose a new filename."))
        }
        let receipt = try AtomicFileCommitter.commit(
            stagedFile: staged, to: destination,
            policy: FileCommitPolicy(
                conflict: .failIfExists,
                maxBytes: maximumResultBytes,
                checkCancellation: { try context.cancellation.throwIfCancelled() }))
        let finalSHA = try await Task.detached(priority: .utility) {
            try FloeDigest.sha256Hex(ofFileAt: receipt.url)
        }.value
        guard finalSHA == stagedSHA else {
            throw NoteError.invalidOperation(OfficeInkText.t(
                "导出文件写入后校验失败。",
                "The exported file failed verification after commit."))
        }
        return CommitReceipt(byteCount: receipt.byteCount, sha256: finalSHA, status: "exported")
    }

    private static func publishIfRequired(_ result: DocumentExportResult,
                                          context: ToolContext,
                                          artifactRoot: URL? = nil) async throws -> DocumentExportResult {
        var result = result
        switch RunOutputPublication.state(context) {
        case .legacyDirect:
            return result
        case .temporaryExempt:
            throw NoteError.invalidOperation(OfficeInkText.t(
                "临时对话不会保留导出文件。",
                "Temporary chats do not keep exported files."))
        case .partiallyBound:
            throw RunOutputPublication.partialBindingFailure
        case .required:
            do {
                let published = result
                let receipt = try await Task.detached(priority: .utility) {
                    try RunOutputSnapshotStore.publish(
                        RunOutputSnapshotRequest(
                            producerTool: NotesExportTool.name,
                            slot: "export",
                            commit: RunOutputCommit(
                                sourceURL: published.fileURL,
                                sha256: published.sha256,
                                byteCount: published.byteCount,
                                displayName: published.displayName,
                                mimeType: published.mimeType,
                                uti: published.uti)),
                        using: context,
                        artifactRoot: artifactRoot)
                }.value
                result.outputFile = receipt
                return result
            } catch let error as RunOutputSnapshotError {
                throw RunOutputPublication.publicationFailure(error)
            }
        }
    }

    // MARK: - Capability helpers

    private static func hashResourceIfAvailable(_ id: UUID?, store: NotesStore) async throws -> String? {
        guard let id else { return nil }
        let url = try await store.resourceURL(id)
        return try await Task.detached(priority: .utility) {
            try FloeDigest.sha256Hex(ofFileAt: url)
        }.value
    }

    private static func engineeringExtension(of document: NoteDocument) -> String? {
        guard let name = document.engineeringFileName else { return nil }
        return (name as NSString).pathExtension.lowercased()
    }

    private static func guidance(for document: NoteDocument,
                                 formats: [DocumentExportCapabilities.FormatInfo],
                                 pdf: DocumentExportCapabilities.PDFInfo?,
                                 liveEditor: DocumentExportCapabilities.LiveEditorInfo) -> String {
        var parts: [String] = []
        let supported = formats.filter(\.supported).map(\.format)
        parts.append("Supported formats here: \(supported.joined(separator: ", ")).")
        if let pdf {
            if pdf.pageIDsSupported {
                parts.append("For a notebook PDF, pass ordered pageIDs (or pages with 1-based numbers) to export a subset; omit both for every page.")
            }
            if pdf.sheetScopeSupported {
                parts.append("For a workbook PDF, pass an exact sheet or sheetIndex with an optional canonical cellRange, workbook=true for every visible sheet, sheets=[tab names] for an explicit multi-sheet full-content selection, usePrintArea=true with one sheet to print that sheet's own saved print area (full content when it declares none), optional paper/orientation/margins, exactly one scaling control (fit, scalePercent 10-400, or the paired fitPagesWide/fitPagesTall 1-99 page budget), and pages for the final PDF pages. A cellRange never implies the first sheet.")
            }
            if pdf.finalPageRangeSupported, !pdf.sheetScopeSupported {
                parts.append("Pass pages (1-based, e.g. 2-4,7) to select final PDF pages.")
            }
        }
        if liveEditor.bound, liveEditor.editable {
            parts.append("A live Office editor is open; export first runs its own save transaction and refuses on an active pen or unproven dirty state.")
        }
        parts.append("Export never overwrites a different existing file. Read this section again after changes.")
        return parts.joined(separator: " ")
    }

    // MARK: - Types

    private static func typeInfo(forExtension ext: String) -> (mime: String, uti: String?) {
        let lower = ext.lowercased()
        if lower == "floenote" {
            return ("application/vnd.floe.note", "org.floeagent.note")
        }
        if let type = UTType(filenameExtension: lower) {
            return (type.preferredMIMEType ?? "application/octet-stream", type.identifier)
        }
        return ("application/octet-stream", nil)
    }

    /// The backend deliberately retains its export child when the shared
    /// automatic gate is quarantined after an unacknowledged close. The outer
    /// lease must not delete the parent in that state either.
    private static func removeOwnedDirectoryUnlessQuarantined(_ url: URL) async {
        #if canImport(FloeOfficeNative)
        if await OfficeAutomaticExecutionGate.shared.isQuarantined { return }
        #endif
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
