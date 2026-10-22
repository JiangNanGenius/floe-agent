// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Foundation
import PDFKit
import FloeCore
import FloeTools
import FloeDocuments

/// The screen supplies real saved-source metadata; this form never reads an
/// editor selection, guesses a worksheet or modifies the source package.
enum OfficePDFExportPurpose: String, Identifiable {
    case export, printDocument
    var id: String { rawValue }
}

/// One modal intent survives SwiftUI task remounts. Ending the actual
/// presentation cancels its work; a transient child-view disappearance does not.
struct OfficePDFPresentationRequest: Identifiable {
    let id = UUID()
    let purpose: OfficePDFExportPurpose
    let cancellation = CancellationToken()
}

enum OfficePDFExportScreenError: Error, LocalizedError {
    case sourceChanged
    /// The mounted session is held by another in-flight operation right now.
    /// Nothing changed in the document: the same frozen source stays valid and
    /// the action can be attempted again once the holder settles. Distinct from
    /// `.sourceChanged`, which means the actual surface or bytes were replaced.
    case sessionBusy
    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            return OfficeInkText.t("文档已变化，请刷新后重试。", "The document changed. Refresh and try again.")
        case .sessionBusy:
            return OfficeInkText.t("文档正忙，请稍后重试。", "The document is busy. Try again shortly.")
        }
    }
}

/// A modal owns one producer. SwiftUI consumers may be cancelled/remounted
/// without cancelling that producer or starting a second save/copy.
@MainActor
final class OfficePDFPreparationCoordinator<Value> {
    @MainActor
    private final class Flight {
        let request: CancellationToken?
        let isCurrent: @MainActor () -> Bool
        var task: Task<Void, Never>?
        var result: Result<Value, Error>?
        init(request: CancellationToken?, isCurrent: @escaping @MainActor () -> Bool) {
            self.request = request; self.isCurrent = isCurrent
        }
    }
    private var active: Flight?

    func run(request: CancellationToken?,
             isCurrent: @escaping @MainActor () -> Bool,
             producer: @escaping @MainActor () async throws -> Value,
             observe: @escaping @MainActor (String) -> Void = { _ in }) async throws -> Value {
        try Task.checkCancellation()
        if request?.isCancelled == true { throw CancellationError() }
        // A different modal waits for the previous producer to release first.
        if let previous = active, previous.request !== request {
            await previous.task?.value
            try Task.checkCancellation()
            if request?.isCancelled == true { throw CancellationError() }
            guard isCurrent() else { throw OfficePDFExportScreenError.sourceChanged }
        }
        let flight: Flight
        if let existing = active {
            guard existing.request === request, existing.isCurrent(), isCurrent() else {
                throw OfficePDFExportScreenError.sessionBusy
            }
            flight = existing
            observe("joined")
        } else {
            guard isCurrent() else { throw OfficePDFExportScreenError.sourceChanged }
            flight = Flight(request: request, isCurrent: isCurrent)
            active = flight
            observe("started")
            flight.task = Task { @MainActor [weak self] in
                guard let self else { flight.result = .failure(CancellationError()); return }
                defer {
                    if self.active === flight { self.active = nil }
                    observe("settled")
                }
                do {
                    try Task.checkCancellation()
                    if request?.isCancelled == true { throw CancellationError() }
                    let value = try await producer()
                    try Task.checkCancellation()
                    if request?.isCancelled == true { throw CancellationError() }
                    guard flight.isCurrent() else { throw OfficePDFExportScreenError.sourceChanged }
                    flight.result = .success(value)
                } catch { flight.result = .failure(error) }
            }
        }
        await flight.task?.value
        try Task.checkCancellation()
        if request?.isCancelled == true { throw CancellationError() }
        guard isCurrent() else { throw OfficePDFExportScreenError.sourceChanged }
        guard let result = flight.result else { throw CancellationError() }
        return try result.get()
    }

    func cancel(request: CancellationToken? = nil) {
        guard let active else { return }
        if let request, active.request !== request { return }
        active.task?.cancel()
    }
}

struct OfficePDFExportChoices: Sendable, Equatable {
    enum Scope: String, CaseIterable {
        case document, currentSheet, workbook, selectedSheets, sheet
    }
    /// What one chosen worksheet prints: its full content (never a used-range
    /// crop, so off-cell ink/drawings stay on the pages), its own saved print
    /// area, or an explicit canonical cell range.
    enum SheetContent: String, CaseIterable { case full, printArea, range }
    enum Paper: String, CaseIterable { case document, a4, a3, letter, legal }
    enum Orientation: String, CaseIterable { case document, portrait, landscape }
    /// Exactly one scaling control. `.exactScale`/`.fitPages` write the same
    /// `pageSetup` members the preset modes already proved the engine reads.
    enum Fit: String, CaseIterable {
        case document, actualSize, width, page, exactScale, fitPages
    }
    enum Margins: String, CaseIterable { case document, normal, narrow, wide }
    /// Printed-gridlines choice. `.document` leaves the workbook's own
    /// `printOptions` untouched; on/off is written only into the private
    /// print copy (never cell borders, never the source package). Excel's
    /// own default prints no gridlines regardless of the screen display,
    /// so `.document` is the honest default.
    enum Gridlines: String, CaseIterable { case document, on, off }
    var scope: Scope = .document
    var sheetName = ""
    var sheetContent: SheetContent = .full
    var cellRange = ""
    var selectedSheetNames: [String] = []
    var paper: Paper = .document
    var orientation: Orientation = .document
    var fit: Fit = .document
    var scalePercentText = "100"
    var fitPagesWideText = "1"
    var fitPagesTallText = "1"
    var margins: Margins = .document
    var gridlines: Gridlines = .document
    var pages = ""

