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
    static let names: Set<String> = ["browser.click", "browser.clickPoint", "browser.type", "browser.scroll"]

    static func arguments(_ waiting: AgentState.WaitingApproval) -> (BrowserAction, UUID?, String?, String?, String?)? {
        guard names.contains(waiting.toolCall.toolName), case .local = waiting.toolCall.scope,
              let raw = try? JSONSerialization.jsonObject(with: waiting.toolCall.argumentsJSON) as? [String: Any] else { return nil }
        switch waiting.toolCall.toolName {
        case "browser.click":
            guard Set(raw.keys).isSubset(of: ["tabID", "ref", "documentID"]),
                  let a = try? JSONDecoder().decode(G04BrowserClickTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  !a.ref.isEmpty, !a.documentID.isEmpty else { return nil }
            return (.click(.element(ref: a.ref, documentID: a.documentID)), a.tabID, nil, nil, nil)
        case "browser.clickPoint":
            guard Set(raw.keys).isSubset(of: ["tabID", "documentID", "x", "y", "screenshotSHA256", "fallbackReason"]),
                  let a = try? JSONDecoder().decode(G04BrowserClickPointTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  !a.documentID.isEmpty, a.x.isFinite, a.y.isFinite,
                  (0...10_000).contains(a.x), (0...10_000).contains(a.y),
                  a.screenshotSHA256.count == 64, a.screenshotSHA256.allSatisfy(\.isHexDigit),
                  ["noStructuredTarget", "insufficientStructuredInformation"].contains(a.fallbackReason) else { return nil }
            return (.click(.point(x: a.x, y: a.y)), a.tabID, a.screenshotSHA256, a.fallbackReason, a.documentID)
        case "browser.type":
            guard Set(raw.keys).isSubset(of: ["tabID", "ref", "documentID", "text", "submit"]),
                  let a = try? JSONDecoder().decode(G04BrowserTypeTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  !a.ref.isEmpty, !a.documentID.isEmpty, a.text.utf8.count <= 16 * 1024 else { return nil }
            return (.type(.element(ref: a.ref, documentID: a.documentID), text: a.text, submit: a.submit ?? false), a.tabID, nil, nil, nil)
        case "browser.scroll":
            guard Set(raw.keys).isSubset(of: ["tabID", "deltaX", "deltaY"]),
                  let a = try? JSONDecoder().decode(G04BrowserScrollTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  a.deltaY.isFinite, a.deltaX?.isFinite != false,
                  abs(a.deltaY) <= 20_000, abs(a.deltaX ?? 0) <= 20_000 else { return nil }
            return (.scroll(deltaX: a.deltaX ?? 0, deltaY: a.deltaY), a.tabID, nil, nil, nil)
        default: return nil
        }
    }

    static func details(_ proof: BrowserInteractionApprovalProof) -> [String: SettingsDomainV1.JSONValue]? {
        guard ["click", "clickPoint", "type", "scroll"].contains(proof.operation),
              let url = G04BrowserTabApprovalPresentation.displayText(proof.url, maximumBytes: 2_048),
              url == proof.url, !proof.documentID.isEmpty, proof.documentID.utf8.count <= 128 else { return nil }
        func string(_ value: String?) -> SettingsDomainV1.JSONValue { value.map { .string($0) } ?? .null }
        var result: [String: SettingsDomainV1.JSONValue] = ["kind": .string("browserInteraction"), "operation": .string(proof.operation),
                "tabID": .string(proof.tabID.uuidString.lowercased()), "documentID": .string(proof.documentID),
                "url": .string(url), "title": string(proof.title), "ref": string(proof.ref),
                "role": string(proof.role), "label": string(proof.label),
                "textBytes": proof.textBytes.map { .integer(Int64($0)) } ?? .null,
                "submit": proof.submit.map { .boolean($0) } ?? .null,
                "deltaX": proof.deltaX.map { .fractional($0) } ?? .null,
                "deltaY": proof.deltaY.map { .fractional($0) } ?? .null]
        if proof.operation == "clickPoint" {
            guard let visual = proof.visual else { return nil }
            let artifact = visual.artifact
            guard artifact.relativePath == "BrowserArtifacts/\(artifact.id.uuidString).jpg",
                  artifact.mimeType == "image/jpeg", artifact.byteCount > 0, artifact.byteCount <= 8 * 1024 * 1024,
                  artifact.pixelWidth > 0, artifact.pixelHeight > 0,
                  visual.x.isFinite, visual.y.isFinite, visual.x >= 0, visual.y >= 0,
                  visual.x < Double(artifact.pixelWidth), visual.y < Double(artifact.pixelHeight) else { return nil }
            result["evidenceFileName"] = .string("\(artifact.id.uuidString).jpg")
            result["evidenceSHA256"] = .string(artifact.sha256.lowercased())
            result["evidenceByteCount"] = .integer(Int64(artifact.byteCount))
            result["pixelWidth"] = .integer(Int64(artifact.pixelWidth))
            result["pixelHeight"] = .integer(Int64(artifact.pixelHeight))
            result["pointX"] = .fractional(visual.x); result["pointY"] = .fractional(visual.y)
            result["fallbackReason"] = .string(visual.fallbackReason)
        } else if proof.visual != nil { return nil }
        return result
    }
}
