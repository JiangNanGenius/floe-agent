// SPDX-License-Identifier: MPL-2.0
//
// G07.1 network diagnostics — typed NetworkObservationV1.
//
// Wire authority (frozen, platform01 `PhoneNetworkService`):
//   {version:1, operationID, method, source:"phone",
//    status:"ok"|"partial"|"permissionRequired"|"unavailable"|"unsupported"|
//           "cancelled"|"timeout"|"error",
//    measuredAt:ISO8601, cacheAgeMs?, network:{...}, target?,
//    observations:{...}, limitations?, missingPermissions?:[string]}
//
// Field names below mirror the ACTUAL `NetworkSnapshot`, Wi-Fi scan, DNS,
// ping, TCP and HTTPS JSON emitted by core/network (not an assumed schema).
// The envelope identity is validated against the REQUEST this tool issued
// (operationID/method/version/source), so a stale or cross-wired reply can
// never be reported as this call's measurement. Unknown fields are preserved
// verbatim for honest export; absent fields stay absent and the service's own
// `limitations` explain what the OS could not expose.
import Foundation

public enum NetworkObservationStatus: String, Sendable, Codable, CaseIterable {
    case ok
    case partial
    case permissionRequired
    case unavailable
    case unsupported
    case cancelled
    case timeout
    case error
}

public enum NetworkObservationError: Error, Sendable, Equatable {
    case tooLarge(Int)
    case malformed
    case unsupportedVersion(Int)
    case wrongSource(String)
    case wrongMethod(String)
    case operationMismatch
    case invalidStatus(String)
    case invalidTimestamp(String)
    case missingPermissions
    case emptyExport
}

// MARK: - Network snapshot (actual captured Android Network)

public struct NetworkHTTPProxy: Sendable, Equatable {
    public let host: String?
    public let port: Int?
}

public struct NetworkWifiLink: Sendable, Equatable {
    public let ssid: String?
    public let ssidRedacted: Bool?
    public let bssid: String?
    public let bssidRedacted: Bool?
    public let rssiDbm: Int?
    public let frequencyMhz: Int?
    public let channel: Int?
    public let band: String?
    public let linkSpeedMbps: Int?
    public let rxLinkSpeedMbps: Int?
    public let txLinkSpeedMbps: Int?
    public let wifiStandard: String?
    public let hiddenSsid: Bool?

