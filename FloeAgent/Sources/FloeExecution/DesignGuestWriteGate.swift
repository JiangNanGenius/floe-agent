// FloeExecution — Pre-dispatch original-write barrier for frozen design tasks.
//
// A bound design modification/restructure freezes the ORIGINAL source on the
// host BEFORE the run reaches the provider (FloeCore DesignFreezeRegistry,
// established by the app's launch coordinator). Host-side workspace writes
// pass through the registry's mutation gate — but the Linux guest addresses
// the same workspace through its 9P share, so an arbitrary guest command
// (exec.shell / exec.localPython / interactive shell sessions) could still
// overwrite the frozen original BEFORE any adoption. Arbitrary shell strings
// cannot be parsed for every write they might perform, so this gate fails
// closed at the dispatch boundary:
//
// - A run that owns NO frozen protection is never touched (ordinary tasks,
//   unbound chats, package installs and native/staging paths keep working
//   exactly as before).
// - A run that owns frozen protections may dispatch ONLY commands the
//   classifier proves read-only (a strict allowlist of inspection commands,
//   no redirection writes, no command substitution, no sub-shells; every
//   pipeline/&&/; segment must independently pass). Everything else is
//   denied BEFORE the backend receives a byte, with a structured
//   unsupported result and the recovery actions (stage via design.propose,
//   or let the user adopt/reject first).
//
// The gate lives below the tool layer (LocalShellService / session tools)
// so model request tags, tool aliasing, jobs.submit replays and delegated
// child runs — which all funnel through these same services with the same
// ToolContext — cannot bypass it.
//
// Reachability review of every registered execution backend (no blanket
// blocks; each backend is denied only when it can actually touch a frozen
// original):
// - exec.shell (guest + native) — reaches the workspace root: GATED.
// - exec.localPython (guest) — reaches the workspace share: GATED.
// - shell.open / shell.exchange (interactive PTY) — same reach: GATED.
// - exec.localService (guest services) — same reach: GATED.
// - network.download — writes a workspace-relative destination through its
//   own downloader (NOT WorkspaceFileService): destination checked against
//   the registry; a new path stays open, a frozen target is denied.
// - exec.javascript — a bare JavaScriptCore context with only console and
//   printJSON injected: NO filesystem surface, cannot reach any original:
//   NOT gated (honest capability, not a blanket block).
// - exec.wasm — no WASI/host imports at all: NOT gated.
// - pdf.form (PDFFillFormTool) — existing outputs are never overwritten; it
//   can only create NEW files: NOT gated.
// - jobs.status/result/cancel, shell.close/signal, environment.linuxStatus
//   — no execution reach at all: NOT gated.

import Foundation
import FloeCore
import FloeTools

/// Test seam for the gate's registry: unit tests swap in an isolated
/// registry; production never sets it, so the shared durable registry is
/// always the authority in the app.
enum DesignGuestWriteGateTesting {
    nonisolated(unsafe) private static var override: DesignFreezeRegistry?
    static func installRegistryOverride(_ registry: DesignFreezeRegistry) {
        override = registry
    }
    static func removeRegistryOverride() {
        override = nil
    }
    static var registry: DesignFreezeRegistry { override ?? .shared }
}

public enum DesignGuestWriteGate {
    /// Structured denial rendered into the tool result. `status=unsupported`
    /// with the frozen path and the recovery actions — never a fake success,
    /// never a bare "blocked" with no way forward.
    public struct Denial: Sendable {
        public let canonicalPath: String
        public let conversationID: String

        public var message: String {
            """
            status=unsupported
            backend=execution
            reason=design_original_frozen path=\(canonicalPath) task=\(conversationID)
            recovery=The original is write-frozen until its design candidate is adopted or rejected: stage changes with design.propose (isolated candidate bytes, original untouched) and let the user adopt, or ask the user to reject the pending candidate first. Read-only inspection commands remain available.
            """
        }
    }

