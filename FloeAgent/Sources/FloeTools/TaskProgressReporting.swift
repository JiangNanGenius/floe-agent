// FloeTools — background-job progress reporting contract.
//
// A tool executing inside a durable background job receives a runtime/app
// injected reporter through `ToolContext.taskProgress`; ordinary foreground
// tool calls leave it nil. Tools report only REAL processor units (frames,
// bytes, batches) at natural checkpoints — never per frame, never an invented
// percentage. Coalescing and persistence are the reporter's job.

import Foundation

/// Native diagnostic data for the existing progress channel. This is not a
/// provider event, permission or terminal tool result. The injected reporter
/// binds it to its own approved run/call; payload IDs only correlate rows.
public struct TaskDiagnosticProgress: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable { case resolved, intermediate, reached, timeout, unreachable }
    public let requestID: UUID
    public let status: Status
    public let ttl: Int?
    public let address: String?
    public let milliseconds: [Double]
    public let reason: String?
    public init?(requestID: UUID, status: Status, ttl: Int? = nil, address: String? = nil,
                 milliseconds: [Double] = [], reason: String? = nil) {
        guard (status == .resolved ? ttl == nil : ttl.map { (1...30).contains($0) } == true),
              address.map({ $0.utf8.count <= 64 && !$0.contains(where: { $0.isNewline || $0.isWhitespace }) }) ?? true,
              milliseconds.count <= 2, milliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        self.requestID = requestID; self.status = status; self.ttl = ttl; self.address = address
        self.milliseconds = milliseconds; self.reason = reason.map { String($0.prefix(256)) }
    }
    private enum CodingKeys: String, CodingKey { case requestID, status, ttl, address, milliseconds, reason }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard let checked = Self(requestID: try fields.decode(UUID.self, forKey: .requestID),
            status: try fields.decode(Status.self, forKey: .status),
            ttl: try fields.decodeIfPresent(Int.self, forKey: .ttl),
            address: try fields.decodeIfPresent(String.self, forKey: .address),
            milliseconds: try fields.decode([Double].self, forKey: .milliseconds),
            reason: try fields.decodeIfPresent(String.self, forKey: .reason)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid native diagnostic observation"))
        }
        self = checked
    }
    /// Same hop-line format as the final native traceroute report.
    public var hopText: String? {
        guard let ttl else { return nil }
        switch status {
        case .intermediate, .reached:
            let rtts = milliseconds.isEmpty ? "none" : milliseconds.map { String(format: "%.2f", $0) }.joined(separator: ",")
            return "hop ttl=\(ttl) address=\(address ?? "*") rttMs=\(rtts)"
        case .timeout: return "hop ttl=\(ttl) status=timeout"
        case .unreachable: return "hop ttl=\(ttl) status=unreachable reason=\(reason ?? "unknown")"
        case .resolved: return nil
        }
    }
}

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
    /// Optional real observation. Existing durable reporters may ignore this
    /// field; foreground cards require a host-injected native reporter.
    public var diagnostic: TaskDiagnosticProgress?

    public init(
        stage: String,
        phase: String? = nil,
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        note: String? = nil,
        diagnostic: TaskDiagnosticProgress? = nil
    ) {
        self.stage = String(stage.prefix(32))
        self.phase = phase.map { String($0.prefix(64)) }
        self.completedUnits = completedUnits.map { max(0, $0) }
        self.totalUnits = totalUnits.map { max(0, $0) }
        self.note = note.map { String($0.prefix(512)) }
        self.diagnostic = diagnostic
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

/// A host-owned adapter for the same channel (including shell stdout). It
/// does not install itself in a foreground context or confer authority.
public struct CallbackTaskProgressReporter: TaskProgressReporting {
    private let receive: @Sendable (TaskProgressUpdate) async -> Void
    public init(_ receive: @escaping @Sendable (TaskProgressUpdate) async -> Void) { self.receive = receive }
    public func report(_ update: TaskProgressUpdate) async { await receive(update) }
}
