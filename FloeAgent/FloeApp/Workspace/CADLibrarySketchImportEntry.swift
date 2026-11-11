// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCAD

private struct CADLibrarySketchImportRequest: Identifiable, Sendable {
    let id = UUID()
    let context: CADSketchImportContext
    let lifetime: CADLibrarySketchImportLifetime
}

@MainActor private final class CADLibrarySketchImportLifetime {
    var cancelled = false
    var operation: Task<Void, Never>?
    func cancel() { cancelled = true; operation?.cancel(); operation = nil }
}

/// Installed by the App host, once per actual editor presentation. No UIKit
/// global presenter and no library dependency inside the CAD package.
@MainActor struct CADLibrarySketchImportEntry: ViewModifier {
    let document: FloeCADDocument
    var onCoverChange: (@MainActor (Bool) -> Void)? = nil
    @Environment(\.cadWorkbenchTransientlyCovered) private var parentCovered
    @State private var request: CADLibrarySketchImportRequest?
    @State private var activeLifetime: CADLibrarySketchImportLifetime?

    func body(content: Content) -> some View {
        content
            .environment(\.cadWorkbenchTransientlyCovered, parentCovered || request != nil)
            .environment(\.cadImportSketchFromLibrary, { context in
                guard request == nil else { return }
                let lifetime = CADLibrarySketchImportLifetime()
                activeLifetime = lifetime
                onCoverChange?(true)
                request = CADLibrarySketchImportRequest(context: context, lifetime: lifetime)
            })
            .sheet(item: $request, onDismiss: {
                activeLifetime?.cancel(); activeLifetime = nil
                onCoverChange?(false)
            }) { request in
                CADLibrarySketchImportSheet(document: document, context: request.context, lifetime: request.lifetime)
            }
            .onChange(of: ObjectIdentifier(document)) { _, _ in
                activeLifetime?.cancel(); request = nil; onCoverChange?(false)
            }
            .onChange(of: document.isClosed) { _, closed in
                if closed { activeLifetime?.cancel(); request = nil; onCoverChange?(false) }
            }
    }
}

