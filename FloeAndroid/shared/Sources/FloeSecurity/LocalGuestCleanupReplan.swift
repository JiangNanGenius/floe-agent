// FloeSecurity — bounded corrective opportunity for an unrequested cleanup.
//
// Observed failure (one-shot113, BEFORE recording media/phone/calendar): an
// ordinary AutoAllow run proposed one compound `exec.shell` command whose
// required part was directory setup and whose optional part was `rm -rf` of
// an accidental literal directory. The action-review model correctly
// escalated the destructive command to the human card. The runtime then
// parked the only continuation, so the model could not abandon the optional
// cleanup and continue with the safe `mkdir` path it already knew. The user
// stopped the run.
//
// The repair is deliberately NOT a policy relaxation and NOT a second
// approval system:
//
// - It is consulted ONLY after the existing approval pipeline already
//   returned `.escalateToHuman` for an AUTO-ALLOW action (model reviewer, or
//   the deterministic sensitive-action fallback when no reviewer is
//   configured). The catastrophic gate, hard denies, manual Ask, Full
//   Access/Control, remote/native execution, temporary/read-only runs,
//   reusable grants and child calls keep their existing behaviour untouched.
// - This helper can only turn that escalation into a NON-DISPATCHED denial
//   with a bounded replan instruction. It can never produce `.allow`, never
//   execute the command and never widen a scope.
// - It applies only to a concrete `exec.shell` proposal for the run's
//   APP-RESOLVED local Linux PRoot target (`localLinuxShellTarget`, false for
//   SSH/no-target/temporary/Notes/native) whose command includes a lexically
//   recognised destructive delete, and only when the user's own messages do
//   not ask for deletion or cleanup. An explicit user request keeps the
//   exact-call human card.
// - A later, different, non-destructive command goes through the ordinary
//   review path unchanged. If deletion is genuinely required, the model must
//   ask the user; the user's later authorization still reaches the normal
//   approval surface.
//
// The delete scan is a bounded lexical screen, not a shell parser and not a
// security boundary. Anything it does not positively recognise simply keeps
// today's human escalation (fail safe); a false positive can only deny an
// already-escalated call, never allow one.

import Foundation

public enum LocalGuestCleanupReplan {
    /// Stable machine marker. It is deliberately part of the model-facing
    /// denial text so the invocation contract is recognisable in evidence,
    /// audit excerpts and tests without parsing prose.
    public static let denialMarker = "[optional-cleanup-replan]"

    /// Returns the model-facing denial for an ALREADY-ESCALATED action that
    /// matches the narrow optional-cleanup case, or nil when the ordinary
    /// exact-call human approval path must remain authoritative.
    ///
    /// `localLinuxShellTarget` is the run's APP-RESOLVED route fact: the
    /// execution target for this run is the local Linux PRoot guest (an SSH
    /// target, no target, temporary/Notes run or native backend is false).
    /// It is passed from the frozen runtime configuration, never derived
    /// from model arguments, an environment label, a path or tool text.
    public static func denialReason(
        for action: ProposedAction,
        localLinuxShellTarget: Bool
    ) -> String? {
        guard localLinuxShellTarget else { return nil }
        guard action.toolCall.toolName == "exec.shell" else { return nil }
        guard case .local = action.toolCall.scope else { return nil }
        guard let context = action.trustedContext,
              context.environmentClass != .remote else { return nil }
        guard let command = shellCommand(in: action.argumentObject),
              containsDestructiveDelete(command) else { return nil }
        guard !userAuthorizesCleanup(action) else { return nil }
        return denialText
    }