    init(object: [String: NetworkJSONValue]) {
        ssid = NetworkJSONValue.firstString(object, ["ssid"])
        ssidRedacted = NetworkJSONValue.firstBool(object, ["ssidRedacted"])
        bssid = NetworkJSONValue.firstString(object, ["bssid"])
        bssidRedacted = NetworkJSONValue.firstBool(object, ["bssidRedacted"])
        rssiDbm = NetworkJSONValue.firstInt(object, ["rssiDbm", "rssi"])
        frequencyMhz = NetworkJSONValue.firstInt(object, ["frequencyMhz", "frequencyMHz"])
        channel = NetworkJSONValue.firstInt(object, ["channel"])
        band = NetworkJSONValue.firstString(object, ["band"])
        linkSpeedMbps = NetworkJSONValue.firstInt(object, ["linkSpeedMbps"])
        rxLinkSpeedMbps = NetworkJSONValue.firstInt(object, ["rxLinkSpeedMbps"])
        txLinkSpeedMbps = NetworkJSONValue.firstInt(object, ["txLinkSpeedMbps"])
        wifiStandard = NetworkJSONValue.firstString(object, ["wifiStandard"])
        hiddenSsid = NetworkJSONValue.firstBool(object, ["hiddenSsid"])
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public let available: Bool?
    public let handle: String?
    public let networkCount: Int?
    public let transports: [String]
    public let capabilities: [String]
    public let typeName: String?
    public let subtypeName: String?
    public let state: String?
    public let detailedState: String?
    public let connected: Bool?
    public let roaming: Bool?
    public let metered: Bool?
    public let validated: Bool?
    public let internet: Bool?
    public let localNetwork: Bool?
    public let captivePortal: Bool?
    public let vpn: Bool?
    public let interfaceName: String?
    public let mtu: Int?
    public let dnsServers: [String]
    public let domains: String?
    public let privateDnsActive: Bool?
    public let privateDnsServerName: String?
    public let httpProxy: NetworkHTTPProxy?
    public let linkAddresses: [String]
    public let routes: Int?
    public let nat64Prefix: String?
    public let dhcpServer: String?
    public let wakeOnLanSupported: Bool?
    public let signalStrengthDbm: Int?
    public let downstreamKbps: Int?
    public let upstreamKbps: Int?
    public let wifi: NetworkWifiLink?
    /// Every unmodeled field stays available for exact export.
    public let additional: [String: NetworkJSONValue]

    init(object: [String: NetworkJSONValue]) {
        available = NetworkJSONValue.firstBool(object, ["available"])
        handle = NetworkJSONValue.firstString(object, ["handle"])
        networkCount = NetworkJSONValue.firstInt(object, ["networkCount"])
        transports = (NetworkJSONValue.firstArray(object, ["transports"]) ?? [])
            .compactMap(\.stringValue)
        capabilities = (NetworkJSONValue.firstArray(object, ["capabilities"]) ?? [])
            .compactMap(\.stringValue)
        typeName = NetworkJSONValue.firstString(object, ["typeName", "networkType", "type"])
        subtypeName = NetworkJSONValue.firstString(object, ["subtypeName"])
        state = NetworkJSONValue.firstString(object, ["state"])
        detailedState = NetworkJSONValue.firstString(object, ["detailedState"])
        connected = NetworkJSONValue.firstBool(object, ["connected"])
        roaming = NetworkJSONValue.firstBool(object, ["roaming"])
        metered = NetworkJSONValue.firstBool(object, ["metered"])
        validated = NetworkJSONValue.firstBool(object, ["validated"])
        internet = NetworkJSONValue.firstBool(object, ["internet"])
        localNetwork = NetworkJSONValue.firstBool(object, ["localNetwork"])
        captivePortal = NetworkJSONValue.firstBool(object, ["captivePortal"])
        vpn = NetworkJSONValue.firstBool(object, ["vpn", "vpnActive", "isVpn"])
        interfaceName = NetworkJSONValue.firstString(object, ["interfaceName", "interface"])
        mtu = NetworkJSONValue.firstInt(object, ["mtu"])
        dnsServers = (NetworkJSONValue.firstArray(object, ["dnsServers", "dnsAddresses"]) ?? [])
            .compactMap(\.stringValue)
        domains = NetworkJSONValue.firstString(object, ["domains"])
        privateDnsActive = NetworkJSONValue.firstBool(object, ["privateDnsActive"])
        privateDnsServerName = NetworkJSONValue.firstString(
            object, ["privateDnsServerName", "privateDNS", "privateDns"])
        httpProxy = NetworkJSONValue.first(object, ["httpProxy"])?.objectValue.map {
            NetworkHTTPProxy(
                host: NetworkJSONValue.firstString($0, ["host"]),
                port: NetworkJSONValue.firstInt($0, ["port"]))
        }
        linkAddresses = (NetworkJSONValue.firstArray(
            object, ["linkAddresses", "addresses"]) ?? []).compactMap(\.stringValue)
        routes = NetworkJSONValue.firstInt(object, ["routes"])
        nat64Prefix = NetworkJSONValue.firstString(object, ["nat64Prefix"])
        dhcpServer = NetworkJSONValue.firstString(object, ["dhcpServer"])
        wakeOnLanSupported = NetworkJSONValue.firstBool(object, ["wakeOnLanSupported"])
        signalStrengthDbm = NetworkJSONValue.firstInt(
            object, ["signalStrengthDbm", "signalStrength"])
        downstreamKbps = NetworkJSONValue.firstInt(
            object, ["downstreamKbps", "linkDownstreamKbps"])
        upstreamKbps = NetworkJSONValue.firstInt(
            object, ["upstreamKbps", "linkUpstreamKbps"])
        wifi = NetworkJSONValue.first(object, ["wifi"])?.objectValue.map {
            NetworkWifiLink(object: $0)
        }
        additional = object
    }

    // Compatibility aliases used by the summary and older callers.
    public var transport: String? { transports.first }
    public var networkType: String? { typeName }
    public var vpnActive: Bool? { vpn }
    public var addresses: [String] { linkAddresses }
    public var privateDNS: String? { privateDnsServerName }
}

// MARK: - Per-method typed observation views

public struct NetworkStatusDetail: Sendable, Equatable {
    public let activeNetwork: Bool?
    public let networkCount: Int?
    public let airplaneMode: Bool?
    public let wifiEnabled: Bool?
    public let wifiState: String?
    public let scanAlwaysAvailable: Bool?
    public let scanThrottleEnabled: Bool?
    public let locationServicesEnabled: Bool?
    public let privateDnsActive: Bool?
    public let privateDnsServerName: String?
    public let vpnTransport: Bool?
    public let metered: Bool?
    public let validated: Bool?
    public let internet: Bool?
    public let localNetwork: Bool?
    public let captivePortal: Bool?

