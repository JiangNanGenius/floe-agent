import Foundation
import BridgeCore

/// Redacted, read-only diagnostics. It intentionally contains no pairing
/// record, token, packet payload, certificate or provisioning identity.
enum BridgeDiagnosticsStatus {
    static func buildJSONData(logTail: Bool = true) -> Data {
        let snapshot = BridgeSharedState.shared.snapshot()
        let ddi = BridgeDDIProbe.status()
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let liveness = BridgeLivenessStatus.evaluate(
            snapshot: snapshot,
            liveness: BridgeAtomicFile.readJSON(BridgePaths.livenessFile),
            engineHeartbeat: BridgeAtomicFile.readJSON(BridgePaths.engineHeartbeatFile)
        )
        var root: [String: Any] = [
            "schema": 1,
            "generatedAt": BridgeClock.timestamp(),
            "prototype": true,
            "build": [
                "marketingVersion": BridgeBuild.marketingVersion,
                "buildNumber": BridgeBuild.buildNumber,
                "hostBundleIdentifier": BridgeBuild.hostBundleIdentifier,
                "tunnelBundleIdentifier": BridgeBuild.tunnelBundleIdentifier,
            ],
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "systemUptime": ProcessInfo.processInfo.systemUptime,
            "engine": snapshotDictionary(snapshot),
            "ddi": BridgeDDIProbe.dictionary(ddi),
            "ddiSource": BridgeAtomicFile.readJSON(BridgePaths.ddiSourceFile) ?? [:],
            "ddiRemoval": BridgeAtomicFile.readJSON(BridgePaths.ddiRemovalReportFile) ?? [:],
            "ddiInstallProgress": ownedReport(
                BridgeAtomicFile.readJSON(BridgePaths.ddiInstallProgressFile),
                snapshotGeneration: snapshot.generation,
                processIdentifier: processIdentifier
            ),
            "ddiStageProbe": ownedReport(
                BridgeAtomicFile.readJSON(BridgePaths.ddiStageProbeFile),
                snapshotGeneration: snapshot.generation,
                processIdentifier: processIdentifier
            ),
            "tunnelSnapshot": BridgeTunnelSnapshotStore.shared.status().dictionary(),
            "liveness": liveness.dictionary(),
            "engineReadyMarker": ownedReadyMarker(
                BridgeAtomicFile.readJSON(BridgePaths.engineReadyFile),
                snapshot: snapshot,
                processIdentifier: processIdentifier
            ),
            "engineEntryConfirmed": ownedDispatchedRecord(
                BridgeAtomicFile.readJSON(BridgePaths.engineEntryConfirmedFile),
                snapshot: snapshot,
                processIdentifier: processIdentifier
            ),
            "engineTerminal": ownedGenerationRecord(
                BridgeAtomicFile.readJSON(BridgePaths.engineTerminalFile),
                snapshot: snapshot,
                processIdentifier: processIdentifier
            ),
            "canary": canaryReportDictionary(
                snapshot: snapshot,
                processIdentifier: processIdentifier
            ),
            "files": [
                "status": BridgePaths.statusFile.path,
                "hostLog": BridgePaths.hostLogFile.path,
                "engineLog": BridgePaths.engineLogFile.path,
                "engineReady": BridgePaths.engineReadyFile.path,
                "engineHeartbeat": BridgePaths.engineHeartbeatFile.path,
                "engineTerminal": BridgePaths.engineTerminalFile.path,
                "engineEntryConfirmed": BridgePaths.engineEntryConfirmedFile.path,
                "liveness": BridgePaths.livenessFile.path,
                "canaryReport": BridgePaths.canaryReportFile.path,
                "ddiRemovalReport": BridgePaths.ddiRemovalReportFile.path,
                "ddiInstallProgress": BridgePaths.ddiInstallProgressFile.path,
                "ddiStageProbe": BridgePaths.ddiStageProbeFile.path,
            ],
        ]
        if logTail {
            root["logTail"] = BridgeLog.shared.tail(maxBytes: 8_192)
        }
        return (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
    }

    /// Ready markers carry a dispatched generation, not the current service
    /// generation. A resumed driver keeps the original dispatch, so that is
    /// the comparison used here.
    private static func ownedReadyMarker(
        _ marker: [String: Any]?,
        snapshot: BridgeSnapshot,
        processIdentifier: Int32
    ) -> [String: Any] {
        guard var marker else { return [:] }
        let pid = (marker["processIdentifier"] as? NSNumber)?.int32Value ?? -1
        let markerGeneration = (marker["dispatchedGeneration"] as? NSNumber)?.uint64Value
        marker["ownerIsCurrentProcess"] = pid == processIdentifier
        marker["currentProcessIdentifier"] = processIdentifier
        marker["statusDispatchedGeneration"] = snapshot.dispatchedGeneration.map(String.init) ?? ""
        marker["dispatchedGenerationMatchesStatus"] =
            markerGeneration != nil && markerGeneration == snapshot.dispatchedGeneration
        return marker
    }

    private static func ownedDispatchedRecord(
        _ record: [String: Any]?,
        snapshot: BridgeSnapshot,
        processIdentifier: Int32
    ) -> [String: Any] {
        guard var record else { return [:] }
        let pid = (record["processIdentifier"] as? NSNumber)?.int32Value ?? -1
        let generation = (record["dispatchedGeneration"] as? NSNumber)?.uint64Value
        record["ownerIsCurrentProcess"] = pid == processIdentifier
        record["currentProcessIdentifier"] = processIdentifier
        record["statusDispatchedGeneration"] = snapshot.dispatchedGeneration.map(String.init) ?? ""
        record["dispatchedGenerationMatchesStatus"] =
            generation != nil && generation == snapshot.dispatchedGeneration
        return record
    }

    private static func ownedGenerationRecord(
        _ record: [String: Any]?,
        snapshot: BridgeSnapshot,
        processIdentifier: Int32
    ) -> [String: Any] {
        guard var record else { return [:] }
        let pid = (record["processIdentifier"] as? NSNumber)?.int32Value ?? -1
        let generation = (record["generation"] as? NSNumber)?.uint64Value
        record["ownerIsCurrentProcess"] = pid == processIdentifier
        record["currentProcessIdentifier"] = processIdentifier
        record["ownerGenerationMatchesStatus"] = generation == snapshot.generation
        record["statusGeneration"] = snapshot.generation
        return record
    }

    private static func canaryReportDictionary(
        snapshot: BridgeSnapshot,
        processIdentifier: Int32
    ) -> [String: Any] {
        guard let report = BridgeCanaryReportStore.read() else { return [:] }
        var value = report.dictionary()
        let ownerCurrent = report.ownerProcessIdentifier == processIdentifier
        let generationMatch = report.ownerGeneration == snapshot.generation
        value["ownerIsCurrentProcess"] = ownerCurrent
        value["currentProcessIdentifier"] = processIdentifier
        value["ownerGenerationMatchesStatus"] = generationMatch
        value["statusGeneration"] = snapshot.generation
        value["staleOwner"] = !ownerCurrent
        // The report's own state stays truthful after a Stop/resume; the
        // generation fields say whether it belongs to the current generation.
        value["effectiveState"] = ownerCurrent ? report.state.rawValue : "stale"
        return value
    }

    /// Adds explicit ownership facts to a persisted diagnostic report. A file
    /// from an old process can therefore never be read as the current state,
    /// even when its own stage says "running".
    private static func ownedReport(
        _ report: [String: Any]?,
        snapshotGeneration: UInt64,
        processIdentifier: Int32
    ) -> [String: Any] {
        guard var report else { return [:] }
        let owner = BridgeDiagnosticReportOwner(
            hostPid: (report["hostPid"] as? NSNumber)?.int32Value ?? -1,
            generation: (report["generation"] as? NSNumber)?.uint64Value ?? 0
        )
        report["ownerIsCurrentProcess"] = owner.isCurrentProcess(processIdentifier)
        report["currentProcessIdentifier"] = processIdentifier
        report["ownerGenerationMatchesStatus"] = owner.matchesGeneration(snapshotGeneration)
        report["statusGeneration"] = snapshotGeneration
        return report
    }

    private static func snapshotDictionary(_ snapshot: BridgeSnapshot) -> [String: Any] {
        var value: [String: Any] = [
            "phase": snapshot.phase.rawValue,
            "generation": snapshot.generation,
            "hostPid": snapshot.hostPid,
            "startAttempted": snapshot.startAttempted,
            "serviceRunning": snapshot.serviceRunning,
            "oneShotDispatched": snapshot.oneShotDispatched,
            "dispatchedGeneration": snapshot.dispatchedGeneration.map(String.init) ?? "",
            "engineEntryObserved": snapshot.engineEntryObserved,
            "engineRunning": snapshot.engineRunning,
            "engineInitializedAt": snapshot.engineInitializedAt ?? "",
            "tunnel": snapshot.tunnel.rawValue,
            "tunnelProbe": snapshot.tunnelProbe,
            "ddi": snapshot.ddi.rawValue,
            "pairingImported": snapshot.pairingImported,
            "updatedAt": snapshot.updatedAt,
            "notes": Array(snapshot.notes.suffix(20)),
        ]
        if let valuePid = snapshot.enginePid { value["enginePid"] = valuePid }
        if let test = snapshot.engineTestMethod { value["engineTestMethod"] = test }
        if let layout = snapshot.ddiLayout { value["ddiLayout"] = layout }
        if let source = snapshot.ddiSource { value["ddiSource"] = source }
        if let lastMount = snapshot.lastOnDeviceMountAt { value["lastOnDeviceMountAt"] = lastMount }
        if let probeAt = snapshot.lastDDIProbeAt { value["lastDDIProbeAt"] = probeAt }
        if let probeMounted = snapshot.lastDDIProbeMounted { value["lastDDIProbeMounted"] = probeMounted }
        if let probeLayout = snapshot.lastDDIProbeLayout { value["lastDDIProbeLayout"] = probeLayout }
        if let probePath = snapshot.lastDDIProbePath { value["lastDDIProbePath"] = probePath }
        if let probeSource = snapshot.lastDDIProbeSource { value["lastDDIProbeSource"] = probeSource }
        if let error = snapshot.lastError { value["lastError"] = error }
        if let code = snapshot.errorCode { value["errorCode"] = code }
        if let activity = snapshot.activity { value["activity"] = activity }
        if let started = snapshot.startedAt { value["startedAt"] = started }
        if let ready = snapshot.readyAt { value["readyAt"] = ready }
        if let stopped = snapshot.stoppedAt { value["stoppedAt"] = stopped }
        return value
    }
}

/// Minimal interface enumeration for the LAN readback and control addresses
/// shown in the UI. No traffic is generated and no reachability is inferred.
enum BridgeNetworkInfo {
    private static func addresses(family: Int32) -> [(name: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(family) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let nameBytes = sequence(first: pointer.pointee.ifa_name, next: { $0.advanced(by: 1) })
                .prefix { $0.pointee != 0 }
                .map { UInt8(bitPattern: $0.pointee) }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if name == "lo0" { continue }
            let hostBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            candidates.append((name, String(decoding: hostBytes, as: UTF8.self)))
        }
        return candidates
    }

