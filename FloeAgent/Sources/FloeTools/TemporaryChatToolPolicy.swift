// FloeTools — Capability ceiling for the temporary (ephemeral) chat mode.
//
// SPDX-License-Identifier: MPL-2.0
//
// A temporary conversation is casual chat: the effective tool ceiling is the
// normal text model plus, at most, the public read-only web retrieval pair.
// Everything else — shell, Python, Linux, ports, files, workspace, Office,
// media, CAD, browser GUI, calendar/reminders/mail, MCP, skills execution,
// delegation, jobs, memory, history, export, task creation, send — is
// excluded. The ceiling is applied as the LAST intersection of the existing
// `allowedToolNames` chain in `ConversationCenter.runService`, so the
// runtime's `Configuration.allowedToolNames` (enforced at tools.list, main
// dispatch AND child dispatch) carries it; wrappers, aliases, batch/jobs and
// delegated children cannot widen it.

import Foundation

/// Builds the exact tool-name ceiling for a temporary chat run.
public enum TemporaryChatToolPolicy {
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
    public static func allowedToolNames(from offered: Set<String>) -> Set<String> {
        nativeToolNames.intersection(offered)
    }

    /// True when `name` is part of the temporary ceiling.
    public static func isTemporaryChatTool(_ name: String) -> Bool {
        nativeToolNames.contains(name)
    }
}
