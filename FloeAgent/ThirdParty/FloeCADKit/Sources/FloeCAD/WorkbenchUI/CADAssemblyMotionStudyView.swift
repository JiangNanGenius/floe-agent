import SwiftUI

@MainActor
struct CADAssemblyMotionStudyView: View {
    let document: FloeCADDocument
    let constraint: CADAssemblyReport.Constraint
    let report: CADAssemblyReport
    @State private var from: String
    @State private var to: String
    @State private var samples = 21
    @State private var operation: Task<Void, Never>?
    @State private var result: [String: Any]?
    @State private var error: String?

    init(document: FloeCADDocument, constraint: CADAssemblyReport.Constraint,
         report: CADAssemblyReport) {
        self.document = document; self.constraint = constraint; self.report = report
        _from = State(initialValue: String(constraint.joint?.lowerLimit ?? 0))
        _to = State(initialValue: String(constraint.joint?.upperLimit ?? (constraint.kind == "hinge" ? 90 : 10)))
    }

    private var valid: Bool {
        guard let a = Double(from), let b = Double(to), a.isFinite, b.isFinite else { return false }
        return a != b
    }

    var body: some View {
        Form {
            Section(constraint.kind == "hinge" ? "°" : "mm") {
                CADPanelNumberField(title: FloeCADStrings.text("cad.joint.from", "From"),
                                    text: $from, identifier: "CADMotionFrom")
                CADPanelNumberField(title: FloeCADStrings.text("cad.joint.to", "To"),
                                    text: $to, identifier: "CADMotionTo")
                Stepper(value: $samples, in: 2...121) {
                    LabeledContent(FloeCADStrings.text("cad.joint.samples", "Positions"), value: String(samples))
                }
            }
            .disabled(operation != nil)
            Section {
                if operation != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(FloeCADStrings.text("cad.joint.checking", "Checking motion…"))
                    }
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"), role: .cancel) { cancel() }
                } else {
                    Button(FloeCADStrings.text("cad.joint.motion", "Check motion")) { start() }
                        .disabled(!valid)
                        .accessibilityIdentifier("CADMotionStart")
                }
            }
            if let result {
                Section(FloeCADStrings.text("cad.joint.complete", "Motion check complete")) {
                    let frames = result["frames"] as? [[String: Any]] ?? []
                    let collisions = frames.filter {
                        (($0["interference"] as? [String: Any])?["interferingPairCount"] as? Int ?? 0) > 0
                    }.count
                    LabeledContent(FloeCADStrings.text("cad.joint.samples", "Positions"), value: String(frames.count))
                    LabeledContent(FloeCADStrings.text("cad.joint.collisions", "Positions with interference"), value: String(collisions))
                    ForEach(Array((result["travelMM"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, row in
                        LabeledContent(report.instanceName(row["instanceID"] as? String ?? ""),
                                       value: String(format: "%.2f mm · %.1f°", row["distance"] as? Double ?? 0, row["angleDegrees"] as? Double ?? 0))
                    }
                }
                .accessibilityIdentifier("CADMotionResult")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(FloeCADStrings.text("cad.joint.motion", "Check motion"))
        .onDisappear { cancel() }
    }

    private func start() {
        guard let a = Double(from), let b = Double(to), operation == nil else { return }
        error = nil; result = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            let reply = await CADAssemblyService(document: document).handleAsync(action: "motionStudy",
                args: ["id": constraint.id, "from": a, "to": b, "samples": samples])
            guard !Task.isCancelled else { return }
            if reply["ok"] as? Bool == true { result = reply }
            else { error = reply["message"] as? String }
        }
    }

    private func cancel() {
        guard operation != nil else { return }
        operation?.cancel()
        _ = CADAssemblyService(document: document).handle(action: "cancelMotionStudy", args: [:])
        // The worker is joined by its service call before its task exits.
        // Keep the run occupied until that exit, even when this view leaves.
    }
}