    /// en0 (Wi-Fi on iPhone) first, then any other live IPv4 interface. The
    /// list is display-only; the listener itself is family- and interface-
    /// agnostic.
    static func ipv4Addresses() -> [String] {
        ordered(addresses(family: AF_INET).map(\.address))
    }

    static func primaryIPv4Address() -> String? {
        ipv4Addresses().first
    }

    /// Global IPv6 addresses only; link-local addresses are omitted because a
    /// URL needs a scope identifier that the UI cannot infer reliably.
    static func ipv6Addresses() -> [String] {
        let raw = addresses(family: AF_INET6).map(\.address)
        return ordered(raw.filter { address in
            let lower = address.lowercased()
            return !lower.hasPrefix("fe80:") && !lower.hasPrefix("::1")
        })
    }

    /// Bracketed IPv6 candidates first (the native-Wi-Fi path that works even
    /// when the Mac's IPv4 ARP entry is incomplete), then IPv4.
    static func controlURLs(port: UInt16, path: String = "/v1/control") -> [String] {
        let ipv6 = ipv6Addresses().map { "http://[\($0)]:\(port)\(path)" }
        let ipv4 = ipv4Addresses().map { "http://\($0):\(port)\(path)" }
        return ordered(ipv6 + ipv4)
    }

    private static func ordered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values where seen.insert(value).inserted {
            output.append(value)
        }
        return output
    }
}