    init?(object: [String: NetworkJSONValue]) {
        let active = NetworkJSONValue.firstBool(object, ["activeNetwork"])
        let count = NetworkJSONValue.firstInt(object, ["networkCount"])
        let airplane = NetworkJSONValue.firstBool(object, ["airplaneMode"])
        let wifiEnabled = NetworkJSONValue.firstBool(object, ["wifiEnabled"])
        let wifiState = NetworkJSONValue.firstString(object, ["wifiState"])
        let scanAlways = NetworkJSONValue.firstBool(object, ["scanAlwaysAvailable"])
        let scanThrottle = NetworkJSONValue.firstBool(object, ["scanThrottleEnabled"])
        let location = NetworkJSONValue.firstBool(object, ["locationServicesEnabled"])
        let privateActive = NetworkJSONValue.firstBool(object, ["privateDnsActive"])
        let privateName = NetworkJSONValue.firstString(object, ["privateDnsServerName"])
        let vpnTransport = NetworkJSONValue.firstBool(object, ["vpnTransport"])
        let metered = NetworkJSONValue.firstBool(object, ["metered"])
        let validated = NetworkJSONValue.firstBool(object, ["validated"])
        let internet = NetworkJSONValue.firstBool(object, ["internet"])
        let local = NetworkJSONValue.firstBool(object, ["localNetworkCapability", "localNetwork"])
        let captive = NetworkJSONValue.firstBool(object, ["captivePortal"])
        guard active != nil || count != nil || airplane != nil || wifiEnabled != nil
            || wifiState != nil || scanAlways != nil || scanThrottle != nil
            || location != nil || privateActive != nil || privateName != nil
            || vpnTransport != nil || metered != nil || validated != nil
            || internet != nil || local != nil || captive != nil else { return nil }
        self.activeNetwork = active
        self.networkCount = count
        self.airplaneMode = airplane
        self.wifiEnabled = wifiEnabled
        self.wifiState = wifiState
        self.scanAlwaysAvailable = scanAlways
        self.scanThrottleEnabled = scanThrottle
        self.locationServicesEnabled = location
        self.privateDnsActive = privateActive
        self.privateDnsServerName = privateName
        self.vpnTransport = vpnTransport
        self.metered = metered
        self.validated = validated
        self.internet = internet
        self.localNetwork = local
        self.captivePortal = captive
    }
}

public struct NetworkWifiAccessPoint: Sendable, Equatable {
    public let ssid: String?
    public let ssidRedacted: Bool?
    public let bssid: String?
    public let bssidRedacted: Bool?
    public let rssiDbm: Int?
    public let frequencyMhz: Int?
    public let channel: Int?
    public let band: String?
    public let ageMs: Int?
    public let timestampMicros: Int?
    public let widthMhz: Int?
    public let centerFreq0Mhz: Int?
    public let centerFreq1Mhz: Int?
    public let capabilities: String?
    public let passpoint: Bool?
    public let venue: String?
    public let operatorName: String?
    public let securityTypes: [String]
    public let wifiStandard: String?

    init(object: [String: NetworkJSONValue]) {
        ssid = NetworkJSONValue.firstString(object, ["ssid"])
        ssidRedacted = NetworkJSONValue.firstBool(object, ["ssidRedacted"])
        bssid = NetworkJSONValue.firstString(object, ["bssid"])
        bssidRedacted = NetworkJSONValue.firstBool(object, ["bssidRedacted"])
        rssiDbm = NetworkJSONValue.firstInt(object, ["rssiDbm", "levelDbm", "level", "rssi"])
        frequencyMhz = NetworkJSONValue.firstInt(
            object, ["frequencyMhz", "frequencyMHz", "frequency"])
        channel = NetworkJSONValue.firstInt(object, ["channel"])
        band = NetworkJSONValue.firstString(object, ["band"])
        ageMs = NetworkJSONValue.firstInt(object, ["ageMs", "cacheAgeMs"])
        timestampMicros = NetworkJSONValue.firstInt(
            object, ["timestampMicros", "timestampMs", "timestamp"])
        widthMhz = NetworkJSONValue.firstInt(
            object, ["widthMhz", "channelWidthMHz", "channelWidth"])
        centerFreq0Mhz = NetworkJSONValue.firstInt(
            object, ["centerFreq0Mhz", "centerFreq0MHz", "centerFreq0"])
        centerFreq1Mhz = NetworkJSONValue.firstInt(
            object, ["centerFreq1Mhz", "centerFreq1MHz", "centerFreq1"])
        capabilities = NetworkJSONValue.firstString(object, ["capabilities"])
        passpoint = NetworkJSONValue.firstBool(object, ["passpoint", "isPasspoint"])
        venue = NetworkJSONValue.firstString(object, ["venue"])
        operatorName = NetworkJSONValue.firstString(
            object, ["operator", "operatorName", "providerName"])
        securityTypes = (NetworkJSONValue.firstArray(object, ["securityTypes"]) ?? [])
            .compactMap(\.stringValue)
        wifiStandard = NetworkJSONValue.firstString(object, ["wifiStandard"])
    }

