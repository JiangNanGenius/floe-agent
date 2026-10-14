// FloeTools — background-job progress reporting contract.
//
// A tool executing inside a durable background job receives a runtime/app
// injected reporter through `ToolContext.taskProgress`; ordinary foreground
// tool calls leave it nil. Tools report only REAL processor units (frames,
// bytes, batches) at natural checkpoints — never per frame, never an invented
// percentage. Coalescing and persistence are the reporter's job.

import Foundation

/// One bounded progress observation from a tool.
public struct TaskProgressUpdate: Sendable, Equatable {
    /// Coarse lifecycle stage, e.g. "running", "cancelling", "finalizing".
    public var stage: String
    /// Tool-specific phase, e.g. "processing", "encoding".
    public var phase: String?
    /// Real completed units from the processor; never invented.
    public var completedUnits: Int?
    /// Real total units when the processor knows it.
    public var totalUnits: Int?
    /// Bounded, human-readable note; never user content.
    public var note: String?

    public init(
        stage: String,
        phase: String? = nil,
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        note: String? = nil
    ) {
        self.stage = String(stage.prefix(32))
        self.phase = phase.map { String($0.prefix(64)) }
        self.completedUnits = completedUnits.map { max(0, $0) }
        self.totalUnits = totalUnits.map { max(0, $0) }
        self.note = note.map { String($0.prefix(512)) }
    }

    /// Fraction only when the caller supplied real units; otherwise nil (the
    /// UI must show an indeterminate state, not a fabricated percentage).
    public var fraction: Double? {
        guard let completedUnits, let totalUnits, totalUnits > 0 else { return nil }
        return min(1, Double(completedUnits) / Double(totalUnits))
    }
}

/// Reporter injected by the job executor for the duration of one tool run.
public protocol TaskProgressReporting: Sendable {
    func report(_ update: TaskProgressUpdate) async
}
