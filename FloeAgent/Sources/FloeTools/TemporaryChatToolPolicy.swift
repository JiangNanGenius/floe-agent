// FloeTools — Capability ceiling for the temporary (ephemeral) chat mode.
//
// SPDX-License-Identifier: MPL-2.0
//
// A temporary conversation is casual chat with a READ-ONLY ceiling: every
// currently authorized tool that is verified to be a safe read stays
// available — public web retrieval, personal-data queries
// (calendar/reminders/mail/notes/conversation history), device queries,
// tool/skill discovery and remote inspections that authenticate with the
// user's own stored credentials — while writes, code execution, installs, VM
// lifecycle, background jobs, delegation, external sends, GUI control and
// credential disclosure stay out.
//
// The authority is the compiled descriptor metadata (`ToolEffect`,
// `RiskLabel`, `isSideEffecting`) plus two small, audited tables:
//
//   * `verifiedActionPolicies` — mixed read/write tools that DO carry a
//     genuine read action. Only the listed action values are inside the
//     ceiling; discovery receives a schema narrowed to exactly those values
//     and the executor re-checks the raw argument before any effect. This is
//     deliberately not derived from remote annotations: a descriptor is
//     admitted only after its implementation was read.
//   * `verifiedExclusions` — read-only-looking tools that are nonetheless
//     unsafe or unusable in a temporary run, each with the exact verified
//     reason. No prefix-wide family bans: `git`/`ssh`/`cloudWorkspace`/
//     `network`/`design`/`remoteHosting` inspections stay available unless a
//     concrete tool is listed here.
//
// `readOnlyDescriptor(_:)` returns the model-facing projection (same
// descriptor for pure reads, narrowed schema copy for mixed actions, nil when
// nothing safe exists); `denialReason(descriptor:arguments:)` is the
// executor-side decision; `allowedToolNames(from:)` derives the name ceiling
// the runtime enforces at tools.list, main dispatch and child dispatch.
// MCP/dynamic runners register conservative `mutating` descriptors, so an
// untrusted remote "readOnlyHint" can never widen this ceiling; a *trusted,
// configured* remote read keeps its ordinary catalog treatment.
//
// The legacy `Set<String>` overloads are kept byte-compatible for callers
// that only know names (the pre-descriptor web pair); new production callers
// must use the descriptor-driven API.

import Foundation

/// Builds the exact tool-name ceiling for a temporary chat run.
public enum TemporaryChatToolPolicy {

    // MARK: - Legacy name-only API (kept for compatibility)

    /// Read-only public web retrieval. `web.search` additionally requires an
    /// already-configured search provider (checked by the caller, which owns
    /// the settings store); `web.fetch` always passes and keeps the existing
    /// approval/SSRF/redirect guards.
    public static let nativeToolNames: Set<String> = [
        "web.search",
        "web.fetch",
    ]

    /// The effective ceiling: only names that exist in the run's offered
    /// descriptor set AND are in the temporary policy. Intersecting with the
    /// offered set keeps the ceiling truthful when a tool is not installed.
    ///
    /// - Note: legacy, name-only overload. Production callers derive the
    ///   ceiling from descriptors (`allowedToolNames(from:)`), which carries
    ///   the verified read capability of every compiled tool. This overload
    ///   cannot classify unknown names and therefore stays at the historical
    ///   public web pair.
    public static func allowedToolNames(from offered: Set<String>) -> Set<String> {
        nativeToolNames.intersection(offered)
    }

    /// True when `name` is part of the legacy temporary web pair.
    public static func isTemporaryChatTool(_ name: String) -> Bool {
        nativeToolNames.contains(name)
    }

    // MARK: - Descriptor-driven read-only ceiling

    /// Provider-backed search tools. Their compiled handler exists, but they
    /// return nothing without a ready, credential-complete provider, so the
    /// caller removes the ones the settings store reports unavailable —
    /// unconfigured services must never be advertised to the model.
    public static let providerBackedWebSearchToolNames: Set<String> = [
        "web.search",
        "web.searchAI",
    ]

    /// Risk labels incompatible with a temporary read-only ceiling even when
    /// a descriptor claims `.readOnly`. `readsFiles`, `networkAccess`,
    /// `accessesCredentials` and `persistsPersonalData` stay allowed: they
    /// describe reads of the user's own data or authenticated reads that
    /// never expose or capture key material.
    public static let forbiddenRiskLabels: Set<RiskLabel> = [
        .writesFiles,
        .deletesFiles,
        .executesLocalCode,
        .executesRemoteCommand,
        .modifiesRemoteSystem,
        .controlsGUI,
        .changesAgentBehavior,
        .sendsDataToProvider,
    ]

