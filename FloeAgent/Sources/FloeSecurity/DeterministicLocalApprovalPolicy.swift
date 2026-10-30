// FloeSecurity — Deterministic local approval carve-outs.
//
// Contract (user policy, 2026-10-15):
//
// - Ordinary document editing that the runtime can POSITIVELY resolve — the
//   typed mutable-target contract (FloeTools `TypedMutationContract`) pinned
//   this action's REAL mutable outputs and none of them is inside a Git
//   worktree — executes under the task's existing workspace/task permission
//   WITHOUT a per-edit interactive review. This covers the whole ordinary
//   workflow for the registered families: save/export/save-as copies and
//   in-place edits for PDF (edit/fillForm/export/render), Office
//   (updateText/create*/apply/export/propose/replaceImage), CAD
//   (create/apply/save/import/propose/export), media.project
//   (propose/apply/export) and the video/audio/image editors. Read-only
//   sources are never classified (a repository read is not a repository
//   write); repository targets, redirected/mixed write extents, anything the
//   runtime could not pin, PDF raster/flatten/OCR/password consents and
//   explicit destructive-overwrite flags keep the existing approval policy.
//   The AUDITED read/draft actions of those same mixed tools (office
//   capabilities/query/read/errors/preview/propose, media
//   capabilities/read/propose, CAD read/query/measure/preview/propose etc.)
//   are covered by `isOrdinaryDocumentReadOrDraft`: they write no original
//   bytes (drafts write internal proposal state only), so they never need a
//   per-step card — the actual commit keeps its review.
// - Native 3D document work (user policy, 2026-10-30) also skips review
//   when the exact resolved .floecad document is inside a repository. This
//   exception covers the document itself, not an unrelated output or shared
//   library. Task/file ownership and revision-bound commit checks still run.
// - Routine commands in a resolved local Linux guest that are either
//   strictly read-only or a bounded build/test/format form do not need
//   repeated review. This is the user's REDUCED-REVIEW policy for the local
//   guest, NOT a sandbox and NOT a claim that the guest owns the data or is
//   disposable (shared/project guests may be reused): build/test/run commands
//   execute project code, so they are admitted only for the guest environment
//   class and (for the build tier) only for a positively resolved
//   non-repository workspace. The native host, remote hosts, unknown
//   environments and repository workspaces keep the existing policy, and
//   deletion/reset/persistent-data safeguards are unchanged.
// - Strictly read-only remote SSH diagnostics (no file-content readers)
//   do not need repeated review; remote changes keep the existing policy.
//
// NEVER covered here: file/document deletion, destructive non-recoverable
// overwrite, PDF rasterization/flatten/OCR and credential-bound PDF
// operations, managed package installation, credential access, external
// sends, privilege elevation, VM lifecycle, any call whose write extent the
// runtime did not pin, and anything the classifier cannot account for.
//
// The carve-outs issue a SINGLE-USE allow scope. They never mint a reusable
// or task-wide grant and never widen an existing one: the next call is
// re-decided from its own resolved targets and environment, so an authorized
// call can never authorize a different tool, another environment, another
// task, or an unresolved extent.

import Foundation

/// The deterministic local carve-outs consulted by the built-in policies
/// BEFORE their normal decision path. A `nil` decision means "not covered":
/// the caller must continue with the existing policy unchanged.
public enum DeterministicLocalApprovalPolicy {

    /// Exact deterministic allow for this call, or nil when the carve-out
    /// does not apply.
    public static func allowDecision(for action: ProposedAction) -> ApprovalDecision? {
        guard let scope = allowedScope(for: action) else { return nil }
        return .allow(scope: scope, expiresAt: nil)
    }

    /// True when this call is deterministically allowed WITHOUT human or
    /// model review.
    public static func isExempt(_ action: ProposedAction) -> Bool {
        allowedScope(for: action) != nil
    }