@MainActor private struct CADLibrarySketchImportSheet: View {
    let document: FloeCADDocument
    let context: CADSketchImportContext
    let lifetime: CADLibrarySketchImportLifetime
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [PersonalContentRecord] = []
    @State private var source: PersonalCADSketchSource?
    @State private var selectedSketchID: UUID?
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?
    @State private var problemDetails: String?
    @State private var generation = UUID()

    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private var selected: CADLibrarySketchItem? {
        source?.native.sketches.first { $0.id == selectedSketchID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(t("目标草图", "Destination sketch"), value: context.sketchName)
                }
                if let source {
                    Section {
                        LabeledContent(t("二维项目", "2D project"), value: source.record.title)
                        Button(t("选择其他项目", "Choose another project")) { clearSource() }
                            .disabled(working)
                            .accessibilityIdentifier("cad.librarySketch.changeProject")
                    }
                    Section(t("选择草图", "Choose a sketch")) {
                        if source.native.sketches.isEmpty {
                            Text(t("这个项目还没有草图。", "This project has no sketches yet."))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(source.native.sketches) { sketch in
                            Button { selectedSketchID = sketch.id; problem = nil } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(sketch.name)
                                        Text("\(sketch.entityCount) " + t("个图形", "entities"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if sketch.id == selectedSketchID { Image(systemName: "checkmark").accessibilityHidden(true) }
                                }
                            }
                            .disabled(working || sketch.entityCount == 0)
                            .accessibilityIdentifier("cad.librarySketch.sketch.\(sketch.id.uuidString)")
                            .accessibilityAddTraits(sketch.id == selectedSketchID ? .isSelected : [])
                        }
                    }
                    if let selected {
                        Section(t("导入摘要", "Import summary")) {
                            LabeledContent(t("图形", "Entities"), value: String(selected.entityCount))
                            LabeledContent(t("构造图形", "Construction entities"), value: String(selected.constructionCount))
                            Text(t("按实际尺寸放入当前草图平面。原项目保留；只复制几何，尺寸、约束与关联留在原项目。",
                                   "Copies geometry at its actual size onto the current sketch plane. The original project, dimensions, constraints and links stay in the source."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section(t("二维CAD项目", "2D CAD projects")) {
                        if loading { ProgressView(t("正在读取项目", "Loading projects")) }
                        else if projects.isEmpty {
                            Text(t("还没有可用的二维CAD项目。", "No 2D CAD projects are available yet."))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(projects) { project in
                            Button { open(project) } label: { Label(project.title, systemImage: "square.on.square") }
                                .disabled(working)
                                .accessibilityIdentifier("cad.librarySketch.project.\(project.id.uuidString)")
                        }
                    }
                }
                if working { ProgressView(t("正在准备导入", "Preparing import")) }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(.orange).textSelection(.enabled)
                        if let problemDetails {
                            DisclosureGroup(t("详情", "Details")) { Text(problemDetails).font(.footnote).textSelection(.enabled) }
                        }
                        Button(t("刷新项目", "Refresh projects")) { refresh() }.disabled(working || loading)
                    }
                }
            }
            .navigationTitle(t("从二维项目导入", "Import from a 2D project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("取消", "Cancel")) { cancel(); dismiss() }
                        .accessibilityIdentifier("cad.librarySketch.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("导入", "Import"), action: startImport)
                        .disabled(working || loading || selected == nil)
                        .accessibilityLabel(t("导入当前草图", "Import into current sketch"))
                        .accessibilityIdentifier("cad.librarySketch.import")
                }
            }
        }
        .accessibilityIdentifier("cad.librarySketch.sheet")
        .task { await loadProjects() }
    }

    private func loadProjects() async {
        loading = true
        do {
            let values = try await PersonalCADSketchImport.projects()
            try Task.checkCancellation()
            guard !lifetime.cancelled else { return }
            try document.validateSketchImportContext(context)
            projects = values; problem = nil
        } catch { if !Task.isCancelled { setProblem(error) } }
        if !Task.isCancelled { loading = false }
    }

    private func open(_ record: PersonalContentRecord) {
        guard !working else { return }
        let id = UUID(); generation = id; working = true; problem = nil
        lifetime.operation = Task { @MainActor in
            defer { if generation == id { working = false; lifetime.operation = nil } }
            do {
                let value = try await PersonalCADSketchImport.load(projectID: record.id)
                try Task.checkCancellation()
                guard generation == id, !lifetime.cancelled else { return }
                try document.validateSketchImportContext(context)
                source = value; selectedSketchID = nil
            } catch { if !Task.isCancelled && generation == id { setProblem(error) } }
        }
    }

    private func startImport() {
        guard !working, let source, let selectedSketchID else { return }
        let id = UUID(); generation = id; working = true; problem = nil
        lifetime.operation = Task { @MainActor in
            defer { if generation == id { working = false; lifetime.operation = nil } }
            do {
                _ = try await PersonalCADSketchImport.append(source, sketchID: selectedSketchID,
                    to: document, context: context)
                guard generation == id, !lifetime.cancelled else { return }
                dismiss()
            } catch { if !Task.isCancelled && generation == id { setProblem(error) } }
        }
    }

    private func clearSource() { source = nil; selectedSketchID = nil; problem = nil; problemDetails = nil }
    private func setProblem(_ error: Error) {
        if error is CADSketchImportError || error is PersonalContentError || error is PersonalCADSketchImportIssue {
            problem = error.localizedDescription; problemDetails = nil
        } else {
            problem = t("读取或导入未完成，请重试或选择其他项目。", "Reading or importing did not finish. Try again or choose another project.")
            problemDetails = error.localizedDescription
        }
    }
    private func refresh() {
        guard !working else { return }
        clearSource()
        loading = true
        lifetime.operation = Task { @MainActor in await loadProjects(); lifetime.operation = nil }
    }
    private func cancel() { generation = UUID(); lifetime.cancel() }
}
#endif
