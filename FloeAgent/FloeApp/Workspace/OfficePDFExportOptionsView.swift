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

enum OfficePDFExportScreenError: Error, LocalizedError {
    case sourceChanged
    var errorDescription: String? {
        OfficeInkText.t("文档已变化，请刷新后重试。", "The document changed. Refresh and try again.")
    }
}

struct OfficePDFExportChoices: Sendable {
    enum Scope: String, CaseIterable { case document, currentSheet, workbook, sheet, cells }
    enum Paper: String, CaseIterable { case document, a4, a3, letter, legal }
    enum Orientation: String, CaseIterable { case document, portrait, landscape }
    enum Fit: String, CaseIterable { case document, actualSize, width, page }
    enum Margins: String, CaseIterable { case document, normal, narrow, wide }
    var scope: Scope = .document
    var sheetName = ""
    var cellRange = ""
    var paper: Paper = .document
    var orientation: Orientation = .document
    var fit: Fit = .document
    var margins: Margins = .document
    var pages = ""

    func plan(activeSheetName: String?) throws -> OfficePDFPrintPlan {
        let resolvedScope: OfficePDFScope
        switch scope {
        case .document: resolvedScope = .documentSettings
        case .workbook: resolvedScope = .allVisibleSheets
        case .currentSheet:
            guard let activeSheetName else {
                throw CocoaError(.featureUnsupported)
            }
            resolvedScope = .sheet(name: activeSheetName, cellRange: nil)
        case .sheet, .cells:
            guard !sheetName.isEmpty else { throw CocoaError(.coderInvalidValue) }
            if scope == .cells, cellRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CocoaError(.coderInvalidValue)
            }
            resolvedScope = .sheet(name: sheetName, cellRange: scope == .cells ? cellRange : nil)
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
        }
        return OfficePDFPrintPlan(scope: resolvedScope, pageSetup: OfficePDFPageSetup(
            paper: OfficePDFPaper(rawValue: paper.rawValue),
            orientation: OfficePDFOrientation(rawValue: orientation.rawValue),
            fit: resolvedFit, margins: OfficePDFMargins(rawValue: margins.rawValue)), pageRange: range)
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
}

struct OfficePDFPreparedDelivery: Identifiable {
    let id = UUID()
    let url: URL
    let lease: OfficePDFExportLease
}

/// Shared pre-generation options for both the app menu and the engine's Print
/// entry. Only supported settings are shown; errors keep the choices intact.
struct OfficePDFExportOptionsView: View {
    let purpose: OfficePDFExportPurpose
    let prepare: @MainActor () async throws -> OfficePDFExportPreparation
    let export: @MainActor (OfficePDFExportPreparation, OfficePDFExportChoices, CancellationToken) async throws -> OfficePDFPreparedDelivery
    @Environment(\.dismiss) private var dismiss
    @State private var source: OfficePDFExportPreparation?
    @State private var choices = OfficePDFExportChoices()
    @State private var error: String?
    @State private var loading = true
    @State private var working = false
    @State private var cancellation = CancellationToken()
    @State private var operation: Task<Void, Never>?
    @State private var delivery: OfficePDFPreparedDelivery?
    @State private var deliveryFailed = false
    @State private var loadAttempt = 0

    private func t(_ chinese: String, _ english: String) -> String { OfficeInkText.t(chinese, english) }

    var body: some View {
        NavigationStack {
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
                                Text(t("指定工作表", "Sheet")).tag(OfficePDFExportChoices.Scope.sheet)
                                Text(t("单元格区域", "Cell range")).tag(OfficePDFExportChoices.Scope.cells)
                            }
                            if choices.scope == .sheet || choices.scope == .cells {
                                Picker(t("工作表", "Sheet"), selection: $choices.sheetName) {
                                    ForEach(source.sheets.filter(\.isVisible), id: \.index) { sheet in
                                        Text(sheet.name).tag(sheet.name)
                                    }
                                }
                            }
                            if choices.scope == .cells {
                                TextField(t("单元格区域（如 A1:R37）", "Cell range (e.g. A1:R37)"), text: $choices.cellRange)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .accessibilityIdentifier("office.pdf.cellRange")
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
                            }
                            Picker(t("页边距", "Margins"), selection: $choices.margins) {
                                Text(t("文档设置", "Document settings")).tag(OfficePDFExportChoices.Margins.document)
                                Text(t("普通", "Normal")).tag(OfficePDFExportChoices.Margins.normal)
                                Text(t("窄", "Narrow")).tag(OfficePDFExportChoices.Margins.narrow)
                                Text(t("宽", "Wide")).tag(OfficePDFExportChoices.Margins.wide)
                            }
                        }
                    }
                    Section {
                        TextField(t("PDF 页码（留空为全部）", "PDF pages (blank for all)"), text: $choices.pages)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("office.pdf.pages")
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
                if working {
                    HStack { Spacer(); ProgressView(t("正在生成…", "Preparing…")); Spacer() }
                }
            }
            .disabled(working)
            .navigationTitle(purpose == .export ? t("导出 PDF", "Export PDF") : t("打印", "Print"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消", "Cancel")) { cancellation.cancel(); operation?.cancel(); dismiss() }
                        .frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose == .export ? t("导出", "Export") : t("继续", "Continue")) { generate() }
                        .fontWeight(.semibold).frame(minHeight: 44)
                        .disabled(source == nil || working)
                        .accessibilityIdentifier("office.pdf.generate")
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(working)
        .task(id: loadAttempt) {
            loading = true; error = nil
            do {
                let prepared = try await prepare()
                try Task.checkCancellation()
                source = prepared
                // This is an actual editor-reported name or a named explicit
                // choice. No first-sheet substitution for Current Sheet.
                choices.sheetName = prepared.activeSheetName
                    ?? prepared.sheets.first(where: \.isVisible)?.name ?? ""
            } catch is CancellationError { }
            catch { self.error = message(for: error) }
            loading = false
        }
        .onDisappear { cancellation.cancel(); operation?.cancel() }
        .sheet(item: $delivery, onDismiss: {
            if deliveryFailed { deliveryFailed = false } else { dismiss() }
        }) { delivered in
            if purpose == .export {
                OfficeDocumentShareSheet(url: delivered.url)
            } else {
                OfficePreparedPDFPrintSheet(url: delivered.url) { failure in
                    if let failure {
                        error = failure.localizedDescription
                        deliveryFailed = true
                    }
                    delivery = nil
                }
            }
        }
    }

    private func generate() {
        guard let source, !working else { return }
        working = true; error = nil
        operation = Task { @MainActor in
            defer { working = false; operation = nil }
            do {
                let result = try await export(source, choices, cancellation)
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                delivery = result
            } catch is CancellationError { }
            catch {
                if needsSourceRefresh(error) { self.source = nil }
                if !cancellation.isCancelled { self.error = message(for: error) }
            }
        }
    }

    private func needsSourceRefresh(_ error: Error) -> Bool {
        if error is OfficePDFExportScreenError { return true }
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
            let completed: UIPrintInteractionCompletionHandler = { [weak self] _, _, error in
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
