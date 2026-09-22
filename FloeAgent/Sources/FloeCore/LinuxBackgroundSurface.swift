// FloeCore — PiP/status surface model for running Linux VMs.
//
// One entry is a truthful, point-in-time view of a single environment. It
// carries exactly what the user asked the floating surface to show: which
// VM/environment it is, CPU, memory, and the counts of active commands,
// managed services and published TCP port forwards. A value that has not been
// measured renders as "—", never as a fabricated zero.
//
// The pager keeps a multi-VM hold readable on a phone-sized PiP window: one VM
// per page with a stable "2/3" position label.

import Foundation

/// Point-in-time surface entry for one Linux environment.
public struct LinuxBackgroundSurfaceEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String { environmentID }
    public var environmentID: String
    public var title: String
    public var state: BackgroundWorkState
    /// Host-side emulator-thread CPU share, 0...1.
    public var emulatorCPUFraction: Double?
    /// Guest-reported aggregate CPU share from /proc, 0...1.
    public var guestCPUFraction: Double?
    public var memoryUsedMB: Int?
    public var memoryTotalMB: Int?
    /// Active guest commands, when the app can observe them; nil = unknown.
    public var activeCommandCount: Int?
    /// Managed long-running services in this environment.
    public var activeServiceCount: Int?
    /// Enabled TCP port-forward rules currently published for this VM.
    public var portForwardCount: Int?
    public var startedAt: Date?
    public var updatedAt: Date

    public init(
        environmentID: String,
        title: String,
        state: BackgroundWorkState = .running,
        emulatorCPUFraction: Double? = nil,
        guestCPUFraction: Double? = nil,
        memoryUsedMB: Int? = nil,
        memoryTotalMB: Int? = nil,
        activeCommandCount: Int? = nil,
        activeServiceCount: Int? = nil,
        portForwardCount: Int? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.environmentID = environmentID
        self.title = title
        self.state = state
        self.emulatorCPUFraction = emulatorCPUFraction.map(Self.clamp)
        self.guestCPUFraction = guestCPUFraction.map(Self.clamp)
        self.memoryUsedMB = memoryUsedMB.map { max(0, $0) }
        self.memoryTotalMB = memoryTotalMB.map { max(0, $0) }
        self.activeCommandCount = activeCommandCount.map { max(0, $0) }
        self.activeServiceCount = activeServiceCount.map { max(0, $0) }
        self.portForwardCount = portForwardCount.map { max(0, $0) }
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// CPU rendered from the guest value when available, else the emulator
    /// proxy. A fraction that was never measured renders "—".
    public var cpuText: String {
        let fraction = guestCPUFraction ?? emulatorCPUFraction
        guard let fraction else { return "—" }
        return String(format: "%.0f%%", fraction * 100)
    }

    public var memoryText: String {
        guard let used = memoryUsedMB, let total = memoryTotalMB else { return "—" }
        return "\(used) / \(total) MB"
    }

    public var commandText: String {
        activeCommandCount.map(String.init) ?? "—"
    }

    public var serviceText: String {
        activeServiceCount.map(String.init) ?? "—"
    }

    public var portText: String {
        portForwardCount.map(String.init) ?? "—"
    }

    public func elapsedSeconds(now: Date = Date()) -> Int? {
        guard let startedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    public func elapsedTimeLabel(now: Date = Date()) -> String {
        guard let total = elapsedSeconds(now: now) else { return "—" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// One caption line per resource. The PiP frame renders these as separate
    /// rows so a narrow window stays readable.
    public func captionLines(now: Date = Date()) -> [String] {
        [
            "\(title) · \(state.surfaceLabel)",
            "CPU \(cpuText) · 内存 \(memoryText)",
            "命令 \(commandText) · 服务 \(serviceText) · 端口 \(portText)",
            "已运行 \(elapsedTimeLabel(now: now))",
        ]
    }

    public func caption(now: Date = Date()) -> String {
        captionLines(now: now).joined(separator: "\n")
    }
}

public extension BackgroundWorkState {
    /// Short user-facing label for the floating surface.
    var surfaceLabel: String {
        switch self {
        case .queued: "排队中"
        case .running: "运行中"
        case .completing: "收尾中"
        case .completed: "已完成"
        case .failed: "运行失败"
        case .suspended: "已暂停"
        case .interrupted: "已中断"
        case .cancelled: "已取消"
        }
    }
}

/// Multi-VM pager for the PiP status surface. One VM per page; the current
/// page survives a refresh as long as its environment is still held.
public struct LinuxBackgroundSurfacePager: Sendable, Equatable {
    public private(set) var entries: [LinuxBackgroundSurfaceEntry]
    public private(set) var index: Int

    public init(entries: [LinuxBackgroundSurfaceEntry] = [], index: Int = 0) {
        self.entries = Self.ordered(entries)
        self.index = self.entries.isEmpty ? 0 : min(max(0, index), self.entries.count - 1)
    }

    /// Deterministic order: start time, then environment id. The same VMs
    /// therefore always occupy the same pages across refreshes.
    public static func ordered(
        _ entries: [LinuxBackgroundSurfaceEntry]
    ) -> [LinuxBackgroundSurfaceEntry] {
        entries.sorted { lhs, rhs in
            let lhsStart = lhs.startedAt ?? .distantPast
            let rhsStart = rhs.startedAt ?? .distantPast
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return lhs.environmentID < rhs.environmentID
        }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var current: LinuxBackgroundSurfaceEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    /// "2/3" when several VMs are held, empty for a single VM.
    public var positionLabel: String {
        guard entries.count > 1 else { return "" }
        return "\(index + 1)/\(entries.count)"
    }

    @discardableResult
    public mutating func advance() -> LinuxBackgroundSurfaceEntry? {
        guard !entries.isEmpty else { return nil }
        index = (index + 1) % entries.count
        return current
    }

    @discardableResult
    public mutating func rewind() -> LinuxBackgroundSurfaceEntry? {
        guard !entries.isEmpty else { return nil }
        index = (index - 1 + entries.count) % entries.count
        return current
    }

    @discardableResult
    public mutating func select(environmentID: String) -> LinuxBackgroundSurfaceEntry? {
        guard let position = entries.firstIndex(where: {
            $0.environmentID == environmentID
        }) else { return current }
        index = position
        return current
    }

    /// Replaces the entry set while keeping the same environment selected when
    /// it is still present. Additions/removals do not move the user's page.
    public mutating func reconcile(
        with newEntries: [LinuxBackgroundSurfaceEntry]
    ) {
        let selected = current?.environmentID
        entries = Self.ordered(newEntries)
        guard !entries.isEmpty else {
            index = 0
            return
        }
        if let selected, let position = entries.firstIndex(where: {
            $0.environmentID == selected
        }) {
            index = position
        } else {
            index = min(index, entries.count - 1)
        }
    }

    /// Full text for the current page, including the position label.
    public func surfaceText(now: Date = Date()) -> String {
        guard let current else { return "" }
        let prefix = positionLabel.isEmpty ? "" : "\(positionLabel) · "
        let lines = current.captionLines(now: now)
        guard let first = lines.first else { return "" }
        return ([prefix + first] + lines.dropFirst()).joined(separator: "\n")
    }
}
