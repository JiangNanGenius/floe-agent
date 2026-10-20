// SPDX-License-Identifier: MPL-2.0
// G02 native TLS / default-trust qualification seam (job-b1709c36b200442c).
//
// Synchronous, bounded @_cdecl entry consumed ONLY by the debug-only
// instrumentation wrapper (`floe_qualification.cpp` -> androidTest class
// `com.floe.android.bridge.QualificationNative`, plus the app-module
// product-UID probe which reuses the same debug JNI library). It exercises the
// REAL Android FoundationNetworking trust path through the ORIGINAL
// `StreamingTransport.makeSession` factory and the ORIGINAL provider/MCP
// adapters:
//
//   P1 system-CA directory probe (apex/system existence, entry count,
//      readability, PEM prefix, Foundation's existence-only selection).
//   P2 trust-environment guard (boolean presence of the upstream lever keys
//      only; the INSECURE_SSL_NO_VERIFY escape must never be set).
//   P3 loaded-binary identity (sha256 of the mapped libFloeAndroidCore.so /
//      libFoundationNetworking.so, compared against manifest-pinned digests).
//   T1 unauthenticated public HTTPS 204/200 via the factory DEFAULT system
//      trust (no override, no user payload).
//   T2 original provider adapters over an owned TLS fixture whose synthetic
//      CA is trusted ONLY through the isolated in-test-process
//      URLSessionCertificateAuthorityInfoFile lever (positive control).
//   T3 unknown-CA negative (no override): must fail with a typed TLS error.
//   T4 wrong-SAN negative with the SAME trusted test CA: only the hostname
//      differs, so a TLS-family failure is meaningful.
//   T5 expired negative with the SAME trusted test CA and correct SAN: only
//      the validity window differs.
//   T6 override-lever proof: pointing the lever at the UNKNOWN CA makes the
//      T3 endpoint succeed (CAINFO replaces CAPATH); the caller then clears
//      the lever and re-runs T3 on a FRESH fixture origin which must fail
//      again (Kotlin orchestrates both legs, this entry implements each leg).
//   T7 redirect/auth policy over TLS: MCP refuse-redirect (fixture target
//      must see ZERO requests) and the provider default-follow path for a
//      synthetic Authorization canary, same-host vs cross-host
//      (localhost vs 127.0.0.1, both valid SANs on the trusted fixture cert).
//      Header forwarding is asserted fixture-side by Kotlin; this entry
//      reports the followed/unfollowed shape and final statuses only.
//
// The test-CA override lever is set/unset by the Kotlin test process around
// each fixture scenario and restored in `finally`; it is NEVER carried into
// the T1 public probe or the product process, and `INSECURE_SSL_NO_VERIFY`
// is never set anywhere. Test certificates are synthetic fixture material
// generated in the lane, never user/store certificates. Each scenario builds
// fresh sessions on unique fixture origins so no TLS connection cache can
// satisfy a negative control.
//
// This is trust-path component evidence only: it is NOT a cloud run, NOT
// key usage, NOT App/UI acceptance and NOT a G02 completion claim. The shared
// core .so export table is reported honestly (same policy as the other
// qualification entries): no release-side Kotlin/JNI loader references it.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import Crypto
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeTransport

// MARK: - bounded JSON helpers (same bounds as the transport seam)

private func tlsReportJSON(_ report: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    else { return "{\"ok\":false,\"error\":\"encoding\"}" }
    return String(decoding: data, as: UTF8.self)
}

private func tlsErrorJSON(_ reason: String) -> String {
    tlsReportJSON(["ok": false, "error": reason])
}

private func tlsJsonDuplicate(_ text: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(text.utf8)
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    if !bytes.isEmpty {
        bytes.withUnsafeBytes { raw in
            UnsafeMutableRawPointer(output).copyMemory(from: raw.baseAddress!, byteCount: bytes.count)
        }
    }
    output[bytes.count] = 0
    return output
}

// MARK: - typed error capture