    /// The protections this run must honor, if any. A protection binds when:
    /// - the run's conversation OWNS it (the originating design task; child
    ///   runs inherit the parent conversation identity), OR
    /// - the run's RESOLVED workspace root CONTAINS the frozen original —
    ///   ANY model run (or delegated child) whose workspace can reach the
    ///   original through the guest share is denied arbitrary execution,
    ///   not only the originating run. Model-supplied targets or forged
    ///   context can never narrow this: reachability is computed from the
    ///   executor-resolved root, never from model text.
    /// Unrelated roots (no overlap with any protection) stay fully usable.
    public static func protections(
        for context: ToolContext,
        registry: DesignFreezeRegistry? = nil
    ) -> [DesignFreezeProtection] {
        let all = (registry ?? DesignGuestWriteGateTesting.registry).allProtections()
        guard !all.isEmpty else { return [] }
        var matched: [DesignFreezeProtection] = []
        if let conversationID = context.conversationID {
            let key = conversationID.uuidString.lowercased()
            matched.append(contentsOf: all.filter { $0.conversationID == key })
        }
        if let root = context.workspaceRootURL {
            let canonicalRoot = DesignFreezeRegistry.canonicalPath(of: root)
            let prefix = canonicalRoot.hasSuffix("/")
                ? canonicalRoot
                : canonicalRoot + "/"
            matched.append(contentsOf: all.filter {
                $0.canonicalPath == canonicalRoot
                    || $0.canonicalPath.hasPrefix(prefix)
            })
        }
        var seen = Set<String>()
        return matched.filter {
            seen.insert($0.canonicalPath + "\n" + $0.conversationID).inserted
        }
    }

    /// Evaluate one arbitrary shell command. nil = safe to dispatch.
    public static func evaluate(
        command: String,
        context: ToolContext,
        registry: DesignFreezeRegistry? = nil
    ) -> Denial? {
        let protections = self.protections(for: context, registry: registry)
        guard let protection = protections.first else { return nil }
        // Strictly read-only commands keep working while a freeze is active
        // (inspection, measurement, diffing); everything that could write is
        // denied BEFORE dispatch. The classifier is deliberately
        // conservative: any unrecognized token fails closed.
        guard ShellReadOnlyClassifier.isReadOnly(command) else {
            return Denial(
                canonicalPath: protection.canonicalPath,
                conversationID: protection.conversationID)
        }
        return nil
    }

    /// Interactive session input (shell.exchange) and one-shot commands share
    /// the same classifier.
    public static func evaluate(
        interactiveInput input: String,
        context: ToolContext,
        registry: DesignFreezeRegistry? = nil
    ) -> Denial? {
        evaluate(command: input, context: context, registry: registry)
    }

    /// Arbitrary-code denial (exec.localPython / shell.open / exec.localService):
    /// a script or service is never provably read-only, so any freeze owned
    /// by the run denies it outright — the shell classifier is NOT applied
    /// to non-shell languages.
    public static func arbitraryCodeDenial(
        context: ToolContext,
        registry: DesignFreezeRegistry? = nil
    ) -> Denial? {
        let protections = self.protections(for: context, registry: registry)
        guard let protection = protections.first else { return nil }
        return Denial(
            canonicalPath: protection.canonicalPath,
            conversationID: protection.conversationID)
    }
}