    /// The exact command string the backend will execute for `exec.shell`.
    /// `script` is the documented alias; other argument keys are not commands.
    private static func shellCommand(in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        guard let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let script = object["script"] as? String,
                  !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return script
        }
        return command
    }

    // MARK: - Delete screen

    /// Destructive file-system removal verbs. A token is matched by its last
    /// path component, so `/bin/rm` and `busybox rm` are recognised while an
    /// unrelated option or data word is not. `find -delete` and `rsync
    /// --delete`/`--remove-source-files` are matched as flags; `git clean` is
    /// matched as the two-word subcommand.
    private static let deleteVerbs: Set<String> = [
        "rm", "rmdir", "unlink", "shred", "truncate", "dd",
        "wipefs", "mkfs", "mkfs.ext2", "mkfs.ext3", "mkfs.ext4",
        "mkfs.xfs", "mkfs.btrfs", "mkfs.vfat", "blkdiscard", "sdelete"
    ]

    private static let deleteFlags: Set<String> = [
        "-delete", "--delete", "--remove-source-files"
    ]

    private static func containsDestructiveDelete(_ command: String) -> Bool {
        let values = shellTokens(command)
        for value in values {
            let stripped = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !stripped.isEmpty else { continue }
            let base = (stripped as NSString).lastPathComponent.lowercased()
            if deleteVerbs.contains(base) { return true }
            if deleteFlags.contains(stripped.lowercased()) { return true }
            if base.hasPrefix("mkfs.") { return true }
        }
        // `git clean` (including `git clean -fdx`) removes untracked files.
        // Match it as a subcommand only, so prose mentioning a clean checkout
        // does not become a deletion signal.
        let compact = command.lowercased()
        return compact.range(
            of: #"(^|[;&|(]\s*)git\s+clean([\s;&|)]|$)"#,
            options: .regularExpression
        ) != nil
    }

    /// Bounded POSIX-ish tokenizer for the delete screen. It honours single
    /// and double quotes and backslash escapes so a quoted argument stays one
    /// token, and splits on shell separators/redirections. It is intentionally
    /// NOT a complete shell parser: nested `sh -c` payloads simply fail to be
    /// recognised, which keeps the ordinary human escalation.
    private static func shellTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                continue
            }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace || ";|&()<>`\n\r".contains(character) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - User authority

    /// Positive deletion/cleanup request vocabulary from the user's OWN
    /// messages. The runtime already supplies only role-checked user text in
    /// `userGoal`/`userRequests`; tool output, assistant prose and file content
    /// never reach this field.
    private static let cleanupAuthorityTerms: [String] = [
        "delete", "deleting", "remove", "removing", "erase", "erasing",
        "clean up", "clean-up", "cleanup", "purge", "prune", "wipe",
        "discard", "trash", "get rid of", "rm -rf", "rm -r", "rm -f",
        "reset the folder", "reset the directory",
        "删除", "删掉", "删去", "删了", "清理", "清除", "清空",
        "移除", "抹掉", "销毁", "丢弃", "回收",
        // Additional common request words. A false positive only keeps the
        // pre-existing human card (never a denial), so broader vocabulary is
        // safe; it avoids silently denying a genuinely requested cleanup to
        // a user who is not writing English or Simplified Chinese.
        "löschen", "entfernen", "aufräumen", "bereinigen",
        "supprimer", "effacer", "nettoyer",
        "eliminar", "borrar", "limpiar",
        "削除", "消去", "クリーンアップ",
        "삭제", "제거", "정리"
    ]

    /// Negated deletion phrases are stripped before the affirmative scan so
    /// "do not delete anything" or "不要删除" cannot be mistaken for
    /// authorization. Any remaining explicit deletion request still counts.
    private static let negatedCleanupPhrases: [String] = [
        "do not delete", "don't delete", "do not remove", "don't remove",
        "never delete", "never remove", "without deleting", "without removing",
        "not delete", "not remove", "do not clean up", "don't clean up",
        "do not clean", "don't clean", "no cleanup", "without cleanup",
        "do not trash", "don't trash", "without trashing",
        "不要删除", "别删除", "不要删", "别删", "不要移除", "别移除",
        "不要清理", "别清理", "不要清空", "别清空", "无需删除", "不需要删除",
        "不用清理", "无需清理", "不必清理", "不要丢弃", "别丢弃"
    ]

    private static func userAuthorizesCleanup(_ action: ProposedAction) -> Bool {
        var text = action.userGoal
        if let requests = action.userRequests {
            text += "\n" + requests.joined(separator: "\n")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var lowered = text.lowercased()
        for phrase in negatedCleanupPhrases {
            lowered = lowered.replacingOccurrences(of: phrase, with: " ")
        }
        return cleanupAuthorityTerms.contains { lowered.contains($0) }
    }

    // MARK: - Model-facing contract

    private static let denialText = """
    \(denialMarker) This exact call was NOT dispatched. It proposes a destructive delete (rm/rmdir/unlink/find -delete or similar) inside the resolved local Linux guest, and the user's own messages do not authorize deleting files. No approval card was shown, nothing was removed, and no command output exists for this call. Do not resend the same command and do not route the deletion through another tool or transport. Continue now with a safe, non-destructive alternative for the user's actual goal (for example create only the required directories). The non-interactive shell is /bin/sh -lc (dash on Debian): brace expansion, arrays, [[ ]], and process substitution are unavailable. Pass each path explicitly as a POSIX argument and check each step's exit status; a trailing echo or any later unrelated success does not prove an earlier setup step succeeded. If deleting specific paths is genuinely required, stop and ask the user what may be deleted; a later user-authorized proposal still goes through the normal exact-call approval path. retryable=false
    """
}