private let urlErrorNames: [Int: String] = [
    -999: "cancelled",
    -1001: "timedOut",
    -1003: "cannotFindHost",
    -1004: "cannotConnectToHost",
    -1005: "networkConnectionLost",
    -1012: "userCancelledAuthentication",
    -1013: "userAuthenticationRequired",
    -1200: "secureConnectionFailed",
    -1201: "serverCertificateHasBadDate",
    -1202: "serverCertificateUntrusted",
    -1203: "serverCertificateHasUnknownRoot",
    -1204: "serverCertificateNotYetValid",
    -1205: "clientCertificateRejected",
    -1206: "clientCertificateRequired",
]

/// Codes whose failure can only come from the TLS/ certificate layer.
private let tlsFamilyCodes: Set<Int> = [-1200, -1201, -1202, -1203, -1204, -1205, -1206]

/// curl/BoringSSL failure phrases corelibs places in the error description
/// when it maps a handshake/verification failure to the generic -1 code.
private let tlsDescriptionMarkers: [String] = [
    "SSL certificate problem",
    "SSL: no alternative certificate subject name",
    "no alternative certificate subject name matches",
    "certificate has expired",
    "certificate is not yet valid",
    "unable to get local issuer certificate",
    "self signed certificate",
    "self-signed certificate",
    "unknown ca",
    "certificate verify failed",
    "unable to verify the first certificate",
    "hostname mismatch",
    "bad certificate",
    "alert unknown ca",
    "alert bad certificate",
    "alert certificate expired",
]

private func looksLikeTLSFailure(_ description: String) -> Bool {
    let lowered = description.lowercased()
    return tlsDescriptionMarkers.contains { lowered.contains($0.lowercased()) }
}

private func typedErrorFields(_ error: Error) -> (label: String, family: String, code: Int, detail: String) {
    if let urlError = error as? URLError {
        let code = urlError.code.rawValue
        // Corelibs wraps the transport failure in a top-level -1
        // NSURLErrorDomain error whose NSUnderlyingError chain and/or
        // NSLocalizedDescription carry the real typed signal (e.g. -1200 or
        // "SSL certificate problem: certificate has expired"); classify
        // through both so the negative controls are meaningful.
        let fullDescription = String(describing: urlError)
        let underlyingScan = deepestUnderlyingCode(urlError as NSError)
        let byCode = tlsFamilyCodes.contains(code) ? code : underlyingScan
        if let byCode {
            let name = urlErrorNames[byCode] ?? "code\(byCode)"
            return ("urlError.\(name)", "tls", byCode,
                    boundedDetail(urlError, underlying: byCode))
        }
        if looksLikeTLSFailure(fullDescription) {
            return ("urlError.tlsHandshakeFailure", "tls", code,
                    boundedDetail(urlError))
        }
        let name = urlErrorNames[code] ?? "code\(code)"
        let family = (code == -999 ? "cancelled"
            : (code <= -1000 && code > -1100 ? "network" : "other"))
        return ("urlError.\(name)", family, code, boundedDetail(urlError))
    }
    if let transport = error as? IncrementalTransportError {
        return ("incrementalTransport.\(transport)", "transport", -2, "\(transport)")
    }
    return ("other.\(String(reflecting: Swift.type(of: error)))", "other", -3,
            boundedDetail(error))
}

/// Walks the NSUnderlyingError chain and returns the first TLS-family code.
private func deepestUnderlyingCode(_ error: NSError, depth: Int = 0) -> Int? {
    guard depth < 4 else { return nil }
    if tlsFamilyCodes.contains(error.code) { return error.code }
    guard let underlying = error.userInfo["NSUnderlyingError"] as? NSError else { return nil }
    return deepestUnderlyingCode(underlying, depth: depth + 1)
}

/// Bounded, single-line diagnostic (never headers, never secrets).
private func boundedDetail(_ error: Error, underlying: Int? = nil, limit: Int = 200) -> String {
    var text = String(describing: error)
        .replacingOccurrences(of: "\n", with: " ")
    if let underlying {
        text += " [effectiveURLErrorCode=\(underlying)]"
    }
    return text.count <= limit ? text : String(text.prefix(limit)) + "…"
}

// MARK: - CA directory probe (P1)

private let apexCADir = "/apex/com.android.conscrypt/cacerts"
private let systemCADir = "/system/etc/security/cacerts"