    /// Verified mixed read/write tools: the base descriptor may be
    /// `.mutating`, but the listed action values are genuine reads whose
    /// implementation was audited. Discovery narrows the schema to these
    /// values and the canonical dispatcher re-checks the raw argument via
    /// `denialReason(descriptor:arguments:)` before any effect — a call with
    /// any other action fails closed.
    public static let verifiedActionPolicies: [String: Set<String>] = [
        // Folders/list/message all fetch with BODY.PEEK semantics; no action
        // marks a message seen, and the listing/search actions never mutate.
        "mail.read": ["folders", "list", "message"],
        // Read-only actions of the media model manager: `list`/`status` only
        // inspect the catalog; `install`/`remove` download or delete models
        // and stay refused by the dispatch-side action check.
        "media.models": ["list", "status"],
        // `plan`/`list` compute a plan or enumerate shares without touching
        // the paired host; `publish`/`stop` mutate the remote system and stay
        // refused by the dispatch-side action check.
        "remoteHosting.manage": ["plan", "list"],
        // `listKeys` reads key NAMES only; generate/delete/encrypt/decrypt/
        // sign/verify can mutate the Keychain or produce output files and
        // stay refused by the dispatch-side action check.
        "crypto.cipher": ["listKeys"],
    ]

    /// Read-only-looking tools that are nonetheless outside a temporary run,
    /// with the exact reason. Audited against the compiled implementations —
    /// never a prefix/family guess.
    public static let verifiedExclusions: [String: String] = [
        // Execute code despite read-only metadata.
        "exec.javascript": "executes JavaScript.",
        "exec.wasm": "executes WebAssembly.",
        // Shared surface mutation (creates/navigates the task's browser).
        "browser.navigate": "navigates (or creates) this task's browser session, changing shared surface state.",
        // Task-workspace reads that fall back to the UI's global workspace
        // root when the run has none: a temporary run must never read
        // another open task's repository or documents.
        "git.status": "task-workspace read; falls back to the UI-global workspace without a task root.",
        "git.diff": "task-workspace read; falls back to the UI-global workspace without a task root.",
        "git.log": "task-workspace read; falls back to the UI-global workspace without a task root.",
        "document.readSheet": "task-workspace read; falls back to the UI-global workspace without a task root.",
        "document.office.inspect": "task-workspace read; falls back to the UI-global workspace without a task root.",
        // Workspace-path reads that require the run's OWN task workspace
        // (a temporary run owns none, so they can never resolve a file).
        "document.pdf.inspect": "requires the run's task workspace.",
        "audio.inspect": "requires the run's task workspace.",
        "video.inspect": "requires the run's task workspace.",
        "image.ocr": "requires the run's task workspace.",
        "image.barcode.scan": "requires the run's task workspace.",
        // Canvas reads are bound to a canvas run (canvas id + live run→canvas
        // authority) that a temporary chat never owns; `runService` already
        // offers canvas tools to canvas runs only.
        "canvas.getState": "requires a canvas binding; canvas surface tools are only offered to canvas runs.",
        "canvas.assetSearch": "requires a canvas binding; canvas surface tools are only offered to canvas runs.",
        "canvas.designCapabilities": "requires a canvas binding; canvas surface tools are only offered to canvas runs.",
        "canvas.designGetState": "requires a canvas binding; canvas surface tools are only offered to canvas runs.",
        "canvas.designGetProjectSpec": "requires a canvas binding; canvas surface tools are only offered to canvas runs.",
        "canvas.generationStatus": "requires a canvas binding; canvas surface tools are only offered to canvas runs.",
        // Preview tools control the user's preview panel/server (start and
        // reload carry the controlsGUI label; stop is labelled empty).
        "preview.start": "controls the user's local preview server/panel.",
        "preview.reload": "controls the user's local preview server/panel.",
        "preview.stop": "controls the user's local preview server/panel.",
        // Background-jobs surface is explicitly outside the temporary-chat
        // contract ("no ... jobs"): creating one is mutating anyway, and
        // reading one from a casual chat would expose background execution.
        "jobs.status": "background-jobs surface is outside the temporary chat contract.",
        "jobs.result": "background-jobs surface is outside the temporary chat contract.",
    ]

