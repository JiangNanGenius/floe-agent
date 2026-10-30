// FloeSecurity — Audited read/draft action semantics for the ordinary
// document/media tools.
//
// The mixed read/write families (`document.office.edit`, `media.project`,
// `cad.document`, `image.svgDocument`) carry ONE mutating descriptor for the
// whole tool, so under the user's default `.ask` policy EVERY action — a pure
// `read`/`query`/`capabilities`/`errors` inspection or a draft-only
// `propose`/`preview` — presented a per-step approval card even though it can
// never write original bytes. The user's policy (2026-10-15) is that ordinary
// document work does not prompt per step; only an action that really rewrites
// user bytes, or an unresolved/unknown one, keeps the existing review.
//
// This table is the compiled, audited answer to "does this exact action write
// anything the user must review?". It is deliberately:
//
// - COMPILED: the role comes from the registered tool plus the action VALUE
//   the tool itself validates and dispatches. A model cannot add
//   `"readOnly":true`/`"safe":true` or any other flag to change it — unknown
//   tools, unknown actions and unlisted values return nil, which keeps the
//   task's existing approval policy (fail closed).
// - NOT a descriptor re-profile: the catalog descriptor (effect, labels,
//   authorization identity) stays exactly as compiled; see
//   `TypedMutationContract` (FloeTools) for the write-target contract that
//   still governs every actual output.
// - NOT a temporary-chat change: `TemporaryChatToolPolicy` (FloeTools) keeps
//   its own public-web name ceiling and descriptor metadata checks. This
//   ordinary-action table follows the audited principle (known values, never
//   model-declared intent) but is consumed only by the approval carve-out.
// - NARROW roles:
//   * `.readOnly`  — no original bytes AND no draft state are written.
//   * `.draftOnly` — writes only internal draft/proposal state; the original
//     bytes are untouched. The draft step itself needs no per-edit card, and
//     the commit that may follow it is classified separately by the
//     write-target contract (repository originals still keep their review on
//     the actual commit).
//
// Audit evidence (frozen checkout d9947b34 plus the approved dirty round):
//
// - `FloeDocuments/OfficeDocumentCommandTool.swift` execute():
//   `capabilities` returns the static engine capability table; `query`
//   returns the engine command catalog (no host call); `read` calls
//   `host.status(documentID:)`; `errors` captures the package snapshot;
//   `preview` loads a stored proposal and returns its expectation list;
//   `propose` calls `host.prepareProposal` + `host.storeProposal` (draft
//   record only). `apply`/`export`/`replaceImage` write and stay typed by
//   the K2 write contract.
// - `FloeWorkbench/MediaProjectTool.swift` execute(): `capabilities`/`read`
//   summarize a host-loaded project; `propose` runs the dry-run gate and
//   stores a revision-bound `MediaProposal` through `host.storeProposal`
//   (internal draft state; the project record is untouched). `apply`/`export`
//   write and stay typed by the K2 write contract.
// - `FloeWorkbench/CadDocumentTool.swift` execute(): `capabilities`, `read`,
//   `query`, `locate`, `measure`, `check`, `status`, `three_d_snapshot` and
//   `three_d_measure` are host read/query calls (the native `read` action is
//   literally the bridge's `snapshot`); `preview` loads a stored proposal;
//   `propose`/`three_d_propose` persist a revision-bound proposal.
//   Known assembly/drawing read payloads (including transient exploded
//   preview/reset) are classified below; persistent service mutations use
//   propose/apply. `cancel`, unknown payloads and writes remain unlisted.
// - `FloeExecution/Compatibility/SVGDocumentTool.swift`: `operation=inspect`
//   reads and reports the SVG source; `operation=edit` writes a new SVG and
//   stays typed by the write contract.
//
// The roles never assert ownership: environment/task ownership, workspace
// path resolution and revision/hash binding remain enforced by the tools and
// their hosts exactly as before. This table only decides whether the
// per-step approval card is pointless.

import Foundation

/// What an audited ordinary-document action can do to the user's bytes.
public enum OrdinaryDocumentActionRole: String, Sendable, Codable, Hashable {
    /// Writes nothing: pure inspection/query of a document, a stored draft or
    /// the tool's own capability surface.
    case readOnly
    /// Writes only internal draft/proposal state; original bytes are
    /// untouched.
    case draftOnly
}

