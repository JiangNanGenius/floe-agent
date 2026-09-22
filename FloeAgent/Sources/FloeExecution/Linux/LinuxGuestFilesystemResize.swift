// FloeExecution — in-guest ext4 capacity extension after host-side disk grow.
//
// The host grows each environment raw container logically to 8 GiB
// (`LinuxGuestDiskLayout`), sparsely and grow-only. The ext4 filesystem
// inside it keeps its old geometry until the guest extends it, so right
// after boot this type runs an online `resize2fs` against the root device.
// The operation is idempotent: an already-extended filesystem is a no-op,
// and a failure is reported (and surfaced in LinuxGuestStatus) rather than
// hidden — the guest still runs at its previous capacity.
//
// Parsing is pure and testable without a guest; only `ensureCapacity`
// needs the runner.

import Foundation
import FloeCore
import FloeTools

public enum LinuxGuestFilesystemResize {
    /// Result of one capacity probe/extend attempt.
    public enum Outcome: Sendable, Equatable {
        /// Filesystem already matches the container capacity.
        case current
        /// Filesystem was extended (or reported a successful resize).
        case extended
    }

    /// Parsed `blockdev --getsize64 <device>` and `dumpe2fs -h` block
    /// geometry. `containerBytes` is the raw device capacity and
    /// `filesystemBytes` is the ext4 block count times block size.
    public struct Geometry: Sendable, Equatable {
        public var containerBytes: Int64
        public var filesystemBytes: Int64

        public init(containerBytes: Int64, filesystemBytes: Int64) {
            self.containerBytes = containerBytes
            self.filesystemBytes = filesystemBytes
        }

        /// True when the filesystem is within one MiB of the container
        /// (resize2fs cannot use the final partial block group).
        public var isCurrent: Bool {
            containerBytes - filesystemBytes <= 1024 * 1024
        }
    }

    /// Parses the guest probe output. Returns nil when the output shape is
    /// unrecognized (caller treats that as an honest resize failure rather
    /// than guessing the geometry).
    ///
    /// Expected format, produced by the shell snippet in `probeScript`:
    /// ```
    /// FLOE_CONTAINER_BYTES=<n>
    /// FLOE_FS_BLOCK_COUNT=<n>
    /// FLOE_FS_BLOCK_SIZE=<n>
    /// ```
    public static func geometry(probeOutput: String) -> Geometry? {
        var container: Int64?
        var blockCount: Int64?
        var blockSize: Int64?
        for rawLine in probeOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = labeledValue("FLOE_CONTAINER_BYTES", in: line) {
                container = Int64(value)
            } else if let value = labeledValue("FLOE_FS_BLOCK_COUNT", in: line) {
                blockCount = Int64(value)
            } else if let value = labeledValue("FLOE_FS_BLOCK_SIZE", in: line) {
                blockSize = Int64(value)
            }
        }
        guard let container, let blockCount, let blockSize,
              container > 0, blockCount > 0, blockSize > 0 else { return nil }
        return Geometry(
            containerBytes: container,
            filesystemBytes: blockCount * blockSize
        )
    }

    private static func labeledValue(_ label: String, in line: String) -> String.SubSequence? {
        let prefix = label + "="
        guard line.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count)
        return value.allSatisfy(\.isNumber) ? value : nil
    }

    /// Shell snippet run inside the guest: prints the container and ext4
    /// geometry, and when the filesystem is below the container size runs
    /// `resize2fs` online, then prints the post-resize geometry.
    /// `device` defaults to the root block device from `LinuxGuestDiskLayout`.
    public static func ensureScript(device: String = LinuxGuestDiskLayout.guestRootDevice) -> String {
        #"""
        set -u
        dev="__DEVICE__"
        probe() {
          cb=$(blockdev --getsize64 "$dev" 2>/dev/null) || return 1
          bc=$(dumpe2fs -h "$dev" 2>/dev/null | awk '/Block count:/ {print $3}') || return 1
          bs=$(dumpe2fs -h "$dev" 2>/dev/null | awk '/Block size:/ {print $3}') || return 1
          [ -n "$cb" ] && [ -n "$bc" ] && [ -n "$bs" ] || return 1
          printf 'FLOE_CONTAINER_BYTES=%s\nFLOE_FS_BLOCK_COUNT=%s\nFLOE_FS_BLOCK_SIZE=%s\n' "$cb" "$bc" "$bs"
        }
        if ! probe; then
          echo "floe-resize: probe failed for $dev" >&2
          exit 10
        fi
        before=$(probe)
        cb=$(printf '%s\n' "$before" | awk -F= '/FLOE_CONTAINER_BYTES/ {print $2}')
        fsb=$(printf '%s\n' "$before" | awk -F= '/FLOE_FS_BLOCK_COUNT/ {print $2}')
        bsz=$(printf '%s\n' "$before" | awk -F= '/FLOE_FS_BLOCK_SIZE/ {print $2}')
        fs_bytes=$((fsb * bsz))
        if [ $((cb - fs_bytes)) -le 1048576 ]; then
          echo "floe-resize: current"
          exit 0
        fi
        if ! resize2fs "$dev" >/tmp/.floe-resize2fs.log 2>&1; then
          echo "floe-resize: resize2fs failed" >&2
          cat /tmp/.floe-resize2fs.log >&2 || true
          exit 11
        fi
        probe || exit 12
        echo "floe-resize: extended"
        exit 0
        """#
        .replacingOccurrences(of: "__DEVICE__", with: device)
    }

    /// Runs the probe/resize once after the guest booted. A non-failing no-op
    /// when the filesystem is current; a `.diskResize` failure otherwise.
    @discardableResult
    public static func ensureCapacity(
        environmentID: String,
        runner: any LinuxCommandRunning,
        device: String = LinuxGuestDiskLayout.guestRootDevice,
        timeout: TimeInterval = 180,
        cancellation: CancellationToken? = nil
    ) async throws -> Outcome {
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", ensureScript(device: device)],
            workingDirectory: nil,
            standardInput: nil,
            timeout: timeout,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        if result.exitCode == 0 {
            return result.stdout.contains("floe-resize: extended") ? .extended : .current
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = detail.count > 400 ? "…" + detail.suffix(400) : detail
        throw LinuxGuestError.startFailed(
            "the Linux disk grew to its target capacity but resize2fs could not extend the ext4 filesystem (exit \(result.exitCode)): \(tail)"
        )
    }
}
