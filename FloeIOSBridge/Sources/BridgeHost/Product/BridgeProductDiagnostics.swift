import Foundation

import BridgeCore

/// Public-safe diagnostics projection. It never includes file paths, client
/// ids or names, pairing/control secrets, typed text, images or log bodies.
/// The model exposes this object for explicit export; the richer prototype
/// diagnostics JSON remains internal and is not presented by the product UI.
struct BridgeProductDiagnosticsReport: Codable, Equatable, Sendable {
    struct State: Codable, Equatable, Sendable {
        var phase: String
        var engineState: String
        var engineEntryObserved: Bool
        var engineRunning: Bool
        var serviceRunning: Bool
        var oneShotDispatched: Bool
        var terminalFault: Bool
        var pairingImported: Bool
        var ddi: String
        var tunnel: String
    }

    struct Service: Codable, Equatable, Sendable {
        var running: Bool
        var loopbackReady: Bool
        var lanEnabled: Bool
        var lanReady: Bool
        var bonjourState: String
        var port: Int?
        var engineReadiness: String
        var supportedMethodCount: Int
        var clientCount: Int
        var capabilities: [String]
        var storageAvailable: Bool
        var storageError: String?
        var networkError: String?
        var pendingApproval: Bool
    }

    struct Timing: Codable, Equatable, Sendable {
        var startedAt: String?
        var readyAt: String?
        var stoppedAt: String?
        var updatedAt: String
    }

    struct Logging: Codable, Equatable, Sendable {
        var source: String
        var retention: String
        var eventCount: Int
        var persistence: String
        var lastFailure: String?
        var retainedDates: [String]
    }

    var schema: Int
    var generatedAt: String
    var product: String
    var marketingVersion: String
    var buildNumber: String
    var state: State
    var service: Service
    var timing: Timing
    var logging: Logging
    var lastError: String?
    var listenerError: String?
    var recentNotes: [String]

    static func make(shared: BridgeSnapshot,
                     rpc: BridgeRPCHostSnapshot,
                     listenerError: String?,
                     pendingApproval: Bool,
                     statusLog: BridgeProductStatusLogHealth = .unavailable,
                     generatedAt: Date = Date()) -> BridgeProductDiagnosticsReport {
        BridgeProductDiagnosticsReport(
            schema: 1,
            generatedAt: BridgeClock.timestamp(generatedAt),
            product: BridgeProductRuntime.productName,
            marketingVersion: BridgeBuild.marketingVersion,
            buildNumber: BridgeBuild.buildNumber,
            state: State(
                phase: shared.phase.rawValue,
                engineState: engineState(shared),
                engineEntryObserved: shared.engineEntryObserved,
                engineRunning: shared.engineRunning,
                serviceRunning: shared.serviceRunning,
                oneShotDispatched: shared.oneShotDispatched,
                terminalFault: shared.terminalFault,
                pairingImported: shared.pairingImported,
                ddi: shared.ddi.rawValue,
                tunnel: shared.tunnel.rawValue
            ),
            service: Service(
                running: rpc.running,
                loopbackReady: rpc.loopbackReady,
                lanEnabled: rpc.lanEnabled,
                lanReady: rpc.lanReady,
                bonjourState: rpc.bonjourState,
                port: rpc.port.map(Int.init),
                engineReadiness: engineReadiness(rpc.engine.readiness),
                supportedMethodCount: rpc.engine.supportedMethods.count,
                clientCount: rpc.clients.count,
                capabilities: rpc.capabilities.sorted(),
                storageAvailable: rpc.storageError == nil && rpc.nonceStoreAvailable,
                storageError: rpc.storageError.map { BridgeProductRedaction.text($0) },
                networkError: rpc.networkError.map { BridgeProductRedaction.text($0) },
                pendingApproval: pendingApproval
            ),
            timing: Timing(
                startedAt: shared.startedAt,
                readyAt: shared.readyAt,
                stoppedAt: shared.stoppedAt,
                updatedAt: shared.updatedAt
            ),
            logging: Logging(
                source: "structured-status-events",
                retention: "bounded-512-events-128k-plus-one-rotation",
                eventCount: statusLog.eventCount,
                persistence: statusLog.persistence,
                lastFailure: statusLog.lastFailure,
                retainedDates: statusLog.retainedDates
            ),
            lastError: shared.lastError.map { BridgeProductRedaction.text($0) },
            listenerError: listenerError.map { BridgeProductRedaction.text($0) },
            recentNotes: shared.notes.suffix(12).map { BridgeProductRedaction.text($0, limit: 180) }
        )
    }

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func engineState(_ snapshot: BridgeSnapshot) -> String {
        if snapshot.terminalFault { return "reopen-required" }
        if snapshot.engineRunning { return "running" }
        if snapshot.engineEntryObserved { return "initialized-stopped" }
        if snapshot.oneShotDispatched { return "entry-dispatched" }
        switch snapshot.phase {
        case .failed: return "failed"
        case .stopped: return "stopped"
        case .idle: return "not-started"
        default: return "preparing"
        }
    }

    private static func engineReadiness(_ readiness: BridgeRPCEngineReadiness) -> String {
        switch readiness {
        case .notRegistered: return "not-registered"
        case .notReady: return "not-ready"
        case .ready: return "ready"
        }
    }
}

/// Redacts display/export strings without trying to preserve a path. A user's
/// home directory, volume path, temporary extraction directory or another
/// file path is never useful in a product support export.
enum BridgeProductRedaction {
    private static let blockedScalars: Set<UInt32> = {
        var values: Set<UInt32> = [0xFEFF]
        values.formUnion(0x200B...0x200F)
        values.formUnion(0x202A...0x202E)
        values.formUnion(0x2060...0x2064)
        values.formUnion(0x2066...0x2069)
        return values
    }()

    static func text(_ raw: String, limit: Int = 320) -> String {
        var value = stripFormatCharacters(raw)
        value = replacePathLikeSequences(in: value)
        value = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > limit {
            value = String(value.prefix(limit)) + "…"
        }
        return value
    }

    private static func stripFormatCharacters(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.filter { scalar in
            let value = scalar.value
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if blockedScalars.contains(value) { return false }
            return true
        }
        return String(String.UnicodeScalarView(filtered))
    }

    private static func replacePathLikeSequences(in raw: String) -> String {
        let prefixes = [
            "/Users/", "/Volumes/", "/private/", "/var/", "/tmp/",
            "/Library/", "/System/", "/Applications/", "/Developer/",
        ]
        var value = raw
        for prefix in prefixes {
            while let range = value.range(of: prefix) {
                let tail = value[range.lowerBound...]
                let end = tail.firstIndex(where: { character in
                    character == " " || character == "\"" || character == "'" ||
                        character == ")" || character == "]" || character == "}" ||
                        character == "," || character == ";" || character == "\n"
                }) ?? tail.endIndex
                value.replaceSubrange(range.lowerBound..<end, with: "<path>")
            }
        }
        return value
    }
}
