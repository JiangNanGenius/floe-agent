// SPDX-License-Identifier: MPL-2.0
//
// G07.1 network diagnostics — bounded MACHINE-STRUCTURED tool summary.
//
// The runtime keeps 4 KiB of an ordinary tool summary, so this projection is
// valid JSON (never a truncated raw payload) that preserves the required
// NetworkObservationV1 identity: version, operationID, method, source,
// status, measuredAt, network, observations, limitations and optional
// cacheAgeMs/target/missingPermissions. Method measurements are compacted
// deterministically; when a list is pruned the projection records
// `<section>Truncated`, `<section>Omitted`/count and an explicit limitation.
// `fullOutputSHA256` still covers the ORIGINAL measured bytes; nothing here
// mutates the observation or BridgeV3. Human-friendly presentation belongs
// to Main's feature/network UI.
import Foundation

public enum NetworkObservationSummary {
    /// Deliberately below the runtime's 4096-character ordinary-tool cap.
    public static let maximumCharacters = 4_000

    private struct Limits {
        let accessPoints: Int
        let dnsAnswers: Int
        let pingProbes: Int
        let tcpAttempts: Int
        let httpRedirects: Int
        let headers: Int
        let addresses: Int
        let capabilities: Int
    }

    private static let full = Limits(accessPoints: 8, dnsAnswers: 8, pingProbes: 10,
                                     tcpAttempts: 6, httpRedirects: 4, headers: 8,
                                     addresses: 4, capabilities: 8)
    private static let tight = Limits(accessPoints: 4, dnsAnswers: 4, pingProbes: 4,
                                      tcpAttempts: 3, httpRedirects: 2, headers: 4,
                                      addresses: 2, capabilities: 0)
    private static let minimal = Limits(accessPoints: 0, dnsAnswers: 0, pingProbes: 0,
                                        tcpAttempts: 0, httpRedirects: 0, headers: 0,
                                        addresses: 0, capabilities: 0)