/// Compiled action table for the mixed ordinary document/media tools.
public enum OrdinaryDocumentActionProfile {

    /// Resolves the audited role of one call, or nil when the tool/action is
    /// not an audited ordinary read/draft action (nil keeps the existing
    /// approval policy).
    public static func role(
        forToolName toolName: String,
        argumentsJSON: Data
    ) -> OrdinaryDocumentActionRole? {
        guard let object = try? JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            return nil
        }
        return role(forToolName: toolName, arguments: object)
    }

    public static func role(
        forToolName toolName: String,
        arguments: [String: Any]
    ) -> OrdinaryDocumentActionRole? {
        switch toolName {
        case "document.office.edit":
            return officeActions[actionValue("action", in: arguments) ?? ""]
        case "media.project":
            return mediaProjectActions[actionValue("action", in: arguments) ?? ""]
        case "cad.document":
            let action = actionValue("action", in: arguments) ?? ""
            if action == "material" || action == "parameters" || action == "animation" {
                guard let payload = cadPayload(in: arguments),
                      let operation = payload["action"] as? String else { return nil }
                if action == "animation" {
                    // Timeline reads and a single-frame capture write no
                    // original bytes or draft state. Authored animation edits
                    // and MP4 export stay typed by the write-target contract
                    // (ordinary 3D edits are no-review; external output keeps
                    // its existing boundary).
                    return ["list", "query", "evaluate", "capture"].contains(operation)
                        ? .readOnly : nil
                }
                if action == "parameters" { return operation == "list" ? .readOnly : nil }
                if ["list", "read", "unresolved", "libraryList"].contains(operation) { return .readOnly }
                // Export to the personal library actually writes shared state.
                if operation == "libraryExport", payload["global"] as? Bool != true { return .readOnly }
                return nil
            }
            if action == "three_d_assembly" || action == "three_d_drawing" {
                guard let payload = cadPayload(in: arguments),
                      let raw = (payload["action"] as? String) ?? (payload["op"] as? String) else { return nil }
                let expectedKind = action == "three_d_assembly" ? "assembly" : "drawing"
                let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 1 || (parts.count == 2 && parts[0] == expectedKind) else { return nil }
                let operation = String(parts.last ?? "")
                let reads: Set<String> = action == "three_d_assembly"
                    ? ["report", "instances", "dof", "interference", "reference", "referenceCandidates",
                       "explodedViews", "previewExplodedView", "resetExplodedView"]
                    : ["pages", "project", "dimensions", "export"]
                // Preview/reset affect only display state, not the stored CAD
                // model. Persistent service changes still use propose/apply.
                return reads.contains(operation) ? .readOnly : nil
            }
            return cadDocumentActions[action]
        case "image.svgDocument":
            return actionValue("operation", in: arguments) == "inspect" ? .readOnly : nil
        default:
            return nil
        }
    }

    /// `document.office.edit` (see the audit note above).
    static let officeActions: [String: OrdinaryDocumentActionRole] = [
        "capabilities": .readOnly,
        "query": .readOnly,
        "read": .readOnly,
        "errors": .readOnly,
        "preview": .readOnly,
        "propose": .draftOnly
    ]

    /// `media.project` (see the audit note above).
    static let mediaProjectActions: [String: OrdinaryDocumentActionRole] = [
        "capabilities": .readOnly,
        "read": .readOnly,
        "propose": .draftOnly
    ]

    /// Top-level CAD reads/drafts. Known service payload reads are resolved
    /// separately above; cancel, unknown payloads and writes are unlisted.
    static let cadDocumentActions: [String: OrdinaryDocumentActionRole] = [
        "capabilities": .readOnly,
        "read": .readOnly,
        "query": .readOnly,
        "locate": .readOnly,
        "measure": .readOnly,
        "check": .readOnly,
        "status": .readOnly,
        "three_d_snapshot": .readOnly,
        "three_d_measure": .readOnly,
        "capture": .readOnly,
        "preview": .readOnly,
        "propose": .draftOnly,
        "three_d_propose": .draftOnly
    ]

    /// Exact action value match (same normalization the write-target contract
    /// uses). Values the tools do not dispatch resolve to nil.
    private static func actionValue(_ key: String, in arguments: [String: Any]) -> String? {
        guard let raw = arguments[key] as? String else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func cadPayload(in arguments: [String: Any]) -> [String: Any]? {
        guard let text = arguments["payload"] as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
