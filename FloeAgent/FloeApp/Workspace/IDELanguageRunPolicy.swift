// SPDX-License-Identifier: MPL-2.0
//
// IDELanguageRunPolicy — the pure, executable-or-not decision layer for the
// IDE Run button. It never talks to a runtime, terminal or SSH host: it maps a
// workspace-relative source file plus an explicit user selection to a typed
// plan. Dispatch, snapshot saving and executable probes happen in the
// controller so this table stays unit-testable without a device or network.
//
// Honesty rules encoded here:
// * Only shipped on-device interpreters (CPython, Node, the local shell and an
//   installed signed WASI `lua`) are local targets. Rust/Swift/C/C++/PHP/Ruby/
//   Go/Java/Kotlin are remote-only and require an explicitly selected
//   configured SSH host plus a real `command -v` probe performed by the caller.
// * A remote plan always executes the staged copy of the just-saved file:
//   the controller stages exact bytes into a run-owned directory below the
//   daemon cloud-workspace root (`IDERunSourceStaging`), proves the landing
//   revision by read-back, and only then dispatches the command built here.
//   The plan therefore never references an unverified remote checkout.
// * Argument vectors are built as arrays and quoted element-by-element; no
//   user string is ever concatenated into a command line.
//
// The run-owned staging directory is removed by the remote command itself
// through a status-preserving trap, and only while its ownership marker
// still carries this run's token.

import Foundation

// MARK: - Languages

enum IDELanguageRunSurface: String, Sendable, Equatable {
    /// The language is interpreted on device by a shipped runtime.
    case localInterpreter
    /// The language can only run on an explicitly selected configured SSH host.
    case remoteOnly
}

enum IDELanguageLocalInterpreter: String, Sendable, Equatable, CaseIterable {
    case python3
    case node
    case shell
    case lua

    var command: String {
        switch self {
        case .python3: return "python3"
        case .node: return "node"
        case .shell: return "sh"
        case .lua: return "lua"
        }
    }
}

/// One language row. `runTemplate`/`compileTemplate` use the `{source}` and
/// `{output}` placeholders; substitution always produces an argument array.
struct IDELanguageRunDefinition: Sendable, Equatable {
    let id: String
    let displayName: String
    let surface: IDELanguageRunSurface
    let localInterpreter: IDELanguageLocalInterpreter?
    /// Executable probed on a remote host (`command -v`).
    let remoteTool: String
    let compileTemplate: [String]?
    let runTemplate: [String]
    let executableName: String?
}

// MARK: - Inputs

struct IDELanguageRunHost: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
}

/// A configured project → remote-host mapping. Staged runs never execute
/// from it; it is surfaced in the sheet as context about an existing full
/// project mirror on the selected host.
struct IDELanguageRunRemoteMapping: Sendable, Equatable {
    let hostID: UUID
    let workingDirectory: String
}

/// One candidate cloud-workspace link considered for a remote mapping. The
/// caller resolves `belongsToPinnedWorkspace` against the pinned workspace root
/// (marker directory exists below that root), so a link loaded for a different
/// workspace can never be selected merely because the host matches.
struct IDELanguageRunMappingCandidate: Sendable, Equatable {
    let name: String
    let hostID: UUID
    let remotePath: String
    let belongsToPinnedWorkspace: Bool
}

/// Identity captured at the start of dispatch. `sourceSHA256` is nil for the
/// structural check (before the snapshot is saved) and set for the revision
/// re-check performed after save and after the remote probe.
struct IDELanguageRunPinnedContext: Sendable, Equatable {
    let workspaceID: UUID?
    let rootPath: String?
    let relativePath: String
    let sourceSHA256: String?
}

enum IDELanguageRunContextDrift: Sendable, Equatable {
    case workspace
    case root
    case path
    case sourceRevision
}

/// Identity of one dispatch attempt. `generation` increments for every new
/// dispatch, and `runToken` names the run-owned remote staging directory (and
/// its ownership marker). Every asynchronous completion, cleanup and status
/// write compares the generation it started with the controller's live
/// generation, so a delayed earlier attempt can neither overwrite newer state
/// nor remove a newer attempt's directory (the token differs, and the cleanup
/// command re-checks the marker before deleting anything).
struct IDELanguageRunAttempt: Sendable, Equatable {
    let generation: Int
    let runToken: String
}

