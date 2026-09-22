// FloeCoreTests — Build 222 PiP/status surface model for running Linux VMs.
//
// The surface must show the real environment identity plus measured CPU,
// memory and the command/service/port counts, and must page across several
// active VMs without losing the user's selected page.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.LinuxBackgroundSurface")
struct LinuxBackgroundSurfaceTests {

    private func entry(
        id: String,
        title: String = "Linux 环境",
        startedAt: Date? = nil,
        commands: Int? = nil,
        services: Int? = nil,
        ports: Int? = nil
    ) -> LinuxBackgroundSurfaceEntry {
        LinuxBackgroundSurfaceEntry(
            environmentID: id,
            title: title,
            activeCommandCount: commands,
            activeServiceCount: services,
            portForwardCount: ports,
            startedAt: startedAt,
            updatedAt: Date()
        )
    }

    @Test("CPU, memory, command, service and port values render truthfully")
    func measuredValuesRender() {
        let entry = LinuxBackgroundSurfaceEntry(
            environmentID: "env-1",
            title: "数据分析环境",
            emulatorCPUFraction: 0.42,
            guestCPUFraction: 0.31,
            memoryUsedMB: 128,
            memoryTotalMB: 256,
            activeCommandCount: 2,
            activeServiceCount: 3,
            portForwardCount: 4
        )
        // The guest's own CPU figure wins over the host-side emulator proxy.
        #expect(entry.cpuText == "31%")
        #expect(entry.memoryText == "128 / 256 MB")
        #expect(entry.commandText == "2")
        #expect(entry.serviceText == "3")
        #expect(entry.portText == "4")
        let caption = entry.caption()
        #expect(caption.contains("数据分析环境"))
        #expect(caption.contains("运行中"))
        #expect(caption.contains("CPU 31%"))
        #expect(caption.contains("内存 128 / 256 MB"))
        #expect(caption.contains("命令 2"))
        #expect(caption.contains("服务 3"))
        #expect(caption.contains("端口 4"))
    }

    @Test("Unmeasured values are unknown, never a fabricated zero")
    func missingValuesAreUnknown() {
        let entry = self.entry(id: "env-1")
        #expect(entry.cpuText == "—")
        #expect(entry.memoryText == "—")
        #expect(entry.commandText == "—")
        #expect(entry.serviceText == "—")
        #expect(entry.portText == "—")
        #expect(entry.elapsedTimeLabel() == "—")
    }

    @Test("Measured fractions and counts are clamped to their real domain")
    func valuesAreClamped() {
        let entry = LinuxBackgroundSurfaceEntry(
            environmentID: "env-1",
            title: "环境",
            emulatorCPUFraction: 2.4,
            guestCPUFraction: -1,
            memoryUsedMB: -5,
            memoryTotalMB: -1,
            activeCommandCount: -3,
            activeServiceCount: -1,
            portForwardCount: -2
        )
        #expect(entry.guestCPUFraction == 0)
        #expect(entry.emulatorCPUFraction == 1)
        #expect(entry.commandText == "0")
        #expect(entry.serviceText == "0")
        #expect(entry.portText == "0")
    }

    @Test("The pager orders VMs deterministically and labels the position")
    func pagerOrderingAndLabel() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let pager = LinuxBackgroundSurfacePager(entries: [
            entry(id: "env-b", startedAt: start.addingTimeInterval(5)),
            entry(id: "env-a", startedAt: start),
            entry(id: "env-c", startedAt: start.addingTimeInterval(5)),
        ])
        #expect(pager.count == 3)
        #expect(pager.current?.environmentID == "env-a")
        #expect(pager.positionLabel == "1/3")
        let text = pager.surfaceText()
        #expect(text.contains("1/3 · "))
    }

    @Test("Paging advances and wraps across multiple active VMs")
    func pagerNavigation() {
        var pager = LinuxBackgroundSurfacePager(entries: [
            entry(id: "env-1", startedAt: Date(timeIntervalSince1970: 1)),
            entry(id: "env-2", startedAt: Date(timeIntervalSince1970: 2)),
            entry(id: "env-3", startedAt: Date(timeIntervalSince1970: 3)),
        ])
        #expect(pager.advance()?.environmentID == "env-2")
        #expect(pager.advance()?.environmentID == "env-3")
        #expect(pager.advance()?.environmentID == "env-1")
        #expect(pager.rewind()?.environmentID == "env-3")
        #expect(pager.positionLabel == "3/3")
        // A single VM never grows a position label.
        let single = LinuxBackgroundSurfacePager(entries: [entry(id: "env-1")])
        #expect(single.positionLabel == "")
    }

    @Test("Refreshing keeps the selected page while its VM is still held")
    func pagerReconcileKeepsSelection() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var pager = LinuxBackgroundSurfacePager(entries: [
            entry(id: "env-1", startedAt: start),
            entry(id: "env-2", startedAt: start.addingTimeInterval(1)),
            entry(id: "env-3", startedAt: start.addingTimeInterval(2)),
        ])
        _ = pager.select(environmentID: "env-2")

        // A metrics refresh with the same VMs must not move the page.
        pager.reconcile(with: [
            entry(id: "env-3", startedAt: start.addingTimeInterval(2), commands: 1),
            entry(id: "env-1", startedAt: start, services: 2),
            entry(id: "env-2", startedAt: start.addingTimeInterval(1), ports: 4),
        ])
        #expect(pager.current?.environmentID == "env-2")
        #expect(pager.current?.portText == "4")

        // When the selected VM stops the page falls back inside the new set.
        pager.reconcile(with: [
            entry(id: "env-1", startedAt: start),
            entry(id: "env-3", startedAt: start.addingTimeInterval(2)),
        ])
        #expect(pager.current?.environmentID == "env-3")

        pager.reconcile(with: [])
        #expect(pager.current == nil)
        #expect(pager.surfaceText().isEmpty)
    }

    @Test("Ordering falls back to the environment id for identical start times")
    func orderingTieBreak() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let ordered = LinuxBackgroundSurfacePager.ordered([
            entry(id: "env-z", startedAt: start),
            entry(id: "env-a", startedAt: start),
        ])
        #expect(ordered.map(\.environmentID) == ["env-a", "env-z"])
    }
}