    /// A descriptor is a safe temporary read when it is a pure read inside
    /// the label rules, or a verified mixed tool whose action policy is the
    /// authority, and it is not in the audited exclusion table.
    public static func isReadOnlySafe(_ descriptor: ToolCatalog.Descriptor) -> Bool {
        guard verifiedExclusions[descriptor.name] == nil else { return false }
        if verifiedActionPolicies[descriptor.name] != nil { return true }
        guard descriptor.effect == .readOnly, !descriptor.isSideEffecting else { return false }
        guard descriptor.riskLabels.isDisjoint(with: forbiddenRiskLabels) else { return false }
        return true
    }

    /// The exact reason a tool name is outside the temporary ceiling, when it
    /// is excluded by the audited table. Nil means "not excluded here"
    /// (metadata rules or the action policy decide).
    public static func verifiedExclusionReason(for name: String) -> String? {
        verifiedExclusions[name]
    }

    /// The model-facing projection of `descriptor` inside the temporary
    /// ceiling, or nil when no safe read action exists.
    ///
    /// Pure read tools return the identical descriptor (identity preserved).
    /// Verified mixed tools return a copy whose `parametersJSON` narrows the
    /// `action` enum to `verifiedActionPolicies[name]`; every other field —
    /// including the catalog identity material used for approval display —
    /// stays untouched on the base descriptor.
    public static func readOnlyDescriptor(_ descriptor: ToolCatalog.Descriptor) -> ToolCatalog.Descriptor? {
        guard isReadOnlySafe(descriptor) else { return nil }
        guard let allowedActions = verifiedActionPolicies[descriptor.name] else {
            return descriptor
        }
        guard let narrowed = narrowedSchema(descriptor.parametersJSON, actions: allowedActions) else {
            // A mixed tool whose schema cannot be narrowed is not offered at
            // all: a model must never see an action the ceiling denies.
            return nil
        }
        var projected = descriptor
        projected.parametersJSON = narrowed
        return projected
    }

    /// The name ceiling derived from the run's actually offered descriptors.
    /// Only tools with a safe read action survive.
    public static func allowedToolNames(from descriptors: [ToolCatalog.Descriptor]) -> Set<String> {
        Set(descriptors.lazy.compactMap { descriptor in
            readOnlyDescriptor(descriptor) == nil ? nil : descriptor.name
        })
    }

    /// Executor-side decision for one concrete call. Returns nil only when
    /// the descriptor is a safe read action AND the arguments stay inside the
    /// recorded read surface; any other call fails closed with a
    /// model-comprehensible reason.
    public static func denialReason(
        descriptor: ToolCatalog.Descriptor,
        arguments: Data
    ) -> String? {
        guard isReadOnlySafe(descriptor) else {
            if let reason = verifiedExclusions[descriptor.name] {
                return "The '\(descriptor.name)' tool is outside the temporary chat's read-only ceiling: \(reason)"
            }
            return "The '\(descriptor.name)' tool is outside the temporary chat's read-only ceiling."
        }
        guard let allowedActions = verifiedActionPolicies[descriptor.name] else {
            return nil
        }
        guard let action = actionArgumentValue(in: arguments) else {
            return "The '\(descriptor.name)' tool requires an explicit read action inside the temporary chat's read-only ceiling: \(allowedActions.sorted().joined(separator: ", "))."
        }
        guard allowedActions.contains(action) else {
            return "The '\(descriptor.name)' action '\(action)' is not a read action; the temporary chat allows only: \(allowedActions.sorted().joined(separator: ", "))."
        }
        return nil
    }

    // MARK: - Internals

    /// The string value of the schema's top-level `action` argument, when it
    /// is a plain JSON object carrying one.
    static func actionArgumentValue(in arguments: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return nil
        }
        return object["action"] as? String
    }

    /// Narrows the top-level `action` property's `enum` to `actions`,
    /// preserving every other keyword. Returns nil when the schema is not a
    /// JSON object or has no string enum on `action` — the caller then drops
    /// the tool instead of offering an unverifiable action surface.
    static func narrowedSchema(_ schema: String, actions: Set<String>) -> String? {
        guard let data = schema.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var properties = root["properties"] as? [String: Any],
              var action = properties["action"] as? [String: Any],
              let enumValues = action["enum"] as? [Any] else {
            return nil
        }
        let narrowed = enumValues.compactMap { $0 as? String }.filter { actions.contains($0) }
        guard !narrowed.isEmpty else { return nil }
        action["enum"] = narrowed
        properties["action"] = action
        root["properties"] = properties
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
