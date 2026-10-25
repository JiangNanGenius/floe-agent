// FloeTools — Capability ceiling for the fast conversation (.chat) mode.
//
// SPDX-License-Identifier: MPL-2.0
//
// A fast chat run is an ordinary (non-temporary) conversation upgraded from
// "no tools" to a narrow, audited two-family ceiling:
//
//   * the public web trio (`web.search`, `web.searchAI`, `web.fetch`) — the
//     SAME descriptor-validated public-web reads the temporary ceiling uses,
//     with the same argument checks (web.fetch keeps refusing LAN/diagnostic
//     targets); and
//   * reads of THIS conversation's associated files only: text reads, OCR
//     and document inspection over the exact workspace-relative paths the
//     app staged from real attachment records (`Attachments/<attachment-id>/…`).
//
// Everything else stays outside: shell/code/install/VM/environment
// execution, workspace mutation and unrestricted workspace discovery
// (`workspace.listDirectory`/`searchFiles` are NOT in the ceiling), browser
// and VNC automation, background jobs and subagent delegation, arbitrary
// notes/contacts/calendar/mail/reminders access, memory and conversation
// history reads, skill discovery, credential handling, remote SSH/serial,
// network scanning and raw HTTP, media generation or editing, canvas/CAD and
// design mutations. Unsupported read attempts fail closed with an
// actionable reason.
//
// The authority is a name allowlist plus compiled descriptor metadata, never
// prompt text:
//
//   * The name allowlist is authoritative. A read-only private tool cannot
//     enter the ceiling merely because its descriptor is `.readOnly`; it must
//     be one of the named families AND, for file reads, resolve to a frozen
//     associated-resource path.
//   * The descriptor is revalidated at execution against the REAL catalog
//     metadata: read-only effect, not side-effecting, no host scope, and no
//     risk label beyond the family's own set. A dynamic, stale or forged
//     descriptor reusing an allowed name fails closed.
//   * Multi-action calls fail closed: any `action` argument is rejected
//     unless the tool declares an explicit read-action entry (none of the
//     current ceiling tools does), and a `scope` argument is always rejected.
//   * The associated-resource proof is the frozen `ResourceContext` the app
//     built from durable attachment records BEFORE the run started. The
//     model can only address paths inside that set — an unbound path, a
//     traversal, an absolute path or a different conversation's file is a
//     denial, not a guard bypass.
//
// Aliases, `tools.search` schema loads and batch/child wrappers cannot widen
// the ceiling: the canonical dispatcher re-checks every concrete call
// against the frozen catalog identity plus this policy before any effect,
// exactly like the temporary ceiling. Callers own provider readiness —
// unconfigured `web.search`/`web.searchAI` are removed before the run
// starts, while `web.fetch` never needs a provider.
//
// Temporary (ephemeral) sessions do NOT use this policy: their stricter
// public-web-only `TemporaryChatToolPolicy` ceiling stays authoritative and
// never gains file access. A run that is both chat-mode and temporary keeps
// the temporary ceiling; the chat mode only changes reasoning and prompt.

import Foundation

/// Builds and enforces the exact tool ceiling for one fast chat run.
public enum ChatToolPolicy {

    // MARK: - Associated-resource proof

    /// Frozen read authority for ONE run: the conversation's attachment
    /// paths, normalized to the exact workspace-relative form the intake
    /// uses (`Attachments/<attachment-id>/<basename>`). Set by the app from
    /// durable attachment records plus this round's staged copies; never
    /// model-minted and never widened mid-run.
    public struct ResourceContext: Sendable, Hashable {
        public var conversationID: UUID
        /// Normalized exact paths. Matching is per-component equality after
        /// normalization; there is no prefix, glob or directory read.
        public var boundRelativePaths: Set<String>

        public init(conversationID: UUID, boundRelativePaths: [String]) {
            self.conversationID = conversationID
            self.boundRelativePaths = Set(boundRelativePaths.compactMap(Self.normalize))
        }

        /// True when `rawPath` resolves to one of the bound files.
        public func contains(_ rawPath: String) -> Bool {
            guard let normalized = Self.normalize(rawPath) else { return false }
            return boundRelativePaths.contains(normalized)
        }

        public var isEmpty: Bool { boundRelativePaths.isEmpty }

