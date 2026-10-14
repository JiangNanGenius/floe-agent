// FloeToolsTests — Temporary chat tool ceiling.

import Foundation
import Testing
@testable import FloeTools

@Suite("FloeTools.TemporaryChatToolPolicy")
struct TemporaryChatToolPolicyTests {

    @Test("Ceiling contains only the public read-only web retrieval pair")
    func ceilingContents() {
        #expect(TemporaryChatToolPolicy.nativeToolNames == ["web.search", "web.fetch"])
    }

    @Test("Ceiling intersects with the offered descriptor set")
    func ceilingIntersectsOffered() {
        let offered: Set<String> = [
            "web.search", "web.fetch", "workspace.readFile", "shell.exec",
            "delegate.task", "batch.run", "jobs.submit", "memory.remember",
            "history.search", "export.data", "browser.open", "calendar.list",
            "mail.search", "skills.run", "task.create", "send.message",
            "python.run", "files.read", "notes.read", "canvas.getState",
        ]
        let allowed = TemporaryChatToolPolicy.allowedToolNames(from: offered)
        #expect(allowed == ["web.search", "web.fetch"])
    }

    @Test("Uninstalled or unconfigured web tools fall out of the ceiling")
    func uninstalledToolsFallOut() {
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: ["web.fetch"]) == ["web.fetch"])
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: []).isEmpty)
        #expect(TemporaryChatToolPolicy.allowedToolNames(from: ["web.searchAI", "bocha.web"]) .isEmpty)
    }

    @Test("Ceiling never widens: every denied family stays denied")
    func deniedFamiliesStayDenied() {
        let denied = [
            "workspace.writeFile", "exec.shell", "exec.localPython", "linux.start",
            "files.import", "office.open", "media.generate", "cad.create",
            "browser.control", "calendar.create", "reminders.add", "mail.send",
            "mcp.call", "skills.execute", "delegate.explore", "jobs.create",
            "memory.extract", "history.read", "export.transcript", "task.create",
            "send.email", "canvas.startOrdinaryTask",
        ]
        for name in denied {
            #expect(!TemporaryChatToolPolicy.isTemporaryChatTool(name), "\(name) must stay outside the temporary ceiling")
        }
        for name in TemporaryChatToolPolicy.nativeToolNames {
            #expect(TemporaryChatToolPolicy.isTemporaryChatTool(name))
        }
    }
}
