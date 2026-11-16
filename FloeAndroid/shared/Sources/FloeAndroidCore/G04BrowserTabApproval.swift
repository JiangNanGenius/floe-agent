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
    /// The complete reviewed-action grammar. Anything else fails closed
    /// before a session or a page can supply an identity.
    static let operations: Set<String> = ["create", "activate", "close"]

    static func arguments(_ waiting: AgentState.WaitingApproval) -> G04BrowserTabTool.Arguments? {
        guard waiting.toolCall.toolName == "browser.tab", case .local = waiting.toolCall.scope,
              let raw = try? JSONSerialization.jsonObject(with: waiting.toolCall.argumentsJSON) as? [String: Any],
              Set(raw.keys).isSubset(of: ["action", "tabID"]),
              let args = try? JSONDecoder().decode(G04BrowserTabTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
              operations.contains(args.action),
              (args.action == "create") == (args.tabID == nil) else { return nil }
        return args
    }

    /// Complete projection of the exact reviewed action.
    ///
    /// `create` keeps the original four-key shape (`url`/`title` null).
    /// `activate`/`close` add the exact native tab UUID, its one-based position
    /// in the reviewed ordered tab set, and the tab's surfaced URL/title.
    /// The target is the native tab/document identity in
    /// the proof; the text is never accepted from model arguments or page
    /// JavaScript, and any change to the reviewed snapshot invalidates the
    /// approval instead of retargeting it.
    static func details(for args: G04BrowserTabTool.Arguments,
                        proof: BrowserTabApprovalProof) -> [String: SettingsDomainV1.JSONValue]? {
        guard proof.operation == args.action, proof.tabID == args.tabID else { return nil }
        switch args.action {
        case "create":
            guard proof.tabID == nil, proof.documentID == nil, proof.navigationRevision == nil,
                  proof.url == nil, proof.title == nil else { return nil }
            return ["kind": .string("browserTab"), "operation": .string("create"),
                    "url": .null, "title": .null]
        case "activate", "close":
            guard let tabID = proof.tabID, proof.documentID?.isEmpty == false,
                  proof.navigationRevision != nil, proof.tabCount > 1,
                  proof.tabCount == proof.tabIDs.count, proof.tabCount <= proof.maximumTabs,
                  Set(proof.tabIDs).count == proof.tabCount,
                  let index = proof.tabIDs.firstIndex(of: tabID) else { return nil }
            return ["kind": .string("browserTab"), "operation": .string(args.action),
                    "tabID": .string(tabID.uuidString.lowercased()),
                    "tabIndex": .integer(Int64(index + 1)), "tabCount": .integer(Int64(proof.tabCount)),
                    "url": proof.url.flatMap { displayText($0, maximumBytes: 2_048) }.map { .string($0) } ?? .null,
                    "title": proof.title.flatMap { displayText($0, maximumBytes: 512) }.map { .string($0) } ?? .null]
        default:
            return nil
        }
    }

    /// Page-controlled display text is bounded and stripped of control,
    /// format (including bidi overrides), line/paragraph separator, surrogate
    /// and unassigned scalars before it ever reaches an approval card.
    static func displayText(_ value: String, maximumBytes: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maximumBytes > 0 else { return nil }
        guard trimmed.utf8.count > maximumBytes else { return trimmed }
        var result = ""
        for character in trimmed {
            guard result.utf8.count + character.utf8.count <= maximumBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }
}