private func probeCADirectory(_ path: String) -> [String: Any] {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    var result: [String: Any] = [
        "path": path,
        "exists": exists,
        "isDirectory": isDirectory.boolValue,
        "entryCount": 0,
        "firstEntryReadable": false,
        "firstEntryPEMPrefix": false,
    ]
    guard exists, isDirectory.boolValue,
          let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
        return result
    }
    result["entryCount"] = entries.count
    // Pick a representative entry the way a by-dir hash store would load
    // first: any regular file; conscrypt names are "<hash>.<index>".
    let candidates = entries.sorted()
    guard let first = candidates.first(where: { !$0.hasPrefix(".") }) ?? candidates.first else {
        return result
    }
    let fullPath = path + "/" + first
    result["firstEntry"] = first
    if let handle = FileHandle(forReadingAtPath: fullPath) {
        result["firstEntryReadable"] = true
        let head = handle.readData(ofLength: 27)
        result["firstEntryPEMPrefix"] = String(decoding: head, as: UTF8.self)
            .hasPrefix("-----BEGIN CERTIFICATE-----")
        try? handle.close()
    }
    return result
}

private func p1StoreProbeReport() -> String {
    let apex = probeCADirectory(apexCADir)
    let system = probeCADirectory(systemCADir)
    // Foundation's os(Android) branch: first EXISTING directory wins
    // (existence-only probe; conscrypt additionally requires non-empty on
    // newer SDKs — REPORT F3/F10/§6 edge).
    let apexExists = (apex["exists"] as? Bool) ?? false
    let selectedByFoundation = apexExists ? apexCADir : systemCADir
    let selectedEntries = apexExists ? (apex["entryCount"] as? Int ?? 0)
                                     : (system["entryCount"] as? Int ?? 0)
    let emptySelectedDirEdge = apexExists && (apex["entryCount"] as? Int ?? 0) == 0
        && (system["entryCount"] as? Int ?? 0) > 0
    return tlsReportJSON([
        "ok": true,
        "apex": apex,
        "system": system,
        "selectedByFoundation": selectedByFoundation,
        "selectedEntryCount": selectedEntries,
        "emptyButExistingSelectedDirEdge": emptySelectedDirEdge,
    ])
}

// MARK: - environment guard (P2)

private let trustEnvKeys = [
    "URLSessionCertificateAuthorityInfoFile",
    "CURL_CA_BUNDLE",
    "CURL_CA_PATH",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "INSECURE_SSL_NO_VERIFY",
]

private func p2EnvGuardReport() -> String {
    let environment = ProcessInfo.processInfo.environment
    var presence: [String: Bool] = [:]
    for key in trustEnvKeys {
        presence[key] = environment[key] != nil
    }
    // The production guard: the upstream escape hatch is never set.
    let insecureEscapeSet = environment["INSECURE_SSL_NO_VERIFY"] != nil
    return tlsReportJSON([
        "ok": !insecureEscapeSet,
        "presence": presence,
        "insecureEscapeSet": insecureEscapeSet,
    ])
}

// MARK: - loaded binary identity (P3)

/// With `extractNativeLibs=false` (the app's packaging policy) the dynamic
/// linker maps every native library directly out of the installed base.apk,
/// so /proc/self/maps names the APK rather than each .so. The on-device
/// identity proof is therefore the running process's mapped APK digest,
/// compared against the installed package digest computed Kotlin-side; the
/// per-library binding (core + the pinned FoundationNetworking SDK binary
/// 74b97134...) is closed host-side by native-manifest.py --check and the
/// APK strip-derivative validator.
private func mappedAPKPath() -> String? {
    // /proc files report a zero stat size, so FileManager.contents returns
    // empty Data; stream-read through FileHandle instead.
    guard let handle = FileHandle(forReadingAtPath: "/proc/self/maps") else { return nil }
    defer { try? handle.close() }
    let data = handle.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        guard let separator = line.lastIndex(of: " ") else { continue }
        let path = String(line[line.index(after: separator)...])
        if path.hasSuffix(".apk") && path.contains("/data/app/") {
            return path
        }
    }
    return nil
}