    public var levelDbm: Int? { rssiDbm }
    public var frequencyMHz: Int? { frequencyMhz }
    public var channelWidthMHz: Int? { widthMhz }
    public var isPasspoint: Bool? { passpoint }
    public var resolvedBand: String? {
        if let band, !band.isEmpty { return band }
        guard let frequencyMhz else { return nil }
        switch frequencyMhz {
        case 2_400...2_500: return "2.4GHz"
        case 4_900...5_925: return "5GHz"
        case 5_925...7_125: return "6GHz"
        default: return nil
        }
    }

    public var resolvedChannel: Int? {
        if let channel { return channel }
        guard let frequencyMhz else { return nil }
        switch frequencyMhz {
        case 2_412...2_472: return (frequencyMhz - 2_407) / 5
        case 5_000...5_900: return (frequencyMhz - 5_000) / 5
        case 5_955...7_115: return (frequencyMhz - 5_950) / 5
        default: return nil
        }
    }
}

public struct NetworkWifiScanObservation: Sendable, Equatable {
    public let cacheAgeMs: Int?
    public let truncated: Bool?
    public let totalAccessPoints: Int?
    public let locationServicesEnabled: Bool?
    public let wifiEnabled: Bool?
    public let wifiState: String?
    public let refreshRequested: Bool?
    public let refreshOutcome: String?
    public let scanThrottleEnabled: Bool?
    public let scanAccepted: Bool?
    public let resultsUpdated: Bool?
    public let channelCounts: [String: NetworkJSONValue]
    public let hardware: [String: NetworkJSONValue]
    public let accessPoints: [NetworkWifiAccessPoint]

    init(object: [String: NetworkJSONValue]) {
        cacheAgeMs = NetworkJSONValue.firstInt(object, ["cacheAgeMs", "ageMs"])
        truncated = NetworkJSONValue.firstBool(object, ["truncated", "resultsTruncated"])
        totalAccessPoints = NetworkJSONValue.firstInt(object, ["totalAccessPoints"])
        locationServicesEnabled = NetworkJSONValue.firstBool(
            object, ["locationServicesEnabled", "locationEnabled"])
        wifiEnabled = NetworkJSONValue.firstBool(object, ["wifiEnabled"])
        wifiState = NetworkJSONValue.firstString(object, ["wifiState"])
        refreshRequested = NetworkJSONValue.firstBool(object, ["refreshRequested"])
        refreshOutcome = NetworkJSONValue.firstString(object, ["refreshOutcome"])
        scanThrottleEnabled = NetworkJSONValue.firstBool(object, ["scanThrottleEnabled"])
        scanAccepted = NetworkJSONValue.firstBool(object, ["scanAccepted"])
        resultsUpdated = NetworkJSONValue.firstBool(object, ["resultsUpdated"])
        channelCounts = NetworkJSONValue.first(object, ["channelCounts"])?.objectValue ?? [:]
        hardware = NetworkJSONValue.first(object, ["hardware"])?.objectValue ?? [:]
        accessPoints = (NetworkJSONValue.firstArray(
            object, ["accessPoints", "results", "aps"]) ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            return NetworkWifiAccessPoint(object: object)
        }
    }

    public var scanResultsTruncated: Bool? { truncated }
    public var locationEnabled: Bool? { locationServicesEnabled }
}

public struct NetworkDNSAnswer: Sendable, Equatable {
    public let name: String?
    public let type: String?
    public let ttlSeconds: Int?
    public let address: String?
    public let value: String?

    init(object: [String: NetworkJSONValue]) {
        name = NetworkJSONValue.firstString(object, ["name", "host"])
        type = NetworkJSONValue.firstString(object, ["type", "recordType"])
        ttlSeconds = NetworkJSONValue.firstInt(object, ["ttlSeconds", "ttl"])
        address = NetworkJSONValue.firstString(object, ["address", "ip"])
        value = NetworkJSONValue.firstString(object, ["value", "data"])
    }

