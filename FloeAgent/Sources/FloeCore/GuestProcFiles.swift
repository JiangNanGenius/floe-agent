// FloeCore — Pure parsers for the bounded Linux guest metrics sampler.
//
// These parse exactly the three /proc text files used to produce a truthful
// point-in-time resource sample. They are pure Foundation code so they can be
// unit-tested off-device; the actor that actually reads the files lives in
// FloeExecution. Missing/malformed input yields nil so the UI renders "—",
// never a fabricated zero.

import Foundation

/// Aggregate CPU jiffies from the first ("cpu  …") line of `/proc/stat`.
public struct GuestProcStatSample: Sendable, Equatable {
    /// Non-idle jiffies (total minus idle and iowait).
    public let busyJiffies: UInt64
    public let totalJiffies: UInt64
}

public enum GuestProcStatParser {
    /// Parses the aggregate CPU line of `/proc/stat`.
    ///
    /// Layout: `cpu user nice system idle iowait irq softirq steal guest
    /// guest_nice`. Idle and iowait are the only non-busy fields. Returns nil
    /// when no aggregate line exists or it carries no numeric fields.
    public static func aggregateSample(_ text: String) -> GuestProcStatSample? {
        guard let line = text.split(separator: "\n").first(where: {
            $0.split(separator: " ", omittingEmptySubsequences: true).first == "cpu"
        }) else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst()
        let values = fields.compactMap { UInt64($0) }
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        let idle = values.indices.contains(3) ? values[3] : 0
        let iowait = values.indices.contains(4) ? values[4] : 0
        let nonBusy = idle.addingReportingOverflow(iowait)
        let busy: UInt64
        if nonBusy.overflow || nonBusy.partialValue > total {
            busy = 0
        } else {
            busy = total - nonBusy.partialValue
        }
        return GuestProcStatSample(busyJiffies: busy, totalJiffies: total)
    }
}

/// `/proc/meminfo` view. Values are in the kernel's native KiB units.
public struct GuestMemoryInfoSample: Sendable, Equatable {
    public let totalKB: UInt64
    public let availableKB: UInt64

    public var usedKB: UInt64 {
        totalKB >= availableKB ? totalKB - availableKB : 0
    }
}

public enum GuestMemInfoParser {
    /// Parses `/proc/meminfo`, requiring MemTotal; MemAvailable is treated as
    /// zero when an older kernel omits it. Returns nil if MemTotal is absent.
    public static func parse(_ text: String) -> GuestMemoryInfoSample? {
        var total: UInt64?
        var available: UInt64 = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let valueText = parts[1].split(separator: " ").first.flatMap(String.init)
            guard let raw = valueText, let value = UInt64(raw) else { continue }
            if key == "MemTotal" { total = value }
            else if key == "MemAvailable" { available = value }
        }
        guard let total else { return nil }
        return GuestMemoryInfoSample(totalKB: total, availableKB: available)
    }

    /// KiB → whole MiB conversion used for the resource sample.
    public static func megabytes(_ kilobytes: UInt64) -> Int {
        Int(kilobytes / 1024)
    }
}

/// Aggregate network byte counters across every non-loopback interface, as
/// reported by `/proc/net/dev`.
public struct GuestNetCounters: Sendable, Equatable {
    public let rxBytes: UInt64
    public let txBytes: UInt64
}

public enum GuestNetDevParser {
    /// Sums received/transmitted bytes of every non-loopback interface.
    ///
    /// Each data line is `iface: rxB rxP ... txB txP ...`; bytes are the
    /// first field after the colon (rx) and the ninth (tx). Header lines and
    /// malformed rows are ignored, so output is zero counters on bad input.
    public static func aggregateCounters(_ text: String) -> GuestNetCounters {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for line in text.split(separator: "\n") {
            guard line.contains(":") else { continue }
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let name = halves[0].trimmingCharacters(in: .whitespaces)
            guard name != "lo" else { continue }
            let fields = halves[1].split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9,
                  let rxBytes = UInt64(fields[0]),
                  let txBytes = UInt64(fields[8]) else { continue }
            rx &+= rxBytes
            tx &+= txBytes
        }
        return GuestNetCounters(rxBytes: rx, txBytes: tx)
    }
}

/// Pure delta arithmetic shared by the CPU sampler.
public enum GuestResourceDeltas {
    /// Converts a busy/total jiffie delta into a 0...1 fraction. Returns nil
    /// when there is no measurable delta (first sample, or a zero window).
    public static func fraction(busyDelta: UInt64, totalDelta: UInt64) -> Double? {
        guard totalDelta > 0 else { return nil }
        let value = Double(busyDelta) / Double(totalDelta)
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
