// FloeExecution — Shell command policy.
// Layers shell-specific prohibitions on top of the bundled catastrophic
// gate. This is a deterministic input filter, not intent classification:
// it stops a small set of high-confidence destructive or self-escalating
// command forms and otherwise defers to the approval policy.

import Foundation
import FloeCore
import FloeSecurity

public struct ShellCommandPolicy: Sendable {
    public struct Verdict: Sendable, Equatable {
        public var stopped: Bool
        public var matchedPatternID: String?
        public var reason: String?

        public static let clear = Verdict(stopped: false, matchedPatternID: nil, reason: nil)
    }

    private struct Rule: Sendable {
        let id: String
        let regex: NSRegularExpression
        let reason: String
    }

    private let gate: CatastrophicActionGate?
    private let rules: [Rule]

    public init(gate: CatastrophicActionGate? = nil) {
        self.gate = gate
        let raw: [(String, String, String)] = [
            (
                "shell-curl-pipe",
                #"(?i)\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(bash|sh|zsh|dash|python3?|perl|ruby)\b"#,
                "Piping a download directly into an interpreter is blocked. Download the file, inspect it, then run it explicitly with its own approval."
            ),
            (
                "shell-sudo",
                #"(?i)(^|[\s;&|])sudo([\s]|$)"#,
                "sudo is unavailable in the iOS sandbox. Use an explicitly approved command instead."
            ),
            (
                "shell-power",
                #"(?i)(^|[\s;&|])(shutdown|reboot|halt|poweroff)([\s]|$)"#,
                "System power commands are unavailable on iOS."
            ),
            (
                "shell-device-write",
                #"(?i)(^|[\s;&|])dd\s+[^\n]*\bof=/dev/"#,
                "Writing raw block devices is blocked."
            ),
            (
                "shell-force-push",
                #"(?i)\bgit\s+push\b[^\n]*(--force|-f)([\s]|$)"#,
                "Force-pushing rewrites remote history; ask the user to confirm the exact refspec explicitly."
            )
        ]
        var compiled: [Rule] = []
        for (id, pattern, reason) in raw {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                compiled.append(Rule(id: id, regex: regex, reason: reason))
            } else {
                FloeLogger(category: .tools).error("shellPolicyPatternInvalid id=\(id)")
            }
        }
        rules = compiled
    }

    public func evaluate(_ command: String) -> Verdict {
        if let gate {
            let verdict = gate.evaluate(command: command)
            if verdict.stopped {
                return Verdict(
                    stopped: true,
                    matchedPatternID: verdict.matchedPatternID,
                    reason: verdict.reason ?? "Command stopped by the catastrophic-action gate."
                )
            }
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        for rule in rules where rule.regex.firstMatch(in: command, options: [], range: range) != nil {
            return Verdict(stopped: true, matchedPatternID: rule.id, reason: rule.reason)
        }
        return .clear
    }

    /// Command names that touch the network. Used only for honest output
    /// annotations; authority stays with the approval policy.
    public static func networkCommands(in command: String) -> [String] {
        let names: Set<String> = ["curl", "wget", "ping", "traceroute", "dig", "nslookup", "host", "nc", "netcat", "whois", "ssh", "scp", "sftp"]
        let tokens = command
            .split(whereSeparator: { $0.isWhitespace || "|;&()<>".contains($0) })
            .map(String.init)
        var found: [String] = []
        for token in tokens {
            let name = token.split(separator: "/").last.map(String.init) ?? token
            if names.contains(name.lowercased()), !found.contains(name.lowercased()) {
                found.append(name.lowercased())
            }
        }
        return found.sorted()
    }
}
