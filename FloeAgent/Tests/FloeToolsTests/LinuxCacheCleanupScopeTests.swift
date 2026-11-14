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

    @Test("Offer intersection includes guest terminal/jobs but never workspace, remote or unrelated tools")
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
            "jobs.result",
            "jobs.cancel",
            "workspace.writeFile",
            "ssh.execute",
            "delegate",
            "web.search"
        ]
        let narrowed = LinuxCacheCleanupScope.allowedToolNames(from: offered)
        #expect(narrowed == LinuxCacheCleanupScope.allowedToolNames)
        #expect(narrowed.contains("exec.shell"))
        #expect(narrowed.contains("jobs.submit") && narrowed.contains("jobs.result"))
        #expect(!narrowed.contains("workspace.writeFile"))
        #expect(!narrowed.contains("delegate"))
        #expect(!narrowed.contains("ssh.execute"))
        #expect(!narrowed.contains("web.search"))
    }

    private func shellDescriptor() -> ToolCatalog.Descriptor {
        descriptor("exec.shell", risks: [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess],
                   sideEffecting: true, effect: .mutating)
    }

    @Test("The existing guest terminal does not require a black-box inspect first")
    func terminalAndJobLifecycleAreOfferedWithoutInspectPrerequisite() {
        #expect(denial("exec.shell", arguments: ["command": "df -Pk /; du -sk /floe/env/cache/pip"],
                       descriptor: shellDescriptor()) == nil)
        let submit = descriptor("jobs.submit", risks: shellDescriptor().riskLabels,
                                sideEffecting: true, effect: .mutating)
        #expect(denial("jobs.submit", arguments: ["tool": "exec.shell", "arguments": #"{"script":"df -Pk /"}"#, "wait": true], descriptor: submit) == nil)
        for tool in ["network.download", "exec.localService", "ssh.execute"] {
            #expect(denial("jobs.submit", arguments: ["tool": tool, "arguments": "{}"], descriptor: submit) != nil)
        }
        #expect(LinuxCacheCleanupScope.usesGuestCommandReview("exec.shell"))
        #expect(!LinuxCacheCleanupScope.usesGuestCommandReview("network.http"))
    }

    @Test("Host scope and model target/installer/receipt overrides are refused before dispatch")
    func hostAndEnvironmentOverridesDeniedAtDispatch() {
        let shell = descriptor(
            "exec.shell",
            risks: [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess],
            sideEffecting: true,
            effect: .mutating
        )
        let scopes: [ToolScope] = [.host(UUID()), .hostPath(hostID: UUID(), path: "/")]
        for scope in scopes {
            let remote = LinuxCacheCleanupScope.denialReason(profile: profile, conversationID: conversationID,
                environmentID: environmentID, descriptor: shell, arguments: args(["command": "df -Pk /"]), scope: scope)
            #expect(remote?.contains("host and remote scopes are refused") == true)
        }
        let extras: [[String: Any]] = [
            ["environmentID": "shared"], ["hostID": UUID().uuidString], ["skillID": "installer"],
            ["packages": ["missing-package"]], ["env": ["FLOE_CLEANUP_NATIVE": "1"]]
        ]
        for extra in extras {
            var input: [String: Any] = ["command": "df -Pk /"]; input.merge(extra) { _, value in value }
            #expect(denial("exec.shell", arguments: input, descriptor: shell) != nil)
        }
    }

    @Test("Old exact helper policies project to the authorized terminal; user restrictions are retained")
    func legacyProjectionPreservesExplicitRestrictions() {
        #expect(LinuxCacheCleanupScope.projectedToolNames(LinuxCacheCleanupScope.legacyToolNames) == LinuxCacheCleanupScope.allowedToolNames)
        let narrowed: Set<String> = ["linux.cache.inspect", "user.ask"]
        #expect(LinuxCacheCleanupScope.projectedToolNames(narrowed) == narrowed)
        #expect(LinuxCacheCleanupScope.projectedToolNames(nil) == nil)
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