    /// Builds the pure plan. `sheetTabOrder` is the saved workbook's own tab
    /// order; an explicit selection is re-ordered by it so the print copy —
    /// and therefore the PDF — follows the workbook's sheet order rather
    /// than the order taps happened to land in.
    func plan(activeSheetName: String?, sheetTabOrder: [String] = []) throws -> OfficePDFPrintPlan {
        let resolvedScope: OfficePDFScope
        switch scope {
        case .document: resolvedScope = .documentSettings
        case .workbook: resolvedScope = .allVisibleSheets
        case .currentSheet:
            guard let activeSheetName else {
                throw CocoaError(.featureUnsupported)
            }
            resolvedScope = .sheet(name: activeSheetName, cellRange: nil)
        case .sheet:
            guard !sheetName.isEmpty else { throw CocoaError(.coderInvalidValue) }
            switch sheetContent {
            case .full:
                resolvedScope = .sheet(name: sheetName, cellRange: nil)
            case .printArea:
                resolvedScope = .sheetWithPrintArea(name: sheetName)
            case .range:
                guard !cellRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CocoaError(.coderInvalidValue)
                }
                resolvedScope = .sheet(name: sheetName, cellRange: cellRange)
            }
        case .selectedSheets:
            let chosen = Set(selectedSheetNames.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            guard !chosen.isEmpty else { throw CocoaError(.coderInvalidValue) }
            if sheetTabOrder.isEmpty {
                // The caller cannot supply the saved tab order (the live
                // adapter path calls this without it). The selection set
                // stays as requested: the print copy resolves every name
                // against the actual workbook, prints in tab order and
                // refuses an unknown tab explicitly, so a stale name still
                // fails honestly instead of mislabeling the picker.
                var seen: Set<String> = []
                resolvedScope = .sheets(names: selectedSheetNames
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted })
            } else {
                let ordered = sheetTabOrder.filter { chosen.contains($0) }
                // Every chosen tab must exist in the saved workbook's current
                // tab order; a stale name is refused instead of silently dropped.
                guard ordered.count == chosen.count else { throw CocoaError(.coderInvalidValue) }
                resolvedScope = .sheets(names: ordered)
            }
        }
        guard let range = OfficePDFPageRange.parse(pages) else {
            throw CocoaError(.coderInvalidValue)
        }
        let resolvedFit: OfficePDFFit?
        switch fit {
        case .document: resolvedFit = nil
        case .actualSize: resolvedFit = .actualSize
        case .width: resolvedFit = .fitToWidth
        case .page: resolvedFit = .fitToOnePage
        case .exactScale, .fitPages: resolvedFit = nil
        }
        var setup = OfficePDFPageSetup(
            paper: OfficePDFPaper(rawValue: paper.rawValue),
            orientation: OfficePDFOrientation(rawValue: orientation.rawValue),
            fit: resolvedFit, margins: OfficePDFMargins(rawValue: margins.rawValue),
            printGridlines: gridlines == .document ? nil : gridlines == .on)
        switch fit {
        case .exactScale:
            guard let percent = Int(scalePercentText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (OfficePDFScale.minimumPercent...OfficePDFScale.maximumPercent).contains(percent) else {
                throw CocoaError(.coderInvalidValue)
            }
            setup.scalePercent = percent
        case .fitPages:
            let width = Int(fitPagesWideText.trimmingCharacters(in: .whitespacesAndNewlines))
            let height = Int(fitPagesTallText.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let width, let height,
                  (OfficePDFFitPages.minimum...OfficePDFFitPages.maximum).contains(width),
                  (OfficePDFFitPages.minimum...OfficePDFFitPages.maximum).contains(height) else {
                throw CocoaError(.coderInvalidValue)
            }
            setup.fitPages = OfficePDFFitPages(width: width, height: height)
        default:
            break
        }
        return OfficePDFPrintPlan(scope: resolvedScope, pageSetup: setup, pageRange: range)
    }
}

/// Owns only its unique export directory. A rendering task and the system
/// share/print surface retain the same lease until they have finished with it.
final class OfficePDFExportLease: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var retainedForRecovery = false
    init(directory: URL) { self.directory = directory }
    func preserveForRecovery() {
        lock.lock(); defer { lock.unlock() }
        retainedForRecovery = true
    }
    deinit {
        lock.lock()
        let retained = retainedForRecovery
        lock.unlock()
        if !retained { try? FileManager.default.removeItem(at: directory) }
    }
}

struct OfficePDFExportPreparation {
    let sourceURL: URL
    let sourceSHA256: String
    let fileExtension: String
    let displayName: String
    let sheets: [OfficeRegionWorkbookSheet]
    let activeSheetName: String?
    let lease: OfficePDFExportLease
    let isCurrent: @MainActor () async -> Bool
    var supportsWorkbookSetup: Bool { fileExtension == "xlsx" }
    var tabOrder: [String] { sheets.map(\.name) }
}

struct OfficePDFPreparedDelivery: Identifiable {
    let id = UUID()
    let url: URL
    let lease: OfficePDFExportLease
    /// Facts measured from the ACTUAL final PDF by the shared service —
    /// never a viewport estimate or a screenshot-derived number.
    let pageCount: Int
    let byteCount: Int
    let pdfSHA256: String
}

/// The preview fence. One generated artifact at a time may feed the final
/// Print/Export action; a newer generation or a choices change fences the
/// older artifact, and a late completion from a fenced generation is
/// refused instead of published. Pure value type so the semantics are
/// testable without a view.
struct OfficePDFExportPreviewState: Equatable {
    struct Artifact: Equatable {
        let url: URL
        let pageCount: Int
        let byteCount: Int
        let pdfSHA256: String
    }
    private(set) var artifact: Artifact?
    private(set) var choicesForArtifact: OfficePDFExportChoices?
    private(set) var generation: UInt64 = 0

