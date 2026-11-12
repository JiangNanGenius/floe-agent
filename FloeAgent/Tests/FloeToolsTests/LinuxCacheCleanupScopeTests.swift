// FloeToolsTests — purpose ceiling and dispatch refusal for the one-tap Linux
// cache-cleanup task. These are pure contracts: no Linux guest, no job and no
// host path is touched.

import Foundation
import Testing
import FloeModels
@testable import FloeTools

@Suite("Linux cache cleanup purpose scope")
struct LinuxCacheCleanupScopeTests {
    private let conversationID = UUID()
    private let environmentID = "shared"

    private var profile: LinuxCacheCleanupTaskProfile {
        LinuxCacheCleanupTaskProfile(
            conversationID: conversationID,
            environmentID: environmentID
        )
    }

    private func descriptor(
        _ name: String,
        risks: Set<RiskLabel>,
        sideEffecting: Bool,
        effect: ToolEffect,
        requiresHostScope: Bool = false
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            riskLabels: risks,
            isSideEffecting: sideEffecting,
            effect: effect,
            requiresHostScope: requiresHostScope,
            executionBoundary: .any
        )
    }

    private func cleanDescriptor() -> ToolCatalog.Descriptor {
        descriptor(
            LinuxCacheCleanupScope.cleanToolName,
            risks: [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles],
            sideEffecting: true,
            effect: .mutating
        )
    }

    private func inspectDescriptor() -> ToolCatalog.Descriptor {
        descriptor(
            LinuxCacheCleanupScope.inspectToolName,
            risks: [.readsFiles, .executesLocalCode],
            sideEffecting: false,
            effect: .readOnly
        )
    }

    private func args(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func denial(
        _ name: String,
        arguments: [String: Any],
        descriptor: ToolCatalog.Descriptor
    ) -> String? {
        LinuxCacheCleanupScope.denialReason(
            profile: profile,
            conversationID: conversationID,
            environmentID: environmentID,
            descriptor: descriptor,
            arguments: args(arguments)
        )
    }

    @Test("Offer intersection can never add a shell, jobs, workspace, host or delegate tool")
    func ceilingIsClosed() {
        let offered: Set<String> = [
            LinuxCacheCleanupScope.inspectToolName,
            LinuxCacheCleanupScope.cleanToolName,
            LinuxCacheCleanupScope.statusToolName,
            LinuxCacheCleanupScope.cancelToolName,
            "user.ask",
            "tools.search",
            "tools.list",
            "tools.readResult",
            "exec.shell",
            "jobs.submit",
            "jobs.status",
            "workspace.writeFile",
            "ssh.execute",
            "delegate",
            "web.search"
        ]
        let narrowed = LinuxCacheCleanupScope.allowedToolNames(from: offered)
        #expect(narrowed == LinuxCacheCleanupScope.allowedToolNames)
        #expect(!narrowed.contains("exec.shell"))
        #expect(!narrowed.contains("jobs.submit"))
        #expect(!narrowed.contains("workspace.writeFile"))
        #expect(!narrowed.contains("delegate"))
        #expect(!narrowed.contains("ssh.execute"))
        #expect(!narrowed.contains("web.search"))
    }

    @Test("A generic shell call is denied at dispatch even if a forged wrapper reaches the runtime")
    func shellDeniedAtDispatch() {
        let shell = descriptor(
            "exec.shell",
            risks: [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles],
            sideEffecting: true,
            effect: .mutating
        )
        let reason = denial("exec.shell", arguments: ["command": "rm -rf /"], descriptor: shell)
        #expect(reason?.contains("outside this Linux cache-cleanup task") == true)
    }

    @Test("A forged cleanup name with broader metadata is refused")
    func forgedCleanupDescriptorDenied() {
        let forged = descriptor(
            LinuxCacheCleanupScope.cleanToolName,
            risks: [.executesLocalCode],
            sideEffecting: false,
            effect: .readOnly
        )
        let reason = denial(LinuxCacheCleanupScope.cleanToolName,
                            arguments: ["categories": ["apt"]],
                            descriptor: forged)
        #expect(reason?.contains("no longer matches") == true)
    }

    @Test("Cleanup arguments admit only apt, pip and npm; legacy scratch is refused")
    func argumentSurface() {
        #expect(denial(LinuxCacheCleanupScope.cleanToolName,
                       arguments: ["categories": ["apt", "pip"]],
                       descriptor: cleanDescriptor()) == nil)
        let rejected: [[String: Any]] = [
            ["categories": ["scratch"]],
            ["categories": ["apt", "scratch"]],
            ["includeScratch": true],
            ["includeScratch": false]
        ]
        for arguments in rejected {
            #expect(denial(LinuxCacheCleanupScope.cleanToolName,
                           arguments: arguments, descriptor: cleanDescriptor()) != nil)
        }
        #expect(denial(LinuxCacheCleanupScope.inspectToolName,
                       arguments: [:],
                       descriptor: inspectDescriptor()) == nil)
        #expect(denial(LinuxCacheCleanupScope.cleanToolName,
                       arguments: ["categories": ["../Documents"]],
                       descriptor: cleanDescriptor()) != nil)
        #expect(denial(LinuxCacheCleanupScope.cleanToolName,
                       arguments: ["path": "/floe/env/home"],
                       descriptor: cleanDescriptor()) != nil)
        #expect(denial(LinuxCacheCleanupScope.cleanToolName,
                       arguments: ["categories": ["apt", "apt"]],
                       descriptor: cleanDescriptor()) != nil)
        #expect(denial(LinuxCacheCleanupScope.cleanToolName,
                       arguments: ["includeScratch": "yes"],
                       descriptor: cleanDescriptor()) != nil)
    }

    @Test("Status and cancel require exactly one real job UUID")
    func jobIDArguments() {
        let status = descriptor(
            LinuxCacheCleanupScope.statusToolName,
            risks: [],
            sideEffecting: false,
            effect: .readOnly
        )
        #expect(denial(LinuxCacheCleanupScope.statusToolName,
                       arguments: ["jobID": UUID().uuidString],
                       descriptor: status) == nil)
        #expect(denial(LinuxCacheCleanupScope.statusToolName,
                       arguments: ["jobID": "not-a-uuid"],
                       descriptor: status) != nil)
        #expect(denial(LinuxCacheCleanupScope.statusToolName,
                       arguments: ["jobID": UUID().uuidString, "path": "/"],
                       descriptor: status) != nil)
    }

    @Test("A profile cannot be rebound to another conversation or environment")
    func profileBindingIsExact() {
        let wrongEnvironment = LinuxCacheCleanupScope.denialReason(
            profile: profile,
            conversationID: conversationID,
            environmentID: "project-1",
            descriptor: cleanDescriptor(),
            arguments: args(["categories": ["apt"]])
        )
        #expect(wrongEnvironment?.contains("does not match") == true)

        let wrongConversation = LinuxCacheCleanupScope.denialReason(
            profile: profile,
            conversationID: UUID(),
            environmentID: environmentID,
            descriptor: cleanDescriptor(),
            arguments: args(["categories": ["apt"]])
        )
        #expect(wrongConversation?.contains("does not match") == true)
    }

    @Test("The profile is structurally valid only for Linux and the current version")
    func profileValidation() {
        #expect(profile.isValid)
        #expect(!LinuxCacheCleanupTaskProfile(
            conversationID: conversationID,
            environmentID: "",
            backend: .linuxVM
        ).isValid)
        #expect(!LinuxCacheCleanupTaskProfile(
            conversationID: conversationID,
            environmentID: environmentID,
            backend: .macBridge
        ).isValid)
    }
}
