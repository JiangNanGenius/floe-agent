import Foundation
import FloeModels

/// Central, bounded guidance for chaining stateful tools. Tool
/// implementations remain the source of truth; this layer only explains how
/// stable identifiers move between existing results and subsequent calls.
enum ToolWorkflowGuidance {
    static func contextLines(for toolNames: [String]) -> [String] {
        let names = Set(toolNames)
        var lines: [String] = []

        let usesTerminalTools = names.contains(where: {
            $0.hasPrefix("ssh.") || $0.hasPrefix("remote.connection.") ||
            $0.hasPrefix("bluetooth.serial.") || $0.hasPrefix("remoteHosting.")
        })
        if usesTerminalTools {
            lines.append("Terminal toolkit (ssh.execute and cloudWorkspace run through the host daemon in the REMOTE environment, never the on-device exec.* tools): pick the host once with ssh.listHosts and reuse that exact hostID; ssh.inspectTarget probes; ssh.updateHost stores config/credential references without exposing secrets. One-shot commands: ssh.execute returns a durable taskID when running; poll ssh.taskStatus with that exact taskID, cancel via ssh.cancelTask, and use ssh.shell.open -> ssh.shell.exchange -> ssh.shell.close (reusing its sessionID) for interactive shells. bootstrapExecutionHost/bootstrapFloeRemoteAgent are one-time deployments. TCP/Telnet and BLE serial reuse the sessionID from open for every exchange until close; remoteHosting reuses shareIDs from inspect/manage and publishes only after explicit sharing authority. Never re-search or invent an ID already returned in this run.")
        }
        if names.contains("browser.navigate") && names.contains("browser.observe") {
            lines.append("Browser workflow: reuse the tabID/documentID from browser.navigate and fresh element refs from browser.observe for one action, then observe again. Full DOM-first strategy: skill.read id=floe.browser.")
        }
        if names.contains("vnc.observe") {
            lines.append("VNC is a strict state machine: vnc.status -> vnc.connect -> vnc.observe -> one input with post-action evidence -> next input. partialSuccess means input may already have executed: never replay it; inputDispatched is not success. Never call observe or input while disconnected, never ask for a password when a secure credential reference can be stored, and honor any user-specified prerequisite route first.")
        }
        if names.contains("canvas.getState") {
            lines.append("Canvas workflow: reuse the latest canvasID/revision/node IDs from canvas.getState; apply returned deltas without re-inspecting unless a revision conflict occurs. Details: skill.read id=floe.data-code.")
        }
        if names.contains("memory.list") || names.contains("memory.search") {
            lines.append("Memory workflow applies only when the user asked to remember/organize something or the current task genuinely needs a durable memory mutation. Do not inspect or save memory during an unrelated diagnostic or tool workflow. Immediately before remember, update, forget, or batchApply, inspect prior memory once in this run with memory.search/list/recall or organizePreview and compare the proposed fact with existing values. For changed environment, address, version, or other mutable facts, reuse the existing memory ID with memory.update or use the same stable subjectKey + attributeKey so the old value is superseded instead of creating a conflict. Search/list returns stable memory IDs; organizePreview returns the batch and entry IDs consumed by batchApply; after one successful inspection, continue the requested task instead of repeatedly inspecting memory.")
        }
        if names.contains("conversation.search") && names.contains("conversation.read") {
            lines.append("Conversation workflow: conversation.search returns conversationID; pass it unchanged to conversation.read and reuse its cursor for older pages.")
        }
        if names.contains("apple.home.list") && names.contains("apple.home.control") {
            lines.append("Apple Home workflow: control only a writable characteristic with the exact accessoryID+characteristicID from apple.home.list. Apple capability rules: skill.read id=floe.apple.")
        }
        if names.contains("apple.calendar.list") || names.contains("apple.reminders.list") || names.contains("apple.automation.list") {
            lines.append("Apple edit workflow: list first for update/delete and reuse the returned stable id. Apple capability rules: skill.read id=floe.apple.")
        }
        if names.contains("font.list") && names.contains("font.remove") {
            lines.append("Font workflow: font.list returns the digest id required by font.remove; never derive it from a filename.")
        }
        if names.contains(where: { $0.hasPrefix("cloudWorkspace.") }) {
            lines.append("Cloud-workspace workflow: reuse the exact hostID/workspaceID already shown under Workspace links (cloudWorkspace.catalog/create provides one when absent). Do not treat the local Cloud marker as remote file content.")
        }
        return lines
    }

