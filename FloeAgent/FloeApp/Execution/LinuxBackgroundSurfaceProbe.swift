// FloeApp — Bounded guest probe for the background surface's command count.
//
// The Linux guest has no protocol frame for "how many commands are running",
// so the app counts processes the Floe runner directly owns with one bounded
// /proc read. Managed services and interactive shell sessions are also
// runner-owned; the caller subtracts the service count it already tracks.
// A missing or failed read returns nil and the surface renders "—" instead of
// inventing a number.

#if canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloeTools

enum LinuxGuestSurfaceProbe {
    static let maximumOutputBytes = 4 * 1024
    static let commandTimeout: TimeInterval = 5

    /// Runner-owned process count, excluding this probe's own shell. The
    /// result is clamped to a sane ceiling so a hostile guest cannot produce a
    /// nonsensical display value.
    static func runnerOwnedProcessCount(
        runner: any LinuxCommandRunning,
        environmentID: String
    ) async -> Int? {
        let script = """
        line=$(cat /proc/$$/stat 2>/dev/null) || exit 3
        rest=${line#*) }
        after_state=${rest#* }
        runner=${after_state%% *}
        [ -n "$runner" ] || exit 3
        count=0
        for d in /proc/[0-9]*; do
          [ "$d" = "/proc/$$" ] && continue
          line=$(cat "$d/stat" 2>/dev/null) || continue
          rest=${line#*) }
          after_state=${rest#* }
          ppid=${after_state%% *}
          [ "$ppid" = "$runner" ] && count=$((count+1))
        done
        echo "$count"
        """
        do {
            let result = try await runner.run(
                environmentID: environmentID,
                argv: ["sh", "-c", script],
                workingDirectory: nil,
                standardInput: nil,
                timeout: commandTimeout,
                maxOutputBytes: maximumOutputBytes,
                cancellation: nil
            )
            guard result.exitCode == 0 else { return nil }
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(text), value >= 0 else { return nil }
            return min(value, 64)
        } catch {
            return nil
        }
    }
}
#endif