    var isReady: Bool { artifact != nil }

    /// Starts one generation and returns its token. Every completion must
    /// present the same token to `accept`; tokens below the current
    /// generation are refused (the view never publishes two generations
    /// concurrently, this fence makes that a checked invariant rather than
    /// an assumption).
    mutating func beginGeneration() -> UInt64 {
        generation += 1
        return generation
    }

    /// Accepts a finished artifact only for the current token. An old token
    /// returns false and keeps the current artifact untouched.
    mutating func accept(token: UInt64, artifact: Artifact,
                         choices: OfficePDFExportChoices) -> Bool {
        guard token == generation else { return false }
        self.artifact = artifact
        self.choicesForArtifact = choices
        return true
    }

    /// Clears the fence (error, cancel or a confirmed source change) and
    /// fences the current generation itself: a late completion that still
    /// carries the pre-invalidate token is refused by `accept` instead of
    /// publishing stale bytes. No final action may proceed without a fresh
    /// accepted artifact.
    mutating func invalidate() {
        generation += 1
        artifact = nil
        choicesForArtifact = nil
    }

    /// The accepted artifact belongs to the exact choices it was generated
    /// with; any visible setting change makes the preview stale and the
    /// final actions must be disabled until a new generation is accepted.
    /// A cleared fence (no artifact) is never "stale" — it is simply not
    /// ready, and the final actions are disabled by the missing artifact.
    func isStale(currentChoices: OfficePDFExportChoices) -> Bool {
        artifact != nil && choicesForArtifact != currentChoices
    }
}

/// Print/export options with the actual PDF preview inline below them, for
/// both the app menu and the engine's Print entry. Settings scroll in the
/// upper region; the dock below always shows the current accepted artifact.
/// Editing any setting (and opening the sheet) automatically regenerates the
/// preview serially: one native render at a time, debounced input, a
/// generation fence that refuses cancelled or stale output, and settings
/// that stay editable while a render runs. The final Print/Share action
/// consumes only the artifact matching the current choices and source — no
/// second PDF is produced when it is tapped. Errors keep the choices intact;
/// a manual retry appears whenever the preview is missing or stale and no
/// render is running.
struct OfficePDFExportOptionsView: View {
    let purpose: OfficePDFExportPurpose
    let prepare: @MainActor () async throws -> OfficePDFExportPreparation
    let export: @MainActor (OfficePDFExportPreparation, OfficePDFExportChoices, CancellationToken) async throws -> OfficePDFPreparedDelivery
    /// Content-free lifecycle breadcrumbs onto the owning session's durable
    /// stage trace (appear/load/cancel/error/preview/dismiss ownership).
    /// Default no-op: hosts without a session trace stay bit-for-bit
    /// unchanged, and nothing here ever carries document content.
    var observe: @MainActor (String, [String: String]) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var source: OfficePDFExportPreparation?
    @State private var choices = OfficePDFExportChoices()
    @State private var error: String?
    @State private var loading = true
    @State private var working = false
    @State private var cancellation = CancellationToken()
    @State private var operation: Task<Void, Never>?
    @State private var preview = OfficePDFExportPreviewState()
    @State private var delivery: OfficePDFPreparedDelivery?
    /// Latest choices waiting for the single serial renderer.
    @State private var pendingChoices: OfficePDFExportChoices?
    @State private var debounce: Task<Void, Never>?
    @State private var presentation: OfficePDFDeliveryPresentation?
    @State private var deliveryFailed = false
    @State private var loadAttempt = 0
    /// Latch distinguishing this view's own teardown (Cancel, delivery done)
    /// from an external presentation dismissal, so the trace names the actual
    /// dismissal owner instead of leaving a silent disappearance.
    @State private var abandoning = false
    /// Content-free identity of this view's state container. A transient
    /// remount and the same view reappearing carry different values, so the
    /// next actual trace can tell a fresh container from preserved state.
    /// Random only; never derived from or joined with document content.
    @State private var traceViewID = UUID()