        /// Deterministic workspace-relative normalization. Rejects absolute
        /// paths, `~` paths and any `..` component instead of "cleaning"
        /// them into a silent containment bypass; collapses `.` and empty
        /// segments. Returns nil for anything that cannot resolve inside
        /// the root.
        public static func normalize(_ rawPath: String) -> String? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
                return nil
            }
            let components = trimmed
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty, !components.contains("..") else { return nil }
            let kept = components.filter { $0 != "." }
            guard !kept.isEmpty else { return nil }
            return kept.joined(separator: "/")
        }
    }

    // MARK: - Name allowlists

    /// The public web tools, shared with the temporary ceiling so both lanes
    /// admit exactly the same audited names.
    public static var publicWebToolNames: Set<String> {
        TemporaryChatToolPolicy.publicWebToolNames
    }

    /// Deterministic read-only file/document tools that may serve a BOUND
    /// attachment path. Admission is name + metadata + resource proof at
    /// execution; unrestricted workspace discovery tools
    /// (`workspace.listDirectory`, `workspace.searchFiles`) and every
    /// mutating workspace tool stay outside on purpose.
    public static let boundFileReadToolNames: Set<String> = [
        "workspace.readFile",
        "workspace.inspectFileMetadata",
        "image.ocr",
        "document.pdf.inspect",
        "document.readSheet",
        "document.office.inspect",
    ]

    /// The only risk labels the web family may carry (public reads).
    public static let allowedWebRiskLabels: Set<RiskLabel> = [.networkAccess]

    /// The only risk labels the bound-file family may carry (local reads).
    public static let allowedFileReadRiskLabels: Set<RiskLabel> = [.readsFiles]

    public static func isPublicWebTool(_ name: String) -> Bool {
        publicWebToolNames.contains(name)
    }

    public static func isBoundFileReadTool(_ name: String) -> Bool {
        boundFileReadToolNames.contains(name)
    }

    /// Executable-tool admission only. tools.search/tools.list/tools.readResult are handled
    /// separately by the main runtime over this run's already-filtered
    /// catalog; admitting those metadata helpers here would also authorize
    /// executor/child dispatch, which is deliberately not part of chat.
    public static func isAllowedName(_ name: String) -> Bool {
        isPublicWebTool(name) || isBoundFileReadTool(name)
    }

    // MARK: - Descriptor revalidation

    /// True when `descriptor` is one of the named public web tools AND its
    /// compiled metadata still describes a pure public read (the identical
    /// check the temporary ceiling applies).
    public static func isSafeWebDescriptor(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        guard isPublicWebTool(descriptor.name) else { return false }
        return TemporaryChatToolPolicy.isReadOnlySafe(descriptor)
    }

    /// True when `descriptor` is one of the named file/document read tools
    /// AND its compiled metadata still describes a pure local read: exact
    /// allowlisted name, `.readOnly` effect, not side-effecting, no host
    /// scope, risk labels inside `{readsFiles}` only, and not a child-only
    /// boundary tool. A dynamic/MCP-shaped descriptor reusing one of these
    /// names with broader metadata fails closed.
    public static func isSafeBoundFileReadDescriptor(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        guard isBoundFileReadTool(descriptor.name) else { return false }
        guard descriptor.effect == .readOnly, !descriptor.isSideEffecting else { return false }
        guard !descriptor.requiresHostScope else { return false }
        guard descriptor.riskLabels.isSubset(of: allowedFileReadRiskLabels) else { return false }
        guard descriptor.executionBoundary == .any else { return false }
        return true
    }

    /// Name + metadata admission without the per-run resource context.
    public static func isSafeDescriptor(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        isSafeWebDescriptor(descriptor) || isSafeBoundFileReadDescriptor(descriptor)
    }

    /// The model-facing projection for the offered catalog. Public web
    /// descriptors pass unchanged; bound file reads pass only when the run
    /// actually has associated resources to read (a chat with no files must
    /// not advertise file reading at all).
    public static func offeredDescriptor(
        _ descriptor: ToolCatalog.Descriptor,
        hasResourceContext: Bool
    ) -> ToolCatalog.Descriptor? {
        if isSafeWebDescriptor(descriptor) { return descriptor }
        guard hasResourceContext, isSafeBoundFileReadDescriptor(descriptor) else { return nil }
        return descriptor
    }

    /// The name ceiling derived from the run's actually offered descriptors.
    public static func allowedToolNames(
        from descriptors: [ToolCatalog.Descriptor],
        hasResourceContext: Bool
    ) -> Set<String> {
        Set(descriptors.lazy.compactMap { descriptor in
            offeredDescriptor(descriptor, hasResourceContext: hasResourceContext) == nil
                ? nil : descriptor.name
        })
    }

    // MARK: - Explicit read-action contract (multi-action tools)

    /// Read actions that a multi-action ceiling tool may expose. The current
    /// allowlist contains no multi-action tool, so this map is EMPTY and any
    /// concrete `action` argument fails closed. A future entry must name a
    /// GENUINE read action (decided from the raw arguments at dispatch) —
    /// never a family prefix, and never an action with side effects.
    public static let readActionsByTool: [String: Set<String>] = [:]

    // MARK: - Executor-side decision

    /// Canonical execution-time decision for one concrete call. Returns nil
    /// only when the descriptor AND the arguments AND the frozen resource
    /// context prove this is an allowed public-web read or a bound-file read.
    /// Every other case fails closed with a model-comprehensible, actionable
    /// reason.
    public static func denialReason(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data,
        resourceContext: ResourceContext?
    ) -> String? {
        if isPublicWebTool(descriptor.name) {
            return webDenial(descriptor: descriptor, arguments: arguments)
        }
        if isBoundFileReadTool(descriptor.name) {
            return boundFileDenial(
                descriptor: descriptor,
                arguments: arguments,
                resourceContext: resourceContext
            )
        }
        return "The '\(descriptor.name)' tool is outside the fast chat's ceiling (public web search/fetch and this conversation's attached files only). \(ceilingHint(hasResourceContext: resourceContext != nil && !(resourceContext?.isEmpty ?? true)))"
    }

    private static func webDenial(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data
    ) -> String? {
        guard isSafeWebDescriptor(descriptor) else {
            return "The '\(descriptor.name)' descriptor is not a public read-only web tool; fast chat refuses it."
        }
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return "The '\(descriptor.name)' call requires a JSON object with public web arguments."
        }
        if descriptor.name == ProfessionalSearchAuthority.unifiedToolName,
           ProfessionalSearchAuthority.requestsProfessionalSource(argumentsJSON: arguments) {
            return "Fast chats allow public web search only; professional dataset search requires an ordinary agent run."
        }
        if descriptor.name == "web.fetch", object["localNetwork"] as? Bool == true {
            return "Fast chats can only fetch public web targets; the local-network option is unavailable."
        }
        return nil
    }

    private static func boundFileDenial(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data,
        resourceContext: ResourceContext?
    ) -> String? {
        guard isSafeBoundFileReadDescriptor(descriptor) else {
            return "The '\(descriptor.name)' descriptor is not a pure local read tool; fast chat refuses it."
        }
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return "The '\(descriptor.name)' call requires a JSON object with an attached-file target."
        }
        // Multi-action and scope-carrying calls fail closed unless the tool
        // explicitly declares a read action. A `scope` argument (host
        // targeting) is never part of this ceiling.
        if object.keys.contains("scope"), object["scope"] != nil {
            return "Fast chat reads apply to this device's conversation files only; remote host scope is unavailable."
        }
        if let action = object["action"] as? String {
            guard let allowed = readActionsByTool[descriptor.name],
                  allowed.contains(action) else {
                return "'\(descriptor.name)' action '\(action)' is not a read action inside the fast chat ceiling."
            }
        } else if object.keys.contains("action") {
            return "'\(descriptor.name)' requires an explicit read action string; fast chat refuses mixed-action calls without one."
        }
        let hasBoundContext = !(resourceContext == nil || resourceContext?.isEmpty ?? true)
        guard hasBoundContext else {
            return "This chat has no attached files to read yet. Attach a file to this conversation, or answer with public web search/fetch."
        }
        // `image.ocr` may also run on inline base64 bytes — that path reads
        // NO files and is content the model already holds, so it stays a
        // pure read; every other tool requires a bound path argument.
        if descriptor.name == "image.ocr",
           object["path"] == nil,
           let inline = object["imageBase64"] as? String,
           !inline.isEmpty {
            return nil
        }
        guard let rawPath = object["path"] as? String,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The '\(descriptor.name)' call must pass the exact workspace-relative path of one of this chat's attached files."
        }
        guard ResourceContext.normalize(rawPath) != nil else {
            return "'\(rawPath)' is not a workspace-relative attachment path. Use the exact path listed for the attached file (Attachments/<id>/<name>)."
        }
        guard resourceContext?.contains(rawPath) == true else {
            return "'\(rawPath)' is not attached to this conversation. Fast chat can only read the files attached here; attach it or use the workspace task mode for project files."
        }
        return nil
    }

    private static func ceilingHint(hasResourceContext: Bool) -> String {
        hasResourceContext
            ? "Allowed here: web.search, web.searchAI, web.fetch, and reading/OCR/inspection of this conversation's attached files."
            : "Allowed here: web.search, web.searchAI and web.fetch (this chat has no attached files yet)."
    }
}
