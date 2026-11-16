// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAgentRuntime
import FloeBrowser

/// Private, one-use handoff between the waiting approval and the exact tool
/// dispatch. A proof is never synthesized from model-provided page metadata.
final class G04BrowserTabApprovalGate: @unchecked Sendable {
    static let shared = G04BrowserTabApprovalGate()
    private let lock = NSLock()
    private var pending: [String: BrowserTabApprovalProof] = [:]
    private func key(_ run: UUID, _ call: String, _ grant: UUID) -> String {
        run.uuidString + ":" + grant.uuidString + ":" + call
    }
    func stage(run: UUID, call: String, grant: UUID, proof: BrowserTabApprovalProof) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = key(run, call, grant)
        guard pending.count < 128, pending[k] == nil else { return false }
        pending[k] = proof
        return true
    }
    func take(run: UUID, call: String, grant: UUID) -> BrowserTabApprovalProof? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: key(run, call, grant))
    }
    func discard(run: UUID, call: String, grant: UUID) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: key(run, call, grant))
    }
    func retire(run: UUID) {
        lock.lock(); defer { lock.unlock() }
        let prefix = run.uuidString + ":"
        pending = pending.filter { !$0.key.hasPrefix(prefix) }
    }
}

enum G04BrowserTabApprovalPresentation {
    static func arguments(_ waiting: AgentState.WaitingApproval) -> G04BrowserTabTool.Arguments? {
        guard waiting.toolCall.toolName == "browser.tab", case .local = waiting.toolCall.scope,
              let raw = try? JSONSerialization.jsonObject(with: waiting.toolCall.argumentsJSON) as? [String: Any],
              Set(raw.keys).isSubset(of: ["action", "tabID"]),
              let args = try? JSONDecoder().decode(G04BrowserTabTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
              args.action == "create", args.tabID == nil else { return nil }
        return args
    }
}