    static func recoveryHint(for toolName: String) -> String? {
        switch toolName {
        case "vnc.connect", "vnc.reconnect":
            return "If vnc.status reports unconfigured, do not retry connect. Follow the prerequisite route and order explicitly requested by the user. If the user requested authorized SSH setup, use ssh.listHosts, ssh.inspectTarget, ssh.execute in host mode, and ssh.updateHost to save one endpoint and its Keychain-backed credential before connecting; otherwise use the available resolver the user selected."
        case "vnc.observe", "vnc.click", "vnc.clickElement", "vnc.scroll",
             "vnc.drag", "vnc.typeText", "vnc.typeCredential", "vnc.keyPress":
            return "Call vnc.status. If configured, use vnc.connect before observation or input. If unconfigured, obey the user's explicit prerequisite route before any further VNC call; when that route is authorized SSH setup, use ssh.listHosts, ssh.inspectTarget, ssh.execute in host mode, and ssh.updateHost, then vnc.connect. SSH is not mandatory when the user selected another available resolver. Do not repeat the unchanged VNC call."
        case "ssh.execute", "ssh.inspectTarget", "ssh.updateHost",
             "ssh.bootstrapExecutionHost", "ssh.bootstrapRemoteAgent":
            return "Resolve hostID with ssh.listHosts and reuse the returned value; do not guess it."
        case "ssh.taskStatus":
            return "Use the exact taskID returned by ssh.execute when it reported state=running; do not execute the command again."
        case "remote.connection.open":
            return "Use hostID and connectionID from ssh.listHosts, or provide the explicit user-supplied kind, host, and port."
        case "remote.connection.exchange", "remote.connection.close":
            return "Use the sessionID returned by remote.connection.open in this run."
        case "bluetooth.serial.open":
            return "Use saved IDs from ssh.listHosts or explicit identifiers from bluetooth.serial.scan."
        case "bluetooth.serial.exchange", "bluetooth.serial.close":
            return "Use the sessionID returned by bluetooth.serial.open in this run."
        case "conversation.read":
            return "Use a conversationID returned by conversation.search."
        case "memory.update", "memory.forget":
            return "Use an id returned by memory.search or memory.list."
        case "memory.batchApply":
            return "Use the batchID and entry IDs returned by memory.organizePreview."
        case "font.remove":
            return "Use the digest id returned by font.list."
        case "apple.calendar.update":
            return "For update/delete, use the id returned by apple.calendar.list."
        case "apple.reminders.update":
            return "For update/delete, use the id returned by apple.reminders.list."
        case "apple.automation.update":
            return "For update/delete, use the id returned by apple.automation.list."
        case "apple.home.control":
            return "Use accessoryID and characteristicID from apple.home.list."
        case "remoteHosting.inspect":
            return "Resolve hostID with ssh.listHosts before inspecting the host."
        case "remoteHosting.manage":
            return "Resolve hostID with ssh.listHosts; for stop, call action=list and reuse the returned shareID."
        default:
            if toolName.hasPrefix("cloudWorkspace.git") {
                return "Use a workspaceID from Workspace links, cloudWorkspace.catalog, or cloudWorkspace.create."
            }
            if toolName.hasPrefix("canvas.") {
                return "Use canvas/document/node IDs and the current revision from canvas.getState."
            }
            return nil
        }
    }

    static func outputSummary(
        _ summary: String,
        exposing artifacts: [ToolArtifactReference]
    ) -> String {
        guard !artifacts.isEmpty else { return summary }
        let bindings = artifacts.prefix(8).map {
            "artifactID=\($0.id.uuidString) path=\($0.relativePath) mime=\($0.mimeType) sha256=\($0.sha256)"
        }.joined(separator: "; ")
        // Put reusable bindings first so ToolResult's 4 KiB boundary cannot
        // discard them when the implementation summary is already large.
        return "resource artifacts: \(bindings)\n" + summary
    }

    static func artifactBindings(_ artifacts: [ToolArtifactReference]) -> String? {
        guard !artifacts.isEmpty else { return nil }
        return "artifact bindings: " + artifacts.prefix(8).map {
            "\($0.id.uuidString)=\($0.relativePath)"
        }.joined(separator: ", ")
    }

    /// Extracts identifier bindings from JSON results so compaction never
    /// trims away the values required by the next tool in the chain.
    static func resourceBindings(in output: String, toolName: String) -> String? {
        let values = structuredResourceBindings(in: output, toolName: toolName)
        guard !values.isEmpty else { return nil }
        return "resource bindings: " + values.map { "\($0.name)=\($0.value)" }
            .joined(separator: ", ")
    }

    static func structuredResourceBindings(
        in output: String,
        toolName: String,
        artifacts: [ToolArtifactReference] = []
    ) -> [ToolResourceBinding] {
        var outputBindings: [ToolResourceBinding] = artifacts.prefix(8).map {
            ToolResourceBinding(
                name: "\(toolName).artifactID",
                value: "\($0.id.uuidString)|\($0.relativePath)"
            )
        }
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return outputBindings
        }
        var bindings: [ToolResourceBinding] = []
        var seen: Set<String> = []

        func visit(_ value: Any, path: String, depth: Int) {
            guard depth <= 6, bindings.count < 12 else { return }
            if let dictionary = value as? [String: Any] {
                for key in dictionary.keys.sorted() {
                    guard let child = dictionary[key] else { continue }
                    let childPath = path.isEmpty ? key : "\(path).\(key)"
                    let normalized = key.lowercased().replacingOccurrences(of: "_", with: "")
                    let isIdentifier = normalized == "id"
                        || normalized.hasSuffix("id")
                        || normalized.hasSuffix("ids")
                        || normalized.hasSuffix("cursor")
                    if isIdentifier, let scalar = scalarString(child), !scalar.isEmpty {
                        let binding = "\(childPath)=\(scalar)"
                        if seen.insert(binding).inserted {
                            bindings.append(ToolResourceBinding(name: childPath, value: scalar))
                        }
                    } else {
                        visit(child, path: childPath, depth: depth + 1)
                    }
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.prefix(12).enumerated() {
                    visit(child, path: "\(path)[\(index)]", depth: depth + 1)
                    if bindings.count >= 12 { break }
                }
            }
        }

        visit(object, path: toolName, depth: 0)
        outputBindings.append(contentsOf: bindings)
        return Array(outputBindings.prefix(16))
    }

    private static func scalarString(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let value = value as? String { return String(value.prefix(160)) }
        if let value = value as? NSNumber { return value.stringValue }
        if let values = value as? [String] {
            return values.prefix(8).joined(separator: ",")
        }
        return nil
    }
}
