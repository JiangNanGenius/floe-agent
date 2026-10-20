// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — REAL transport/default-system-TLS startup
// admission (MAIN_PRODUCT_TRANSPORT_STARTUP_ADMISSION_DECISION_20261020).
//
// Engineering qualification receipts are release verification; an end-user
// device cannot read a private receipt and no manual flip may be required
// to make ordinary cloud/MCP usable. Runtime admission is therefore derived
// at STARTUP — before the immutable RunContext snapshot is constructed —
// from the ACTUAL production transport and default-system-TLS
// initialization/binding facts on this very process/device:
//
//   1. Trust-environment guard: the upstream `INSECURE_SSL_NO_VERIFY`
//      escape hatch is NOT set (the qualified P2 production guard). A
//      subverted trust environment never admits.
//   2. Default system CA store: the platform default-trust input that
//      FoundationNetworking actually selects on Android — `/apex/
//      com.android.conscrypt/cacerts` first, then `/system/etc/security/
//      cacerts` (existence-only selection, conscrypt non-empty rule) — must
//      resolve to a real, readable store whose first entry carries the PEM
//      prefix. This is the same bounded probe the qualified native TLS lane
//      ran as P1; it opens no socket and reaches no network.
//   3. Production transport initialization: the ORIGINAL
//      `StreamingTransport.makeSession` factory (the same factory the
//      provider/MCP adapters use) must actually create a session that
//      `isStreamable` recognizes, which is then invalidated. No second
//      transport, no test CA, no override lever.
//
// All three facts are REAL initialization/binding evidence — never a
// source-file/port-presence claim, never an unconditional true, never a
// permanent false, and never a test-only setter as the product path.
// What admission does NOT claim: per-request TLS/hostname/default-trust
// validation stays in the transport layer for EVERY request; offline or
// missing-configuration answers remain their own typed network/config
// failures (distinct from implementation-unavailable); Main independently
// runs the unchanged ProductDefaultTLSProbe under the actual full/play
// product UID and the real cloud stream/cancel on the exact current APK.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeTransport

public enum G02TransportStartupAdmission {

    /// The evaluated startup facts. `reason` is the typed unavailability
    /// reason when admission is refused (implementation/trust facts missing)
    /// — never an offline/config absence, which the transport types per
    /// request.
    public struct Result: Sendable, Equatable {
        public let admitted: Bool
        public let reason: String?
        public let trustEnvironmentClean: Bool
        public let caStoreSelected: String?
        public let caStoreEntries: Int
        public let caStoreReadablePEM: Bool
        public let transportSessionInitialized: Bool

        public init(admitted: Bool, reason: String?,
                    trustEnvironmentClean: Bool,
                    caStoreSelected: String?,
                    caStoreEntries: Int,
                    caStoreReadablePEM: Bool,
                    transportSessionInitialized: Bool) {
            self.admitted = admitted
            self.reason = reason
            self.trustEnvironmentClean = trustEnvironmentClean
            self.caStoreSelected = caStoreSelected
            self.caStoreEntries = caStoreEntries
            self.caStoreReadablePEM = caStoreReadablePEM
            self.transportSessionInitialized = transportSessionInitialized
        }
    }

    /// Android platform default-trust directories (the same constants and
    /// existence-only selection order the qualified TLS lane probed as P1).
    private static let apexCADir = "/apex/com.android.conscrypt/cacerts"
    private static let systemCADir = "/system/etc/security/cacerts"

    /// The upstream trust-subversion escape hatch (qualified P2 guard).
    private static let insecureEscapeKey = "INSECURE_SSL_NO_VERIFY"

    /// Evaluates the real startup facts. Bounded: two bounded directory
    /// probes (one 27-byte head read), one environment lookup and one
    /// session factory create/invalidate. No network, no socket, no I/O
    /// beyond those bounded probes.
    public static func evaluate() -> Result {
        let environment = ProcessInfo.processInfo.environment
        let trustClean = environment[insecureEscapeKey] == nil

        // Foundation's os(Android) selection: first EXISTING directory wins;
        // conscrypt additionally requires a non-empty store on newer SDKs.
        let apex = probeCADirectory(apexCADir)
        let system = probeCADirectory(systemCADir)
        let apexExists = apex.exists
        let selectedPath = apexExists ? apexCADir : systemCADir
        let selected = apexExists ? apex : system
        let storeUsable = selected.exists && selected.entryCount > 0
            && selected.firstEntryPEMPrefix

        // The ORIGINAL production session factory must initialize with the
        // platform default trust (no override, no test CA, no delegate
        // substitution) and be recognized as streamable.
        let transportInitialized: Bool = {
            let configuration = URLSessionConfiguration.ephemeral
            let session = StreamingTransport.makeSession(configuration: configuration)
            let streamable = StreamingTransport.isStreamable(session)
            session.invalidateAndCancel()
            return streamable
        }()

        let admitted = trustClean && storeUsable && transportInitialized
        let reason: String?
        if admitted {
            reason = nil
        } else if !trustClean {
            reason = "trustEnvironmentSubverted"
        } else if !storeUsable {
            reason = "defaultTrustStoreUnavailable"
        } else {
            reason = "transportInitializationFailed"
        }
        return Result(admitted: admitted, reason: reason,
                      trustEnvironmentClean: trustClean,
                      caStoreSelected: selectedPath,
                      caStoreEntries: selected.entryCount,
                      caStoreReadablePEM: selected.firstEntryPEMPrefix,
                      transportSessionInitialized: transportInitialized)
    }

    private struct CAProbe: Sendable {
        let exists: Bool
        let entryCount: Int
        let firstEntryPEMPrefix: Bool
    }

    /// Bounded CA-store probe (same facts as the qualified P1 probe): the
    /// directory must exist and, for the selected store, hold a readable
    /// PEM-prefixed first entry — the way a by-dir hash store loads.
    private static func probeCADirectory(_ path: String) -> CAProbe {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path,
                                                    isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: path)
        else {
            return CAProbe(exists: exists && isDirectory.boolValue,
                           entryCount: 0, firstEntryPEMPrefix: false)
        }
        let candidates = entries.sorted()
        guard let first = candidates.first(where: { !$0.hasPrefix(".") })
                ?? candidates.first else {
            return CAProbe(exists: true, entryCount: entries.count,
                           firstEntryPEMPrefix: false)
        }
        let fullPath = path + "/" + first
        guard let handle = FileHandle(forReadingAtPath: fullPath) else {
            return CAProbe(exists: true, entryCount: entries.count,
                           firstEntryPEMPrefix: false)
        }
        let head = handle.readData(ofLength: 27)
        try? handle.close()
        let pem = String(decoding: head, as: UTF8.self)
            .hasPrefix("-----BEGIN CERTIFICATE-----")
        return CAProbe(exists: true, entryCount: entries.count,
                       firstEntryPEMPrefix: pem)
    }
}