struct IDELanguageRunSelection: Sendable, Equatable {
    enum Target: Sendable, Equatable, Hashable {
        case local
        case remote(hostID: UUID, hostName: String)
        /// A GitHub Actions run on the user's own repository. `ref` overrides
        /// the repository default branch; `workflowPath` selects an existing
        /// workflow, nil installs a Floe template on the run-owned branch.
        case githubActions(
            repository: GitHubActionsRepositorySelection,
            ref: String?,
            workflowPath: String?
        )

        var hostID: UUID? {
            if case .remote(let id, _) = self { return id }
            return nil
        }

        var hostName: String? {
            if case .remote(_, let name) = self { return name }
            return nil
        }

        var repository: GitHubActionsRepositorySelection? {
            if case .githubActions(let repository, _, _) = self { return repository }
            return nil
        }

        var gitHubActionsRef: String? {
            if case .githubActions(_, let ref, _) = self { return ref }
            return nil
        }

        var gitHubActionsWorkflowPath: String? {
            if case .githubActions(_, _, let path) = self { return path }
            return nil
        }
    }

    var target: Target

    init(target: Target = .local) {
        self.target = target
    }
}

struct IDELanguageRunCapabilities: Sendable, Equatable {
    var localInterpreters: Set<IDELanguageLocalInterpreter> = []
    /// Informational only: the configured project mapping for the selected
    /// host. Staged runs never execute from it; the sheet shows it so the
    /// user knows a full project mirror exists.
    var mapping: IDELanguageRunRemoteMapping?
}

struct IDELanguageRunRequest: Sendable, Equatable {
    let relativePath: String
    let selection: IDELanguageRunSelection
    let capabilities: IDELanguageRunCapabilities
    /// Short opaque token (for example a UUID prefix) used to name the
    /// run-owned remote temporary directory.
    let runToken: String
}

// MARK: - Outputs

enum IDELanguageRunUnavailableReason: Sendable, Equatable {
    case noActiveFile
    case invalidPath
    case unsupportedFileType(ext: String)
    case localRuntimeMissing(interpreter: IDELanguageLocalInterpreter)
    case remoteLanguageNeedsHost(tool: String)
    case noRemoteHostConfigured
    case conflictUnresolved
    case snapshotSaveFailed
    /// GitHub Actions target without a connected GitHub account or a selected
    /// repository.
    case gitHubNotConnected
    case noGitHubRepositorySelected
    /// The selected repository has no Floe template for this language/role.
    case gitHubActionsUnsupported(language: String)
    /// The caller named a workflow outside `.github/workflows`.
    case invalidWorkflowPath
}

/// One verified remote execution of the staged current file. All remote
/// paths are daemon-cloud-root-relative; the shell forms expand `$HOME`
/// against the daemon's default root and the pre-flight visibility probe
/// proves the staged file is actually reachable there before dispatch.
struct IDELanguageRunRemoteCommand: Sendable, Equatable {
    let languageID: String
    let hostID: UUID
    let hostName: String
    /// Sanitized run token naming the run-owned staging directory and its
    /// ownership marker.
    let runToken: String
    /// Daemon-relative run-owned staging root (`floe-ide-run/<token>`).
    let stagingRoot: String
    /// Daemon-relative staged source path.
    let stagedSourcePath: String
    /// Daemon-relative directory the run `cd`s into (staged source parent).
    let workingDirectory: String
    /// Basename handed to the templates as `{source}`.
    let sourceFileName: String
    /// Executable probed on the remote host (`command -v`).
    let probeTool: String
    /// `command -v <tool>` run through the verified SSH command service.
    var probeCommand: String { "command -v " + IDELanguageRunPolicy.shellQuote(probeTool) }
    /// Compiler argument vector, or nil for interpreted languages.
    let compileCommand: [String]?
    let runCommand: [String]

    /// Pre-flight check executed over SSH after staging: the staged source
    /// must be visible at the daemon's default cloud root, otherwise the
    /// daemon runs with a customized root and the run is refused instead of
    /// guessing an absolute path.
    var visibilityProbeCommand: String {
        "test -f \(IDELanguageRunPolicy.homeQuoted(stagedSourcePath)) && printf %s "
            + IDELanguageRunPolicy.shellQuote(IDERunStagingLayout.visibilityMarker)
    }

