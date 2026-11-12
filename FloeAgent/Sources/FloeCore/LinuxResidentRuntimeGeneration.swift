// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A retaining rebuild changes the physical Linux disk while keeping the old
/// software/data. It must not use the initial-reset path that silently refreshes
/// resumable task pins. The native committed recovery UUID is the sole issuer.
public enum LinuxResidentRuntimeGeneration {
    private static let prefix = "resident-rebuild:"

    public static func value(recoveryID: UUID) -> String {
        prefix + recoveryID.uuidString.lowercased()
    }

    public static func recoveryID(from value: String?) -> UUID? {
        guard let value, value.hasPrefix(prefix), value.count == prefix.count + 36 else { return nil }
        return UUID(uuidString: String(value.dropFirst(prefix.count)))
    }

    /// A malformed value in this reserved namespace is still a hard boundary;
    /// it cannot fall back to ordinary reset auto-rebinding.
    public static func requiresExplicitTaskRebind(_ value: String?) -> Bool {
        value?.hasPrefix(prefix) == true
    }
}
