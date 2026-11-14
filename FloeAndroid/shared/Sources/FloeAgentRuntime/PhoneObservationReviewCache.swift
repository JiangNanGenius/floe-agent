// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeSecurity

/// Activation-local evidence for device (phone/tablet) approval. It is
/// intentionally absent from checkpoints: resumed work must obtain a new
/// device observation. Dispatch still checks live owner, window, generation
/// and expiry itself. Both the canonical device.* names and the bounded
/// legacy phone.* spellings are accepted so a restored activation that still
/// names the old tools keeps identical evidence behavior.
struct PhoneObservationReviewCache: Sendable {
    private struct Node: Sendable {
        let sourceTool: String
        let page: String
        let line: String
    }
    private struct Observation: Sendable {
        let id: UUID
        let screen: String
        var nodes: [String: Node] = [:]
        var ambiguous: Set<String> = []
    }
    private struct PageRequest: Decodable {
        let observationId: UUID
        let offset: Int?
    }
    // Match the host's bounded captured tree/text budget. This is evidence
    // retention, never an extension of the host's observation lifetime.
    private static let maximumNodes = 400
    private static let maximumCharacters = 64_000
    private var latest: Observation?

    /// Called only on the normal, just-settled execution path, before durable
    /// result compaction. Recovery and assistant messages never populate it.
    mutating func record(call: ToolCall, result: ToolResult, outcomeUnknown: Bool) {
        guard DeviceToolNames.allInteractionNames.contains(call.toolName) else { return }
        let previous = latest
        latest = nil
        guard result.callID == call.id, result.status == .ok, !outcomeUnknown else { return }
        let prefix = String(result.outputSummary.prefix(4_096))
        var lines = prefix
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if result.outputSummary.count > prefix.count, !prefix.hasSuffix("\n") {
            lines.removeLast() // Never project a partially retained node.
        }
        guard let header = lines.first(where: { $0.hasPrefix("observation=") }),
              header.contains(" page="),
              let first = header.split(separator: " ").first,
              let id = UUID(uuidString: String(first.dropFirst("observation=".count)))
        else { return }
        let screen = header.split(separator: " ").filter {
            $0.hasPrefix("page=") || $0.hasPrefix("window=") || $0.hasPrefix("display=")
        }.joined(separator: " ")
        let request = try? JSONDecoder().decode(PageRequest.self, from: call.argumentsJSON)
        let isPage = DeviceToolNames.canonical(call.toolName) == DeviceToolNames.observe
            && request?.observationId == id
            && (0...Self.maximumNodes).contains(request?.offset ?? 0)
        var observation = Observation(id: id, screen: screen)
        if isPage, let previous, previous.id == id {
            guard previous.screen == screen else { return }
            observation = previous
        }
        var seen: Set<String> = []
        for line in lines {
            guard let separator = line.firstIndex(of: "|") else { continue }
            let ref = String(line[..<separator])
            guard Self.isNodeRef(ref) else { continue }
            if !seen.insert(ref).inserted
                || observation.nodes[ref].map({ $0.line != line }) == true {
                observation.ambiguous.insert(ref)
            }
            if observation.nodes[ref] == nil {
                observation.nodes[ref] = Node(sourceTool: call.toolName, page: header, line: line)
            }
        }
        guard observation.nodes.count <= Self.maximumNodes,
              observation.nodes.values.reduce(0, { $0 + $1.line.count }) <= Self.maximumCharacters
        else { return }
        latest = observation
    }

    func evidence(for call: ToolCall, redactingSecret secret: String?) -> PhoneObservationEvidence? {
        guard DeviceToolNames.canonical(call.toolName) == DeviceToolNames.act, let latest,
              let args = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              let rawID = args["observationId"] as? String,
              let id = UUID(uuidString: rawID), id == latest.id,
              let ref = args["nodeRef"] as? String, Self.isNodeRef(ref)
        else { return nil }
        // Reject an ambiguous projection instead of guessing a node. Labels
        // from other observations or assistant text cannot fill this slot.
        guard !latest.ambiguous.contains(ref), let node = latest.nodes[ref] else { return nil }
        return PhoneObservationEvidence(
            sourceTool: node.sourceTool, observationID: latest.id.uuidString.lowercased(),
            pageSummary: SecretRedactor.redact(node.page, secret: secret), nodeRef: ref,
            nodeSummary: SecretRedactor.redact(node.line, secret: secret)
        )
    }

    private static func isNodeRef(_ ref: String) -> Bool {
        ref.count <= 32 && ref.hasPrefix("n") && ref.count > 1
            && ref.dropFirst().allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}
