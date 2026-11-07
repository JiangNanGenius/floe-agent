// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import CryptoKit
import FloeCAD

/// Ordinary model files enter the same CAD editor before printing or cutting.
/// The source stays an independent original; the library publishes the native
/// CAD copy only after import, source revalidation and a verified save.
@MainActor
enum PersonalCADImport {
    private enum Prepared: Sendable { case mesh(CADSingleMeshImportPlan), exact(CADExactImportPlan) }
    static func open(record:PersonalContentRecord,title:String,unitScale:Double?,
                     cancellation:MeshImportCancellation,service suppliedService:PersonalContentService? = nil) async throws -> PersonalContentRecord {
        let service = suppliedService ?? .shared
        try PersonalLibraryFileActions.requireAvailable(record.id)
        let source = try await service.originalFile(record.id)
        let format = source.pathExtension.lowercased()
        guard CADUnifiedModelImport.extensions.contains(format) else { throw PersonalContentError.invalidProject }
        let bytes = try await read(source)
        let digest = SHA256.hash(data:bytes)
        let prepared:Prepared
        if ["stl","obj"].contains(format) {
            guard let unitScale,unitScale.isFinite,unitScale > 0 else { throw PersonalContentError.invalidProject }
            prepared = .mesh(try await CADMeshImportService.parseSingleMeshOffMain(data:bytes,fileName:source.lastPathComponent,format:format,unitScale:unitScale,cancellation:cancellation))
        } else {
            prepared = .exact(try await CADExactImportService.parseOffMain(data:bytes,format:format,fileName:source.lastPathComponent,cancellation:cancellation))
        }
        try Task.checkCancellation()
        let library = try await service.library()
        return try await library.create(kind:.cad3D,title:title,in:record.folders) { directory,_ in
            try await apply(prepared,to:directory,title:title,cancellation:cancellation)
            try await PersonalLibraryFileActions.requireAvailable(record.id)
            let current = try await service.originalFile(record.id)
            guard current.standardizedFileURL == source.standardizedFileURL,
                  try await SHA256.hash(data:read(current)) == digest else { throw PersonalContentError.changedDocument }
            try Task.checkCancellation()
        }
    }
    private static func apply(_ prepared:Prepared,to directory:URL,title:String,cancellation:MeshImportCancellation) async throws {
        let document = try await FloeCADDocument.create(at:directory.appendingPathComponent("Document.floecad"),name:title)
        defer { document.close() }
        let outcome:CADCommandOutcome
        switch prepared {
        case .mesh(let plan): outcome = try CADMeshImportService.applySingleMesh(plan,to:document,cancellation:cancellation)
        case .exact(let plan): outcome = try CADExactImportService.apply(plan,to:document,cancellation:cancellation,undoMode:.singleStep).outcome
        }
        guard outcome.isOK else { throw CADDocumentError(code:outcome.errorCode ?? "import_failed",message:outcome.message ?? "Unable to import the CAD model.") }
        try Task.checkCancellation()
        let saved = await document.save()
        guard saved.succeeded else { throw CADDocumentError(code:"save_failed",message:saved.error ?? "Unable to save the CAD model.") }
    }
    private nonisolated static func read(_ url:URL) async throws -> Data {
        let worker = Task.detached(priority:.userInitiated) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max) <= 128*1024*1024 else { throw PersonalContentError.invalidProject }
            let data = try Data(contentsOf:url)
            try Task.checkCancellation(); return data
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
    }
}

struct PersonalCADImportRequest: Identifiable { let id = UUID(); let record:PersonalContentRecord; let file:URL }

struct PersonalCADImportSheet: View {
    let request:PersonalCADImportRequest
    let onImported:(PersonalContentRecord)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var title:String
    @State private var scale:Double?
    @State private var importing = false
    @State private var problem:String?
    @State private var work:Task<Void,Never>?
    @State private var token:MeshImportCancellation?
    init(request:PersonalCADImportRequest,onImported:@escaping(PersonalContentRecord)->Void) {
        self.request = request; self.onImported = onImported
        _title = State(initialValue:String(request.record.title.prefix(48))+" CAD")
    }
    private var unitless:Bool { ["stl","obj"].contains(request.file.pathExtension.lowercased()) }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.file.lastPathComponent)
                    Text(IDELanguageRunText.t("创建可编辑的 CAD 副本，原文件保留。", "Creates an editable CAD copy and keeps the original file."))
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField(IDELanguageRunText.t("名称","Name"),text:$title)
                    if unitless {
                        Picker(IDELanguageRunText.t("文件单位","File units"),selection:$scale) {
                            Text(IDELanguageRunText.t("请选择","Choose units")).tag(Double?.none)
                            Text("mm").tag(Double?.some(1)); Text("cm").tag(Double?.some(10))
                            Text("m").tag(Double?.some(1000)); Text("inch").tag(Double?.some(25.4))
                        }.accessibilityIdentifier("space.cadImport.units")
                    }
                    Button(IDELanguageRunText.t("导入并打开","Import and open"),action:start)
                        .disabled(importing || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (unitless && scale == nil))
                        .accessibilityIdentifier("space.cadImport.open")
                    if importing { ProgressView(IDELanguageRunText.t("正在导入模型","Importing model")) }
                }.disabled(importing)
                if let problem { Section {
                    Text(IDELanguageRunText.t("导入未完成，原文件已保留。","Import did not finish. The original file is preserved.")).foregroundStyle(.orange)
                    DisclosureGroup(IDELanguageRunText.t("详情","Details")) { Text(problem).font(.footnote).textSelection(.enabled) }
                } }
            }
            .navigationTitle(IDELanguageRunText.t("在 CAD 打开","Open in CAD"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button(IDELanguageRunText.t("取消","Cancel")) {
                token?.cancel(); work?.cancel(); dismiss()
            } } }
        }
        .interactiveDismissDisabled(importing)
        .onDisappear { token?.cancel(); work?.cancel() }
    }
    private func start() {
        guard !importing else { return }
        importing = true; problem = nil
        let cancellation = MeshImportCancellation(); token = cancellation
        work = Task { @MainActor in
            defer { importing = false; token = nil; work = nil }
            do {
                let result = try await PersonalCADImport.open(record:request.record,title:title,unitScale:scale,cancellation:cancellation)
                try Task.checkCancellation(); onImported(result)
            } catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
}
#endif
