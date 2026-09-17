// SPDX-License-Identifier: MPL-2.0
//
// Pure policy tests for the IDE Run flow. No simulator, terminal, SSH host or
// network is touched: these assert the typed plan, quoting, the dispatch gate,
// the routing identities (WASM catalog command, remote mapping ownership), the
// staged remote command construction and the dispatch-time identity re-check
// the controller consults.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.IDELanguageRunPolicy")
struct IDELanguageRunPolicyTests {

    private func capabilities(
        interpreters: Set<IDELanguageLocalInterpreter> = [.python3, .node, .shell, .lua],
        mapping: IDELanguageRunRemoteMapping? = nil
    ) -> IDELanguageRunCapabilities {
        IDELanguageRunCapabilities(localInterpreters: interpreters, mapping: mapping)
    }

    private func request(
        _ path: String,
        _ capabilities: IDELanguageRunCapabilities,
        target: IDELanguageRunSelection.Target = .local,
        token: String = "run123"
    ) -> IDELanguageRunRequest {
        IDELanguageRunRequest(
            relativePath: path,
            selection: IDELanguageRunSelection(target: target),
            capabilities: capabilities,
            runToken: token
        )
    }

    // MARK: Quoting

    @Test func quotesEachArgumentIndividually() {
        #expect(IDELanguageRunPolicy.shellQuote("plain.py") == "plain.py")
        #expect(IDELanguageRunPolicy.shellQuote("my script.py") == "'my script.py'")
        #expect(IDELanguageRunPolicy.shellQuote("it's.py") == "'it'\\''s.py'")
        #expect(IDELanguageRunPolicy.shellQuote("") == "''")
        #expect(IDELanguageRunPolicy.shellCommand(["python3", "a b.py"]) == "python3 'a b.py'")
    }