    /// The full remote line executed through the bounded SSH command
    /// service. Every element is quoted, and the compile/run chain is joined
    /// with `&&` so a failed compile never executes a stale binary.
    ///
    /// The subshell (1) refuses to run unless the ownership marker still
    /// carries this run's token, (2) installs `EXIT/HUP/INT/TERM` traps that
    /// remove only the run-owned staging root — and only while the marker
    /// still matches — and (3) preserves the program's exit status through
    /// cleanup. A naive trailing `; rm -rf` would discard the status and
    /// could remove another run's directory.
    var shellCommand: String {
        let root = IDELanguageRunPolicy.homeQuoted(stagingRoot)
        let workdir = IDELanguageRunPolicy.homeQuoted(workingDirectory)
        let marker = "\"$s/\(IDERunStagingLayout.markerName)\""
        let ownership = "[ \"$(cat \(marker) 2>/dev/null)\" = \"\(runToken)\" ]"
        var chain = "cd \(workdir)"
        if let compileCommand {
            chain += " && " + IDELanguageRunPolicy.shellCommand(compileCommand)
        }
        chain += " && " + IDELanguageRunPolicy.shellCommand(runCommand)
        return "s=\(root); ( if \(ownership); then "
            + "trap 'x=$?; if \(ownership); then rm -rf \"$s\"; fi; exit $x' EXIT HUP INT TERM; "
            + "\(chain); else echo 'floe: staging ownership marker mismatch' >&2; exit 1; fi )"
    }
}

enum IDELanguageRunPlan: Sendable, Equatable {
    case local(languageID: String, argv: [String], mechanism: IDELanguageRunMechanism)
    case remote(IDELanguageRunRemoteCommand, mechanism: IDELanguageRunMechanism)
    case githubActions(IDEGitHubActionsRunPlan, mechanism: IDELanguageRunMechanism)
    case unavailable(IDELanguageRunUnavailableReason)

    var languageID: String? {
        switch self {
        case .local(let id, _, _): return id
        case .remote(let command, _): return command.languageID
        case .githubActions(let plan, _): return plan.languageID
        case .unavailable: return nil
        }
    }

    var mechanism: IDELanguageRunMechanism? {
        switch self {
        case .local(_, _, let mechanism): return mechanism
        case .remote(_, let mechanism): return mechanism
        case .githubActions(_, let mechanism): return mechanism
        case .unavailable: return nil
        }
    }

    /// The exact line that will be sent into the terminal, or a readable
    /// dispatch summary for a GitHub Actions run, or nil when unavailable.
    var commandLine: String? {
        switch self {
        case .local(_, let argv, _): return IDELanguageRunPolicy.shellCommand(argv)
        case .remote(let command, _): return command.shellCommand
        case .githubActions(let plan, _):
            return "workflow_dispatch \(plan.workflowPath ?? "Floe template") @ \(plan.repository.fullName) ref=\(plan.ref)"
        case .unavailable: return nil
        }
    }

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// Distinguishes the on-device interpreter, a remote interpreted run, a
/// remote compile-then-run and a GitHub-hosted cloud build so the sheet never
/// presents cross-compilation as a local build.
enum IDELanguageRunMechanism: String, Sendable, Equatable {
    case localInterpreter
    case remoteInterpreter
    case remoteCompileRun
    /// A GitHub-hosted runner builds or checks the snapshot. The output is a
    /// Linux/macOS artifact; it is never an iOS-executable binary and the
    /// device cannot run it directly.
    case gitHubActionsCloud

