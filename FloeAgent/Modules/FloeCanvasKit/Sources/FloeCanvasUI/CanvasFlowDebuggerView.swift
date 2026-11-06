#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore
import FloeCanvasFlow

/// Live flow debugger. Every row comes from real runtime events or runtime
/// queries — no cosmetic timer, no fabricated success.
public struct CanvasFlowDebuggerView: View {
    @ObservedObject var store: CanvasEditorStore
    private var strings: CanvasStrings { store.strings }

    public init(store: CanvasEditorStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            if let run = store.flowRun {
                List {
                    Section(strings[.debuggerInputsOutputs]) {
                        ForEach(run.stepRecords, id: \.id) { record in
                            stepRow(record)
                        }
                    }
                    if !run.lateDeliveries.isEmpty {
                        Section(strings[.debuggerLateDeliveries]) {
                            ForEach(run.lateDeliveries, id: \.attemptID) { delivery in
                                Text(delivery.attemptID.uuidString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section(strings[.debuggerTitle]) {
                        if run.events.isEmpty {
                            Text(strings[.debuggerEmpty])
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(run.events.prefix(80), id: \.self) { event in
                                eventRow(event)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier(CanvasAccessibilityID.debuggerEventList.identifier)
            } else {
                Spacer()
                Text(strings[.debuggerEmpty])
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.debuggerPanel.identifier)
    }

    private var statusHeader: some View {
        VStack(spacing: 0) {
        HStack {
            Circle()
                .fill(phaseColor)
                .frame(width: 10, height: 10)
            if let run = store.flowRun {
                Text(phaseTitle(run.phase))
                    .font(.headline)
                Spacer()
                Text("\(run.completedSteps)/\(run.totalUnits)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if run.failureCount > 0 {
                    Label("\(run.failureCount)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let checkpointFailure = run.checkpointFailure {
                    // Real run-save failure state: shown as a warning with
                    // the host diagnostic — never as a successful save.
                    Label(checkpointFailure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(strings[.debuggerCheckpointFailed])
                }
            } else {
                Text(strings[.debuggerEmpty])
                    .foregroundStyle(.secondary)
            }
            Button { store.showsDebugger = false } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(strings[.toolbarDone])
            .accessibilityIdentifier("floe.canvas.debugger.close")
        }
        debuggerControls
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.debuggerStatus.identifier)
    }

    private var debuggerControls: some View {
        HStack(spacing: 10) {
            if let run = store.flowRun {
                if run.phase == .completed {
                    Button {
                        Task { await store.placeFlowRunOutputsOnPage() }
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .help(strings[.debuggerPlaceOutputs])
                    .accessibilityIdentifier(
                        CanvasAccessibilityID.debuggerPlaceOutputsButton.identifier)
                }
            }
            if let run = store.flowRun, !run.isTerminal {
                Button { store.pauseFlowRun() } label: {
                    Image(systemName: "pause.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowPause.identifier)
                Button { store.stepFlowRun() } label: {
                    Image(systemName: "forward.frame")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowStep.identifier)
                Button { store.resumeFlowRun() } label: {
                    Image(systemName: "play.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowResume.identifier)
                Button { store.cancelFlowRun() } label: {
                    Image(systemName: "stop.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowStop.identifier)
            }
        }
    }

    private func stepRow(_ record: FlowStepRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusColor(record.status))
                    .frame(width: 8, height: 8)
                Text(record.nodeID.uuidString.prefix(8) + "…")
                    .font(.caption)
                Spacer()
                Text(record.status.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !record.inputs.isEmpty {
                Text("\(strings[.debuggerInputs]): \(formatValues(record.inputs))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !record.outputs.isEmpty {
                Text("\(strings[.debuggerOutputs]): \(formatValues(record.outputs))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = record.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .swipeActions {
            if case .failed = record.status {
                Button(strings[.toolbarBypass]) {
                    store.bypassFlowNode(record.nodeID)
                }
                .tint(.orange)
            }
        }
    }

    private func eventRow(_ event: FlowRuntimeEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: eventIcon(event))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(eventTitle(event))
                    .font(.caption)
                if let detail = eventDetail(event) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func eventTitle(_ event: FlowRuntimeEvent) -> String {
        switch event {
        case .runStarted: return "run started"
        case .stepScheduled: return "scheduled"
        case .stepStarted: return "started"
        case .stepCompleted: return "completed"
        case .stepFailed: return "failed"
        case .stepSkipped: return "skipped"
        case .conditionSelected: return "condition selected"
        case .loopIteration: return "loop iteration"
        case .batchProgress: return "batch progress"
        case .breakpointHit: return "breakpoint"
        case .paused: return "paused"
        case .steppingPaused: return "stepped"
        case .resumed: return "resumed"
        case .cancelled: return "cancelled"
        case .reconcileRequired: return "reconcile required"
        case .reconciled: return "reconciled"
        case .lateDeliveryRecorded: return "late delivery"
        case .checkpointSaved: return "checkpoint"
        case .checkpointFailed: return strings[.debuggerCheckpointFailed]
        case .runFinished(_, let phase): return "finished: \(phase.rawValue)"
        }
    }

    private func eventIcon(_ event: FlowRuntimeEvent) -> String {
        switch event {
        case .stepFailed, .reconcileRequired, .checkpointFailed: return "exclamationmark.triangle"
        case .stepCompleted: return "checkmark.circle"
        case .breakpointHit: return "pause.circle"
        case .runFinished: return "flag"
        default: return "circle"
        }
    }

    private func eventDetail(_ event: FlowRuntimeEvent) -> String? {
        switch event {
        case .stepScheduled(_, let nodeID, let attempt, _):
            return "\(nodeID.uuidString.prefix(8)) #\(attempt)"
        case .stepStarted(_, let nodeID, let attempt, let external):
            return "\(nodeID.uuidString.prefix(8)) #\(attempt)\(external ? " · external" : "")"
        case .stepCompleted(_, let nodeID, _, let outputs):
            return "\(nodeID.uuidString.prefix(8)) · \(formatValues(outputs))"
        case .stepFailed(_, let nodeID, _, let error):
            return "\(nodeID.uuidString.prefix(8)) · \(error)"
        case .stepSkipped(_, let nodeID, let reason):
            return "\(nodeID.uuidString.prefix(8)) · \(reason)"
        case .loopIteration(_, let nodeID, let iteration):
            return "\(nodeID.uuidString.prefix(8)) · \(iteration)"
        case .batchProgress(_, let nodeID, let completedItems, let totalItems):
            return "\(nodeID.uuidString.prefix(8)) · \(completedItems)/\(totalItems)"
        case .reconcileRequired(_, let attemptID, let nodeID):
            return "\(nodeID.uuidString.prefix(8)) · \(attemptID.uuidString.prefix(8))"
        case .checkpointFailed(_, let error):
            return error
        default:
            return nil
        }
    }

    private var phaseColor: Color {
        guard let run = store.flowRun else { return .secondary }
        switch run.phase {
        case .running: return .green
        case .paused, .stepping: return .orange
        case .waitingReconcile: return .yellow
        case .completed: return .blue
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private func phaseTitle(_ phase: FlowRunPhase) -> String {
        switch phase {
        case .running: return strings[.debuggerRunning]
        case .paused: return strings[.debuggerPaused]
        case .stepping: return strings[.debuggerPaused]
        case .waitingReconcile: return strings[.debuggerWaitingReconcile]
        case .completed: return strings[.debuggerCompleted]
        case .failed: return strings[.debuggerFailed]
        case .cancelled: return strings[.debuggerCancelled]
        }
    }

    private func statusColor(_ status: FlowStepStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .running: return .green
        case .succeeded: return .blue
        case .failed: return .red
        case .cancelled, .skipped: return .secondary
        }
    }

    private func formatValues(_ values: [String: FlowValue]) -> String {
        values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.valueType.rawValue)" }
            .joined(separator: " ")
    }
}

/// Sheet wrapper for the debugger on narrow layouts.
public struct CanvasFlowDebuggerSheet: View {
    @ObservedObject var store: CanvasEditorStore

    public var body: some View {
        CanvasFlowDebuggerView(store: store)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.vertical, 60)
    }
}
#endif