    @Test func homeQuotedExpandsHomeButQuotesTheRemainder() {
        #expect(IDELanguageRunPolicy.homeQuoted("floe-ide-run/run123/main.c")
                == "\"$HOME\"/.floe/cloud-workspaces/floe-ide-run/run123/main.c")
        #expect(IDELanguageRunPolicy.homeQuoted("floe-ide-run/run123/my file.c")
                == "\"$HOME\"/.floe/cloud-workspaces/'floe-ide-run/run123/my file.c'")
    }

    @Test func pathTraversalAndAbsolutePathsAreRejected() {
        for path in ["/etc/passwd", "../secret.py", "a/../../b.py", "a//b.py", "a/./b.py", "line\nbreak.py"] {
            #expect(IDELanguageRunPolicy.plan(request(path, capabilities())) == .unavailable(.invalidPath),
                    "expected invalid path for \(path)")
        }
        #expect(IDELanguageRunPolicy.plan(request("", capabilities())) == .unavailable(.noActiveFile))
    }

    @Test func argumentVectorValidationRejectsControlCharacters() {
        #expect(!IDELanguageRunPolicy.isValidArgumentVector([]))
        #expect(!IDELanguageRunPolicy.isValidArgumentVector([""]))
        #expect(IDELanguageRunPolicy.isValidArgumentVector(["cc", "src/main.c"]))
        #expect(!IDELanguageRunPolicy.isValidArgumentVector(["cc", "a\nb.c"]))
        #expect(!IDELanguageRunPolicy.isValidArgumentVector(["cc", "a\tb.c"]))
    }

    // MARK: Local interpreters

    @Test func localPythonPlanKeepsPathAsOneQuotedArgument() {
        let plan = IDELanguageRunPolicy.plan(request("src/my script.py", capabilities()))
        #expect(plan == .local(languageID: "python", argv: ["python3", "src/my script.py"], mechanism: .localInterpreter))
        #expect(plan.commandLine == "python3 'src/my script.py'")
        #expect(plan.mechanism?.isCrossCompile == false)
        #expect(plan.mechanism?.isRemote == false)
    }

    @Test func missingLocalRuntimeIsUnavailable() {
        let plan = IDELanguageRunPolicy.plan(request("main.py", capabilities(interpreters: [.shell])))
        #expect(plan == .unavailable(.localRuntimeMissing(interpreter: .python3)))
    }

    @Test func luaRequiresTheInstalledSignedRuntime() {
        #expect(IDELanguageRunPolicy.plan(request("init.lua", capabilities())) ==
                .local(languageID: "lua", argv: ["lua", "init.lua"], mechanism: .localInterpreter))
        #expect(IDELanguageRunPolicy.plan(request("init.lua", capabilities(interpreters: [.python3, .node, .shell]))) ==
                .unavailable(.localRuntimeMissing(interpreter: .lua)))
    }

    @Test func shellIsAlwaysALocalInterpreter() {
        let plan = IDELanguageRunPolicy.plan(request("scripts/setup.sh", capabilities(interpreters: [.shell])))
        #expect(plan == .local(languageID: "shell", argv: ["sh", "scripts/setup.sh"], mechanism: .localInterpreter))
    }

    @Test func unsupportedFileTypeIsReported() {
        #expect(IDELanguageRunPolicy.plan(request("notes.txt", capabilities())) ==
                .unavailable(.unsupportedFileType(ext: "txt")))
        #expect(IDELanguageRunPolicy.plan(request("Makefile", capabilities())) ==
                .unavailable(.unsupportedFileType(ext: "")))
    }

    // MARK: WASM interpreter identity

    @Test func luaAvailabilityResolvesCanonicalCatalogCommand() {
        // The registry's shell alias is `lua`; the signed catalog identity is
        // `floe-lua`. Both must resolve, with the canonical one preferred.
        #expect(IDELanguageRunPolicy.matchingWasmEntryCommand(for: .lua, catalogCommands: ["floe-lua"]) == "floe-lua")
        #expect(IDELanguageRunPolicy.matchingWasmEntryCommand(for: .lua, catalogCommands: ["lua"]) == "lua")
        #expect(IDELanguageRunPolicy.matchingWasmEntryCommand(for: .lua, catalogCommands: ["lua", "floe-lua"]) == "floe-lua")
        #expect(IDELanguageRunPolicy.matchingWasmEntryCommand(for: .lua, catalogCommands: ["floe-text"]) == nil)
        // Python/Node are separate runtimes and must not be resolved from the
        // WASM catalog by a `floe-*` guess.
        #expect(IDELanguageRunPolicy.matchingWasmEntryCommand(for: .python3, catalogCommands: ["floe-python"]) == nil)
    }

    // MARK: Remote-only languages

    @Test func remoteOnlyLanguagesCannotRunLocally() {
        for path in ["main.rs", "App.swift", "main.c", "main.cpp", "index.php", "app.rb", "main.go", "Main.java", "Main.kt"] {
            guard case .unavailable(.remoteLanguageNeedsHost) = IDELanguageRunPolicy.plan(request(path, capabilities())) else {
                Issue.record("expected remote-only local rejection for \(path)")
                continue
            }
        }
    }

    // MARK: Staged remote plans

    @Test func remoteCompilePlanTargetsTheRunOwnedStagingCopy() throws {
        let host = UUID()
        let target = IDELanguageRunSelection.Target.remote(hostID: host, hostName: "buildbox")
        let plan = IDELanguageRunPolicy.plan(request("src/main.c", capabilities(), target: target))

        guard case .remote(let command, let mechanism) = plan else {
            Issue.record("expected a remote plan, got \(plan)")
            return
        }
        #expect(mechanism == .remoteCompileRun)
        #expect(command.hostID == host)
        #expect(command.runToken == "run123")
        #expect(command.stagingRoot == "floe-ide-run/run123")
        #expect(command.stagedSourcePath == "floe-ide-run/run123/src/main.c")
        #expect(command.workingDirectory == "floe-ide-run/run123/src")
        #expect(command.sourceFileName == "main.c")
        #expect(command.probeTool == "cc")
        #expect(command.probeCommand == "command -v cc")
        // The compile output lives beside the staged source inside the
        // run-owned root, so one trap removes exactly this run's artifacts.
        #expect(command.compileCommand == ["cc", "main.c", "-o", "./program"])
        #expect(command.runCommand == ["./program"])
    }

    @Test func remoteInterpretedPlanRunsTheStagedBasename() throws {
        let host = UUID()
        let target = IDELanguageRunSelection.Target.remote(hostID: host, hostName: "buildbox")
        let plan = IDELanguageRunPolicy.plan(request("main.go", capabilities(), target: target))
        guard case .remote(let command, let mechanism) = plan else {
            Issue.record("expected a remote plan, got \(plan)")
            return
        }
        #expect(mechanism == .remoteInterpreter)
        #expect(command.workingDirectory == "floe-ide-run/run123")
        #expect(command.runCommand == ["go", "run", "main.go"])
        #expect(command.compileCommand == nil)
        #expect(command.probeTool == "go")
    }

    @Test func remoteShellCommandIsMarkerGuardedAndStatusPreserving() throws {
        let host = UUID()
        let target = IDELanguageRunSelection.Target.remote(hostID: host, hostName: "buildbox")
        let plan = IDELanguageRunPolicy.plan(request("src/main.c", capabilities(), target: target))
        let line = try #require(plan.commandLine)
        #expect(line == "s=\"$HOME\"/.floe/cloud-workspaces/floe-ide-run/run123; ( if "
                + "[ \"$(cat \"$s/.floe-run-token\" 2>/dev/null)\" = \"run123\" ]; then "
                + "trap 'x=$?; if [ \"$(cat \"$s/.floe-run-token\" 2>/dev/null)\" = \"run123\" ]; then rm -rf \"$s\"; fi; exit $x' EXIT HUP INT TERM; "
                + "cd \"$HOME\"/.floe/cloud-workspaces/floe-ide-run/run123/src && cc main.c -o ./program && ./program; "
                + "else echo 'floe: staging ownership marker mismatch' >&2; exit 1; fi )")
        // Ownership marker checked before running AND again inside the trap
        // before anything is removed; never a bare trailing `; rm -rf`.
        #expect(!line.contains("; rm -rf"))
        #expect(line.contains("rm -rf \"$s\""))
        // Interpreted runs keep the same ownership/cleanup guard.
        let interpreted = IDELanguageRunPolicy.plan(request("main.php", capabilities(), target: target))
        #expect(try #require(interpreted.commandLine).contains("trap 'x=$?"))
    }

    @Test func remoteVisibilityProbeChecksTheDefaultDaemonRoot() {
        let host = UUID()
        let target = IDELanguageRunSelection.Target.remote(hostID: host, hostName: "buildbox")
        let plan = IDELanguageRunPolicy.plan(request("src/main.c", capabilities(), target: target))
        guard case .remote(let command, _) = plan else {
            Issue.record("expected a remote plan, got \(plan)")
            return
        }
        #expect(command.visibilityProbeCommand ==
                "test -f \"$HOME\"/.floe/cloud-workspaces/floe-ide-run/run123/src/main.c && printf %s floe-ide-staged-visible")
    }

    @Test func remotePlanQuotesStagedPathsWithSpaces() throws {
        let host = UUID()
        let target = IDELanguageRunSelection.Target.remote(hostID: host, hostName: "buildbox")
        let plan = IDELanguageRunPolicy.plan(request("src/my file.c", capabilities(), target: target))
        guard case .remote(let command, _) = plan else {
            Issue.record("expected a remote plan, got \(plan)")
            return
        }
        let line = command.shellCommand
        #expect(line.contains("cc 'my file.c' -o ./program"))
        #expect(command.compileCommand == ["cc", "my file.c", "-o", "./program"])
        #expect(command.visibilityProbeCommand.contains("'floe-ide-run/run123/src/my file.c'"))
    }

    @Test func remotePlanSanitizesTheRunToken() {
        let host = UUID()
        let target = IDELanguageRunSelection.Target.remote(hostID: host, hostName: "buildbox")
        let plan = IDELanguageRunPolicy.plan(request("main.rs", capabilities(), target: target, token: "ab'; rm -rf /;'"))
        guard case .remote(let command, _) = plan else {
            Issue.record("expected a remote plan, got \(plan)")
            return
        }
        #expect(command.runToken == "abrm-rf")
        #expect(command.stagingRoot == "floe-ide-run/abrm-rf")
        #expect(!command.shellCommand.contains("'ab'"))
        #expect(!command.shellCommand.contains("; rm"))
    }

    // MARK: Remote mapping identity (informational)

    @Test func remoteMappingSelectionIgnoresOtherWorkspaceLinks() {
        let host = UUID()
        let otherHost = UUID()
        // A link loaded for another workspace root must never match by host.
        let otherWorkspace = IDELanguageRunMappingCandidate(
            name: "app", hostID: host, remotePath: "/srv/other", belongsToPinnedWorkspace: false)
        #expect(IDELanguageRunPolicy.selectRemoteMapping(
            candidates: [otherWorkspace], hostID: host, activePath: "Cloud/app/src/main.c") == nil)
        // A link for the same host but a different hostID is not a match.
        let pinned = IDELanguageRunMappingCandidate(
            name: "app", hostID: host, remotePath: "/srv/app", belongsToPinnedWorkspace: true)
        #expect(IDELanguageRunPolicy.selectRemoteMapping(
            candidates: [pinned], hostID: otherHost, activePath: "Cloud/app/src/main.c") == nil)
    }

    @Test func remoteMappingSelectionRequiresTheActiveCloudMarker() {
        let host = UUID()
        let app = IDELanguageRunMappingCandidate(name: "app", hostID: host, remotePath: "/srv/app", belongsToPinnedWorkspace: true)
        let lib = IDELanguageRunMappingCandidate(name: "lib", hostID: host, remotePath: "/srv/lib", belongsToPinnedWorkspace: true)

        // The active file's Cloud marker owns the mapping.
        #expect(IDELanguageRunPolicy.selectRemoteMapping(
            candidates: [app, lib], hostID: host, activePath: "Cloud/lib/src/main.c") ==
                IDELanguageRunRemoteMapping(hostID: host, workingDirectory: "/srv/lib"))
        // Two same-host links and no marker match is ambiguous, not a guess.
        #expect(IDELanguageRunPolicy.selectRemoteMapping(
            candidates: [app, lib], hostID: host, activePath: "src/main.c") == nil)
        #expect(IDELanguageRunPolicy.selectRemoteMapping(
            candidates: [app], hostID: host, activePath: "src/main.c") == nil)
    }

    // MARK: Dispatch-time identity re-check

    @Test func contextDriftDetectsWorkspaceRootPathAndRevisionChanges() {
        let workspace = UUID()
        let initial = IDELanguageRunPinnedContext(
            workspaceID: workspace, rootPath: "/root/ws", relativePath: "src/main.c", sourceSHA256: nil)
        #expect(IDELanguageRunPolicy.contextDrift(initial: initial, current: initial) == nil)

        let otherWorkspace = IDELanguageRunPinnedContext(
            workspaceID: UUID(), rootPath: "/root/ws", relativePath: "src/main.c", sourceSHA256: nil)
        #expect(IDELanguageRunPolicy.contextDrift(initial: initial, current: otherWorkspace) == .workspace)

        let otherRoot = IDELanguageRunPinnedContext(
            workspaceID: workspace, rootPath: "/root/other", relativePath: "src/main.c", sourceSHA256: nil)
        #expect(IDELanguageRunPolicy.contextDrift(initial: initial, current: otherRoot) == .root)

        let otherPath = IDELanguageRunPinnedContext(
            workspaceID: workspace, rootPath: "/root/ws", relativePath: "src/other.c", sourceSHA256: nil)
        #expect(IDELanguageRunPolicy.contextDrift(initial: initial, current: otherPath) == .path)

        // Revision is only compared once it was actually observed after save.
        let unknownAtStart = IDELanguageRunPinnedContext(
            workspaceID: workspace, rootPath: "/root/ws", relativePath: "src/main.c", sourceSHA256: "aaa")
        let changedAfterSave = IDELanguageRunPinnedContext(
            workspaceID: workspace, rootPath: "/root/ws", relativePath: "src/main.c", sourceSHA256: "bbb")
        #expect(IDELanguageRunPolicy.contextDrift(initial: initial, current: changedAfterSave) == nil)
        #expect(IDELanguageRunPolicy.contextDrift(initial: unknownAtStart, current: changedAfterSave) == .sourceRevision)
    }

    // MARK: Dispatch gate

    @Test func unresolvedConflictBlocksDispatch() {
        let plan = IDELanguageRunPolicy.plan(request("main.py", capabilities()))
        #expect(IDELanguageRunPolicy.dispatchDecision(plan: plan, snapshotSaved: true, hasUnresolvedConflict: true) ==
                .blocked(.conflictUnresolved))
    }

    @Test func failedSnapshotBlocksDispatch() {
        let plan = IDELanguageRunPolicy.plan(request("main.py", capabilities()))
        #expect(IDELanguageRunPolicy.dispatchDecision(plan: plan, snapshotSaved: false, hasUnresolvedConflict: false) ==
                .blocked(.snapshotSaveFailed))
    }

    @Test func availablePlanDispatchesOnlyWhenTheSnapshotIsSaved() {
        let plan = IDELanguageRunPolicy.plan(request("main.py", capabilities()))
        #expect(IDELanguageRunPolicy.dispatchDecision(plan: plan, snapshotSaved: true, hasUnresolvedConflict: false) == .dispatch)
    }

    // MARK: Attempt identity and lifecycle

    @Test func attemptIdentityIsGenerationScoped() {
        let first = IDELanguageRunAttempt(generation: 1, runToken: "aaa111")
        let second = IDELanguageRunAttempt(generation: 2, runToken: "bbb222")
        #expect(IDELanguageRunPolicy.isCurrentAttempt(first, generation: 1))
        #expect(!IDELanguageRunPolicy.isCurrentAttempt(first, generation: 2))
        #expect(IDELanguageRunPolicy.isCurrentAttempt(second, generation: 2))
        // Every attempt carries its own staging token, so a delayed cleanup
        // cannot name (let alone remove) a newer attempt's directory.
        #expect(first.runToken != second.runToken)
    }

    @Test func pinnedRevisionProofFailsClosedWhenUnknownOrChanged() {
        #expect(IDELanguageRunPolicy.sourceRevisionMatches(pinnedSHA256: "abc", observedSHA256: "abc"))
        #expect(!IDELanguageRunPolicy.sourceRevisionMatches(pinnedSHA256: "abc", observedSHA256: "def"))
        #expect(!IDELanguageRunPolicy.sourceRevisionMatches(pinnedSHA256: nil, observedSHA256: "abc"))
        #expect(!IDELanguageRunPolicy.sourceRevisionMatches(pinnedSHA256: "", observedSHA256: "abc"))
        #expect(!IDELanguageRunPolicy.sourceRevisionMatches(pinnedSHA256: "abc", observedSHA256: ""))
    }

    @Test func stagingCleanupIsMarkerGuardedAndReportsItsBranch() {
        let line = IDELanguageRunPolicy.stagingCleanupCommand(stagingRoot: "floe-ide-run/run123", runToken: "run123")
        #expect(line == "s=\"$HOME\"/.floe/cloud-workspaces/floe-ide-run/run123; if "
                + "[ \"$(cat \"$s/.floe-run-token\" 2>/dev/null)\" = run123 ]; then "
                + "rm -rf \"$s\" && printf %s floe-ide-cleanup-removed; "
                + "else printf %s floe-ide-cleanup-skipped; fi")
        #expect(line.contains("rm -rf \"$s\""))
        #expect(!line.contains("; rm -rf \"/\""))
        #expect(line.contains(".floe-run-token"))

        let hostile = IDELanguageRunPolicy.stagingCleanupCommand(
            stagingRoot: "floe-ide-run/x",
            runToken: IDERunStagingLayout.sanitizedToken("ab'; rm -rf /;'"))
        #expect(hostile.contains("= abrm-rf ]"))
        #expect(!hostile.contains("'ab'"))
    }

    @Test func stagingCleanupOutcomeRequiresAProvenMarker() {
        #expect(IDELanguageRunPolicy.stagingCleanupOutcome(stdout: "floe-ide-cleanup-removed", exitCode: 0) == .removed)
        #expect(IDELanguageRunPolicy.stagingCleanupOutcome(stdout: "floe-ide-cleanup-skipped", exitCode: 0) == .skippedForeignData)
        #expect(IDELanguageRunPolicy.stagingCleanupOutcome(stdout: "floe-ide-cleanup-removed", exitCode: 1)
                == .unconfirmed(detail: "exit 1"))
        #expect(IDELanguageRunPolicy.stagingCleanupOutcome(stdout: "unexpected", exitCode: 0)
                == .unconfirmed(detail: "exit 0"))
    }
}
#endif
