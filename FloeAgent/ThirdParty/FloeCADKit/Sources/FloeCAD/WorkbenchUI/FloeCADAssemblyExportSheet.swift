//
//  FloeCADAssemblyExportSheet.swift
//  FloeCADKit
//
//  Small exchange-export sheet. It is deliberately a thin view over the same
//  `FloeCADDocument.exchangeCoverage` / `nativeExchangeExport` plan used by
//  `cad.document`; there is no second export implementation here.
//
//  The normal flow stays short: pick STEP/GLB/USDZ and Part/Assembly, read
//  the object counts and excluded reasons, then Export. A partial receipt is
//  only written after the user explicitly chooses "Export Included".
//

import SwiftUI
import UniformTypeIdentifiers

struct CADAssemblyExportSheet: View {
    let document: FloeCADDocument
    let onReady: (ExportDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: ExchangeFormat = .step
    @State private var scope: CADExchangeScope = .part
    @State private var reviewedChangeCount: Int?
    @State private var coverage: CADExchangeCoverage?
    @State private var message: String?
    @State private var acceptedPartial = false

    init(document: FloeCADDocument, onReady: @escaping (ExportDocument) -> Void) {
        self.document = document
        self.onReady = onReady
        let assembly = try? CADAssembly.decode(from: document.session.document.assemblyData)
        let placed = assembly?.occurrences(includeHidden: false).contains(where: \.isDrawablePart) == true
        _scope = State(initialValue: placed ? .assembly : .part)
    }

    enum ExchangeFormat: String, CaseIterable, Identifiable, Equatable {
        case step
        case glb
        case usdz

        var id: String { rawValue }

        var title: String {
            switch self {
            case .step:
                return FloeCADStrings.text("cad.ui.export.format.step", "STEP (exact B-rep)")
            case .glb:
                return FloeCADStrings.text("cad.ui.export.format.glb", "GLB (scene)")
            case .usdz:
                return FloeCADStrings.text("cad.ui.export.format.usdz", "USDZ (scene)")
            }
        }

        var fileExtension: String { rawValue }

        var contentType: UTType {
            switch self {
            case .step: return ExportDocument.stepType
            case .glb: return ExportDocument.glbType
            case .usdz: return ExportDocument.usdzType
            }
        }
    }

    private var selection: CADExchangeSelection {
        CADExchangeSelection(scope: scope, acceptPartial: acceptedPartial,
                             expectedChangeCount: reviewedChangeCount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(FloeCADStrings.label("cad.ui.export.format", "Format"),
                           selection: $format) {
                        ForEach(ExchangeFormat.allCases.filter { $0 != .usdz || USDZExporter.isSupported }) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Picker(FloeCADStrings.label("cad.ui.export.scope", "Scope"),
                           selection: $scope) {
                        Text(FloeCADStrings.text("cad.ui.export.scope.part", "Part / parts only"))
                            .tag(CADExchangeScope.part)
                        Text(FloeCADStrings.text("cad.ui.export.scope.assembly",
                                                 "Assembly (placed instances)"))
                            .tag(CADExchangeScope.assembly)
                    }
                }

                if let coverage {
                    CADExportCoverageSummary(coverage: coverage)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.ui.export.exchangeTitle", "Export"))
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .onAppear { refresh() }
            .onChange(of: format) { _, _ in refresh() }
            .onChange(of: scope) { _, _ in refresh() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if coverage?.requiresConfirmation == true {
                        Button(FloeCADStrings.label("cad.ui.export.coverage.confirmPartial",
                                                    "Export Included")) {
                            acceptedPartial = true
                            perform()
                        }
                        .disabled((coverage?.includedCount ?? 0) == 0)
                    } else {
                        Button(FloeCADStrings.label("cad.ui.common.export", "Export")) {
                            perform()
                        }
                        .disabled((coverage?.includedCount ?? 0) == 0)
                    }
                }
            }
        }
    }

    private func refresh() {
        acceptedPartial = false
        message = nil
        reviewedChangeCount = document.liveChangeCount
        switch document.exchangeCoverage(format: format.rawValue, selection: selection) {
        case .success(let value):
            coverage = value
            if value.requiresConfirmation {
                message = FloeCADStrings.text(
                    "cad.ui.export.coverage.incomplete",
                    "Some objects cannot be carried in this format. Review the list before exporting.")
            }
        case .failure(let error):
            coverage = nil
            message = error.message
        }
    }

    private func perform() {
        switch document.nativeExchangeExport(format: format.rawValue, pageID: nil,
                                             selection: selection, dryRun: false) {
        case let .success(data, _, _):
            onReady(ExportDocument(data: data,
                                   contentType: format.contentType,
                                   fileExtension: format.fileExtension))
            dismiss()
        case .coverageRequired(let value):
            coverage = value
            acceptedPartial = false
            message = FloeCADStrings.text(
                "cad.ui.export.coverage.incomplete",
                "Some objects cannot be carried in this format. Review the list before exporting.")
        case .coverage(let value):
            coverage = value
        case .failure(let error):
            if error.code == "stale_export" {
                refresh()
                message = FloeCADStrings.text("cad.ui.export.coverage.changed",
                    "The model changed. Check the updated list before exporting.")
            } else {
                message = error.message
            }
        }
    }
}

/// Shared reason/copy mapping for a coverage receipt. The exchange sheet and
/// the GLB mesh options sheet show the exact same strings.
nonisolated enum CADExportCopy {
    static func reason(_ reason: String?) -> String {
        switch reason {
        case "mesh_only_no_analytic_brep":
            return FloeCADStrings.text("cad.export.reason.meshOnlyStep",
                                       "Mesh-only; STEP needs an analytic solid.")
        case "invalid_mesh", "empty_mesh", "normal_count_mismatch",
             "index_count_not_triangles", "index_out_of_range", "non_finite_mesh":
            return FloeCADStrings.text("cad.export.reason.invalidMesh",
                                       "Mesh data is invalid.")
        case "unsupported_face_materials":
            return FloeCADStrings.text("cad.export.reason.unsupportedFaceMaterials",
                                       "This format cannot carry per-face materials.")
        case "invalid_placement":
            return FloeCADStrings.text("cad.export.reason.invalidPlacement",
                                       "This placement is invalid.")
        case "source_body_missing":
            return FloeCADStrings.text("cad.export.reason.missingSource",
                                       "The source part is missing.")
        case .some(let other):
            return other.replacingOccurrences(of: "_", with: " ")
        case .none:
            return FloeCADStrings.text("cad.export.reason.excluded", "Not included.")
        }
    }

    static func materialWarning(_ warning: String) -> String {
        switch warning {
        case "texture_baseColor_missing", "texture_roughness_missing",
             "texture_metallic_missing", "texture_normal_missing",
             "texture_emissive_missing", "texture_opacity_missing":
            return FloeCADStrings.text("cad.export.reason.missingTexture",
                                       "A material image is missing.")
        case "texture_baseColor_invalid", "texture_roughness_invalid",
             "texture_metallic_invalid", "texture_normal_invalid",
             "texture_emissive_invalid", "texture_opacity_invalid":
            return FloeCADStrings.text("cad.export.reason.invalidTexture",
                                       "A material image is invalid or too large.")
        case "texture_baseColor_identity_mismatch", "texture_roughness_identity_mismatch",
             "texture_metallic_identity_mismatch", "texture_normal_identity_mismatch",
             "texture_emissive_identity_mismatch", "texture_opacity_identity_mismatch":
            return FloeCADStrings.text("cad.export.reason.textureIdentity",
                                       "A material image no longer matches its record.")
        case "texture_uv_unmapped":
            return FloeCADStrings.text("cad.export.reason.textureMapping",
                                       "A material image has no usable texture mapping.")
        case "ambiguous_texture_metadata":
            return FloeCADStrings.text("cad.export.reason.ambiguousTexture",
                                       "A material image is recorded more than once.")
        case "face_material_ranges_unavailable", "face_material_ambiguous",
             "face_material_unresolved":
            return FloeCADStrings.text("cad.export.reason.faceRanges",
                                       "Face material ranges are stale.")
        case "unsupported_hdr_emission":
            return FloeCADStrings.text("cad.export.reason.hdrEmission",
                                       "This format cannot keep this glow strength.")
        default:
            return warning.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func formatLoss(_ losses: [String]) -> String {
        if losses.contains("brep"), losses.contains("assembly_hierarchy") {
            return FloeCADStrings.text(
                "cad.export.formatLoss.meshFlat",
                "Mesh exchange: exact B-rep, history and PMI are not carried; hierarchy is flat.")
        }
        if losses.contains("brep") {
            return FloeCADStrings.text(
                "cad.export.formatLoss.mesh",
                "Mesh exchange: exact B-rep, history and PMI are not carried.")
        }
        return FloeCADStrings.text(
            "cad.export.formatLoss.step",
            "Exact geometry only: this file does not keep history, PMI, part names or assembly hierarchy.")
    }
}

/// One coverage receipt, rendered the same way wherever export options are
/// shown (the exchange sheet and the GLB mesh options sheet).
struct CADExportCoverageSummary: View {
    let coverage: CADExchangeCoverage

    private var warnedItems: [CADExchangeCoverageItem] {
        coverage.items.filter { !$0.materialWarnings.isEmpty }
    }

    var body: some View {
        Section {
            LabeledContent(
                FloeCADStrings.text("cad.ui.export.coverage.objects", "Objects"),
                value: "\(coverage.includedCount) / \(coverage.selectedCount)")
            LabeledContent(
                FloeCADStrings.text("cad.ui.export.coverage.units", "Units"),
                value: coverage.unit)
            if coverage.excludedCount > 0 {
                LabeledContent(
                    FloeCADStrings.text("cad.ui.export.coverage.excluded", "Excluded"),
                    value: "\(coverage.excludedCount)")
            }
        }

        if !coverage.excludedItems.isEmpty {
            Section {
                ForEach(Array(coverage.excludedItems.prefix(12).enumerated()),
                        id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(CADExportCopy.reason(item.reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(FloeCADStrings.text("cad.ui.export.coverage.reasons", "Not included"))
            }
        }

        if !warnedItems.isEmpty {
            Section {
                ForEach(Array(warnedItems.prefix(12).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.materialWarnings
                            .map { CADExportCopy.materialWarning($0) }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(FloeCADStrings.text("cad.ui.export.coverage.materialWarnings",
                                         "Material warnings"))
            }
        }

        if !coverage.formatLoss.isEmpty {
            Section {
                Text(CADExportCopy.formatLoss(coverage.formatLoss))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
