// FloeTools — Capability ceiling for the temporary (ephemeral) chat mode.
//
// SPDX-License-Identifier: MPL-2.0
//
// A temporary conversation is casual chat with a narrow, audited READ-ONLY
// ceiling made of exactly two families:
//
//   * the public web trio — public web search (`web.search`, and Bocha's
//     AI-summary `web.searchAI` when its provider is configured) and
//     `web.fetch`. `web.fetch` keeps refusing LAN/diagnostic targets here in
//     addition to the tool's own `publicWebOnly` validation, and professional
//     dataset search stays outside; and
//   * basic on-device reads — the compiled read-only Apple integrations
//     `apple.calendar.list`, `apple.reminders.list`, `apple.maps.search`,
//     `apple.home.list`, `apple.watch.status` and `apple.location.current`.
//     These read live system state only through the system's own existing
//     authorization; they never request new access, never write and never
//     leave the device (maps search asks Apple MapKit for public places).
//
// Everything else stays outside the ceiling even when its ordinary-run
// descriptor is read-only: personal-data history (mail/notes/conversation
// reads), workspace/file reads, device state beyond the six named reads,
// skill/instruction discovery, authenticated remote inspection (SSH/cloud),
// credentials, LAN targets, writes, code execution, installs, VM lifecycle,
// background jobs, delegation, external sends, GUI control and credential
// disclosure.
//
// The authority is a small, audited name allowlist plus the compiled
// descriptor metadata:
//
//   * The name allowlist is authoritative. A read-only private tool cannot
//     enter the ceiling merely because its descriptor is classified
//     `.readOnly`; it must be one of the named tools.
//   * The descriptor is revalidated as a genuine read: `.readOnly` effect,
//     not side-effecting, no host scope, the default `.any` execution
//     boundary, and risk labels inside the family's own set
//     (`{networkAccess}` for the web trio; `{persistsPersonalData,
//     networkAccess}` for the device family — exactly the labels the real
//     compiled handlers carry). A dynamic, stale or forged descriptor that
//     reuses an allowed name with broader capabilities fails closed.
//   * Execution re-checks the descriptor AND the concrete arguments before
//     any effect. `apple.location.current` takes no arguments at all — any
//     field fails closed — while the other device reads validate their own
//     arguments inside the compiled tool. `web.fetch` refuses the
//     LAN/diagnostic opt-in here as well as in the tool's existing
//     `publicWebOnly` target validation.
//
// `readOnlyDescriptor(_:)` returns the model-facing projection (the identical
// descriptor for an admitted tool, nil otherwise); `denialReason(...)` is the
// executor-side decision; `allowedToolNames(from:)` derives the name ceiling
// the runtime enforces at tools.list, main dispatch and child dispatch. The
// caller remains responsible for provider readiness: unconfigured
// `web.search`/`web.searchAI` are removed before the run starts, while
// `web.fetch` needs no provider and always remains available when offered.
// User capability toggles (for example the per-feature Apple switches)
// similarly narrow the OFFERED descriptor set before this policy ever runs.
//
// The legacy `Set<String>` overloads keep the historical two-name public web
// pair byte-compatible for callers that only know names. The descriptor-driven
// API below is the production path used by `ConversationCenter`,
// `AgentRuntime` and `SubagentRunner`; it admits the public web tools plus the
// basic device reads whose compiled implementations are read-only only. Every
// caller gates it on the typed temporary authority, so ordinary sessions and
// ordinary read-only children keep their own catalog semantics.

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

    /// The exact basic on-device reads admitted by the temporary ceiling.
    /// These are the compiled read-only Apple integrations: listing calendar
    /// events and reminders, searching public places with MapKit, listing
    /// authorized Home accessories, reporting Watch companionship and one
    /// current-location fix. The run's offered set (user capability toggles,
    /// task policy, provider ceilings) may remove any of them; nothing here
    /// widens what the app already offers.
    public static let basicDeviceReadToolNames: Set<String> = [
        "apple.calendar.list",
        "apple.reminders.list",
        "apple.maps.search",
        "apple.home.list",
        "apple.watch.status",
        "apple.location.current",
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

    /// True when `name` is one of the basic on-device read tools.
    public static func isBasicDeviceReadTool(_ name: String) -> Bool {
        basicDeviceReadToolNames.contains(name)
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

    /// The only risk labels a temporary public web read may carry. Every
    /// other label — including `readsFiles`, `accessesCredentials` and
    /// `persistsPersonalData` — describes capabilities outside the temporary
    /// public-web ceiling and fails closed even when the descriptor claims a
    /// read-only effect.
    public static let allowedRiskLabels: Set<RiskLabel> = [
        .networkAccess,
    ]

    /// The only risk labels the basic device family may carry, matching the
    /// actual compiled handlers: personal-data listings (calendar, reminders,
    /// Home), the MapKit network query, and the risk-free Watch/location
    /// reads. Anything broader (credentials, writes, remote effects) fails
    /// closed.
    public static let allowedBasicDeviceRiskLabels: Set<RiskLabel> = [
        .persistsPersonalData,
        .networkAccess,
    ]

    /// A descriptor is inside the public web ceiling only when it is one of
    /// the named public web tools AND its compiled metadata still describes
    /// a pure public read. A descriptor with a spoofed name but a broader
    /// effect, host scope or risk label is never offered or executed.
    public static func isReadOnlySafe(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        guard publicWebToolNames.contains(descriptor.name) else { return false }
        guard descriptor.effect == .readOnly, !descriptor.isSideEffecting else { return false }
        guard !descriptor.requiresHostScope else { return false }
        return descriptor.riskLabels.isSubset(of: allowedRiskLabels)
    }

    /// A descriptor is inside the basic device family only when it is one of
    /// the six named reads AND its compiled metadata still describes a pure
    /// on-device read: `.readOnly` effect, not side-effecting, no host scope,
    /// the default `.any` execution boundary (child-only/main-run-only
    /// reshapes never enter), and risk labels inside
    /// `{persistsPersonalData, networkAccess}` only. A dynamic, stale or
    /// forged descriptor reusing one of these names with broader capabilities
    /// fails closed.
    public static func isSafeBasicDeviceDescriptor(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        guard basicDeviceReadToolNames.contains(descriptor.name) else { return false }
        guard descriptor.effect == .readOnly, !descriptor.isSideEffecting else { return false }
        guard !descriptor.requiresHostScope else { return false }
        guard descriptor.executionBoundary == .any else { return false }
        return descriptor.riskLabels.isSubset(of: allowedBasicDeviceRiskLabels)
    }

    /// The model-facing projection of `descriptor` inside the temporary
    /// ceiling, or nil when it is not an admitted tool with genuine read
    /// metadata. Admitted descriptors are returned unchanged, preserving
    /// their exact catalog identity for approval display and execution.
    public static func readOnlyDescriptor(
        _ descriptor: ToolCatalog.Descriptor
    ) -> ToolCatalog.Descriptor? {
        (isReadOnlySafe(descriptor) || isSafeBasicDeviceDescriptor(descriptor))
            ? descriptor
            : nil
    }

    /// The name ceiling derived from the run's actually offered descriptors.
    /// Only the public web search/fetch tools and the basic device reads
    /// survive.
    public static func allowedToolNames(from descriptors: [ToolCatalog.Descriptor]) -> Set<String> {
        Set(descriptors.lazy.compactMap { descriptor in
            readOnlyDescriptor(descriptor) == nil ? nil : descriptor.name
        })
    }

    /// Executor-side decision for one concrete call. Returns nil only when
    /// the descriptor is one of the admitted tools with genuine read metadata
    /// AND the arguments are a JSON object inside that tool's documented
    /// surface (`apple.location.current` additionally takes NO arguments);
    /// any other call fails closed with a model-comprehensible reason.
    public static func denialReason(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data
    ) -> String? {
        if publicWebToolNames.contains(descriptor.name) {
            return publicWebDenial(descriptor: descriptor, arguments: arguments)
        }
        if basicDeviceReadToolNames.contains(descriptor.name) {
            return basicDeviceDenial(descriptor: descriptor, arguments: arguments)
        }
        return "The '\(descriptor.name)' tool is outside the temporary chat's read ceiling (public web search/fetch and basic on-device reads: calendar events, reminders, maps place search, Home accessories, Watch status and the current location)."
    }

    private static func publicWebDenial(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data
    ) -> String? {
        guard isReadOnlySafe(descriptor) else {
            return "The '\(descriptor.name)' descriptor is not a public read-only web tool; the temporary chat refuses it."
        }
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return "The '\(descriptor.name)' call requires a JSON object with public web arguments."
        }
        if descriptor.name == ProfessionalSearchAuthority.unifiedToolName,
           ProfessionalSearchAuthority.requestsProfessionalSource(argumentsJSON: arguments) {
            return "Temporary chats can search public web sources; professional dataset search needs an ordinary conversation with a configured, authorized source."
        }
        if descriptor.name == "web.fetch", object["localNetwork"] as? Bool == true {
            return "Temporary chats can only fetch public web targets; the local-network option is unavailable."
        }
        return nil
    }

    private static func basicDeviceDenial(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data
    ) -> String? {
        guard isSafeBasicDeviceDescriptor(descriptor) else {
            return "The '\(descriptor.name)' descriptor is not a pure on-device read; the temporary chat refuses it."
        }
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return "The '\(descriptor.name)' call requires a JSON object with its documented arguments."
        }
        // `apple.location.current` takes no arguments at all: any field is a
        // spoof attempt at the policy boundary. The other device reads
        // validate their own arguments inside the compiled tool.
        if descriptor.name == "apple.location.current", !object.isEmpty {
            return "apple.location.current takes no arguments; the temporary chat refuses extra fields."
        }
        return nil
    }
}
