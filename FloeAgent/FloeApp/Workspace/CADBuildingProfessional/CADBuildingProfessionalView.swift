// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeCAD
import FloeCore

@MainActor
struct CADBuildingProfessionalView: View {
    let document: FloeCADDocument
    let action: CADBuildingProfessionalAction
    let root: URL?
    let workspaceID: UUID?
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var structural = CADBuildingStructuralSettings()
    @State private var beams: [CADBuildingElement] = []
    @State private var inputsConfirmed = false
    @State private var operation: CADBuildingProfessionalOperation?
    @State private var starting = false
    @State private var startTask: Task<Void, Never>?
    @State private var cancelling = false
    @State private var message: String?
    @State private var artifacts: [URL] = []
    private func t(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
    private var title: String {
        switch action {
        case .ifc: FloeL10n.l("app.cadbuilding_professional_view.export_ifc")
        case .structure: FloeL10n.l("app.cadbuilding_professional_view.beam_analysis")
        case .mep: FloeL10n.l("app.cadbuilding_professional_view.mep_coordination")
        case .information: FloeL10n.l("app.cadbuilding_professional_view.information_requirements")
        }
    }
    private var structuralValid: Bool {
        structural.memberID != nil && inputsConfirmed && structural.elasticModulusNPerMM2.isFinite
            && (1...1e7).contains(structural.elasticModulusNPerMM2)
            && structural.poissonRatio.isFinite && (0..<0.5).contains(structural.poissonRatio)
            && structural.lineLoadNPerMM.isFinite && (0.000001...1e6).contains(structural.lineLoadNPerMM)
    }
    private var canStart: Bool {
        !starting && operation?.isRunning != true && (action != .structure || structuralValid)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(introduction).font(.callout).foregroundStyle(.secondary)
                    Text(FloeL10n.l("app.cadbuilding_professional_view.calculates_on_this_device_with"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if action == .structure { structuralInputs.disabled(starting || operation?.isRunning == true) }
                Section {
                    if starting || operation?.isRunning == true {
                        HStack {
                            ProgressView()
                            Text(cancelling || operation?.state == .cancelling ? FloeL10n.l("app.core_aimodel_inspection.cancelling") : FloeL10n.l("app.cadbuilding_professional_view.preparing_and_calculating"))
                            Spacer()
                            if starting {
                                Button(FloeL10n.l("cad.scene.cancel"), role: .destructive) { cancelling = true; startTask?.cancel() }.disabled(cancelling)
                            } else if let operation {
                                Button(FloeL10n.l("cad.scene.cancel"), role: .destructive) { cancel(operation.id) }.disabled(cancelling)
                            }
                        }.accessibilityIdentifier("cad.building.professional.progress")
                    } else {
                        Button(title, systemImage: "play.fill") { start() }
                            .disabled(!canStart).accessibilityIdentifier("cad.building.professional.start")
                    }
                    if let operation {
                        LabeledContent(FloeL10n.l("envdetail.status"), value: stateTitle(operation.state))
                        if operation.state == .ready {
                            Text(FloeL10n.l("app.cadbuilding_professional_view.these_results_use_the_saved"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message {
                        Text(FloeL10n.l("app.cadbuilding_professional_view.the_study_could_not_complete")).foregroundStyle(.red)
                        DisclosureGroup(FloeL10n.l("app.cadbuilding_professional_view.error_details")) { Text(message).font(.caption).textSelection(.enabled) }
                    }
                }
                if let result = operation?.result, operation?.state == .ready {
                    resultSections(result)
                    if !artifacts.isEmpty {
                        Section(FloeL10n.l("app.floe_agent_app.files")) {
                            ForEach(artifacts, id: \.self) { url in
                                ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                            }
                        }
                    }
                    Section {
                        DisclosureGroup(FloeL10n.l("app.cadbuilding_professional_view.calculation_details")) {
                            ForEach(result.backendVersions.keys.sorted(), id: \.self) { key in LabeledContent(key, value: result.backendVersions[key] ?? "") }
                            LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.source_revision"), value: "\(result.sourceRevision)")
                            LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.display_triangles"), value: "\(result.triangles)")
                        }
                    }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(FloeL10n.l("help.done")) { dismiss() } } }
            .onAppear {
                do { beams = try document.building()?.elements.filter { $0.kind == .beam } ?? [] }
                catch { message = error.localizedDescription }
            }
            .task(id: operation?.id) {
                if operation == nil, !starting {
                    operation = environment.buildingProfessionalCenter.latest(documentURL: document.url, action: action, root: root, conversationID: conversationID)
                }
                while !Task.isCancelled, let current = operation {
                    await refresh()
                    if !current.isRunning { break }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                }
            }
        }
    }
    private var introduction: String {
        switch action {
        case .ifc: FloeL10n.l("app.cadbuilding_professional_view.generate_ifc4_from_the_current")
        case .structure: FloeL10n.l("app.cadbuilding_professional_view.run_a_linear_elastic_calculation")
        case .mep: FloeL10n.l("app.cadbuilding_professional_view.check_geometric_intersections_between_pipes")
        case .information: FloeL10n.l("app.cadbuilding_professional_view.use_ids_information_requirements_to")
        }
    }
    private var structuralInputs: some View {
        Section(FloeL10n.l("app.cadbuilding_professional_view.analysis_inputs")) {
            Picker(FloeL10n.l("cad.building.element.beam"), selection: $structural.memberID) {
                Text(FloeL10n.l("app.cadbuilding_professional_view.choose_a_beam")).tag(Optional<UUID>.none)
                ForEach(beams) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("cad.building.professional.beam")
            if beams.isEmpty { Text(FloeL10n.l("app.cadbuilding_professional_view.add_a_beam_to_the")).foregroundStyle(.secondary) }
            Picker(FloeL10n.l("app.cadbuilding_professional_view.supports"), selection: $structural.support) {
                Text(FloeL10n.l("app.cadbuilding_professional_view.simply_supported")).tag(CADBuildingStructuralSettings.Support.simplySupported)
                Text(FloeL10n.l("app.cadbuilding_professional_view.cantilever")).tag(CADBuildingStructuralSettings.Support.cantilever)
            }
            numberField(FloeL10n.l("app.cadbuilding_professional_view.elastic_modulus_n_mm"), value: $structural.elasticModulusNPerMM2)
            numberField(FloeL10n.l("app.cadbuilding_professional_view.poisson_ratio"), value: $structural.poissonRatio)
            numberField(FloeL10n.l("app.cadbuilding_professional_view.downward_uniform_load_kn_m"), value: $structural.lineLoadNPerMM)
            Toggle(FloeL10n.l("app.cadbuilding_professional_view.use_these_supports_material_and"), isOn: $inputsConfirmed)
                .accessibilityIdentifier("cad.building.professional.confirmInputs")
        }
    }
    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number).multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad).frame(maxWidth: 140)
        }
    }
    @ViewBuilder private func resultSections(_ result: CADBuildingProfessionalResult) -> some View {
        if let analysis = result.analysis {
            Section(FloeL10n.l("app.cadbuilding_professional_view.single_beam_results")) {
                LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.span"), value: number(analysis.spanMM, unit: "mm"))
                LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.downward_uniform_load"), value: number(analysis.lineLoadNPerMM, unit: "kN/m"))
                LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.minimum_vertical_deflection"), value: number(analysis.minimumDeflectionMM, unit: "mm"))
                LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.total_support_reaction"), value: number(analysis.reactionSumN, unit: "N"))
            }.accessibilityIdentifier("cad.building.professional.structuralResult")
        }
        if let coordination = result.coordination {
            Section(FloeL10n.l("app.cadbuilding_professional_view.geometric_coordination")) {
                if coordination.status == "notEvaluated" {
                    Text(FloeL10n.l("app.cadbuilding_professional_view.geometry_could_not_be_evaluated"))
                } else {
                    if coordination.status == "partiallyEvaluated" {
                        Text(FloeL10n.l("app.cadbuilding_professional_view.some_geometry_could_not_be"))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.intersections"), value: "\(coordination.clashes.count)")
                    if let count = coordination.unevaluatedMeshPairs, count > 0 { LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.unevaluated_pairs"), value: "\(count)") }
                    if let tolerance = coordination.toleranceM { LabeledContent(FloeL10n.l("app.cadbuilding_professional_view.tolerance"), value: number(tolerance * 1000, unit: "mm")) }
                    ForEach(Array(coordination.clashes.prefix(50).enumerated()), id: \.offset) { _, clash in
                        VStack(alignment: .leading) {
                            Text("\(clash.a) ↔ \(clash.b)").font(.caption.monospaced())
                            if let volume = clash.overlapVolumeM3 {
                                Text(FloeL10n.l("app.cadbuilding_professional_view.overlap_volume") + number(volume, unit: "m³")).font(.caption)
                            } else if let distance = clash.distanceM {
                                Text(number(distance * 1000, unit: "mm")).font(.caption)
                            }
                        }
                    }
                }
            }.accessibilityIdentifier("cad.building.professional.mepResult")
        }
        if let information = result.information {
            Section(FloeL10n.l("app.cadbuilding_professional_view.information_requirements_2")) {
                ForEach(Array(information.checks.enumerated()), id: \.offset) { _, check in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(check.name, systemImage: check.passed ? "checkmark.circle" : "exclamationmark.circle")
                        Text(FloeL10n.l("app.cadbuilding_professional_view.applicable_failed", check.applicable, check.failed)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityIdentifier("cad.building.professional.informationResult")
        }
    }
    private func number(_ value: Double, unit: String) -> String { "\(value.formatted(.number.precision(.significantDigits(5)))) \(unit)" }
    private func stateTitle(_ state: CADBuildingProfessionalOperation.State) -> String {
        switch state {
        case .preparing: FloeL10n.l("canvas.generation.state.preparing")
        case .running: FloeL10n.l("app.cadbuilding_professional_view.running")
        case .ready: FloeL10n.l("app.cadbuilding_professional_view.ready")
        case .cancelling: FloeL10n.l("skills.authoring.phase.cancelling")
        case .cancelled: FloeL10n.l("background.event.cancelled")
        case .failed: FloeL10n.l("canvas.generation.state.failed")
        case .interrupted: FloeL10n.l("core.linux_background_surface.interrupted")
        }
    }
    private func start() {
        guard canStart else { return }
        starting = true; message = nil; artifacts = []; operation = nil
        startTask = Task {
            defer { starting = false; cancelling = false; startTask = nil }
            do {
                let created = try await environment.buildingProfessionalCenter.startFromUI(document: document, action: action,
                    structural: structural, root: root, workspaceID: workspaceID, conversationID: conversationID)
                operation = Task.isCancelled ? try await environment.buildingProfessionalCenter.cancel(created.id) : created
            }
            catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
    private func cancel(_ id: UUID) {
        cancelling = true
        Task {
            defer { cancelling = false }
            do { operation = try await environment.buildingProfessionalCenter.cancel(id) }
            catch { message = error.localizedDescription }
        }
    }
    private func refresh() async {
        guard let current = operation else { return }
        do {
            let updated = try await environment.buildingProfessionalCenter.refresh(current.id)
            guard operation?.id == current.id else { return }
            operation = updated; message = updated.error
            if updated.state == .ready, artifacts.isEmpty { artifacts = try environment.buildingProfessionalCenter.artifactURLs(updated) }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
