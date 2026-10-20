// FloeTools — Capability ceiling for the temporary (ephemeral) chat mode.
//
// SPDX-License-Identifier: MPL-2.0
//
// A temporary conversation is casual chat with a PUBLIC-WEB-ONLY tool
// ceiling: public web search (`web.search`, and Bocha's AI-summary
// `web.searchAI` when its provider is configured) and `web.fetch` are offered
// and executable. Personal-data reads (calendar/reminders/mail/notes/
// conversation history), workspace/file/media reads, device state,
// skill/instruction discovery and authenticated remote inspections stay
// outside the ceiling even when their ordinary-run descriptors are read-only. Writes, code execution, installs, VM lifecycle,
// background jobs, delegation, external sends, GUI control and credential
// disclosure remain outside as before.
//
// The authority is a small, audited name allowlist plus the compiled
// descriptor metadata:
//
//   * The name allowlist is authoritative. A read-only private tool cannot
//     enter the ceiling merely because its descriptor is classified
//     `.readOnly`; it must be one of the public web tools.
//   * The descriptor is revalidated as a genuine public read: `.readOnly`
//     effect, not side-effecting, no host scope, and no risk label other than
//     `networkAccess`. A dynamic, stale or forged descriptor that reuses a
//     public web name with broader capabilities fails closed.
//   * Execution re-checks the descriptor AND the concrete arguments before
//     any effect. `web.fetch` refuses the LAN/diagnostic opt-in here as well
//     as in the tool's existing `publicWebOnly` target validation.
//
// `readOnlyDescriptor(_:)` returns the model-facing projection (the identical
// descriptor for a public web tool, nil otherwise); `denialReason(...)` is the
// executor-side decision; `allowedToolNames(from:)` derives the name ceiling
// the runtime enforces at tools.list, main dispatch and child dispatch. The
// caller remains responsible for provider readiness: unconfigured
// `web.search`/`web.searchAI` are removed before the run starts, while
// `web.fetch` needs no provider and always remains available when offered.
//
// The legacy `Set<String>` overloads keep the historical two-name public web
// pair byte-compatible for callers that only know names. The descriptor-driven
// API below is the production path used by `ConversationCenter`,
// `AgentRuntime` and `SubagentRunner`; it admits the three public web tools
// whose compiled implementations are public search/fetch only. Every caller
// gates it on the typed temporary authority, so ordinary sessions and ordinary
// read-only children keep their own catalog semantics.

import Foundation

/// Builds the exact tool-name ceiling for a temporary chat run.
public enum TemporaryChatToolPolicy {

    // MARK: - Name allowlist

    /// The historical two-name public web pair, retained for the legacy
    /// name-only API. Production descriptor composition uses
    /// `publicWebToolNames` below.
    public static let nativeToolNames: Set<String> = [
        "web.search",
        "web.fetch",
    ]

    /// The exact public web tools admitted by the descriptor-driven temporary
    /// ceiling. `web.search` and `web.searchAI` additionally require their
    /// configured search provider (checked by the caller, which owns the
    /// settings store); `web.fetch` always passes and keeps the existing
    /// approval/SSRF/redirect/public-target guards.
    public static let publicWebToolNames: Set<String> = [
        "web.search",
        "web.searchAI",
        "web.fetch",
    ]

    /// The exact name ceiling: only names that exist in the run's offered
    /// descriptor set AND are in the public web pair. Intersecting with the
    /// offered set keeps the ceiling truthful when a tool is not installed.
    public static func allowedToolNames(from offered: Set<String>) -> Set<String> {
        nativeToolNames.intersection(offered)
    }

    /// True when `name` is part of the historical two-name public web pair.
    public static func isTemporaryChatTool(_ name: String) -> Bool {
        nativeToolNames.contains(name)
    }

    /// True when `name` is one of the three descriptor-driven public web tools.
    public static func isPublicWebTool(_ name: String) -> Bool {
        publicWebToolNames.contains(name)
    }

    // MARK: - Descriptor-driven public web ceiling

    /// Provider-backed public search tools inside the descriptor ceiling.
    /// Their compiled handlers exist, but they return nothing without a ready,
    /// credential-complete provider, so the caller removes the ones the
    /// settings store reports unavailable — an unconfigured service must never
    /// be advertised to the model.
    public static let providerBackedWebSearchToolNames: Set<String> = [
        "web.search",
        "web.searchAI",
    ]

    /// The only risk label a public web read may carry. Every other label —
    /// including `readsFiles`, `accessesCredentials` and
    /// `persistsPersonalData` — describes capabilities outside the temporary
    /// public-web ceiling and fails closed even when the descriptor claims a
    /// read-only effect.
    public static let allowedRiskLabels: Set<RiskLabel> = [
        .networkAccess,
    ]

    /// A descriptor is inside the temporary ceiling only when it is one of
    /// the named public web tools AND its compiled metadata still describes
    /// a pure public read. A descriptor with a spoofed name but a broader
    /// effect, host scope or risk label is never offered or executed.
    public static func isReadOnlySafe(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        guard publicWebToolNames.contains(descriptor.name) else { return false }
        guard descriptor.effect == .readOnly, !descriptor.isSideEffecting else { return false }
        guard !descriptor.requiresHostScope else { return false }
        return descriptor.riskLabels.isSubset(of: allowedRiskLabels)
    }

    /// The model-facing projection of `descriptor` inside the temporary
    /// ceiling, or nil when it is not a public web tool with public read
    /// metadata. Public web descriptors are returned unchanged, preserving
    /// their exact catalog identity for approval display and execution.
    public static func readOnlyDescriptor(
        _ descriptor: ToolCatalog.Descriptor
    ) -> ToolCatalog.Descriptor? {
        isReadOnlySafe(descriptor) ? descriptor : nil
    }

    /// The name ceiling derived from the run's actually offered descriptors.
    /// Only the public web search/fetch tools survive.
    public static func allowedToolNames(from descriptors: [ToolCatalog.Descriptor]) -> Set<String> {
        Set(descriptors.lazy.compactMap { descriptor in
            readOnlyDescriptor(descriptor) == nil ? nil : descriptor.name
        })
    }

    /// Executor-side decision for one concrete call. Returns nil only when
    /// the descriptor is one of the public web tools with public read
    /// metadata AND the arguments are a JSON object inside the temporary
    /// public-web surface; any other call fails closed with a
    /// model-comprehensible reason.
    public static func denialReason(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data
    ) -> String? {
        guard publicWebToolNames.contains(descriptor.name) else {
            return "The '\(descriptor.name)' tool is outside the temporary chat's public-web-only ceiling."
        }
        guard isReadOnlySafe(descriptor) else {
            return "The '\(descriptor.name)' descriptor is not a public read-only web tool; the temporary chat refuses it."
        }
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return "The '\(descriptor.name)' call requires a JSON object with public web arguments."
        }
        if descriptor.name == "web.fetch", object["localNetwork"] as? Bool == true {
            return "Temporary chats can only fetch public web targets; the local-network option is unavailable."
        }
        return nil
    }
}