/// Strict, conservative read-only classifier for arbitrary shell strings.
///
/// A command passes ONLY when every one of its segments (split at pipes,
/// `&&`, `||`, `;` and newlines) is a recognized read-only invocation with
/// no write redirection, no command substitution, no sub-shell and no
/// backgrounding. Anything else is potentially-mutating and — while a design
/// original is frozen — denied before dispatch. This is a protection
/// boundary, not a general shell parser: it errs on the side of denial and
/// the denial carries the recovery actions.
enum ShellReadOnlyClassifier {
    static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // No command substitution, sub-shells, process substitution, here-docs
        // or background jobs: each can smuggle an arbitrary write past a
        // per-segment token check.
        let forbidden: [String] = ["$(", "`", "<(", ">(", "<<", "&\n"]
        for token in forbidden where trimmed.contains(token) {
            // `$(`/`backtick` substitution and `<(`/`>(` substitution are
            // never provably read-only here; `&` followed by newline starts a
            // background job. (`2>&1`-style fd duplication is handled below
            // and is NOT one of these tokens.)
            return false
        }
        if trimmed.hasSuffix("&") { return false }
        // Write redirections. Input redirection (`< file`) only reads.
        // fd-duplication (`2>&1`, `>&2`, `1>&-`) creates no file and stays.
        var scan = trimmed
        let dupPattern = "[0-9]*>&[0-9-]+"
        if let regex = try? NSRegularExpression(pattern: dupPattern) {
            let range = NSRange(scan.startIndex..., in: scan)
            scan = regex.stringByReplacingMatches(in: scan, range: range, withTemplate: "")
        }
        let closePattern = "[0-9]*>&-"
        if let regex = try? NSRegularExpression(pattern: closePattern) {
            let range = NSRange(scan.startIndex..., in: scan)
            scan = regex.stringByReplacingMatches(in: scan, range: range, withTemplate: "")
        }
        guard !scan.contains(">") else { return false }
        // Every segment (of the fd-duplication-stripped form, so `2>&1`
        // never splits mid-token) must independently be read-only.
        let segments = splitSegments(scan)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy(isReadOnlySegment)
    }

    /// Split a compound command at `|`, `&&`, `||`, `;` and newlines — none
    /// of which can appear inside the allowlisted invocations' arguments by
    /// construction (quoted strings containing them fail the segment check).
    static func splitSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var index = command.startIndex
        while index < command.endIndex {
            let ch = command[index]
            if ch == "\n" || ch == ";" {
                segments.append(String(current))
                current = ""
            } else if ch == "|" {
                // `||` is a separator like `;`; a single `|` is a pipe.
                let next = command.index(after: index)
                if next < command.endIndex, command[next] == "|" {
                    segments.append(String(current))
                    current = ""
                    index = next
                } else {
                    segments.append(String(current))
                    current = ""
                }
            } else if ch == "&" {
                let next = command.index(after: index)
                if next < command.endIndex, command[next] == "&" {
                    segments.append(String(current))
                    current = ""
                    index = next
                } else {
                    // Lone `&` (background) — poison the whole command by
                    // emitting an unmatchable segment.
                    segments.append(String(current))
                    current = ""
                }
            } else {
                current.append(ch)
            }
            index = command.index(after: index)
        }
        segments.append(String(current))
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One invocation is read-only when its base command is allowlisted AND
    /// its flags cannot turn it into a writer. A leading `VAR=value`
    /// assignment prefix is allowed only for allowlisted bases.
    static func isReadOnlySegment(_ rawSegment: String) -> Bool {
        var segment = rawSegment
        // Strip environment-variable assignment prefixes (FOO=bar ls).
        while let match = assignmentPrefix(segment) {
            let rest = segment[match...]
            // Quoted values may hide separators; fail closed rather than
            // parse shell quoting. Unquoted values end at whitespace.
            guard let first = rest.first, first != "\"" && first != "'" else { return false }
            let remainder = rest.drop(while: { !$0.isWhitespace })
            segment = remainder.trimmingCharacters(in: .whitespaces)
        }
        guard !segment.isEmpty else { return false }
        let tokens = segment.split(
            whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let base = tokens.first else { return false }
        // Path-qualified invocation (`/usr/bin/ls`) still resolves by name.
        let name = (base as NSString).lastPathComponent
        switch name {
        case "ls", "pwd", "cat", "head", "tail", "wc", "printenv", "env",
             "uname", "stat", "file", "sort", "uniq", "cut", "tr",
             "diff", "cmp", "basename", "dirname", "date", "true", "false",
             "du", "df", "ps", "uptime", "id", "whoami", "hostname",
             "sha256sum", "md5sum", "shasum", "cksum", "nl", "od", "hexdump",
             "printf", "echo", "seq", "which":
            return flagsAreReadOnly(name: name, tokens: Array(tokens.dropFirst()))
        case "grep", "egrep", "fgrep", "rg", "jq", "yq":
            // These never write files; flags only refine matching/parsing.
            return true
        case "command":
            // `command -v name` (or `-V`) is an inspection builtin.
            guard tokens.count >= 2, tokens[1] == "-v" || tokens[1] == "-V" else {
                return false
            }
            return true
        case "test", "[":
            return true
        case "find":
            // find is read-only only without execution/deletion primaries.
            let args = tokens.dropFirst()
            return !args.contains("-exec")
                && !args.contains("-execdir")
                && !args.contains("-ok")
                && !args.contains("-okdir")
                && !args.contains("-delete")
                && !args.contains("-fprint")
                && !args.contains("-fprintf")
                && !args.contains("-fls")
        case "xargs":
            // Only `xargs -r echo`-style no-op invocations could ever be
            // safe; rather than proving the inner command, deny xargs.
            return false
        case "python3", "python", "node", "npm", "npx", "pnpm", "yarn",
             "apt", "apt-get", "apt-cache", "dpkg", "pip", "pip3", "go",
             "cargo", "make", "gcc", "cc", "clang", "git", "curl", "wget",
             "tar", "unzip", "zip", "gzip", "gunzip", "sed", "awk", "perl",
             "ruby", "lua", "vim", "vi", "nano", "ed", "patch", "systemctl",
             "service", "mount", "umount", "crontab", "ssh", "scp", "sftp",
             "sh", "bash", "dash", "zsh", "fish", "ksh", "busybox", "eval",
             "exec", "source", ".":
            // Tooling that can execute code or write state. Only a sole
            // `--version`/`-v`/`-V`/`--help` probe is accepted for the
            // version-capable runtimes (never for shells/interpreters that
            // still parse further arguments — keep them fully denied except
            // the version flags themselves).
            return versionProbeOnly(name: name, tokens: Array(tokens.dropFirst()))
        default:
            // Anything unrecognized fails closed.
            return false
        }
    }

    /// A version/help probe: every argument is one of the benign flags and
    /// at least one exists. Shells and write-capable tools never qualify.
    static func versionProbeOnly(name: String, tokens: [String]) -> Bool {
        let runnable: Set<String> = [
            "python3", "python", "node", "npm", "npx", "pnpm", "yarn",
            "apt", "apt-get", "dpkg", "pip", "pip3", "go", "cargo",
            "git", "curl", "systemctl",
        ]
        guard runnable.contains(name), !tokens.isEmpty else { return false }
        let benign: Set<String> = ["--version", "-v", "-V", "--help", "-h"]
        return tokens.allSatisfy { benign.contains($0) }
    }

    /// Flags that must never appear for otherwise-read-only bases, mapped by
    /// name. Conservative: unknown flags on bases with known write flags are
    /// checked explicitly; everything else passes only when no flag looks
    /// like an output target (`-o`, `--output`, `-w`, ...).
    static func flagsAreReadOnly(name: String, tokens: [String]) -> Bool {
        // Output-capable flags per base. A base not listed here has no known
        // file-writing flags and passes (its arguments are paths to READ).
        let outputFlags: [String: Set<String>] = [
            "sort": ["-o", "--output"],
            "du": [],
            "stat": [],
        ]
        let banned = outputFlags[name] ?? []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if banned.contains(token) { return false }
            // Attached forms: -ofile / --output=file.
            for flag in banned where token.hasPrefix(flag) && token != flag {
                if token.hasPrefix("-o") && name == "sort" && token != "-o" {
                    return false
                }
                if token.hasPrefix("--output=") { return false }
            }
            index += 1
        }
        return true
    }

    /// Match one leading `NAME=value` assignment (POSIX name characters).
    static func assignmentPrefix(_ segment: String) -> Substring.Index? {
        var index = segment.startIndex
        var matched = false
        while index < segment.endIndex {
            let ch = segment[index]
            let isNameChar = ch.isLetter || ch == "_"
                || (matched && (ch.isNumber || ch == "_"))
            if isNameChar {
                matched = true
                index = segment.index(after: index)
            } else {
                break
            }
        }
        guard matched, index < segment.endIndex, segment[index] == "=" else {
            return nil
        }
        return segment.index(after: index)
    }
}