    var isCrossCompile: Bool { self == .remoteCompileRun || self == .gitHubActionsCloud }
    var isRemote: Bool { self != .localInterpreter }
    var isCloudHosted: Bool { self == .gitHubActionsCloud }
}

enum IDELanguageRunDispatchDecision: Sendable, Equatable {
    case dispatch
    case blocked(IDELanguageRunUnavailableReason)
}

// MARK: - Policy

enum IDELanguageRunPolicy {
    /// Extension → language. Only the table entries below are runnable.
    static let definitions: [String: IDELanguageRunDefinition] = {
        var table: [String: IDELanguageRunDefinition] = [:]
        func add(
            _ id: String,
            _ name: String,
            ext: [String],
            surface: IDELanguageRunSurface,
            interpreter: IDELanguageLocalInterpreter?,
            remoteTool: String,
            compile: [String]? = nil,
            run: [String],
            executableName: String? = nil
        ) {
            let definition = IDELanguageRunDefinition(
                id: id,
                displayName: name,
                surface: surface,
                localInterpreter: interpreter,
                remoteTool: remoteTool,
                compileTemplate: compile,
                runTemplate: run,
                executableName: executableName
            )
            for key in ext { table[key] = definition }
        }

        add("python", "Python", ext: ["py"], surface: .localInterpreter, interpreter: .python3,
            remoteTool: "python3", run: ["python3", "{source}"])
        add("javascript", "JavaScript", ext: ["js", "mjs", "cjs"], surface: .localInterpreter, interpreter: .node,
            remoteTool: "node", run: ["node", "{source}"])
        add("shell", "Shell", ext: ["sh", "bash", "zsh"], surface: .localInterpreter, interpreter: .shell,
            remoteTool: "sh", run: ["sh", "{source}"])
        add("lua", "Lua", ext: ["lua"], surface: .localInterpreter, interpreter: .lua,
            remoteTool: "lua", run: ["lua", "{source}"])

        add("rust", "Rust", ext: ["rs"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "rustc", compile: ["rustc", "{source}", "-o", "{output}"],
            run: ["{output}"], executableName: "program")
        add("swift", "Swift", ext: ["swift"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "swiftc", compile: ["swiftc", "{source}", "-o", "{output}"],
            run: ["{output}"], executableName: "program")
        add("c", "C", ext: ["c"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "cc", compile: ["cc", "{source}", "-o", "{output}"],
            run: ["{output}"], executableName: "program")
        add("cpp", "C++", ext: ["cc", "cpp", "cxx"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "c++", compile: ["c++", "{source}", "-o", "{output}"],
            run: ["{output}"], executableName: "program")
        add("php", "PHP", ext: ["php"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "php", run: ["php", "{source}"])
        add("ruby", "Ruby", ext: ["rb"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "ruby", run: ["ruby", "{source}"])
        add("go", "Go", ext: ["go"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "go", run: ["go", "run", "{source}"])
        add("java", "Java", ext: ["java"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "java", run: ["java", "{source}"])
        add("kotlin", "Kotlin", ext: ["kt", "kts"], surface: .remoteOnly, interpreter: nil,
            remoteTool: "kotlinc", compile: ["kotlinc", "{source}", "-include-runtime", "-d", "{output}"],
            run: ["java", "-jar", "{output}"], executableName: "program.jar")
        return table
    }()

    static func definition(forRelativePath path: String) -> IDELanguageRunDefinition? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return definitions[ext]
    }

    // MARK: Plan

    static func plan(_ request: IDELanguageRunRequest) -> IDELanguageRunPlan {
        let path = request.relativePath
        guard !path.isEmpty, isSafeWorkspaceRelativePath(path) else {
            return .unavailable(path.isEmpty ? .noActiveFile : .invalidPath)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard let definition = definitions[ext] else {
            return .unavailable(.unsupportedFileType(ext: ext))
        }

        switch request.selection.target {
        case .local:
            return localPlan(definition, path: path, capabilities: request.capabilities)
        case .remote(let hostID, let hostName):
            return remotePlan(
                definition,
                path: path,
                hostID: hostID,
                hostName: hostName,
                runToken: request.runToken
            )
        case .githubActions(let repository, let ref, let workflowPath):
            return gitHubActionsPlan(
                definition,
                path: path,
                repository: repository,
                ref: ref,
                workflowPath: workflowPath
            )
        }
    }

    /// Role of one language on GitHub's runners: compiled languages get a
    /// build template, interpreted languages get a lint/check template.
    static func gitHubActionsRole(for languageID: String) -> IDEGitHubActionsRunRole? {
        switch languageID {
        case "rust", "swift", "c", "cpp", "go", "java", "kotlin":
            return .build
        case "python", "javascript", "shell", "lua", "php", "ruby":
            return .lintTest
        default:
            return nil
        }
    }

    /// The GitHub Actions plan for one language. A user-supplied workflow path
    /// is validated and used verbatim; with no workflow, the catalog must have
    /// a Floe template for this language/role or the target is unavailable —
    /// the plan never invents a build recipe.
    private static func gitHubActionsPlan(
        _ definition: IDELanguageRunDefinition,
        path: String,
        repository: GitHubActionsRepositorySelection,
        ref: String?,
        workflowPath: String?
    ) -> IDELanguageRunPlan {
        guard repository.id != 0, !repository.fullName.isEmpty else {
            return .unavailable(.noGitHubRepositorySelected)
        }
        let selectedWorkflow: String?
        if let workflowPath {
            let trimmed = workflowPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard IDEGitHubActionsWorkflowCatalog.isWorkflowPath(trimmed) else {
                return .unavailable(.invalidWorkflowPath)
            }
            selectedWorkflow = trimmed
        } else {
            selectedWorkflow = nil
        }
        guard let role = gitHubActionsRole(for: definition.id) else {
            return .unavailable(.gitHubActionsUnsupported(language: definition.id))
        }
        let platform: GitHubActionsRunnerPlatform = definition.id == "swift" ? .macOS : .linux
        let template = IDEGitHubActionsWorkflowCatalog.template(
            languageID: definition.id, role: role, platform: platform
        )
        // When no workflow is selected a template is mandatory; otherwise the
        // build recipe is unknown and the target must refuse.
        if selectedWorkflow == nil, template == nil {
            return .unavailable(.gitHubActionsUnsupported(language: definition.id))
        }
        let baseRef = (ref?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? ref!.trimmingCharacters(in: .whitespacesAndNewlines)
            : repository.defaultBranch
        let inputs: [String: String] = selectedWorkflow == nil ? ["target_file": path] : [:]
        let plan = IDEGitHubActionsRunPlan(
            languageID: definition.id,
            role: role,
            repository: repository,
            ref: baseRef,
            targetFile: path,
            workflowPath: selectedWorkflow,
            expectedArtifactName: selectedWorkflow == nil ? template?.expectedArtifactName : nil,
            runnerPlatform: platform,
            dispatchInputs: inputs,
            installsTemplate: selectedWorkflow == nil
        )
        return .githubActions(plan, mechanism: .gitHubActionsCloud)
    }

    private static func localPlan(
        _ definition: IDELanguageRunDefinition,
        path: String,
        capabilities: IDELanguageRunCapabilities
    ) -> IDELanguageRunPlan {
        guard let interpreter = definition.localInterpreter else {
            return .unavailable(.remoteLanguageNeedsHost(tool: definition.remoteTool))
        }
        guard capabilities.localInterpreters.contains(interpreter) else {
            return .unavailable(.localRuntimeMissing(interpreter: interpreter))
        }
        let argv = substitute(definition.runTemplate, source: path, output: nil)
        return .local(languageID: definition.id, argv: argv, mechanism: .localInterpreter)
    }

    /// Builds the staged remote execution for the explicit user-selected
    /// host. The command operates exclusively on the run-owned staging copy
    /// that `IDERunSourceStager` writes and verifies before dispatch; it
    /// never names an unverified remote checkout or a guessed workdir.
    private static func remotePlan(
        _ definition: IDELanguageRunDefinition,
        path: String,
        hostID: UUID,
        hostName: String,
        runToken: String
    ) -> IDELanguageRunPlan {
        guard let staged = IDERunStagingLayout.stagedPaths(workspaceRelativePath: path, runToken: runToken) else {
            return .unavailable(.invalidPath)
        }
        // Compile artifacts land beside the staged source inside the
        // run-owned staging root, so the trap's single `rm -rf "$s"` removes
        // exactly this run's artifacts and nothing else.
        let output = definition.compileTemplate == nil
            ? nil
            : "./" + (definition.executableName ?? "program")
        let compileCommand = definition.compileTemplate.map {
            substitute($0, source: staged.sourceFileName, output: output)
        }
        let runCommand = substitute(definition.runTemplate, source: staged.sourceFileName, output: output)
        if let compileCommand, !isValidArgumentVector(compileCommand) {
            return .unavailable(.invalidPath)
        }
        guard isValidArgumentVector(runCommand) else {
            return .unavailable(.invalidPath)
        }
        let command = IDELanguageRunRemoteCommand(
            languageID: definition.id,
            hostID: hostID,
            hostName: hostName,
            runToken: staged.runToken,
            stagingRoot: staged.stagingRoot,
            stagedSourcePath: staged.stagedSourcePath,
            workingDirectory: staged.workingDirectory,
            sourceFileName: staged.sourceFileName,
            probeTool: definition.compileTemplate == nil ? definition.remoteTool : compileTool(definition),
            compileCommand: compileCommand,
            runCommand: runCommand
        )
        return .remote(command, mechanism: compileCommand == nil ? .remoteInterpreter : .remoteCompileRun)
    }

    private static func compileTool(_ definition: IDELanguageRunDefinition) -> String {
        definition.compileTemplate?.first ?? definition.remoteTool
    }

    // MARK: Dispatch gate

    /// The single pure gate the controller consults after saving the snapshot.
    /// A dirty/conflicted editor or a failed save must never dispatch.
    static func dispatchDecision(
        plan: IDELanguageRunPlan,
        snapshotSaved: Bool,
        hasUnresolvedConflict: Bool
    ) -> IDELanguageRunDispatchDecision {
        if hasUnresolvedConflict { return .blocked(.conflictUnresolved) }
        if !snapshotSaved { return .blocked(.snapshotSaveFailed) }
        if case .unavailable(let reason) = plan { return .blocked(reason) }
        return .dispatch
    }

    // MARK: Quoting

    /// POSIX single-quote quoting for exactly one argument. Safe characters
    /// pass through unchanged; everything else is single-quoted with embedded
    /// quotes escaped as `'\''`. Newlines are preserved inside quotes but the
    /// caller rejects control characters in paths.
    static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/=+:,@%")
        if value.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Joins an argument vector into one shell line, quoting every element.
    static func shellCommand(_ argv: [String]) -> String {
        argv.map(shellQuote).joined(separator: " ")
    }

    // MARK: Helpers

    static func substitute(_ template: [String], source: String, output: String?) -> [String] {
        template.map { token in
            switch token {
            case "{source}": return source
            case "{output}": return output ?? ""
            default: return token
            }
        }
    }

    /// Rejects absolute paths, parent traversal, empty components and control
    /// characters. The IDE active path is already workspace-relative; this is
    /// defense in depth so a crafted value cannot redirect a run.
    static func isSafeWorkspaceRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Shell form of a daemon-root-relative path: `"$HOME"/.floe/...` so the
    /// remote shell expands the home directory while the remainder stays
    /// quoted. Concatenating an expanding segment with a quoted segment is
    /// exactly how POSIX shells compose words.
    static func homeQuoted(_ daemonRelativePath: String) -> String {
        "\"$HOME\"/" + IDERunStagingLayout.daemonRootHomeRelative + "/" + shellQuote(daemonRelativePath)
    }

    // MARK: WASM interpreter identity

    /// The canonical signed-catalog command for an interpreter, when it differs
    /// from the shell alias the run template invokes. The shell registry
    /// registers the canonical `floe-*` command and additionally aliases it to
    /// the bare name (`floe-lua` → `lua`), so availability must be resolved
    /// against the catalog identity, not the alias.
    static func catalogCommand(for interpreter: IDELanguageLocalInterpreter) -> String? {
        switch interpreter {
        case .lua: return "floe-lua"
        case .python3, .node, .shell: return nil
        }
    }

    /// Returns the catalog command that provides `interpreter`, preferring the
    /// canonical `floe-*` identity but still accepting a catalog that exposes
    /// the bare alias directly. Nil when the catalog has no such entry.
    static func matchingWasmEntryCommand(
        for interpreter: IDELanguageLocalInterpreter,
        catalogCommands: [String]
    ) -> String? {
        var candidates = [interpreter.command]
        if let canonical = catalogCommand(for: interpreter) { candidates.append(canonical) }
        // Canonical identity wins when both are present.
        for candidate in candidates.reversed() where catalogCommands.contains(candidate) {
            return candidate
        }
        return nil
    }

    // MARK: Remote mapping identity

    /// Selects a project remote mapping for `activePath` from the links that
    /// actually belong to the pinned workspace. Only a link whose `Cloud/<name>`
    /// marker owns the active file is eligible, and an ambiguous set is
    /// rejected instead of guessing another project's remote path by host.
    static func selectRemoteMapping(
        candidates: [IDELanguageRunMappingCandidate],
        hostID: UUID,
        activePath: String
    ) -> IDELanguageRunRemoteMapping? {
        let eligible = candidates.filter {
            $0.belongsToPinnedWorkspace
                && $0.hostID == hostID
                && !$0.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !eligible.isEmpty else { return nil }
        let matches = eligible.filter { isUnderCloudMarker(activePath, name: $0.name) }
        guard matches.count == 1 else { return nil }
        let link = matches[0]
        return IDELanguageRunRemoteMapping(
            hostID: hostID,
            workingDirectory: link.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func isUnderCloudMarker(_ relativePath: String, name: String) -> Bool {
        let prefix = "Cloud/\(name)"
        return relativePath == prefix || relativePath.hasPrefix(prefix + "/")
    }

    // MARK: Dispatch identity re-check

    /// Compares the identity captured before a dispatch await with the identity
    /// observed after it. A changed workspace, root, active file or saved
    /// source revision aborts before any command is dispatched.
    static func contextDrift(
        initial: IDELanguageRunPinnedContext,
        current: IDELanguageRunPinnedContext
    ) -> IDELanguageRunContextDrift? {
        if initial.workspaceID != current.workspaceID { return .workspace }
        if initial.rootPath != current.rootPath { return .root }
        if initial.relativePath != current.relativePath { return .path }
        if initial.sourceSHA256 != current.sourceSHA256, initial.sourceSHA256 != nil {
            return .sourceRevision
        }
        return nil
    }

    /// A command vector is dispatched only when it is non-empty, every element
    /// is non-empty and no element carries control characters.
    static func isValidArgumentVector(_ argv: [String]) -> Bool {
        guard !argv.isEmpty else { return false }
        return argv.allSatisfy { element in
            !element.isEmpty && !element.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        }
    }

    // MARK: Attempt identity

    /// True while `attempt` is still the controller's live dispatch attempt.
    /// A completion or cleanup handler that fails this check must not mutate
    /// observable state.
    static func isCurrentAttempt(_ attempt: IDELanguageRunAttempt, generation: Int) -> Bool {
        attempt.generation == generation
    }

    // MARK: Source revision proof

    /// The bytes about to be staged must equal the revision captured right
    /// after the snapshot save. A missing pinned revision can never match:
    /// without a known revision there is nothing to prove the executed source
    /// against, so this fails closed.
    static func sourceRevisionMatches(pinnedSHA256: String?, observedSHA256: String) -> Bool {
        guard let pinnedSHA256, !pinnedSHA256.isEmpty, !observedSHA256.isEmpty else { return false }
        return pinnedSHA256 == observedSHA256
    }

    // MARK: Marker-guarded pre-execution cleanup

    /// Cleanup for a run that aborted after staging but before its execution
    /// trap was installed. It removes only the exact run-owned path, and only
    /// while the ownership marker still carries this attempt's token; foreign
    /// content is never deleted. The command prints which branch it took so the
    /// caller keeps the honest outcome instead of assuming success.
    static func stagingCleanupCommand(stagingRoot: String, runToken: String) -> String {
        let root = homeQuoted(stagingRoot)
        let marker = "\"$s/\(IDERunStagingLayout.markerName)\""
        let ownership = "[ \"$(cat \(marker) 2>/dev/null)\" = \(shellQuote(runToken)) ]"
        return "s=\(root); if \(ownership); then rm -rf \"$s\" && printf %s "
            + "\(shellQuote(IDERunStagingLayout.cleanupRemovedMarker)); "
            + "else printf %s \(shellQuote(IDERunStagingLayout.cleanupSkippedMarker)); fi"
    }

    /// Parses the cleanup command's bounded result. A non-zero exit or a reply
    /// without a known marker is `unconfirmed`, never a silent success.
    static func stagingCleanupOutcome(stdout: String, exitCode: Int32) -> IDERunStagingCleanupOutcome {
        if exitCode == 0 {
            if stdout.contains(IDERunStagingLayout.cleanupRemovedMarker) { return .removed }
            if stdout.contains(IDERunStagingLayout.cleanupSkippedMarker) { return .skippedForeignData }
        }
        return .unconfirmed(detail: "exit \(exitCode)")
    }
}
