// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeSecurity

/// Activation-local evidence for phone approval. It is intentionally absent
/// from checkpoints: resumed work must obtain a new device observation.
/// Dispatch still checks live owner, window, generation and expiry itself.
struct PhoneObservationReviewCache: Sendable {
    private struct Observation: Sendable {
        let sourceTool: String
        let id: UUID
        let page: String
        let lines: [String]
    }
    private var latest: Observation?

    /// Called only on the normal, just-settled execution path, before durable
    /// result compaction. Recovery and assistant messages never populate it.
    mutating func record(call: ToolCall, result: ToolResult, outcomeUnknown: Bool) {
        guard call.toolName == "phone.observe" || call.toolName == "phone.act" else { return }
        latest = nil
        guard result.callID == call.id, result.status == .ok, !outcomeUnknown else { return }
        let lines = String(result.outputSummary.prefix(4_096))
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first(where: { $0.hasPrefix("observation=") }),
              header.contains(" page="),
              let first = header.split(separator: " ").first,
              let id = UUID(uuidString: String(first.dropFirst("observation=".count)))
        else { return }
        latest = Observation(sourceTool: call.toolName, id: id,
                             page: header, lines: lines)
    }

    func evidence(for call: ToolCall, redactingSecret secret: String?) -> PhoneObservationEvidence? {
        guard call.toolName == "phone.act", let latest,
              let args = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              let rawID = args["observationId"] as? String,
              let id = UUID(uuidString: rawID), id == latest.id,
              let ref = args["nodeRef"] as? String, ref.count <= 32,
              ref.hasPrefix("n"), ref.count > 1,
              ref.dropFirst().allSatisfy({ $0 >= "0" && $0 <= "9" })
        else { return nil }
        // Reject an ambiguous projection instead of guessing a node. Labels
        // from other observations or assistant text cannot fill this slot.
        let matches = latest.lines.filter { $0.hasPrefix(ref + "|") }
        guard matches.count == 1, let node = matches.first else { return nil }
        return PhoneObservationEvidence(
            sourceTool: latest.sourceTool, observationID: latest.id.uuidString.lowercased(),
            pageSummary: SecretRedactor.redact(latest.page, secret: secret), nodeRef: ref,
            nodeSummary: SecretRedactor.redact(node, secret: secret)
        )
    }
}