private func sha256HexFile(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = handle.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func p3BinaryIdentityReport(expectedAPKSHA256: String?) -> String {
    var fields: [String: Any] = [
        "ok": false,
        "binding": "apk-digest-host-side-manifest",
    ]
    let pageSize = sysconf(Int32(_SC_PAGESIZE))
    fields["pageSize"] = Int(pageSize)
    guard let apkPath = mappedAPKPath() else {
        fields["mapped"] = false
        return tlsReportJSON(fields)
    }
    fields["mapped"] = true
    fields["apkPath"] = apkPath
    guard let digest = sha256HexFile(apkPath) else {
        fields["apkReadable"] = false
        return tlsReportJSON(fields)
    }
    fields["apkReadable"] = true
    fields["apkSHA256"] = digest
    if let expected = expectedAPKSHA256, !expected.isEmpty {
        fields["expectedAPKSHA256"] = expected
        fields["matchesExpected"] = digest == expected
        fields["ok"] = digest == expected
    } else {
        fields["ok"] = true
    }
    return tlsReportJSON(fields)
}

// MARK: - fixture helpers

private func fixtureProvider(base: URL, wire: ModelProtocol) -> ProviderProfile {
    ProviderProfile(
        kind: wire == .anthropicMessages ? .anthropic : .openAI,
        wireProtocol: wire,
        baseURL: base,
        displayName: "TLS Fixture",
        allowsPlainHTTP: false
    )
}

private func fixtureModel(provider: ProviderProfile) -> ModelProfile {
    ModelProfile(
        providerID: provider.id,
        remoteModelID: "tls-fixture-model",
        displayName: "TLS Fixture Model",
        limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 256),
        capabilities: [.text]
    )
}

private func tlsAdapterFor(_ wire: ModelProtocol) -> any ProviderAdapter {
    switch wire {
    case .openAIResponses: OpenAIResponsesAdapter()
    case .anthropicMessages: AnthropicMessagesAdapter()
    default: OpenAIChatCompletionsAdapter()
    }
}

private enum TLSFixtureWire: String, CaseIterable {
    case chat, responses, anthropic
    var modelWire: ModelProtocol {
        switch self {
        case .responses: .openAIResponses
        case .anthropic: .anthropicMessages
        default: .openAIChatCompletions
        }
    }
}

/// Runs one synthetic Authorization canary through the ORIGINAL provider
/// adapter over TLS and returns the streamed text (fixture asserts the canary
/// arrival server-side; this side proves the wrapper completes over TLS).
private func providerFixtureReport(base: URL, canary: String) async throws -> String {
    var perWire: [String: Any] = [:]
    var allOK = true
    for wire in TLSFixtureWire.allCases {
        let provider = fixtureProvider(base: base.appendingPathComponent("wire-\(wire.rawValue)"),
                                       wire: wire.modelWire)
        let request = ProviderStreamRequest(
            provider: provider,
            model: fixtureModel(provider: provider),
            messages: [(role: "user", content: "ping")]
        )
        var text = ""
        var eventCount = 0
        for try await event in tlsAdapterFor(wire.modelWire).stream(
            request: request,
            credentials: ProviderCredentials(apiKey: canary)) {
            eventCount += 1
            if case .textDelta(let delta) = event { text += delta.text }
        }
        // One text delta completes the wire (the fixture sends one delta plus
        // the terminal marker); the assertion target here is TLS completion
        // through the ORIGINAL adapter, not event cardinality.
        let ok = text == "tls-ok" && eventCount >= 1
        allOK = allOK && ok
        perWire[wire.rawValue] = [
            "ok": ok,
            "text": text,
            "eventCount": eventCount,
        ]
    }
    return tlsReportJSON(["ok": allOK, "wires": perWire])
}