    public var rendered: String {
        let kind = type ?? "?"
        let renderedValue = address ?? value ?? "?"
        var line = "\(kind) \(renderedValue)"
        if let ttlSeconds { line += " ttl=\(ttlSeconds)" }
        return line
    }
}

public struct NetworkDNSQueryFailure: Sendable, Equatable {
    public let type: String?
    public let errorCode: String?
    public let errorClass: String?
}

public struct NetworkDNSLookupObservation: Sendable, Equatable {
    public let recordType: String?
    public let queryTypes: [String]
    public let resolver: String?
    public let rcode: Int?
    public let rcodeName: String?
    public let answers: [NetworkDNSAnswer]
    public let addresses: [String]
    public let truncated: Bool?
    public let ttlSupported: Bool?
    public let elapsedMs: Int?
    public let queryFailures: [NetworkDNSQueryFailure]

    init(object: [String: NetworkJSONValue]) {
        recordType = NetworkJSONValue.firstString(object, ["recordType", "queryType"])
        queryTypes = (NetworkJSONValue.firstArray(object, ["queryTypes"]) ?? [])
            .compactMap(\.stringValue)
        resolver = NetworkJSONValue.firstString(object, ["resolver"])
        rcode = NetworkJSONValue.firstInt(object, ["rcode"])
        rcodeName = NetworkJSONValue.firstString(object, ["rcodeName", "status", "resultCode"])
        answers = (NetworkJSONValue.firstArray(
            object, ["answers", "records"]) ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            return NetworkDNSAnswer(object: object)
        }
        addresses = (NetworkJSONValue.firstArray(object, ["addresses"]) ?? [])
            .compactMap(\.stringValue)
        truncated = NetworkJSONValue.firstBool(object, ["truncated"])
        ttlSupported = NetworkJSONValue.firstBool(object, ["ttlSupported"])
        elapsedMs = NetworkJSONValue.firstInt(object, ["elapsedMs"])
        queryFailures = (NetworkJSONValue.firstArray(object, ["queryFailures"]) ?? [])
            .compactMap { value in
                guard let object = value.objectValue else { return nil }
                return NetworkDNSQueryFailure(
                    type: NetworkJSONValue.firstString(object, ["type"]),
                    errorCode: NetworkJSONValue.firstString(object, ["errorCode"]),
                    errorClass: NetworkJSONValue.firstString(object, ["errorClass"]))
            }
    }

    public var renderedAnswers: [String] { answers.map(\.rendered) }
}

public struct NetworkPingProbe: Sendable, Equatable {
    public let sequence: Int?
    public let replied: Bool?
    public let rttMillis: Double?
    public let replyFrom: String?

    init(object: [String: NetworkJSONValue]) {
        sequence = NetworkJSONValue.firstInt(object, ["sequence", "seq", "index"])
        replied = NetworkJSONValue.firstBool(object, ["replied"])
        rttMillis = NetworkJSONValue.firstDouble(
            object, ["rttMs", "rttMillis", "roundTripMs", "timeMs", "ms"])
        replyFrom = NetworkJSONValue.firstString(object, ["replyFrom", "address", "from", "ip"])
    }

    public var address: String? { replyFrom }
}

public struct NetworkPingObservation: Sendable, Equatable {
    public let sent: Int?
    public let received: Int?
    public let lost: Int?
    public let packetLossPercent: Double?
    public let rttMinMs: Double?
    public let rttAvgMs: Double?
    public let rttMaxMs: Double?
    public let resolvedAddress: String?
    public let family: String?
    public let countRequested: Int?
    public let timeoutBudgetMs: Int?
    public let socketType: String?
    public let probes: [NetworkPingProbe]

    init(object: [String: NetworkJSONValue]) {
        sent = NetworkJSONValue.firstInt(object, ["sent", "transmitted", "count"])
        received = NetworkJSONValue.firstInt(object, ["received", "replies"])
        lost = NetworkJSONValue.firstInt(object, ["lost"])
        packetLossPercent = NetworkJSONValue.firstDouble(
            object, ["packetLossPercent", "lossPercent", "packetLoss"])
        rttMinMs = NetworkJSONValue.firstDouble(
            object, ["rttMinMs", "minRttMs", "minRTTMillis"])
        rttAvgMs = NetworkJSONValue.firstDouble(
            object, ["rttAvgMs", "avgRttMs", "avgRTTMillis"])
        rttMaxMs = NetworkJSONValue.firstDouble(
            object, ["rttMaxMs", "maxRttMs", "maxRTTMillis"])
        resolvedAddress = NetworkJSONValue.firstString(
            object, ["resolvedAddress", "address", "ip"])
        family = NetworkJSONValue.firstString(object, ["family"])
        countRequested = NetworkJSONValue.firstInt(object, ["countRequested"])
        timeoutBudgetMs = NetworkJSONValue.firstInt(object, ["timeoutBudgetMs"])
        socketType = NetworkJSONValue.firstString(object, ["socketType", "icmpMode", "mode"])
        probes = (NetworkJSONValue.firstArray(object, ["probes", "echoes", "replies"]) ?? [])
            .compactMap { value in
                guard let object = value.objectValue else { return nil }
                return NetworkPingProbe(object: object)
            }
    }