    private func t(_ chinese: String, _ english: String) -> String { OfficeInkText.t(chinese, english) }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    settingsForm
                    Divider()
                    // The dock keeps the real preview visible at every size;
                    // height comes from the actual container, never from an
                    // idiom check, so a later foldable host gets the same
                    // layout from its available size.
                    previewDock
                        .frame(height: min(max(220, proxy.size.height * 0.42), 460))
                }
            }
            .navigationTitle(purpose == .export ? t("导出 PDF", "Export PDF") : t("打印", "Print"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消", "Cancel")) { abandon(source: "cancelButton") }
                        .frame(minHeight: 44)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(working || presentation != nil)
        .task(id: loadAttempt) {
            loading = true; error = nil
            observe("export.options.loadBegin",
                    ["attempt": String(loadAttempt), "view": traceViewID.uuidString])
            do {
                let prepared = try await prepare()
                try Task.checkCancellation()
                source = prepared
                // This is an actual editor-reported name or a named explicit
                // choice. No first-sheet substitution for Current Sheet.
                choices.sheetName = prepared.activeSheetName
                    ?? prepared.sheets.first(where: \.isVisible)?.name ?? ""
                observe("export.options.loaded",
                        ["attempt": String(loadAttempt), "view": traceViewID.uuidString])
            } catch is CancellationError {
                observe("export.options.loadCancelled",
                        ["attempt": String(loadAttempt), "view": traceViewID.uuidString])
            }
            catch {
                observe("export.options.loadError",
                        ["attempt": String(loadAttempt), "view": traceViewID.uuidString,
                         "kind": Self.errorKind(error)])
                self.error = message(for: error)
            }
            loading = false
            // The initial preview is automatic: no Generate stage.
            scheduleAutoPreview(choices)
        }
        .onChange(of: choices) { _, next in scheduleAutoPreview(next) }
        .onAppear {
            observe("export.options.appear", ["view": traceViewID.uuidString])
        }
        .onDisappear {
            // A genuine dismissal writes the parent's presentation binding
            // nil (Cancel/completion here, or the owner's interactive
            // dismissal): that nil write is the authoritative request
            // cancellation. A transient content remount only reaches this
            // callback, so it must tear down THIS container's preview work
            // but must never call dismiss() — that would cancel the
            // still-live parent-owned preparation. `traceViewID` separates a
            // fresh state container from the same view reappearing.
            var facts = ["owner": abandoning ? "explicit" : "external",
                         "view": traceViewID.uuidString]
            if presentation != nil { facts["covered"] = "presenting" }
            observe("export.options.disappear", facts)
            if presentation != nil {
                // The nested share/print surface currently owns the visible
                // delivery and its leased artifact; its completion/failure
                // path decides the next step. Do not tear the preview or
                // delivery down under it.
                return
            }
            teardownPreview(source: "disappear")
        }
        .sheet(item: $presentation, onDismiss: {
            if deliveryFailed {
                deliveryFailed = false
                // A generation could not run while the share/print surface
                // held the leased delivery slot; resume the automatic queue
                // only now that the session continues on this same source.
                scheduleAutoPreview(choices)
            } else if delivery != nil {
                // A completed share/print run ends the export session, as
                // before: the user already received the final artifact. This
                // is our own dismissal, so the trace names it as such.
                abandon(source: "deliveryComplete")
            }
        }) { presentation in
            switch presentation {
            case .share(let delivered):
                OfficeDocumentShareSheet(url: delivered.url)
            case .print(let delivered):
                OfficePreparedPDFPrintSheet(url: delivered.url) { failure in
                    if let failure {
                        error = failure.localizedDescription
                        deliveryFailed = true
                    }
                    self.presentation = nil
                }
            }
        }
    }

    /// Ends the presentation explicitly: the user tapped Cancel, or a
    /// finished share/print delivery already handed the artifact to the
    /// system surface. ONLY this path calls `dismiss()`, which writes the
    /// parent presentation binding nil and therefore owns request
    /// cancellation; a transient child disappearance must never reach it.
    private func abandon(source: String) {
        abandoning = true
        observe("export.options.abandon",
                ["source": source, "view": traceViewID.uuidString])
        teardownPreview(source: source)
        dismiss()
    }

    /// Releases only work this view instance owns: the preview generation
    /// consumer, the queued/debounced choices and the accepted-artifact
    /// fence. The parent's presentation request and its preparation are NOT
    /// owned here, so a transient remount cannot cancel them; they end only
    /// when the presentation binding is actually written nil.
    private func teardownPreview(source: String) {
        observe("export.options.teardown",
                ["source": source, "view": traceViewID.uuidString])
        cancellation.cancel(); operation?.cancel()
        debounce?.cancel(); pendingChoices = nil
        preview.invalidate()
    }

    // MARK: - Settings (upper scrolling region)

    private var settingsForm: some View {
        Form {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let source {
                if source.supportsWorkbookSetup {
                    Section {
                        Picker(t("范围", "Scope"), selection: $choices.scope) {
                            Text(t("文档设置", "Document settings")).tag(OfficePDFExportChoices.Scope.document)
                            if source.activeSheetName != nil {
                                Text(t("当前工作表", "Current sheet")).tag(OfficePDFExportChoices.Scope.currentSheet)
                            }
                            Text(t("整个工作簿", "Workbook")).tag(OfficePDFExportChoices.Scope.workbook)
                            Text(t("所选工作表", "Selected sheets")).tag(OfficePDFExportChoices.Scope.selectedSheets)
                            Text(t("指定工作表", "Sheet")).tag(OfficePDFExportChoices.Scope.sheet)
                        }
                        .accessibilityIdentifier("office.pdf.scope")
                        if choices.scope == .selectedSheets {
                            ForEach(source.sheets.filter(\.isVisible), id: \.index) { sheet in
                                Toggle(isOn: bindingForSelectedSheet(sheet.name)) {
                                    Text(sheet.name)
                                }
                            }
                        }
                        if choices.scope == .sheet {
                            Picker(t("工作表", "Sheet"), selection: $choices.sheetName) {
                                ForEach(source.sheets.filter(\.isVisible), id: \.index) { sheet in
                                    Text(sheet.name).tag(sheet.name)
                                }
                            }
                            Picker(t("打印内容", "Print content"), selection: $choices.sheetContent) {
                                Text(t("全部内容（含手写）", "Full content (with ink)")).tag(OfficePDFExportChoices.SheetContent.full)
                                Text(t("工作表打印区域", "Sheet's print area")).tag(OfficePDFExportChoices.SheetContent.printArea)
                                Text(t("指定单元格区域", "Cell range")).tag(OfficePDFExportChoices.SheetContent.range)
                            }
                            .accessibilityIdentifier("office.pdf.sheetContent")
                            if choices.sheetContent == .range {
                                TextField(t("单元格区域（如 A1:R37）", "Cell range (e.g. A1:R37)"), text: $choices.cellRange)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .accessibilityIdentifier("office.pdf.cellRange")
                            }
                        }
                    }
                    Section {
                        Picker(t("纸张", "Paper"), selection: $choices.paper) {
                            Text(t("文档设置", "Document settings")).tag(OfficePDFExportChoices.Paper.document)
                            Text("A4").tag(OfficePDFExportChoices.Paper.a4)
                            Text("A3").tag(OfficePDFExportChoices.Paper.a3)
                            Text("Letter").tag(OfficePDFExportChoices.Paper.letter)
                            Text("Legal").tag(OfficePDFExportChoices.Paper.legal)
                        }
                        Picker(t("方向", "Orientation"), selection: $choices.orientation) {
                            Text(t("文档设置", "Document settings")).tag(OfficePDFExportChoices.Orientation.document)
                            Text(t("纵向", "Portrait")).tag(OfficePDFExportChoices.Orientation.portrait)
                            Text(t("横向", "Landscape")).tag(OfficePDFExportChoices.Orientation.landscape)
                        }
                        Picker(t("缩放", "Scaling"), selection: $choices.fit) {
                            Text(t("文档设置", "Document settings")).tag(OfficePDFExportChoices.Fit.document)
                            Text(t("实际大小", "Actual size")).tag(OfficePDFExportChoices.Fit.actualSize)
                            Text(t("适合页宽", "Fit to width")).tag(OfficePDFExportChoices.Fit.width)
                            Text(t("适合一页", "Fit on one page")).tag(OfficePDFExportChoices.Fit.page)
                            Text(t("精确百分比", "Exact scale")).tag(OfficePDFExportChoices.Fit.exactScale)
                            Text(t("指定页数", "Fit to pages")).tag(OfficePDFExportChoices.Fit.fitPages)
                        }
                        .accessibilityIdentifier("office.pdf.scaling")
                        if choices.fit == .exactScale {
                            // The percentage is directly visible and settable
                            // two ways: slide, or type any exact value.
                            HStack {
                                TextField(t("缩放百分比", "Scale percent"), text: $choices.scalePercentText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .frame(width: 72)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("office.pdf.scalePercent")
                                Text("%")
                                    .font(.body.monospacedDigit())
                            }
                            Slider(value: scalePercentSlider,
                                   in: Double(OfficePDFScale.minimumPercent)...Double(OfficePDFScale.maximumPercent),
                                   step: 5)
                                .accessibilityIdentifier("office.pdf.scaleSlider")
                            Text(t("范围 \(OfficePDFScale.minimumPercent)–\(OfficePDFScale.maximumPercent)%。",
                                   "Valid range: \(OfficePDFScale.minimumPercent)–\(OfficePDFScale.maximumPercent)%."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if choices.fit == .fitPages {
                            HStack {
                                TextField(t("宽度页数", "Wide"), text: $choices.fitPagesWideText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Text(t("页宽 ×", "pages wide ×"))
                                TextField(t("高度页数", "Tall"), text: $choices.fitPagesTallText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Text(t("页高", "tall"))
                            }
                            Text(t("每个方向 1–\(OfficePDFFitPages.maximum) 页。",
                                   "Each direction: 1–\(OfficePDFFitPages.maximum) pages."))
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("office.pdf.fitPages")
                        }
                        Picker(t("页边距", "Margins"), selection: $choices.margins) {
                            Text(t("文档设置", "Document settings")).tag(OfficePDFExportChoices.Margins.document)
                            Text(t("普通", "Normal")).tag(OfficePDFExportChoices.Margins.normal)
                            Text(t("窄", "Narrow")).tag(OfficePDFExportChoices.Margins.narrow)
                            Text(t("宽", "Wide")).tag(OfficePDFExportChoices.Margins.wide)
                        }
                        Picker(t("打印网格线", "Print gridlines"), selection: $choices.gridlines) {
                            Text(t("文档设置", "Document settings")).tag(OfficePDFExportChoices.Gridlines.document)
                            Text(t("打印", "Print")).tag(OfficePDFExportChoices.Gridlines.on)
                            Text(t("不打印", "Don't print")).tag(OfficePDFExportChoices.Gridlines.off)
                        }
                        .accessibilityIdentifier("office.pdf.gridlines")
                    } header: {
                        Text(t("页面设置", "Page setup"))
                    }
                }
                Section {
                    TextField(t("PDF 页码（留空为全部）", "PDF pages (blank for all)"), text: $choices.pages)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("office.pdf.pages")
                } header: {
                    Text(t("PDF 页码", "PDF pages"))
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    if source == nil {
                        Button(t("重试", "Retry")) { loadAttempt &+= 1 }
                            .frame(minHeight: 44).disabled(loading)
                    }
                }
            }
        }
        // The automatic renderer owns one operation at a time; the form
        // stays editable while a render runs.
        .disabled(loading)
    }

    /// Live percentage for the slider: typing an out-of-range or partial
    /// value moves the slider from the last valid percentage instead of
    /// rewriting the user's text mid-edit.
    private var scalePercentSlider: Binding<Double> {
        Binding(
            get: {
                let parsed = Int(choices.scalePercentText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 100
                return Double(min(max(parsed, OfficePDFScale.minimumPercent),
                                  OfficePDFScale.maximumPercent))
            },
            set: { choices.scalePercentText = String(Int($0)) })
    }

    // MARK: - Actual preview dock (always visible below the settings)

    private var previewDock: some View {
        VStack(spacing: 8) {
            Group {
                if let artifact = preview.artifact {
                    // Re-keyed by the accepted PDF's own digest: the leased
                    // delivery slot keeps one stable name, so this is what
                    // forces a real reload of the newly generated bytes.
                    OfficePDFPreviewSurface(url: artifact.url, pageCount: artifact.pageCount)
                        .id(artifact.pdfSHA256)
                        .accessibilityIdentifier("office.pdf.inlinePreview")
                } else {
                    Group {
                        if loading {
                            ProgressView(t("正在准备预览…", "Preparing preview…"))
                        } else if working {
                            ProgressView(t("正在生成预览…", "Preparing preview…"))
                        } else {
                            Text(t("暂无预览", "No preview yet"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error {
                // Export and print-panel failures land here too: the user
                // stays on the same recoverable message with the preview
                // visible and can retry without losing their settings.
                Text(error)
                    .font(.footnote).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if let artifact = preview.artifact {
                    // The number below is measured from the actual
                    // generated PDF, never estimated from the viewport.
                    Text(t("共 \(artifact.pageCount) 页 · \(byteText(artifact.byteCount))",
                           "\(artifact.pageCount) pages · \(byteText(artifact.byteCount))"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("office.pdf.measuredPages")
                }
                if working {
                    ProgressView().controlSize(.small)
                    Text(t("正在更新预览…", "Updating preview…"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("office.pdf.autoupdating")
                } else if preview.isStale(currentChoices: choices) {
                    Text(t("设置已修改", "Settings changed"))
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("office.pdf.stale")
                }
                Spacer()
            }
            HStack(spacing: 12) {
                if source != nil, !loading, !working,
                   preview.artifact == nil || preview.isStale(currentChoices: choices) {
                    Button(t("更新预览", "Update preview")) { retryNow() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("office.pdf.retry")
                }
                Spacer()
                Button {
                    guard canFinish, let delivery else { return }
                    presentation = purpose == .export ? .share(delivery) : .print(delivery)
                } label: {
                    Label(purpose == .export
                          ? t("分享 / 存储 PDF", "Share / Save PDF")
                          : t("打印", "Print"),
                          systemImage: purpose == .export ? "square.and.arrow.up" : "printer")
                        .fontWeight(.semibold)
                }
                .frame(minHeight: 44)
                .disabled(!canFinish)
                .accessibilityIdentifier(purpose == .export
                                         ? "office.pdf.finalShare" : "office.pdf.finalPrint")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// The final action consumes only the accepted artifact that matches the
    /// current choices — never while a newer render is in flight.
    private var canFinish: Bool {
        preview.artifact != nil
            && !preview.isStale(currentChoices: choices)
            && delivery != nil
            && !working
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func bindingForSelectedSheet(_ name: String) -> Binding<Bool> {
        Binding(
            get: { choices.selectedSheetNames.contains(name) },
            set: { on in
                if on {
                    if !choices.selectedSheetNames.contains(name) {
                        choices.selectedSheetNames.append(name)
                    }
                } else {
                    choices.selectedSheetNames.removeAll { $0 == name }
                }
            })
    }

    // MARK: - Automatic generation

    /// Debounces edits into the single serial queue. The newest snapshot wins:
    /// a change that lands while a render runs is stored pending and rendered
    /// as soon as the current generation settles, so overlapping renders are
    /// structurally impossible (the leased delivery slot and the native host
    /// each carry exactly one operation at a time).
    private func scheduleAutoPreview(_ next: OfficePDFExportChoices) {
        guard source != nil else {
            observe("export.preview.skip", ["reason": "noSource"])
            return
        }
        pendingChoices = next
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            debounce = nil
            pumpPreview()
        }
    }

    private func pumpPreview() {
        guard let source, !loading, !working, presentation == nil,
              let pending = pendingChoices else {
            observe("export.preview.skip", ["reason": pumpSkipReason()])
            return
        }
        pendingChoices = nil
        // Already-current artifact: nothing to regenerate.
        if preview.artifact != nil, !preview.isStale(currentChoices: pending) {
            observe("export.preview.skip", ["reason": "current"])
            return
        }
        // Auto-render complete, valid settings only. Mid-edit input (a
        // partial range, an out-of-bounds percent) stays silently queued
        // until the next change instead of spamming an error for every
        // keystroke; the visible preview just reads as stale.
        guard (try? pending.plan(activeSheetName: source.activeSheetName,
                                 sheetTabOrder: source.tabOrder)) != nil else {
            observe("export.preview.skip", ["reason": "invalidPlan"])
            return
        }
        startGeneration(for: pending, source: source)
    }

    /// Why the automatic queue could not pump right now; content-free.
    private func pumpSkipReason() -> String {
        if source == nil { return "noSource" }
        if loading { return "loading" }
        if working { return "working" }
        if presentation != nil { return "presenting" }
        return "noPending"
    }

    private func startGeneration(for snapshot: OfficePDFExportChoices,
                                 source: OfficePDFExportPreparation) {
        working = true; error = nil
        let token = preview.beginGeneration()
        observe("export.preview.generationStarted", ["token": String(token)])
        operation = Task { @MainActor in
            defer {
                working = false; operation = nil
                // Pick up any change queued while this render ran.
                pumpPreview()
            }
            do {
                let result = try await export(source, snapshot, cancellation)
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                let accepted = preview.accept(
                    token: token,
                    artifact: OfficePDFExportPreviewState.Artifact(
                        url: result.url, pageCount: result.pageCount,
                        byteCount: result.byteCount, pdfSHA256: result.pdfSHA256),
                    choices: snapshot)
                guard accepted else {
                    // A fenced generation's late completion never publishes:
                    // the session was cancelled or the source changed while
                    // this run was in flight. The lease and directory stay
                    // owned by the preparation; nothing here touches them.
                    observe("export.preview.generationFenced", ["token": String(token)])
                    return
                }
                delivery = result
                observe("export.preview.generationAccepted", ["token": String(token)])
            } catch is CancellationError {
                observe("export.preview.generationCancelled", ["token": String(token)])
            }
            catch {
                // Content-free error family only; the user-facing message
                // keeps its existing mapping below.
                observe("export.preview.generationError",
                        ["token": String(token), "kind": Self.errorKind(error)])
                if needsSourceRefresh(error) {
                    self.source = nil
                    preview.invalidate()
                    delivery = nil
                }
                if !cancellation.isCancelled { self.error = message(for: error) }
            }
        }
    }

    /// Recovery affordance for a failed or missing auto-generation (for
    /// example a transient busy session). It is not a stage button: the
    /// normal path never needs it because edits already regenerate.
    private func retryNow() {
        guard let source, !working else { return }
        debounce?.cancel(); debounce = nil
        if (try? choices.plan(activeSheetName: source.activeSheetName,
                              sheetTabOrder: source.tabOrder)) == nil {
            error = t("请检查工作表、单元格区域、缩放和 PDF 页码。",
                      "Check the sheet, range, scale and PDF pages.")
            return
        }
        pendingChoices = choices
        pumpPreview()
    }

    private func needsSourceRefresh(_ error: Error) -> Bool {
        if let screenError = error as? OfficePDFExportScreenError {
            // Only a genuinely replaced surface or changed bytes invalidates the
            // frozen source. A session that is merely held by another in-flight
            // operation leaves the exact same verified preparation usable, so the
            // user can start a new generation without re-preparing; the failed
            // generation itself is still reported and nothing is published.
            switch screenError {
            case .sourceChanged: return true
            case .sessionBusy: return false
            }
        }
        #if canImport(FloeOfficeNative)
        if let exportError = error as? OfficePDFExportError {
            switch exportError {
            case .invalidSourceIdentity, .staleSource, .sourceChangedDuringExport: return true
            default: break
            }
        }
        #endif
        if let copyError = error as? OfficePrintCopyError {
            switch copyError {
            case .staleSource, .sourceChangedDuringCopy, .unknownSheet: return true
            default: break
            }
        }
        return false
    }

    /// Content-free error family for trace breadcrumbs: never the localized
    /// message, never document content.
    private static func errorKind(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let screen = error as? OfficePDFExportScreenError {
            switch screen {
            case .sourceChanged: return "sourceChanged"
            case .sessionBusy: return "sessionBusy"
            }
        }
        if error is OfficePDFPlanError { return "plan" }
        if error is OfficePrintCopyError { return "copy" }
        #if canImport(FloeOfficeNative)
        if error is OfficePDFExportError { return "exportError" }
        #endif
        if let floe = error as? FloeError, case .validationFailed = floe { return "validation" }
        return "other"
    }

    private func message(for error: Error) -> String {
        if let screenError = error as? OfficePDFExportScreenError { return screenError.localizedDescription }
        if let planError = error as? OfficePDFPlanError {
            switch planError {
            case .pageOutOfRange(let page, let count):
                return t("第 \(page) 页超出范围；此 PDF 共 \(count) 页。", "Page \(page) is out of range. This PDF has \(count) pages.")
            case .invalidPageSelection, .tooManySelectedPages:
                return t("请检查 PDF 页码后重试。", "Check the PDF pages and try again.")
            case .invalidRange, .rangeOutsideWorksheetBounds:
                return t("请检查单元格区域（如 A1:R37）。", "Check the cell range (e.g. A1:R37).")
            case .invalidSheetName, .unknownSheet:
                return t("找不到所选工作表，请重新打开导出。", "The selected sheet is unavailable. Open export again.")
            case .emptySheetSelection:
                return t("请至少选择一个工作表。", "Select at least one worksheet.")
            case .duplicateSheetName(let name):
                return t("工作表 \(name) 被重复选择。", "Worksheet \(name) is selected more than once.")
            case .tooManySheets(let requested, let maximum):
                return t("最多选择 \(maximum) 个工作表（当前 \(requested) 个）。", "Select at most \(maximum) worksheets (requested \(requested)).")
            case .conflictingScalingControls:
                return t("缩放方式只能选择一种。", "Choose only one scaling control.")
            case .scalePercentOutOfRange(let requested, let minimum, let maximum):
                return t("缩放 \(requested)% 超出 \(minimum)–\(maximum)% 范围。", "Scale \(requested)% is outside \(minimum)–\(maximum)%.")
            case .fitPagesOutOfRange(let requested, let maximum):
                return t("页数 \(requested.width)×\(requested.height) 超出每方向 1–\(maximum) 页范围。", "Pages \(requested.width)×\(requested.height) is outside the 1–\(maximum) per-direction range.")
            case .unsupportedFormat, .unsupportedScope, .unsupportedPageSetup:
                return t("此格式不支持所选导出设置。", "This format does not support the selected export settings.")
            default: break
            }
        }
        if let copyError = error as? OfficePrintCopyError {
            switch copyError {
            case .invalidRange, .rangeOutsideWorksheetBounds:
                return t("请检查单元格区域（如 A1:R37）。", "Check the cell range (e.g. A1:R37).")
            case .unknownSheet, .noVisibleSheets:
                return t("没有可打印的工作表，请重新打开导出。", "No printable sheet is available. Open export again.")
            case .staleSource, .sourceChangedDuringCopy:
                return t("文档已变化，请重新打开导出。", "The document changed. Open export again.")
            default: break
            }
        }
        #if canImport(FloeOfficeNative)
        if let exportError = error as? OfficePDFExportError {
            switch exportError {
            case .invalidSourceIdentity, .staleSource, .sourceChangedDuringExport:
                return t("文档已变化，请重新打开导出。", "The document changed. Open export again.")
            case .pageSelectionFailed:
                return t("请检查 PDF 页码后重试。", "Check the PDF pages and try again.")
            case .savedExportUnavailable:
                return t("此格式不支持所选导出设置。", "This format does not support the selected export settings.")
            default: break
            }
        }
        #endif
        if let floeError = error as? FloeError, case .validationFailed(let message) = floeError {
            return message
        }
        return t("未能生成 PDF，请重试。", "The PDF could not be created. Try again.")
    }
}

/// Identifies the final action presented for the one accepted preview
/// artifact. The lease travels with the delivery so the file survives until
/// the share/print surface is done with it.
enum OfficePDFDeliveryPresentation: Identifiable {
    case share(OfficePDFPreparedDelivery)
    case print(OfficePDFPreparedDelivery)
    var id: UUID {
        switch self {
        case .share(let delivery): return delivery.id
        case .print(let delivery): return delivery.id
        }
    }
    var delivery: OfficePDFPreparedDelivery {
        switch self {
        case .share(let delivery): return delivery
        case .print(let delivery): return delivery
        }
    }
}

/// Displays the ACTUAL generated PDF. The document is built on the MainActor
/// behind the ObjC exception guard — the same thread-ownership rule the
/// shared PDF reader follows — and is never a viewport screenshot. Page
/// count/geometry were already measured through PDFKitGate by the export
/// service; this surface renders the same bytes the final action will use.
struct OfficePDFPreviewSurface: View {
    let url: URL
    let pageCount: Int
    @StateObject private var loader = OfficePDFPreviewLoader()

    var body: some View {
        Group {
            if let message = loader.errorMessage {
                ContentUnavailableView {
                    Label(t("无法预览", "Preview unavailable"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(t("重试", "Retry")) { Task { await loader.load(url) } }
                        .frame(minHeight: 44)
                }
            } else if let document = loader.document {
                OfficePDFPreviewPDFView(document: document)
                    .accessibilityIdentifier("office.pdf.preview.document")
            } else {
                ProgressView(t("正在打开预览…", "Opening preview…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) { await loader.load(url) }
    }

    private func t(_ chinese: String, _ english: String) -> String { OfficeInkText.t(chinese, english) }
}

@MainActor
final class OfficePDFPreviewLoader: ObservableObject {
    @Published var document: PDFDocument?
    @Published var errorMessage: String?

    func load(_ url: URL) async {
        errorMessage = nil
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= 64 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Bytes are read off the main actor; the PDFDocument itself is
            // created here because PDFView owns it and it must never migrate
            // threads (the same rule PDFReadingSession follows).
            let bytes = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            try Task.checkCancellation()
            let loaded = try withPDFExceptionGuard { PDFDocument(data: bytes) }
            guard let loaded, !loaded.isLocked else {
                throw CocoaError(.fileReadCorruptFile)
            }
            document = loaded
        } catch is CancellationError {
        } catch {
            document = nil
            errorMessage = OfficeInkText.t("预览文件无法读取，请重新生成预览。",
                                           "The preview file could not be read. Generate the preview again.")
        }
    }
}

/// One shared `PDFView` bound to the generated document. Continuous vertical
/// reading matches how the printed pages actually flow; UIKit owns zooming.
private struct OfficePDFPreviewPDFView: UIViewControllerRepresentable {
    let document: PDFDocument
    func makeUIViewController(context: Context) -> PDFViewController {
        let controller = PDFViewController()
        controller.pdfView.autoScales = true
        controller.pdfView.displayMode = .singlePageContinuous
        controller.pdfView.displayDirection = .vertical
        controller.pdfView.backgroundColor = .secondarySystemBackground
        return controller
    }
    func updateUIViewController(_ controller: PDFViewController, context: Context) {
        guard controller.pdfView.document !== document else { return }
        controller.pdfView.document = document
        if let first = document.page(at: 0) {
            controller.pdfView.go(to: first)
        }
    }
    final class PDFViewController: UIViewController {
        let pdfView = PDFView()
        override func viewDidLoad() {
            super.viewDidLoad()
            pdfView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(pdfView)
            NSLayoutConstraint.activate([
                pdfView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                pdfView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
                pdfView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                pdfView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
        }
    }
}

/// The PDF has already been generated and validated with the user's scope
/// and layout. UIKit now owns printer choice, copies and the final Print tap.
struct OfficePreparedPDFPrintSheet: UIViewControllerRepresentable {
    let url: URL
    let finish: @MainActor (Error?) -> Void
    func makeUIViewController(context: Context) -> Presenter { Presenter(url: url, finish: finish) }
    func updateUIViewController(_ controller: Presenter, context: Context) { }

    final class Presenter: UIViewController {
        let url: URL
        let finish: @MainActor (Error?) -> Void
        private var presentedPrint = false
        init(url: URL, finish: @escaping @MainActor (Error?) -> Void) {
            self.url = url; self.finish = finish
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presentedPrint else { return }
            presentedPrint = true
            let printing = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = url.deletingPathExtension().lastPathComponent
            do {
                let fileURL = url
                let landscape = try PDFKitGate.run {
                    try withPDFExceptionGuard {
                        guard let pdf = PDFDocument(url: fileURL), !pdf.isLocked,
                              let page = pdf.page(at: 0) else { throw CocoaError(.fileReadCorruptFile) }
                        let size = page.bounds(for: .cropBox).size
                        guard size.width.isFinite, size.height.isFinite,
                              size.width > 0, size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
                        return size.width > size.height
                    }
                }
                info.orientation = landscape ? .landscape : .portrait
            } catch {
                finish(error)
                return
            }
            printing.printInfo = info
            printing.printingItem = url
            let completed: UIPrintInteractionController.CompletionHandler = { [weak self] _, _, error in
                Task { @MainActor in self?.finish(error) }
            }
            let accepted: Bool
            if UIDevice.current.userInterfaceIdiom == .pad {
                accepted = printing.present(from: CGRect(x: view.bounds.midX, y: 1, width: 1, height: 1),
                                            in: view, animated: true, completionHandler: completed)
            } else {
                accepted = printing.present(animated: true, completionHandler: completed)
            }
            if !accepted { finish(CocoaError(.featureUnsupported)) }
        }
    }
}
#endif
