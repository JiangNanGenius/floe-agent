// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAgentRuntime
import FloeBrowser

/// One-use, in-memory handoff; input text itself is never stored here.
final class G04BrowserInteractionApprovalGate: @unchecked Sendable {
    static let shared = G04BrowserInteractionApprovalGate()
    private let lock = NSLock()
    private var pending: [String: BrowserInteractionApprovalProof] = [:]
    private func key(_ run: UUID, _ call: String, _ grant: UUID) -> String {
        run.uuidString + ":" + grant.uuidString + ":" + call
    }
    func stage(run: UUID, call: String, grant: UUID, proof: BrowserInteractionApprovalProof) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = key(run, call, grant)
        guard pending.count < 128, pending[k] == nil else { return false }
        pending[k] = proof; return true
    }
    func take(run: UUID, call: String, grant: UUID) -> BrowserInteractionApprovalProof? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: key(run, call, grant))
    }
    func discard(run: UUID, call: String, grant: UUID) {
        lock.lock(); defer { lock.unlock() }; pending.removeValue(forKey: key(run, call, grant))
    }
    func retire(run: UUID) {
        lock.lock(); defer { lock.unlock() }
        pending = pending.filter { !$0.key.hasPrefix(run.uuidString + ":") }
    }
}

enum G04BrowserInteractionApprovalPresentation {
    static let names: Set<String> = ["browser.click", "browser.type", "browser.scroll"]

    static func arguments(_ waiting: AgentState.WaitingApproval) -> (BrowserAction, UUID?)? {
        guard names.contains(waiting.toolCall.toolName), case .local = waiting.toolCall.scope,
              let raw = try? JSONSerialization.jsonObject(with: waiting.toolCall.argumentsJSON) as? [String: Any] else { return nil }
        switch waiting.toolCall.toolName {
        case "browser.click":
            guard Set(raw.keys).isSubset(of: ["tabID", "ref", "documentID"]),
                  let a = try? JSONDecoder().decode(G04BrowserClickTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  !a.ref.isEmpty, !a.documentID.isEmpty else { return nil }
            return (.click(.element(ref: a.ref, documentID: a.documentID)), a.tabID)
        case "browser.type":
            guard Set(raw.keys).isSubset(of: ["tabID", "ref", "documentID", "text", "submit"]),
                  let a = try? JSONDecoder().decode(G04BrowserTypeTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  !a.ref.isEmpty, !a.documentID.isEmpty, a.text.utf8.count <= 16 * 1024 else { return nil }
            return (.type(.element(ref: a.ref, documentID: a.documentID), text: a.text, submit: a.submit ?? false), a.tabID)
        case "browser.scroll":
            guard Set(raw.keys).isSubset(of: ["tabID", "deltaX", "deltaY"]),
                  let a = try? JSONDecoder().decode(G04BrowserScrollTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  a.deltaY.isFinite, a.deltaX?.isFinite != false,
                  abs(a.deltaY) <= 20_000, abs(a.deltaX ?? 0) <= 20_000 else { return nil }
            return (.scroll(deltaX: a.deltaX ?? 0, deltaY: a.deltaY), a.tabID)
        default: return nil
        }
    }

    static func details(_ proof: BrowserInteractionApprovalProof) -> [String: SettingsDomainV1.JSONValue]? {
        guard ["click", "type", "scroll"].contains(proof.operation),
              let url = G04BrowserTabApprovalPresentation.displayText(proof.url, maximumBytes: 2_048),
              url == proof.url, !proof.documentID.isEmpty, proof.documentID.utf8.count <= 128 else { return nil }
        func string(_ value: String?) -> SettingsDomainV1.JSONValue { value.map { .string($0) } ?? .null }
        return ["kind": .string("browserInteraction"), "operation": .string(proof.operation),
                "tabID": .string(proof.tabID.uuidString.lowercased()), "documentID": .string(proof.documentID),
                "url": .string(url), "title": string(proof.title), "ref": string(proof.ref),
                "role": string(proof.role), "label": string(proof.label),
                "textBytes": proof.textBytes.map { .integer(Int64($0)) } ?? .null,
                "submit": proof.submit.map { .boolean($0) } ?? .null,
                "deltaX": proof.deltaX.map { .fractional($0) } ?? .null,
                "deltaY": proof.deltaY.map { .fractional($0) } ?? .null]
    }
}