    static func allowedScope(for action: ProposedAction) -> ApprovalScope? {
        // Managed package acquisition keeps its dedicated source review.
        guard !action.isSoftwareInstallRequest else { return nil }
        guard isOrdinaryNativeCADWork(action)
            || isOrdinaryDocumentEdit(action)
            || isOrdinaryDocumentReadOrDraft(action)
            || isLocalGuestRoutineCommand(action)
            || isRemoteReadOnlyDiagnostic(action) else { return nil }
        return AutomaticApprovalPolicyScope.scope(for: action.toolCall)
    }

    /// Native 3D editing is an ordinary no-review feature, including when
    /// the document is kept in a repository. This changes review routing only:
    /// task ownership, containment and revision-bound commits still execute.
    /// External exports and shared-library writes retain their own policy.
    public static func isOrdinaryNativeCADWork(_ action: ProposedAction) -> Bool {
        guard case .local = action.toolCall.scope,
              action.toolCall.toolName == "cad.document",
              let arguments = action.argumentObject else { return false }
        // Static capability discovery does not require an existing document.
        if arguments["action"] as? String == "capabilities" {
            return isOrdinaryDocumentReadOrDraft(action)
        }
        guard let context = action.trustedContext, !context.hasUnresolvedExtent,
              let path = arguments["path"] as? String,
              (path as NSString).pathExtension.lowercased() == "floecad" else { return false }
        if isOrdinaryDocumentReadOrDraft(action) { return true }
        guard let operation = arguments["action"] as? String,
              ["create", "apply", "three_d_apply", "save", "import",
               "material", "parameters", "animation"].contains(operation),
              context.typedContractCovered,
              context.mutableTargetPaths.count == 1 else { return false }
        if let resolved = context.nativeCADDocumentPath {
            // A Canvas-relative path maps to its staged document, not the
            // task root. Only the runtime can supply this resolved identity.
            return (resolved as NSString).pathExtension.lowercased() == "floecad"
                && URL(fileURLWithPath: resolved).standardizedFileURL.resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: context.mutableTargetPaths[0])
                        .standardizedFileURL.resolvingSymlinksInPath().path
        }
        // The trusted typed target must be precisely this document, rather
        // than a model-claimed safe flag or an unrelated output/library file.
        let target: URL
        if (path as NSString).isAbsolutePath {
            target = URL(fileURLWithPath: path)
        } else if let root = context.workspaceRootPath {
            target = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        } else { return false }
        return target.standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: context.mutableTargetPaths[0])
                .standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Ordinary document reads and drafts

    /// True for an AUDITED read-only or draft-only action of an ordinary
    /// document/media tool (`OrdinaryDocumentActionProfile`, compiled in this
    /// module from the frozen tool implementations):
    ///
    /// - `.readOnly` (office capabilities/query/read/errors/preview, media
    ///   capabilities/read, CAD capabilities/read/query/locate/measure/check/
    ///   status/three_d_snapshot/three_d_measure/preview, SVG inspect) writes
    ///   neither original bytes nor draft state, so it never needs an edit
    ///   card — including when the inspected document happens to live inside
    ///   a Git worktree: inspecting repository content writes no code, and
    ///   the actual commit still keeps the existing review.
    /// - `.draftOnly` (office/media/CAD propose, three_d_propose) writes only
    ///   internal proposal state. The declared document must still RESOLVE
    ///   for the runtime (an unresolved extent — e.g. a media project whose
    ///   store root is missing, or a draft with no declared path — keeps the
    ///   existing policy, exactly like the write contract). The commit that
    ///   may follow is classified separately: a repository original keeps its
    ///   card on apply/export.
    ///
    /// The role is resolved from the compiled table on the tool name and the
    /// action value the tool itself validates; a model-authored
    /// `readOnly`/`safe` flag is not consulted and cannot create a role. Only
    /// local (native) calls qualify: host-scoped/remote calls keep the
    /// existing policy.
    public static func isOrdinaryDocumentReadOrDraft(_ action: ProposedAction) -> Bool {
        guard case .local = action.toolCall.scope else { return false }
        guard let role = OrdinaryDocumentActionProfile.role(
            forToolName: action.toolCall.toolName,
            argumentsJSON: action.toolCall.argumentsJSON
        ) else { return false }
        switch role {
        case .readOnly:
            return true
        case .draftOnly:
            // Drafts write no original bytes, but a draft whose declared
            // document/target the runtime could not pin keeps the existing
            // policy (fail closed, same rule as the write contract).
            guard let context = action.trustedContext else { return false }
            return !context.hasUnresolvedExtent
        }
    }

    // MARK: - Ordinary document editing

    /// True for an ordinary document/media edit whose mutable write extent the
    /// runtime POSITIVELY pinned through the typed mutable-target contract
    /// (single source of truth, FloeTools `TypedMutationContract`):
    ///
    /// - the contract declares this tool+action as an ordinary edit family
    ///   (`typedContractCovered` — PDF edit/fillForm/export/render, office
    ///   updateText/create*/apply/export/propose/replaceImage, cad.document
    ///   create/apply/save/import/propose/export, media.project
    ///   propose/apply/export, video/audio/image outputs);
    /// - at least one MUTABLE target was pinned and EVERY pinned target is
    ///   outside a Git worktree (one repository target fails the whole call);
    ///   read-only sources (pdf `inputPath`, office `imagePath`, video/audio
    ///   `input`/`mixPath`, a preserved source of an authorized copy) are not
    ///   classified, so reading repository content is not a repository write;
    /// - the call carries no unresolved extent (a required output missing or
    ///   unresolvable, a redirected/mixed batch the contract could not pin);
    /// - no PDF rasterization/flatten/OCR or credential-bound consent op and
    ///   no explicit destructive-overwrite flag (see the guard helpers).
    ///
    /// Explicit review stays available: a user-requested confirmation and the
    /// existing UI grant/apply paths are untouched — this carve-out only
    /// skips the per-edit CARD for ordinary resolved targets. Revision/hash
    /// binding, ownership, idempotency, replay and atomic commits live in the
    /// tools and hosts and are untouched here.
    public static func isOrdinaryDocumentEdit(_ action: ProposedAction) -> Bool {
        guard case .local = action.toolCall.scope,
              let context = action.trustedContext else { return false }
        guard context.typedContractCovered else { return false }
        guard !context.hasUnresolvedExtent,
              context.targetsAllOutsideRepository else { return false }
        guard !requiresPDFConsentReview(action) else { return false }
        guard !requiresDestructiveOverwriteReview(action) else { return false }
        return true
    }

    /// PDF rasterization/flattening/searchable-OCR and any use of the user's
    /// or owner's password require explicit consent review; they are never
    /// exempt (rasterizing/flattening invalidates signatures and OCR creates
    /// a derivative copy the user explicitly has to authorize).
    static func requiresPDFConsentReview(_ action: ProposedAction) -> Bool {
        guard action.toolCall.toolName == "document.pdf.edit",
              let object = try? JSONSerialization.jsonObject(
                  with: action.toolCall.argumentsJSON
              ) as? [String: Any] else { return false }
        if object["userPasswordRef"] != nil || object["ownerPasswordRef"] != nil { return true }
        let operations = object["operations"] as? [[String: Any]] ?? []
        return operations.contains {
            ["rasterRedact", "flattenAnnotations", "searchableOCR"].contains($0["action"] as? String ?? "")
        }
    }

    /// An EXPLICIT destructive-overwrite consent flag keeps the existing
    /// review: the user's no-card policy covers safe saves/exports to NEW
    /// local files, not replacing an existing file in place. (Tools that
    /// never overwrite without the flag — the default refusal — are
    /// unaffected.)
    static func requiresDestructiveOverwriteReview(_ action: ProposedAction) -> Bool {
        guard let object = action.argumentObject else { return false }
        switch action.toolCall.toolName {
        case "document.pdf.export", "video.interpolate", "video.superResolution":
            return object["overwrite"] as? Bool == true
        default:
            return false
        }
    }

    // MARK: - Local Linux guest routine commands

    /// True for a bounded routine command in a resolved local Linux guest.
    /// The environment class is resolved by the app from the real environment
    /// record (`executionBackend == .linuxVM`, not deleting) and travels in
    /// the frozen run configuration; shared/project guests are included and
    /// no ownership/disposability claim is made here. A native backend,
    /// remote host, unknown environment or unresolved context keeps the
    /// existing policy.
    public static func isLocalGuestRoutineCommand(_ action: ProposedAction) -> Bool {
        guard case .local = action.toolCall.scope else { return false }
        guard let context = action.trustedContext,
              context.environmentClass == .localLinuxVM else { return false }
        switch action.toolCall.toolName {
        case "exec.shell", "shell.open":
            break
        default:
            // `shell.exchange` feeds raw stdin into an already-open session
            // (possibly an interactive program), and background jobs carry a
            // nested target tool; both keep the existing policy. Interactive
            // `shell.open` without a command is not covered either.
            return false
        }
        guard let object = action.argumentObject,
              let command = firstShellCommand(in: object) else { return false }
        switch LocalGuestCommandClassifier.classify(command) {
        case .readOnly:
            // Strictly non-mutating forms only; see the classifier.
            return true
        case .routineWorkspace:
            // Build/test/format forms EXECUTE project code in the guest. They
            // are admitted only as the user's reduced-review policy for the
            // local guest, and only when the bounding workspace was positively
            // resolved outside a repository. This is neither a sandbox
            // guarantee nor a claim that the guest/data are disposable.
            return context.workspaceRootOutsideRepository
        case .other:
            return false
        }
    }

    private static func firstShellCommand(in object: [String: Any]) -> String? {
        for key in ["command", "script"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - Remote read-only diagnostics

    /// A strictly read-only `ssh.execute` command needs no repeated review on
    /// any host or host mode. Only known non-mutating diagnostic forms pass;
    /// file-content readers, interpreters, mutating flags (`date -s`, …),
    /// remote changes, interactive sessions, bootstrap and apply operations
    /// keep the existing policy and explicit grants.
    public static func isRemoteReadOnlyDiagnostic(_ action: ProposedAction) -> Bool {
        guard action.toolCall.toolName == "ssh.execute" else { return false }
        if case .local = action.toolCall.scope { return false }
        guard let object = action.argumentObject,
              let command = object["command"] as? String else { return false }
        return LocalGuestCommandClassifier.isClearlyReadOnlyDiagnostic(command)
    }

    /// Bounded command classification for the local guest and the read-only
    /// remote rule. Deterministic input filtering over the command
    /// text — the one field a command necessarily carries — never an intent
    /// claim from the model. This is NOT a shell parser and no verb is
    /// assumed read-only by name alone: every exempt form is either a known
    /// fixed diagnostic shape or a narrowed build/test form, and anything not
    /// fully accounted for is `.other`, which keeps the task's existing
    /// approval policy.
    enum LocalGuestCommandClassifier {
        enum Classification: Equatable {
            /// Strictly non-mutating inspection forms: no file, package,
            /// network or process mutation.
            case readOnly
            /// Bounded build/test/lint/format forms. These execute project
            /// code; the policy admits them only in a resolved local Linux
            /// guest and (for this tier) only outside a repository workspace.
            case routineWorkspace
            /// Everything else: the existing policy decides.
            case other
        }

        static let maximumCommandBytes = 16 * 1024

        static func classify(_ command: String) -> Classification {
            guard let clauses = splitClauses(command) else { return .other }
            if clauses.allSatisfy({ isReadOnlyClause($0) }) { return .readOnly }
            if clauses.allSatisfy({ isReadOnlyClause($0) || isRoutineWorkspaceClause($0) }) {
                return .routineWorkspace
            }
            return .other
        }

        static func isClearlyReadOnlyDiagnostic(_ command: String) -> Bool {
            guard let clauses = splitClauses(command) else { return false }
            return clauses.allSatisfy { isRemoteReadOnlyClause($0) }
        }

        // MARK: clause splitting

        /// Splits on `&&` only, after rejecting every other shell
        /// metacharacter. Returns nil for multi-line input: an embedded
        /// heredoc/newline cannot be classified by a bounded prefix filter.
        static func splitClauses(_ command: String) -> [String]? {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= maximumCommandBytes else { return nil }
            guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
            let forbidden = [";", "|", ">", "<", "`", "$", "&"]
            let carrier = trimmed.replacingOccurrences(of: "&&", with: "\u{1f}")
            for token in forbidden where carrier.contains(token) { return nil }
            let clauses = carrier
                .components(separatedBy: "\u{1f}")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !clauses.isEmpty, clauses.allSatisfy({ !$0.isEmpty }) else { return nil }
            return clauses
        }

        static func tokens(of clause: String) -> [String] {
            clause.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        /// Tokens that may never appear in an exempt clause: inline
        /// interpreters, shells, privilege elevation, network clients,
        /// schedulers, process/device/mount control and package managers. A
        /// clause containing one of these keeps the existing policy even when
        /// its verb is otherwise allowed.
        static let forbiddenTokens: Set<String> = [
            "sudo", "su", "doas", "runas", "pkexec",
            "eval", "exec", "source", "nohup", "setsid", "xargs",
            "sh", "bash", "zsh", "dash", "fish", "csh", "ksh",
            "perl", "ruby", "awk", "gawk", "mawk",
            "curl", "wget", "nc", "ncat", "netcat", "socat", "telnet", "ftp", "sftp",
            "ssh", "scp", "rsync",
            "systemctl", "launchctl", "crontab", "service", "journalctl",
            "kill", "pkill", "killall", "reboot", "shutdown", "halt", "poweroff",
            "mount", "umount", "fdisk", "parted", "mkfs", "dd", "shred", "truncate", "tee",
            "chmod", "chown", "chgrp", "chattr", "ln", "mkfifo",
            "apt", "apt-get", "dpkg", "pip", "pip3", "gem", "brew",
            "docker", "podman", "kubectl", "vagrant"
        ]

        static func containsForbiddenToken(_ values: [String]) -> Bool {
            values.contains { token in
                let lowered = token.lowercased()
                let base = lowered.split(separator: "=").first.map(String.init) ?? lowered
                return forbiddenTokens.contains(base) || forbiddenTokens.contains(lowered)
            }
        }

        /// Arguments that redirect a command's own output into a file or
        /// mutate in place. Rejected in EVERY exempt clause: a form that can
        /// write is not read-only, and the canonical resolver does not follow
        /// it.
        static func containsMutationFlag(_ values: [String]) -> Bool {
            values.dropFirst().contains { token in
                let lowered = token.lowercased()
                let flag = lowered.split(separator: "=").first.map(String.init) ?? lowered
                if flag == "-o" || flag == "--out" { return true }
                if flag.hasPrefix("--output") || flag.hasPrefix("--outfile") { return true }
                return ["--in-place", "--fix", "--write", "--set", "--delete", "--remove"]
                    .contains(flag)
            }
        }

        /// Absolute and home paths, and parent-directory escapes, are never
        /// exempt: inspection stays inside the workspace or the guest's own
        /// relative working directory.
        static func hasOutOfBoundsPath(_ values: [String]) -> Bool {
            values.dropFirst().contains {
                $0.hasPrefix("/") || $0.hasPrefix("~")
                    || $0 == ".." || $0.hasPrefix("../")
            }
        }

        /// Exact version-probe shapes only. `python3 script.py --version`
        /// EXECUTES the script, so any extra operand fails the whole clause.
        static func isVersionProbe(_ values: [String]) -> Bool {
            guard values.count == 2 else { return false }
            return values[1] == "--version" || values[1] == "-V"
        }

        /// `date` is a diagnostic only in its bare or format-only form; any
        /// flag can set the clock (`-s`, `--set`) or read a reference file.
        static func isDateDiagnostic(_ values: [String]) -> Bool {
            guard values.count >= 1, values[0] == "date" else { return false }
            return values.dropFirst().allSatisfy { $0.hasPrefix("+") && $0.count > 1 }
        }

        /// `hostname` is a diagnostic only with NO argument or with exactly
        /// one explicit read-only query flag. A positional operand or
        /// `-F/--file`/`-b` SETS the host name (a persistent mutation on the
        /// remote machine), so any other shape keeps the existing policy in
        /// both the local and the remote vocabulary.
        static func isHostnameDiagnostic(_ values: [String]) -> Bool {
            guard values.first == "hostname" else { return false }
            guard values.count > 1 else { return true }
            guard values.count == 2 else { return false }
            return ["-s", "-f", "-d", "-i", "-a",
                    "--short", "--fqdn", "--domain", "--ip-address"].contains(values[1])
        }

        // MARK: read-only vocabulary

        /// Strictly non-mutating inspection forms. Verbs whose common flags
        /// can write or execute (`sed`, `sort -o`, `uniq <in> <out>`,
        /// `diff --output`, `rg --pre`, `file -C`, `tree -o`, `column`) are
        /// deliberately absent rather than guessed safe.
        static func isReadOnlyClause(_ clause: String) -> Bool {
            let values = tokens(of: clause)
            guard let verb = values.first, !verb.contains("/"), !verb.hasPrefix("-") else { return false }
            guard !containsForbiddenToken(values),
                  !containsMutationFlag(values),
                  !hasOutOfBoundsPath(values) else { return false }
            switch verb {
            case "pwd", "id", "whoami", "uname", "uptime", "arch",
                 "printf", "echo", "which", "type",
                 "ls", "stat", "df", "du", "free", "vm_stat", "sw_vers", "systeminfo", "ver",
                 "cat", "head", "tail", "wc", "grep", "nl", "cut", "tr",
                 "sha256sum", "sha1sum", "md5sum", "shasum", "cksum",
                 "cmp", "basename", "dirname", "realpath", "readlink":
                return true
            case "hostname":
                return isHostnameDiagnostic(values)
            case "date":
                return isDateDiagnostic(values)
            case "command":
                return values.count == 2 && values[1] == "-v"
            case "find":
                // A read-only find: no deletion or command execution flags.
                let writeActions: Set<String> = [
                    "-delete", "-exec", "-execdir", "-ok", "-okdir",
                    "-fprint", "-fprint0", "-fls", "-fprintf"
                ]
                return !values.contains { writeActions.contains($0) }
            case "git":
                return isReadOnlyGitClause(values)
            case "python", "python3", "node", "npm", "pip", "pip3", "swift", "swiftc",
                 "gcc", "clang", "cmake", "cargo", "pytest", "java", "docker", "podman":
                return isVersionProbe(values)
            case "go":
                return values.count == 2 && values[1] == "version"
            default:
                return false
            }
        }

        /// The conservative REMOTE vocabulary: bare/format `date`, system
        /// status, directory/usage listing and exact version probes only.
        /// File-content readers are deliberately absent — on a remote host a
        /// relative path resolves against the login home, where credentials
        /// may live.
        static func isRemoteReadOnlyClause(_ clause: String) -> Bool {
            let values = tokens(of: clause)
            guard let verb = values.first, !verb.contains("/"), !verb.hasPrefix("-") else { return false }
            guard !containsForbiddenToken(values),
                  !containsMutationFlag(values),
                  !hasOutOfBoundsPath(values) else { return false }
            switch verb {
            case "pwd", "id", "whoami", "uname", "uptime", "arch",
                 "printf", "echo", "which", "type",
                 "ls", "stat", "df", "du", "free", "vm_stat", "sw_vers", "systeminfo", "ver":
                return true
            case "hostname":
                return isHostnameDiagnostic(values)
            case "date":
                return isDateDiagnostic(values)
            case "command":
                return values.count == 2 && values[1] == "-v"
            case "python", "python3", "node", "docker", "podman", "git", "go":
                if verb == "go" { return values.count == 2 && values[1] == "version" }
                return isVersionProbe(values)
            default:
                return false
            }
        }

        /// `git symbolic-ref` reads a ref only without a second positional
        /// operand; `git symbolic-ref HEAD refs/heads/x` (or `-d`, `-m`) is a
        /// ref REWRITE and keeps the existing policy. Only the plain query
        /// flags are accepted.
        static func isReadOnlySymbolicRefClause(_ values: [String]) -> Bool {
            var operands = 0
            for token in values.dropFirst(2) {
                if token.hasPrefix("-") {
                    guard ["-q", "--quiet", "--short"].contains(token) else { return false }
                } else {
                    operands += 1
                    if operands > 1 { return false }
                }
            }
            return true
        }

        /// `git grep` flags that LAUNCH a program: `--open-files-in-pager`
        /// (with any attached `=<cmd>`) and its `-O[cmd]` short form, alone
        /// (`-Ocat`) or inside a grouped short cluster (`-nOcat`). `git grep`
        /// has no other short flag containing `o`, so no legitimate read-only
        /// form is rejected here.
        static func containsGitPagerLaunch(_ values: [String]) -> Bool {
            values.dropFirst(2).contains { token in
                if token.lowercased().hasPrefix("--open-files-in-pager") { return true }
                guard token.hasPrefix("-"), !token.hasPrefix("--") else { return false }
                return token.dropFirst().contains("O") || token.dropFirst().contains("o")
            }
        }

        /// Read-only git plumbing only, and never with git's own file-output
        /// redirection. Mutating, network and history-writing subcommands
        /// keep the existing policy.
        static func isReadOnlyGitClause(_ values: [String]) -> Bool {
            guard values.count >= 2 else { return false }
            guard !values.contains(where: { $0 == "-o" || $0.hasPrefix("--output") }) else { return false }
            let subcommand = values[1].lowercased()
            // `git symbolic-ref` REWRITES HEAD when it carries a second
            // positional ref (or `-d/--delete`/`-m`), so only its querying
            // forms stay read-only.
            if subcommand == "symbolic-ref" { return isReadOnlySymbolicRefClause(values) }
            // `git grep --open-files-in-pager[=<cmd>]` / `-O[cmd]` EXECUTES
            // the pager program; it is never a read-only form.
            if subcommand == "grep" { return !containsGitPagerLaunch(values) }
            let readOnly: Set<String> = [
                "status", "diff", "log", "show", "rev-parse", "rev-list", "ls-files",
                "ls-tree", "cat-file", "describe", "blame", "shortlog", "merge-base",
                "name-rev", "count-objects", "whatchanged",
                "for-each-ref", "show-ref", "verify-commit", "verify-tag"
            ]
            if readOnly.contains(subcommand) { return true }
            switch subcommand {
            case "branch", "tag":
                if values.count == 2 { return true }
                let listingFlags = values.dropFirst(2).allSatisfy {
                    $0 == "-l" || $0 == "-v" || $0 == "--verbose" || $0 == "--show-current"
                        || $0.hasPrefix("--list") || $0.hasPrefix("--contains")
                        || $0.hasPrefix("--merged") || $0.hasPrefix("--no-merged")
                        || $0.hasPrefix("--format")
                }
                return listingFlags
            case "remote":
                return values.contains("-v") || values.contains("--verbose")
            case "config":
                return values.contains("--list") || values.contains("-l")
                    || values.contains { $0.hasPrefix("--get") }
            case "stash":
                return values.count >= 3 && values[2].lowercased() == "list"
            case "worktree":
                return values.count >= 3 && values[2].lowercased() == "list"
            default:
                return false
            }
        }

        // MARK: routine workspace vocabulary

        /// Bounded build/test/lint/format forms. Every clause must avoid the
        /// forbidden tokens, output redirection flags and out-of-bounds
        /// paths, and must contain no destructive token. These commands
        /// EXECUTE project code (test runners, build systems, npm scripts);
        /// the policy admits them only as the user's reduced-review choice
        /// for a resolved local Linux guest and only outside a repository
        /// workspace.
        /// Downloading dependencies (`npm ci/install`, `cargo fetch`,
        /// `go get`, `apt`, `pip`) is NOT in this vocabulary: package
        /// acquisition keeps its dedicated review.
        static func isRoutineWorkspaceClause(_ clause: String) -> Bool {
            let values = tokens(of: clause)
            guard let verb = values.first, !verb.contains("/"), !verb.hasPrefix("-") else { return false }
            guard !containsForbiddenToken(values),
                  !containsMutationFlag(values),
                  !hasOutOfBoundsPath(values) else { return false }
            guard !values.contains(where: { destructiveTokens.contains($0.lowercased()) }) else {
                return false
            }
            switch verb {
            case "make", "ninja", "ctest", "pytest", "tsc", "eslint", "mypy",
                 "flake8", "staticcheck", "xcodebuild":
                return true
            case "prettier":
                // Formatting writes only with --write (rejected above);
                // --check/--list-different stays a report.
                return values.contains("--check") || values.contains("--list-different")
            case "black":
                return values.contains("--check") || values.contains("--diff")
            case "ruff":
                // `ruff check` reports; `ruff format` and `--fix` (rejected
                // above) rewrite files.
                return values.count >= 2 && values[1] == "check"
            case "rubocop":
                let correcting: Set<String> = ["-a", "-A", "--auto-correct", "--autocorrect", "--fix"]
                return !values.contains(where: { correcting.contains($0) })
            case "gofmt":
                return !values.contains("-w")
            case "swiftlint":
                return !values.contains("--fix")
            case "swift":
                guard values.count >= 2 else { return false }
                // `swift format` rewrites files; it is not in this list.
                return ["build", "test", "run", "package", "lint"].contains(values[1])
            case "cmake":
                // Configure/build only; `--install` writes outside the tree.
                return !values.contains("--install")
            case "python", "python3":
                guard values.count >= 3, values[1] == "-m" else { return false }
                // Module forms that only report; `json.tool` (output
                // positional), `black`/`ruff` (rewrite) are excluded.
                return ["pytest", "unittest", "mypy", "flake8"].contains(values[2])
            case "node":
                guard values.count >= 2, values[1].hasSuffix(".js") else { return false }
                return !values.contains("-e") && !values.contains("--eval")
            case "npm", "pnpm", "yarn":
                guard values.count >= 2 else { return false }
                // `ci`/`install`/`add` download packages: excluded.
                return ["test", "run", "build", "lint", "format"].contains(values[1])
            case "cargo":
                guard values.count >= 2 else { return false }
                return ["build", "test", "check", "run", "clippy", "bench", "doc"].contains(values[1])
            case "go":
                guard values.count >= 2 else { return false }
                // `go fmt` rewrites source files; it is not in this list.
                return ["build", "test", "run", "vet"].contains(values[1])
            default:
                return false
            }
        }

        /// Tokens that force an otherwise routine verb into the existing
        /// policy: deletion, in-place/recursive writes, hard history resets
        /// and clean targets.
        static let destructiveTokens: Set<String> = [
            "rm", "rmdir", "unlink", "shred", "truncate", "dd", "mkfs",
            "-delete", "-exec", "-execdir", "-ok", "-okdir",
            "-fprint", "-fprint0", "-fls", "-fprintf",
            "--hard", "--in-place", "--install", "purge", "uninstall",
            "erase", "clean", "reset"
        ]
    }
}