/// Raw collect through the factory session; returns status/finalURL/bytes or
/// the typed failure.
private func fixtureCollectReport(url: URL, canary: String?) async -> String {
    let session = StreamingTransport.makeSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    if let canary {
        request.setValue("Bearer \(canary)", forHTTPHeaderField: "Authorization")
        // Synthetic opaque header used by the redirect matrix to prove a
        // cross-origin hop drops custom headers too (never a credential).
        request.setValue("synthetic-tls-opaque", forHTTPHeaderField: "X-Provider-Custom")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }
    do {
        let (data, response) = try await StreamingTransport.collect(
            request, via: session, maxBytes: 16_384)
        let http = response as? HTTPURLResponse
        return tlsReportJSON([
            "ok": true,
            "failed": false,
            "status": http?.statusCode ?? -1,
            "finalURL": response.url?.absoluteString ?? "",
            "bytes": data.count,
        ])
    } catch {
        let typed = typedErrorFields(error)
        return tlsReportJSON([
            "ok": false,
            "failed": true,
            "errorLabel": typed.label,
            "errorFamily": typed.family,
            "errorCode": typed.code,
            "errorDetail": typed.detail,
        ])
    }
}

/// Runs the ORIGINAL OpenAI chat-completions provider adapter through the
/// factory session over TLS. The fixture decides the redirect topology and
/// records the canary per hop; this side reports only whether the provider
/// stream completed and the visible text. No policy delegate is installed
/// here (the production provider path has none); MCP's refuse-redirect policy
/// stays covered by `t7MCPRefuseRedirect`.
private func t7ProviderRedirectReport(base: URL, canary: String) async -> String {
    let provider = fixtureProvider(base: base, wire: .openAIChatCompletions)
    let request = ProviderStreamRequest(
        provider: provider,
        model: fixtureModel(provider: provider),
        messages: [(role: "user", content: "ping")]
    )
    var text = ""
    var eventCount = 0
    do {
        for try await event in OpenAIChatCompletionsAdapter().stream(
            request: request,
            credentials: ProviderCredentials(apiKey: canary)) {
            eventCount += 1
            if case .textDelta(let delta) = event { text += delta.text }
        }
        return tlsReportJSON([
            "ok": true,
            "text": text,
            "eventCount": eventCount,
        ])
    } catch {
        let typed = typedErrorFields(error)
        return tlsReportJSON([
            "ok": false,
            "failed": true,
            "text": text,
            "eventCount": eventCount,
            "errorLabel": typed.label,
            "errorFamily": typed.family,
            "errorCode": typed.code,
            "errorDetail": typed.detail,
        ])
    }
}

// MARK: - scenarios

private func t1PublicPositiveReport() async -> String {
    // Fixed unauthenticated public probes; no headers, no payload, DEFAULT
    // system trust only (the caller guarantees no CA override is set).
    struct Probe: Sendable {
        let url: URL
        let expect: Int
    }
    let probes: [Probe] = [
        Probe(url: URL(string: "https://www.google.com/generate_204")!, expect: 204),
        Probe(url: URL(string: "https://example.com/")!, expect: 200),
    ]
    var results: [[String: Any]] = []
    var anyCleanSuccess = false
    for probe in probes {
        let report = await fixtureCollectReport(url: probe.url, canary: nil)
        var fields: [String: Any] = [:]
        if let data = report.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fields = object
        }
        fields["url"] = probe.url.absoluteString
        fields["expectedStatus"] = probe.expect
        let status = fields["status"] as? Int ?? -1
        let matched = fields["ok"] as? Bool ?? false
        fields["statusMatched"] = matched && status == probe.expect
        anyCleanSuccess = anyCleanSuccess || (fields["statusMatched"] as? Bool ?? false)
        results.append(fields)
    }
    return tlsReportJSON([
        "ok": anyCleanSuccess,
        "probes": results,
    ])
}

private func t2ProviderFixtureReport(base: URL, canary: String) async throws -> String {
    try await providerFixtureReport(base: base, canary: canary)
}