    public var transmitted: Int? { sent }
    public var minRTTMillis: Double? { rttMinMs }
    public var avgRTTMillis: Double? { rttAvgMs }
    public var maxRTTMillis: Double? { rttMaxMs }
    public var icmpMode: String? { socketType }
    public var echoes: [NetworkPingProbe] { probes }
}

public struct NetworkTCPAttempt: Sendable, Equatable {
    public let address: String?
    public let family: String?
    public let result: String?
    public let elapsedMs: Int?
    public let errorClass: String?
}

public struct NetworkTCPProbeObservation: Sendable, Equatable {
    public let connected: Bool?
    public let port: Int?
    public let resolvedAddresses: [String]
    public let attempts: [NetworkTCPAttempt]
    public let timeoutBudgetMs: Int?
    public let refused: Bool?
    public let connectTimeMs: Int?
    public let localAddress: String?
    public let localPort: Int?
    public let remoteAddress: String?

    init(object: [String: NetworkJSONValue]) {
        connected = NetworkJSONValue.firstBool(object, ["connected", "reachable"])
        port = NetworkJSONValue.firstInt(object, ["port", "remotePort"])
        resolvedAddresses = (NetworkJSONValue.firstArray(
            object, ["resolvedAddresses"]) ?? []).compactMap(\.stringValue)
        attempts = (NetworkJSONValue.firstArray(object, ["attempts"]) ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            return NetworkTCPAttempt(
                address: NetworkJSONValue.firstString(object, ["address", "ip"]),
                family: NetworkJSONValue.firstString(object, ["family", "addressFamily"]),
                result: NetworkJSONValue.firstString(object, ["result"]),
                elapsedMs: NetworkJSONValue.firstInt(object, ["elapsedMs"]),
                errorClass: NetworkJSONValue.firstString(object, ["errorClass"]))
        }
        timeoutBudgetMs = NetworkJSONValue.firstInt(object, ["timeoutBudgetMs"])
        refused = NetworkJSONValue.firstBool(object, ["refused"])
        connectTimeMs = NetworkJSONValue.firstInt(
            object, ["connectTimeMs", "connectMillis", "connectMs", "latencyMs"])
        localAddress = NetworkJSONValue.firstString(object, ["localAddress", "localIp"])
        localPort = NetworkJSONValue.firstInt(object, ["localPort"])
        remoteAddress = NetworkJSONValue.firstString(
            object, ["remoteAddress", "address", "ip"])
    }

    public var remotePort: Int? { port }
    public var connectMillis: Int? { connectTimeMs }
    public var addressFamily: String? { attempts.first?.family }
}

public struct NetworkHTTPRedirect: Sendable, Equatable {
    public let url: String?
    public let statusCode: Int?
    public let redirectedTo: String?
}

public struct NetworkHTTPObservation: Sendable, Equatable {
    public let requestedUrl: String?
    public let finalUrl: String?
    public let statusCode: Int?
    public let redirectCount: Int?
    public let redirects: [NetworkHTTPRedirect]
    public let contentType: String?
    public let contentLength: Int?
    public let responseHeaders: [String: String]
    public let tlsCipherSuite: String?
    public let certificateChainAnalyzed: Bool?
    public let stoppedReason: String?

    init(object: [String: NetworkJSONValue]) {
        requestedUrl = NetworkJSONValue.firstString(object, ["requestedUrl", "requestedURL", "url"])
        finalUrl = NetworkJSONValue.firstString(object, ["finalUrl", "finalURL"])
        statusCode = NetworkJSONValue.firstInt(object, ["statusCode", "status"])
        redirectCount = NetworkJSONValue.firstInt(object, ["redirectCount", "redirects"])
        redirects = (NetworkJSONValue.firstArray(object, ["redirects"]) ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            return NetworkHTTPRedirect(
                url: NetworkJSONValue.firstString(object, ["url"]),
                statusCode: NetworkJSONValue.firstInt(object, ["statusCode"]),
                redirectedTo: NetworkJSONValue.firstString(object, ["redirectedTo"]))
        }
        contentType = NetworkJSONValue.firstString(object, ["contentType"])
        contentLength = NetworkJSONValue.firstInt(
            object, ["contentLength", "bodyBytes", "bytes"])
        responseHeaders = (NetworkJSONValue.first(
            object, ["responseHeaders", "headers"])?.objectValue ?? [:]).compactMapValues(\.stringValue)
        let tls = NetworkJSONValue.first(object, ["tls"])?.objectValue ?? [:]
        tlsCipherSuite = NetworkJSONValue.firstString(tls, ["cipherSuite", "cipher"])
        certificateChainAnalyzed = NetworkJSONValue.firstBool(tls, ["certificateChainAnalyzed"])
        stoppedReason = NetworkJSONValue.firstString(object, ["stoppedReason"])
    }