    public static func render(_ observation: NetworkObservationV1) -> String {
        for limits in [full, tight, minimal] {
            let object = projection(observation, limits: limits)
            if let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8),
               text.count <= maximumCharacters {
                return text
            }
        }
        // Guaranteed-fit identity-only envelope. Every required key is
        // present; the detailed measurement is explicitly omitted rather
        // than emitting invalid/truncated JSON.
        let fallback: [String: Any] = identity(observation).merging([
            "network": ["available": observation.network.available ?? false],
            "observations": [
                "summaryPruned": true,
                "method": observation.method.rawValue,
            ],
            "limitations": boundedStrings(
                observation.limitations + [
                    "Detailed measurements were omitted to keep the structured tool summary within 4000 characters.",
                ], limit: 4, maxCharacters: 200),
            "summaryTruncated": true,
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: fallback,
                                                 options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return #"{"version":1,"status":"error","source":"phone","observations":{},"network":{},"limitations":[]}"#
    }

    // MARK: - Projection

    private static func projection(_ observation: NetworkObservationV1,
                                   limits: Limits) -> [String: Any] {
        var root = identity(observation)
        var notes: [String] = []
        root["network"] = compactNetwork(observation, limits: limits, notes: &notes)
        var observations: [String: Any] = [:]
        switch observation.method {
        case .status:
            observations = compactStatus(observation.observations.status, raw: observation.observations.raw)
        case .wifiScan:
            observations = compactWifiScan(observation.observations.wifiScan,
                                            raw: observation.observations.raw,
                                            limits: limits, notes: &notes)
        case .dnsLookup:
            observations = compactDNS(observation.observations.dnsLookup,
                                      raw: observation.observations.raw,
                                      limits: limits, notes: &notes)
        case .ping:
            observations = compactPing(observation.observations.ping,
                                       raw: observation.observations.raw,
                                       limits: limits, notes: &notes)
        case .tcpProbe:
            observations = compactTCP(observation.observations.tcpProbe,
                                      raw: observation.observations.raw,
                                      limits: limits, notes: &notes)
        case .http:
            observations = compactHTTP(observation.observations.http,
                                       raw: observation.observations.raw,
                                       limits: limits, notes: &notes)
        }
        copyRawDiagnostics(from: observation.observations.raw, into: &observations)
        root["observations"] = observations
        if notes.isEmpty {
            root["limitations"] = boundedStrings(observation.limitations, limit: 8,
                                                 maxCharacters: 200)
        } else {
            root["limitations"] = boundedStrings(observation.limitations + notes, limit: 8,
                                                 maxCharacters: 200)
            root["summaryTruncated"] = true
            root["summaryNotes"] = boundedStrings(notes, limit: 6, maxCharacters: 200)
        }
        if observation.limitations.count > 8 {
            root["limitationsOmitted"] = observation.limitations.count - 8
            root["summaryTruncated"] = true
        }
        return root
    }

    private static func identity(_ observation: NetworkObservationV1) -> [String: Any] {
        var root: [String: Any] = [
            "version": observation.version,
            "operationID": observation.operationID,
            "method": observation.method.rawValue,
            "source": observation.source,
            "status": observation.status.rawValue,
            "measuredAt": observation.measuredAt,
        ]
        if let cacheAgeMs = observation.cacheAgeMs { root["cacheAgeMs"] = cacheAgeMs }
        if let target = observation.target, !target.isEmpty {
            root["target"] = bounded(target, 256)
            if target.count > 256 { root["targetTruncated"] = true }
        }
        if let missing = observation.missingPermissions {
            root["missingPermissions"] = boundedStrings(missing, limit: 8, maxCharacters: 96)
            if missing.count > 8 {
                root["missingPermissionsOmitted"] = missing.count - 8
            }
        }
        return root
    }

    private static func compactNetwork(_ observation: NetworkObservationV1,
                                       limits: Limits,
                                       notes: inout [String]) -> [String: Any] {
        let network = observation.network
        var object: [String: Any] = [:]
        set(&object, "available", network.available)
        set(&object, "handle", network.handle)
        set(&object, "networkCount", network.networkCount)
        if !network.transports.isEmpty {
            object["transports"] = boundedStrings(network.transports, limit: 8,
                                                  maxCharacters: 32)
        }
        if limits.capabilities > 0, !network.capabilities.isEmpty {
            object["capabilities"] = boundedStrings(network.capabilities,
                                                    limit: limits.capabilities,
                                                    maxCharacters: 48)
            object["capabilityCount"] = network.capabilities.count
            if network.capabilities.count > limits.capabilities {
                notes.append("network capabilities pruned to \(limits.capabilities) of \(network.capabilities.count).")
            }
        }
        set(&object, "typeName", network.typeName)
        set(&object, "subtypeName", network.subtypeName)
        set(&object, "state", network.state)
        set(&object, "detailedState", network.detailedState)
        set(&object, "connected", network.connected)
        set(&object, "roaming", network.roaming)
        set(&object, "metered", network.metered)
        set(&object, "validated", network.validated)
        set(&object, "internet", network.internet)
        set(&object, "localNetwork", network.localNetwork)
        set(&object, "captivePortal", network.captivePortal)
        set(&object, "vpn", network.vpn)
        set(&object, "interfaceName", network.interfaceName)
        set(&object, "mtu", network.mtu)
        if !network.dnsServers.isEmpty {
            object["dnsServers"] = boundedStrings(network.dnsServers, limit: limits.addresses,
                                                   maxCharacters: 64)
            object["dnsServerCount"] = network.dnsServers.count
            if network.dnsServers.count > limits.addresses {
                notes.append("network DNS servers pruned to \(limits.addresses) of \(network.dnsServers.count).")
            }
        }
        set(&object, "domains", network.domains)
        set(&object, "privateDnsActive", network.privateDnsActive)
        set(&object, "privateDnsServerName", network.privateDnsServerName)
        if let proxy = network.httpProxy {
            var proxyObject: [String: Any] = [:]
            set(&proxyObject, "host", proxy.host)
            set(&proxyObject, "port", proxy.port)
            if !proxyObject.isEmpty { object["httpProxy"] = proxyObject }
        }
        if !network.linkAddresses.isEmpty {
            object["linkAddresses"] = boundedStrings(network.linkAddresses,
                                                      limit: limits.addresses,
                                                      maxCharacters: 64)
            object["linkAddressCount"] = network.linkAddresses.count
            if network.linkAddresses.count > limits.addresses {
                notes.append("network link addresses pruned to \(limits.addresses) of \(network.linkAddresses.count).")
            }
        }
        set(&object, "routes", network.routes)
        set(&object, "nat64Prefix", network.nat64Prefix)
        set(&object, "dhcpServer", network.dhcpServer)
        set(&object, "wakeOnLanSupported", network.wakeOnLanSupported)
        set(&object, "signalStrengthDbm", network.signalStrengthDbm)
        set(&object, "downstreamKbps", network.downstreamKbps)
        set(&object, "upstreamKbps", network.upstreamKbps)
        if let wifi = network.wifi {
            var wifiObject: [String: Any] = [:]
            set(&wifiObject, "ssid", wifi.ssid.map { bounded($0, 64) })
            set(&wifiObject, "ssidRedacted", wifi.ssidRedacted)
            if wifi.bssid != nil {
                // Withheld from the machine summary; in-App detail/export
                // rules own AP identifiers.
                wifiObject["bssidRedacted"] = true
            }
            set(&wifiObject, "rssiDbm", wifi.rssiDbm)
            set(&wifiObject, "frequencyMhz", wifi.frequencyMhz)
            set(&wifiObject, "channel", wifi.channel)
            set(&wifiObject, "band", wifi.band)
            set(&wifiObject, "linkSpeedMbps", wifi.linkSpeedMbps)
            set(&wifiObject, "rxLinkSpeedMbps", wifi.rxLinkSpeedMbps)
            set(&wifiObject, "txLinkSpeedMbps", wifi.txLinkSpeedMbps)
            set(&wifiObject, "wifiStandard", wifi.wifiStandard)
            set(&wifiObject, "hiddenSsid", wifi.hiddenSsid)
            object["wifi"] = wifiObject
        }
        return object
    }

    // MARK: - Method projections

    private static func compactStatus(_ detail: NetworkStatusDetail?,
                                      raw: [String: NetworkJSONValue]) -> [String: Any] {
        var object: [String: Any] = [:]
        if let detail {
            set(&object, "activeNetwork", detail.activeNetwork)
            set(&object, "networkCount", detail.networkCount)
            set(&object, "airplaneMode", detail.airplaneMode)
            set(&object, "wifiEnabled", detail.wifiEnabled)
            set(&object, "wifiState", detail.wifiState)
            set(&object, "scanAlwaysAvailable", detail.scanAlwaysAvailable)
            set(&object, "scanThrottleEnabled", detail.scanThrottleEnabled)
            set(&object, "locationServicesEnabled", detail.locationServicesEnabled)
            set(&object, "privateDnsActive", detail.privateDnsActive)
            set(&object, "privateDnsServerName", detail.privateDnsServerName)
            set(&object, "vpnTransport", detail.vpnTransport)
            set(&object, "metered", detail.metered)
            set(&object, "validated", detail.validated)
            set(&object, "internet", detail.internet)
            set(&object, "localNetwork", detail.localNetwork)
            set(&object, "captivePortal", detail.captivePortal)
        }
        copyRawDiagnostics(from: raw, into: &object)
        return object
    }

    private static func compactWifiScan(_ scan: NetworkWifiScanObservation?,
                                        raw: [String: NetworkJSONValue],
                                        limits: Limits,
                                        notes: inout [String]) -> [String: Any] {
        guard let scan else { return [:] }
        var object: [String: Any] = [:]
        set(&object, "cacheAgeMs", scan.cacheAgeMs)
        set(&object, "truncated", scan.truncated)
        let total = scan.totalAccessPoints ?? scan.accessPoints.count
        object["totalAccessPoints"] = total
        set(&object, "locationServicesEnabled", scan.locationServicesEnabled)
        set(&object, "wifiEnabled", scan.wifiEnabled)
        set(&object, "wifiState", scan.wifiState)
        set(&object, "refreshRequested", scan.refreshRequested)
        set(&object, "refreshOutcome", scan.refreshOutcome)
        set(&object, "scanThrottleEnabled", scan.scanThrottleEnabled)
        set(&object, "scanAccepted", scan.scanAccepted)
        set(&object, "resultsUpdated", scan.resultsUpdated)
        if !scan.hardware.isEmpty {
            object["hardware"] = scan.hardware.mapValues(\.foundationObject)
        }
        if !scan.channelCounts.isEmpty {
            object["channelCounts"] = scan.channelCounts.mapValues(\.foundationObject)
        }
        let rows = scan.accessPoints.prefix(limits.accessPoints).map { ap -> [String: Any] in
            var row: [String: Any] = [:]
            set(&row, "ssid", ap.ssid.map { bounded($0, 64) })
            set(&row, "ssidRedacted", ap.ssidRedacted)
            if ap.bssid != nil { row["bssidRedacted"] = true }
            set(&row, "rssiDbm", ap.rssiDbm)
            set(&row, "frequencyMhz", ap.frequencyMhz)
            set(&row, "channel", ap.resolvedChannel)
            set(&row, "band", ap.resolvedBand)
            set(&row, "ageMs", ap.ageMs)
            set(&row, "widthMhz", ap.widthMhz)
            set(&row, "capabilities", ap.capabilities.map { bounded($0, 96) })
            set(&row, "passpoint", ap.passpoint)
            set(&row, "venue", ap.venue.map { bounded($0, 64) })
            set(&row, "operator", ap.operatorName.map { bounded($0, 64) })
            if !ap.securityTypes.isEmpty {
                row["securityTypes"] = boundedStrings(ap.securityTypes, limit: 3, maxCharacters: 48)
            }
            set(&row, "wifiStandard", ap.wifiStandard)
            return row
        }
        object["accessPoints"] = rows
        let omitted = max(0, total - rows.count)
        if omitted > 0 {
            object["accessPointsTruncated"] = true
            object["accessPointsOmitted"] = omitted
            notes.append("Wi-Fi summary includes \(rows.count) of \(total) access points; \(omitted) omitted.")
        }
        return object
    }

    private static func compactDNS(_ lookup: NetworkDNSLookupObservation?,
                                   raw: [String: NetworkJSONValue],
                                   limits: Limits,
                                   notes: inout [String]) -> [String: Any] {
        guard let lookup else { return [:] }
        var object: [String: Any] = [:]
        set(&object, "recordType", lookup.recordType)
        if !lookup.queryTypes.isEmpty {
            object["queryTypes"] = boundedStrings(lookup.queryTypes, limit: 4,
                                                   maxCharacters: 16)
        }
        set(&object, "resolver", lookup.resolver)
        set(&object, "rcode", lookup.rcode)
        set(&object, "rcodeName", lookup.rcodeName)
        set(&object, "truncated", lookup.truncated)
        set(&object, "ttlSupported", lookup.ttlSupported)
        set(&object, "elapsedMs", lookup.elapsedMs)
        object["answerCount"] = lookup.answers.count
        let answers = lookup.answers.prefix(limits.dnsAnswers).map { answer -> [String: Any] in
            var row: [String: Any] = [:]
            set(&row, "name", answer.name.map { bounded($0, 253) })
            set(&row, "type", answer.type)
            set(&row, "ttlSeconds", answer.ttlSeconds)
            set(&row, "address", answer.address)
            set(&row, "value", answer.value.map { bounded($0, 253) })
            return row
        }
        object["answers"] = answers
        if lookup.answers.count > answers.count {
            object["answersTruncated"] = true
            object["answersOmitted"] = lookup.answers.count - answers.count
            notes.append("DNS summary includes \(answers.count) of \(lookup.answers.count) answers.")
        }
        if !lookup.addresses.isEmpty {
            object["addresses"] = boundedStrings(lookup.addresses, limit: limits.addresses,
                                                  maxCharacters: 64)
            object["addressCount"] = lookup.addresses.count
            if lookup.addresses.count > limits.addresses {
                notes.append("DNS addresses pruned to \(limits.addresses) of \(lookup.addresses.count).")
            }
        }
        if !lookup.queryFailures.isEmpty {
            let failures = lookup.queryFailures.prefix(4).map { failure -> [String: Any] in
                var row: [String: Any] = [:]
                set(&row, "type", failure.type)
                set(&row, "errorCode", failure.errorCode)
                set(&row, "errorClass", failure.errorClass)
                return row
            }
            object["queryFailures"] = failures
            if lookup.queryFailures.count > failures.count {
                object["queryFailuresTruncated"] = true
                object["queryFailuresOmitted"] = lookup.queryFailures.count - failures.count
            }
        }
        return object
    }

    private static func compactPing(_ ping: NetworkPingObservation?,
                                    raw: [String: NetworkJSONValue],
                                    limits: Limits,
                                    notes: inout [String]) -> [String: Any] {
        guard let ping else { return [:] }
        var object: [String: Any] = [:]
        set(&object, "countRequested", ping.countRequested)
        set(&object, "sent", ping.sent)
        set(&object, "received", ping.received)
        set(&object, "lost", ping.lost)
        set(&object, "packetLossPercent", ping.packetLossPercent)
        set(&object, "rttMinMs", ping.rttMinMs)
        set(&object, "rttAvgMs", ping.rttAvgMs)
        set(&object, "rttMaxMs", ping.rttMaxMs)
        set(&object, "resolvedAddress", ping.resolvedAddress)
        set(&object, "family", ping.family)
        set(&object, "timeoutBudgetMs", ping.timeoutBudgetMs)
        set(&object, "socketType", ping.socketType)
        object["probeCount"] = ping.probes.count
        let probes = ping.probes.prefix(limits.pingProbes).map { probe -> [String: Any] in
            var row: [String: Any] = [:]
            set(&row, "sequence", probe.sequence)
            set(&row, "replied", probe.replied)
            set(&row, "rttMs", probe.rttMillis)
            set(&row, "replyFrom", probe.replyFrom)
            return row
        }
        object["probes"] = probes
        if ping.probes.count > probes.count {
            object["probesTruncated"] = true
            object["probesOmitted"] = ping.probes.count - probes.count
            notes.append("Ping summary includes \(probes.count) of \(ping.probes.count) probes.")
        }
        return object
    }

    private static func compactTCP(_ probe: NetworkTCPProbeObservation?,
                                   raw: [String: NetworkJSONValue],
                                   limits: Limits,
                                   notes: inout [String]) -> [String: Any] {
        guard let probe else { return [:] }
        var object: [String: Any] = [:]
        set(&object, "connected", probe.connected)
        set(&object, "port", probe.port)
        set(&object, "refused", probe.refused)
        set(&object, "connectTimeMs", probe.connectTimeMs)
        set(&object, "localAddress", probe.localAddress)
        set(&object, "localPort", probe.localPort)
        set(&object, "remoteAddress", probe.remoteAddress)
        set(&object, "timeoutBudgetMs", probe.timeoutBudgetMs)
        if !probe.resolvedAddresses.isEmpty {
            object["resolvedAddresses"] = boundedStrings(probe.resolvedAddresses,
                                                          limit: limits.addresses,
                                                          maxCharacters: 64)
            object["resolvedAddressCount"] = probe.resolvedAddresses.count
            if probe.resolvedAddresses.count > limits.addresses {
                notes.append("TCP resolved addresses pruned to \(limits.addresses) of \(probe.resolvedAddresses.count).")
            }
        }
        object["attemptCount"] = probe.attempts.count
        let attempts = probe.attempts.prefix(limits.tcpAttempts).map { attempt -> [String: Any] in
            var row: [String: Any] = [:]
            set(&row, "address", attempt.address)
            set(&row, "family", attempt.family)
            set(&row, "result", attempt.result)
            set(&row, "elapsedMs", attempt.elapsedMs)
            set(&row, "errorClass", attempt.errorClass)
            return row
        }
        object["attempts"] = attempts
        if probe.attempts.count > attempts.count {
            object["attemptsTruncated"] = true
            object["attemptsOmitted"] = probe.attempts.count - attempts.count
            notes.append("TCP summary includes \(attempts.count) of \(probe.attempts.count) attempts.")
        }
        return object
    }

    private static func compactHTTP(_ http: NetworkHTTPObservation?,
                                    raw: [String: NetworkJSONValue],
                                    limits: Limits,
                                    notes: inout [String]) -> [String: Any] {
        guard let http else { return [:] }
        var object: [String: Any] = [:]
        set(&object, "requestedUrl", http.requestedUrl.map { bounded($0, 512) })
        set(&object, "finalUrl", http.finalUrl.map { bounded($0, 512) })
        set(&object, "statusCode", http.statusCode)
        set(&object, "redirectCount", http.redirectCount)
        set(&object, "contentType", http.contentType.map { bounded($0, 128) })
        set(&object, "contentLength", http.contentLength)
        set(&object, "stoppedReason", http.stoppedReason)
        var tls: [String: Any] = [:]
        set(&tls, "cipherSuite", http.tlsCipherSuite)
        set(&tls, "certificateChainAnalyzed", http.certificateChainAnalyzed)
        if !tls.isEmpty { object["tls"] = tls }
        object["redirectCountObserved"] = http.redirects.count
        let redirects = http.redirects.prefix(limits.httpRedirects).map { redirect -> [String: Any] in
            var row: [String: Any] = [:]
            set(&row, "statusCode", redirect.statusCode)
            set(&row, "url", redirect.url.map { bounded($0, 512) })
            set(&row, "redirectedTo", redirect.redirectedTo.map { bounded($0, 512) })
            return row
        }
        object["redirects"] = redirects
        if http.redirects.count > redirects.count {
            object["redirectsTruncated"] = true
            object["redirectsOmitted"] = http.redirects.count - redirects.count
            notes.append("HTTPS summary includes \(redirects.count) of \(http.redirects.count) redirects.")
        }
        return object
    }

    // MARK: - Shared helpers

    private static func copyRawDiagnostics(from raw: [String: NetworkJSONValue],
                                           into object: inout [String: Any]) {
        let copied: [String: Int] = [
            "requiredFor": 128, "errorCode": 128, "unsupportedReason": 128,
            "reason": 128, "message": 200, "phase": 64, "cancelled": 8,
            "truncated": 8, "limitBytes": 16, "timeoutMs": 16, "cacheAgeMs": 16,
        ]
        for (key, limit) in copied {
            guard let value = raw[key] else { continue }
            if key == "cancelled" || key == "truncated" {
                if let bool = value.boolValue { object[key] = bool }
            } else if let int = value.intValue, key == "limitBytes" || key == "timeoutMs" || key == "cacheAgeMs" {
                object[key] = int
            } else if let string = value.stringValue {
                object[key] = bounded(string, limit)
            } else if let int = value.intValue {
                object[key] = int
            }
        }
    }

    private static func set(_ object: inout [String: Any], _ key: String, _ value: Any?) {
        guard let value else { return }
        object[key] = value
    }

    private static func bounded(_ value: String, _ limit: Int) -> String {
        let cleaned = String(value.filter { character in
            character.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        })
        return String(cleaned.prefix(limit))
    }

    private static func boundedStrings(_ values: [String], limit: Int,
                                       maxCharacters: Int = 300) -> [String] {
        values.prefix(limit).map { bounded($0, maxCharacters) }
    }
}