/// Shared body for the TLS-negative controls: a connect that MUST fail for a
/// TLS-family reason. `chainTrusted` documents the methodology control: for
/// T4/T5 the same synthetic test CA is trusted via the isolated lever, so the
/// only changed variable is SAN (T4) or expiry (T5); T3 has no trusted chain.
private func tlsNegativeReport(base: URL, caseName: String, chainTrusted: Bool) async -> String {
    let session = StreamingTransport.makeSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: base)
    request.timeoutInterval = 20
    do {
        _ = try await StreamingTransport.collect(request, via: session, maxBytes: 4_096)
        // Any 2xx/complete body here is a trust bypass: blocking failure.
        return tlsReportJSON([
            "ok": false,
            "case": caseName,
            "failed": false,
            "bypassSuspected": true,
        ])
    } catch {
        let typed = typedErrorFields(error)
        let rightReason = typed.family == "tls"
        return tlsReportJSON([
            "ok": failedAsExpected(rightReason),
            "case": caseName,
            "failed": true,
            "rightReason": rightReason,
            "chainTrustedByLever": chainTrusted,
            "errorLabel": typed.label,
            "errorFamily": typed.family,
            "errorCode": typed.code,
            "errorDetail": typed.detail,
        ])
    }
}

/// A negative passes only when it failed for a TLS-family reason; a
/// non-TLS-family failure (DNS, timeout, refuse) is an inconclusive
/// environment result, not a pass.
private func failedAsExpected(_ rightReason: Bool) -> Bool {
    rightReason
}

private func t6OverridePositiveReport(base: URL) async -> String {
    // Caller has set URLSessionCertificateAuthorityInfoFile to the UNKNOWN
    // CA bundle in this isolated test process: the formerly-unknown endpoint
    // must now verify cleanly (proves the lever works and CAINFO replaces
    // CAPATH). Never used with INSECURE_SSL_NO_VERIFY.
    let report = await fixtureCollectReport(url: base, canary: nil)
    var fields: [String: Any] = ["lever": "CAINFO"]
    if let data = report.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        fields.merge(object) { _, new in new }
    }
    fields["ok"] = (fields["status"] as? Int) == 200
    return tlsReportJSON(fields)
}

private func t7MCPRefuseRedirectReport(base: URL) async -> String {
    let configuration = MCPServerConfiguration(
        displayName: "TLS Fixture MCP",
        endpoint: base.appendingPathComponent("mcp-redirect"),
        allowInsecureHTTP: false,
        timeoutSeconds: 15
    )
    let client = try? MCPRemoteClient(
        configuration: configuration,
        credential: nil,
        artifactRootProvider: { FileManager.default.temporaryDirectory }
    )
    guard let client else {
        return tlsReportJSON(["ok": false, "error": "clientInit"])
    }
    do {
        _ = try await client.discoverTools()
        await client.disconnect()
        // Even a "successful" discover means the redirect was not refused
        // with an error; the SECURITY evidence is fixture-side zero target
        // requests. Report the shape honestly.
        return tlsReportJSON(["ok": true, "redirectOutcome": "completedNoError"])
    } catch let error as MCPClientError {
        await client.disconnect()
        if case .httpError(let status, _) = error {
            return tlsReportJSON(["ok": true, "redirectOutcome": "httpError",
                                  "status": status])
        }
        return tlsReportJSON(["ok": true, "redirectOutcome": "mcpError",
                              "detail": "\(error)"])
    } catch let error as URLError {
        await client.disconnect()
        let typed = typedErrorFields(error)
        return tlsReportJSON(["ok": true, "redirectOutcome": "urlError",
                              "errorLabel": typed.label, "errorCode": typed.code,
                              "errorDetail": typed.detail])
    } catch {
        await client.disconnect()
        return tlsReportJSON(["ok": true, "redirectOutcome": "other",
                              "detail": "\(String(reflecting: error))"])
    }
}

// MARK: - entry

@_cdecl("floe_tls_qualification")
public func floeTLSQualification(_ specPointer: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let specPointer else { return tlsJsonDuplicate(tlsErrorJSON("missingSpec")) }
    let text = String(cString: specPointer)
    guard !text.isEmpty, text.utf8.count <= 65_536,
          let data = text.data(using: .utf8),
          let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let scenario = spec["scenario"] as? String else {
        return tlsJsonDuplicate(tlsErrorJSON("invalidSpec"))
    }
    // Extract plain Sendable values for the bounded runner (raw JSON dicts
    // are not Sendable); the runner sees only value types.
    let baseText = spec["base"] as? String
    let canary = (spec["authCanary"] as? String) ?? "synthetic-tls-canary"
    let path = spec["path"] as? String
    let expectedAPKSHA = spec["expectedAPKSHA256"] as? String
    let outcome = runBounded(timeout: 120) {
        await tlsScenario(scenario: scenario, baseText: baseText, canary: canary,
                          path: path, expectedAPKSHA: expectedAPKSHA)
    }
    return tlsJsonDuplicate(outcome)
}