    public var requestedURL: String? { requestedUrl }
    public var finalURL: String? { finalUrl }
    public var bodyBytes: Int? { contentLength }
    public var tlsCipher: String? { tlsCipherSuite }
    public var tlsProtocol: String? { nil }
    public var httpProtocol: String? { nil }
}

public struct NetworkObservationPayload: Sendable, Equatable {
    public let raw: [String: NetworkJSONValue]
    public let status: NetworkStatusDetail?
    public let wifiScan: NetworkWifiScanObservation?
    public let dnsLookup: NetworkDNSLookupObservation?
    public let ping: NetworkPingObservation?
    public let tcpProbe: NetworkTCPProbeObservation?
    public let http: NetworkHTTPObservation?

    /// The delivered PhoneNetworkService emits method observations FLAT
    /// (`observations.accessPoints`, `.answers`, `.sent`, ...). Accept the
    /// historical nested shape too, but the authoritative path is flat.
    init(raw: [String: NetworkJSONValue], method: NetworkToolMethod) {
        self.raw = raw
        var statusValue: NetworkStatusDetail?
        var wifiValue: NetworkWifiScanObservation?
        var dnsValue: NetworkDNSLookupObservation?
        var pingValue: NetworkPingObservation?
        var tcpValue: NetworkTCPProbeObservation?
        var httpValue: NetworkHTTPObservation?
        switch method {
        case .status:
            statusValue = NetworkStatusDetail(object: raw["status"]?.objectValue ?? raw)
        case .wifiScan:
            wifiValue = NetworkWifiScanObservation(
                object: raw["wifiScan"]?.objectValue ?? raw)
        case .dnsLookup:
            dnsValue = NetworkDNSLookupObservation(
                object: raw["dnsLookup"]?.objectValue ?? raw)
        case .ping:
            pingValue = NetworkPingObservation(object: raw["ping"]?.objectValue ?? raw)
        case .tcpProbe:
            tcpValue = NetworkTCPProbeObservation(
                object: raw["tcpProbe"]?.objectValue ?? raw)
        case .http:
            httpValue = NetworkHTTPObservation(object: raw["http"]?.objectValue ?? raw)
        }
        self.status = statusValue
        self.wifiScan = wifiValue
        self.dnsLookup = dnsValue
        self.ping = pingValue
        self.tcpProbe = tcpValue
        self.http = httpValue
    }

    public var errorCode: String? {
        NetworkJSONValue.firstString(raw, ["errorCode", "unsupportedReason", "reason"])
    }

    public var requiredFor: String? {
        NetworkJSONValue.firstString(raw, ["requiredFor"])
    }
}

// MARK: - Envelope

public struct NetworkObservationV1: Sendable, Equatable {
    public let version: Int
    public let operationID: String
    public let method: NetworkToolMethod
    public let source: String
    public let status: NetworkObservationStatus
    public let measuredAt: String
    public let cacheAgeMs: Int?
    public let network: NetworkSnapshot
    public let networkRaw: [String: NetworkJSONValue]
    public let target: String?
    public let observations: NetworkObservationPayload
    public let limitations: [String]
    public let missingPermissions: [String]?

    private struct RawEnvelope: Decodable {
        let version: Int
        let operationID: String
        let method: String
        let source: String
        let status: String
        let measuredAt: String
        let cacheAgeMs: Int?
        let network: [String: NetworkJSONValue]
        let target: String?
        let observations: [String: NetworkJSONValue]?
        let limitations: [String]?
        let missingPermissions: [String]?
    }