private func tlsScenario(scenario: String, baseText: String?,
                         canary: String, path: String?,
                         expectedAPKSHA: String?) async -> String {
    switch scenario {
    case "p1StoreProbe":
        return p1StoreProbeReport()
    case "p2EnvGuard":
        return p2EnvGuardReport()
    case "p3BinaryIdentity":
        return p3BinaryIdentityReport(expectedAPKSHA256: expectedAPKSHA)
    case "t1PublicPositive":
        // Guard: refuse to run the public positive if the escape hatch or an
        // override lever is present in this process (product default only).
        if ProcessInfo.processInfo.environment["INSECURE_SSL_NO_VERIFY"] != nil
            || ProcessInfo.processInfo.environment["URLSessionCertificateAuthorityInfoFile"] != nil {
            return tlsErrorJSON("overrideLeverPresentInProcess")
        }
        return await t1PublicPositiveReport()
    case "t2ProviderFixture":
        guard let baseText, let base = URL(string: baseText) else {
            return tlsErrorJSON("invalidBase")
        }
        do {
            return try await t2ProviderFixtureReport(base: base, canary: canary)
        } catch {
            let typed = typedErrorFields(error)
            return tlsReportJSON(["ok": false, "failed": true,
                                  "errorLabel": typed.label,
                                  "errorFamily": typed.family,
                                  "errorCode": typed.code,
                                  "errorDetail": typed.detail])
        }
    case "t3UnknownCA":
        guard let baseText, let base = URL(string: baseText) else {
            return tlsErrorJSON("invalidBase")
        }
        return await tlsNegativeReport(base: base, caseName: "unknownCA",
                                       chainTrusted: false)
    case "t4WrongSAN":
        guard let baseText, let base = URL(string: baseText) else {
            return tlsErrorJSON("invalidBase")
        }
        return await tlsNegativeReport(base: base, caseName: "wrongSAN",
                                       chainTrusted: true)
    case "t5Expired":
        guard let baseText, let base = URL(string: baseText) else {
            return tlsErrorJSON("invalidBase")
        }
        return await tlsNegativeReport(base: base, caseName: "expired",
                                       chainTrusted: true)
    case "t6OverridePositive":
        guard let baseText, let base = URL(string: baseText) else {
            return tlsErrorJSON("invalidBase")
        }
        if ProcessInfo.processInfo.environment["INSECURE_SSL_NO_VERIFY"] != nil {
            return tlsErrorJSON("insecureEscapePresent")
        }
        return await t6OverridePositiveReport(base: base)
    case "t7MCPRefuseRedirect":
        guard let baseText, let base = URL(string: baseText) else {
            return tlsErrorJSON("invalidBase")
        }
        return await t7MCPRefuseRedirectReport(base: base)
    case "t7ProviderRedirect":
        // Default-follow redirect shape for the synthetic Authorization
        // canary; the fixture records whether the canary arrived per host
        // (asserted Kotlin-side; booleans only in the final report).
        guard let baseText, let base = URL(string: baseText),
              let path, !path.isEmpty else {
            return tlsErrorJSON("invalidBase")
        }
        let url = base.appendingPathComponent(path)
        return await fixtureCollectReport(url: url, canary: canary)
    case "t7ProviderAdapterRedirect":
        // The REAL provider adapter (not a raw collect) over the same
        // factory session. `base` already includes the fixture redirect
        // path; the adapter appends chat/completions.
        guard let baseText, let base = URL(string: baseText) else {
            return tlsErrorJSON("invalidBase")
        }
        return await t7ProviderRedirectReport(base: base, canary: canary)
    default:
        return tlsErrorJSON("unknownScenario:\(scenario)")
    }
}