    /// Decodes and binds the reply to the EXACT request this tool issued.
    public static func decode(_ data: Data,
                              expecting request: NetworkToolRequest) throws -> NetworkObservationV1 {
        guard data.count <= NetworkToolLimits.maximumObservationBytes else {
            throw NetworkObservationError.tooLarge(data.count)
        }
        let raw: RawEnvelope
        do {
            raw = try JSONDecoder().decode(RawEnvelope.self, from: data)
        } catch {
            throw NetworkObservationError.malformed
        }
        guard raw.version == 1 else {
            throw NetworkObservationError.unsupportedVersion(raw.version)
        }
        guard raw.source == "phone" else {
            throw NetworkObservationError.wrongSource(raw.source)
        }
        guard let method = NetworkToolMethod(rawValue: raw.method) else {
            throw NetworkObservationError.wrongMethod(raw.method)
        }
        guard method == request.method else {
            throw NetworkObservationError.wrongMethod(raw.method)
        }
        guard let replyID = UUID(uuidString: raw.operationID),
              replyID == request.operationID else {
            throw NetworkObservationError.operationMismatch
        }
        guard let status = NetworkObservationStatus(rawValue: raw.status) else {
            throw NetworkObservationError.invalidStatus(raw.status)
        }
        guard Self.isISO8601(raw.measuredAt) else {
            throw NetworkObservationError.invalidTimestamp(raw.measuredAt)
        }
        if let cacheAgeMs = raw.cacheAgeMs, cacheAgeMs < 0 {
            throw NetworkObservationError.malformed
        }
        return NetworkObservationV1(
            version: raw.version,
            operationID: replyID.uuidString,
            method: method,
            source: raw.source,
            status: status,
            measuredAt: raw.measuredAt,
            cacheAgeMs: raw.cacheAgeMs,
            network: NetworkSnapshot(object: raw.network),
            networkRaw: raw.network,
            target: raw.target,
            observations: NetworkObservationPayload(
                raw: raw.observations ?? [:], method: method),
            limitations: raw.limitations ?? [],
            missingPermissions: raw.missingPermissions)
    }

    private static func isISO8601(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64, !value.contains("\n") else { return false }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if plain.date(from: value) != nil { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        // Corelibs' ISO8601DateFormatter has lagged on fractional seconds in
        // some toolchains; accept the exact ISO-8601 shape rather than
        // rejecting a real phone timestamp on an implementation gap.
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    /// In-App user result (AP identifiers are already part of what the phone
    /// measured). Shared exports MUST keep the default `true` redaction.
    public func inAppJSON() throws -> Data {
        try exportJSON(redactingAccessPointIdentifiers: false)
    }

    /// Deterministic sorted-key export. By default Wi-Fi SSID/BSSID values
    /// are replaced, because AP identifiers are device-local evidence and a
    /// shared/exported diagnostic must not leak them.
    public func exportJSON(redactingAccessPointIdentifiers: Bool = true) throws -> Data {
        var root: [String: Any] = [
            "version": version,
            "operationID": operationID,
            "method": method.rawValue,
            "source": source,
            "status": status.rawValue,
            "measuredAt": measuredAt,
            "network": (redactingAccessPointIdentifiers
                ? Self.redactedNetworkIdentifiers(networkRaw)
                : networkRaw).mapValues(\.foundationObject),
            "limitations": limitations,
        ]
        if let cacheAgeMs { root["cacheAgeMs"] = cacheAgeMs }
        if let target, !target.isEmpty { root["target"] = target }
        if let missingPermissions { root["missingPermissions"] = missingPermissions }
        let observationsRaw = redactingAccessPointIdentifiers
            ? Self.redactedAccessPointIdentifiers(observations.raw)
            : observations.raw
        root["observations"] = observationsRaw.mapValues(\.foundationObject)
        guard JSONSerialization.isValidJSONObject(root) else {
            throw NetworkObservationError.emptyExport
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func redactedNetworkIdentifiers(
        _ network: [String: NetworkJSONValue]
    ) -> [String: NetworkJSONValue] {
        guard var wifi = network["wifi"]?.objectValue else { return network }
        for identifier in ["ssid", "bssid"] where wifi[identifier] != nil {
            wifi[identifier] = .string("<redacted>")
            wifi["\(identifier)Redacted"] = .bool(true)
        }
        var copy = network
        copy["wifi"] = .object(wifi)
        return copy
    }

    private static func redactedAccessPointIdentifiers(
        _ observations: [String: NetworkJSONValue]
    ) -> [String: NetworkJSONValue] {
        let keys = ["accessPoints", "results", "aps"]
        if var wifiScan = observations["wifiScan"]?.objectValue {
            redactAccessPointRows(in: &wifiScan, keys: keys)
            var copy = observations
            copy["wifiScan"] = .object(wifiScan)
            return copy
        }
        var copy = observations
        redactAccessPointRows(in: &copy, keys: keys)
        return copy
    }

    private static func redactAccessPointRows(in object: inout [String: NetworkJSONValue],
                                              keys: [String]) {
        guard let key = keys.first(where: { object[$0]?.arrayValue != nil }),
              let accessPoints = object[key]?.arrayValue else { return }
        object[key] = .array(accessPoints.map { value -> NetworkJSONValue in
            guard var row = value.objectValue else { return value }
            for identifier in ["ssid", "bssid"] where row[identifier] != nil {
                row[identifier] = .string("<redacted>")
                row["\(identifier)Redacted"] = .bool(true)
            }
            return .object(row)
        })
    }
}