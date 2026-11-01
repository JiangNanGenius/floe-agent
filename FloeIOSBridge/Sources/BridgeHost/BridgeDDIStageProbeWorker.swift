import Foundation
import IDevice
import BridgeCore

/// Blocking, read-only stage probe for the pinned cryptex DDI path.
///
/// Every call is separated by a cancellation check and recorded immediately
/// before/after it, with each marker persisted to the bounded report file so a
/// hung call leaves a timestamped "running" stage behind. The worker never
/// installs, mounts, uninstalls or re-pairs; it never prints or persists the
/// personalization dictionary, ECID/UDID, raw nonce, pairing record or TSS
/// data. A cryptexd handle is either freed unused (cancellation before the
/// call) or left to the consumed call; a returned plist/data value is freed
/// exactly once.
enum BridgeDDIStageProbeWorker {
    static func probe(
        pairingPath: URL,
        imageDirectory: URL,
        reportURL: URL,
        recorder: BridgeDDIStageProbeRecorder,
        gate: BridgeDDIMutationGate
    ) -> BridgeDDIStageProbeReport {
        if gate.isCancelled {
            recorder.note("cancelled before the probe session")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        var pairing: OpaquePointer?
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
            if let pairing { rp_pairing_file_free(pairing) }
        }

        begin(.rsdSession, recorder: recorder, reportURL: reportURL)
        if let failure = describe(rp_pairing_file_read(pairingPath.path, &pairing)) {
            fail(.rsdSession, code: "rp-\(failure)", recorder: recorder, reportURL: reportURL)
            _ = recorder.finish(.failed, errorCode: "pairing-read")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = BridgeTransport.remotePairingPort.bigEndian
        guard BridgeTransport.peerAddress.withCString({
            inet_pton(AF_INET, $0, &address.sin_addr)
        }) == 1 else {
            fail(.rsdSession, code: "transport", recorder: recorder, reportURL: reportURL)
            _ = recorder.finish(.failed, errorCode: "transport")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        let createError: UnsafeMutablePointer<IdeviceFfiError>? = withUnsafePointer(to: &address) {
            pointer in
            pointer.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { socketAddress in
                tunnel_create_rppairing(
                    socketAddress,
                    idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                    "FloeBridgeProbe",
                    pairing,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let failure = describe(createError) {
            fail(
                .rsdSession,
                code: "ffi-\(failure)",
                recorder: recorder,
                reportURL: reportURL
            )
            _ = recorder.finish(.failed, errorCode: "rsd-session")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        guard adapter != nil, handshake != nil else {
            fail(.rsdSession, code: "missing-handles", recorder: recorder, reportURL: reportURL)
            _ = recorder.finish(.failed, errorCode: "rsd-session")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        complete(.rsdSession, recorder: recorder, reportURL: reportURL)

        if gate.isCancelled {
            recorder.note("cancelled after the RSD session")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        let counts = BridgeDDIAssetByteCounts.measure(directory: imageDirectory, method: .cryptex)
        begin(.cachedAssetsLoad, recorder: recorder, reportURL: reportURL)
        var assets: OpaquePointer?
        if let failure = describe(cryptex1_assets_load(imageDirectory.path, &assets)) {
            fail(
                .cachedAssetsLoad,
                code: "ffi-\(failure)",
                recorder: recorder,
                reportURL: reportURL
            )
            _ = recorder.finish(.failed, errorCode: "assets-load")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        guard let assets else {
            fail(.cachedAssetsLoad, code: "no-assets", recorder: recorder, reportURL: reportURL)
            _ = recorder.finish(.failed, errorCode: "assets-load")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        defer { cryptex1_assets_free(assets) }
        complete(
            .cachedAssetsLoad,
            detail: "totalBytes=\(counts.total) imageBytes=\(counts.image)",
            recorder: recorder,
            reportURL: reportURL
        )

        if gate.isCancelled {
            recorder.note("cancelled after the cached assets loaded")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        var nonceDomain: UInt64 = 0
        begin(.assetsNonceDomain, recorder: recorder, reportURL: reportURL)
        if let failure = describe(cryptex1_assets_nonce_domain(assets, &nonceDomain)) {
            fail(
                .assetsNonceDomain,
                code: "ffi-\(failure)",
                recorder: recorder,
                reportURL: reportURL
            )
            _ = recorder.finish(.failed, errorCode: "assets-nonce-domain")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        complete(
            .assetsNonceDomain,
            detail: "nonceDomainPresent=\(nonceDomain != 0)",
            recorder: recorder,
            reportURL: reportURL
        )

        if gate.isCancelled {
            recorder.note("cancelled after the nonce domain was read")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        // The personalization dictionary is never inspected, logged or copied.
        // Only the fact that a non-null plist returned is recorded.
        begin(.personalizationIdentifiers, recorder: recorder, reportURL: reportURL)
        if gate.isCancelled {
            recorder.cancel(.personalizationIdentifiers)
            log(.personalizationIdentifiers, "cancelled")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        var identifiersClient: OpaquePointer?
        if let failure = describe(cryptexd_connect_rsd(adapter, handshake, &identifiersClient)) {
            if let identifiersClient { cryptexd_free(identifiersClient) }
            fail(
                .personalizationIdentifiers,
                code: "ffi-\(failure)",
                recorder: recorder,
                reportURL: reportURL
            )
        } else if let identifiersClient {
            if gate.isCancelled {
                // Connected but never called: this handle is unused.
                cryptexd_free(identifiersClient)
                recorder.cancel(.personalizationIdentifiers)
                log(.personalizationIdentifiers, "cancelled")
                _ = recorder.finish(.cancelled, errorCode: "cancelled")
                recorder.write(to: reportURL)
                return recorder.snapshot()
            }
            var identifiers: plist_t?
            let readFailure = describe(
                cryptexd_read_personalization_identifiers(identifiersClient, &identifiers)
            )
            let identifiersPresent = identifiers != nil
            if let identifiers { plist_free(identifiers) }
            if let readFailure {
                fail(
                    .personalizationIdentifiers,
                    code: "ffi-\(readFailure)",
                    recorder: recorder,
                    reportURL: reportURL
                )
            } else {
                complete(
                    .personalizationIdentifiers,
                    detail: "identifiersPresent=\(identifiersPresent)",
                    recorder: recorder,
                    reportURL: reportURL
                )
            }
        } else {
            fail(
                .personalizationIdentifiers,
                code: "no-client",
                recorder: recorder,
                reportURL: reportURL
            )
        }

        if gate.isCancelled {
            recorder.note("cancelled before the cryptex nonce read")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        // A fresh handle is required: the previous cryptex client was consumed
        // by read-personalization-id even when that call returned an error.
        begin(.cryptexNonce, recorder: recorder, reportURL: reportURL)
        if gate.isCancelled {
            recorder.cancel(.cryptexNonce)
            log(.cryptexNonce, "cancelled")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        var nonceClient: OpaquePointer?
        if let failure = describe(cryptexd_connect_rsd(adapter, handshake, &nonceClient)) {
            if let nonceClient { cryptexd_free(nonceClient) }
            fail(
                .cryptexNonce,
                code: "ffi-\(failure)",
                recorder: recorder,
                reportURL: reportURL
            )
            _ = recorder.finish(.failed, errorCode: "cryptex-nonce")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        guard let nonceClient else {
            fail(.cryptexNonce, code: "no-client", recorder: recorder, reportURL: reportURL)
            _ = recorder.finish(.failed, errorCode: "cryptex-nonce")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        if gate.isCancelled {
            // Connected but never called: this handle is unused.
            cryptexd_free(nonceClient)
            recorder.cancel(.cryptexNonce)
            log(.cryptexNonce, "cancelled")
            _ = recorder.finish(.cancelled, errorCode: "cancelled")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }

        var nonce: UnsafeMutablePointer<UInt8>?
        var nonceLength: UInt = 0
        let nonceFailure = describe(
            cryptexd_cryptex_nonce(nonceClient, nonceDomain, &nonce, &nonceLength)
        )
        let noncePresent = nonce != nil
        // Never copy, hash or log the bytes; only the length and presence.
        if let nonce { idevice_data_free(nonce, nonceLength) }
        if let nonceFailure {
            fail(
                .cryptexNonce,
                code: "ffi-\(nonceFailure)",
                recorder: recorder,
                reportURL: reportURL
            )
            _ = recorder.finish(.failed, errorCode: "cryptex-nonce")
            recorder.write(to: reportURL)
            return recorder.snapshot()
        }
        complete(
            .cryptexNonce,
            detail: "nonceBytes=\(nonceLength) noncePresent=\(noncePresent)",
            recorder: recorder,
            reportURL: reportURL
        )

        let snapshot = recorder.snapshot()
        if let failed = snapshot.stages.last(where: { $0.state == .failed }) {
            _ = recorder.finish(.failed, errorCode: failed.errorCode ?? "stage-failed")
        } else {
            _ = recorder.finish(.completed)
        }
        recorder.write(to: reportURL)
        return recorder.snapshot()
    }

    private static func begin(
        _ stage: BridgeDDIProbeStage,
        recorder: BridgeDDIStageProbeRecorder,
        reportURL: URL
    ) {
        recorder.begin(stage)
        log(stage, "begin")
        recorder.write(to: reportURL)
    }

    private static func complete(
        _ stage: BridgeDDIProbeStage,
        detail: String? = nil,
        recorder: BridgeDDIStageProbeRecorder,
        reportURL: URL
    ) {
        recorder.complete(stage, detail: detail)
        log(stage, "complete", detail)
        recorder.write(to: reportURL)
    }

    private static func fail(
        _ stage: BridgeDDIProbeStage,
        code: String,
        recorder: BridgeDDIStageProbeRecorder,
        reportURL: URL
    ) {
        recorder.fail(stage, code: code)
        log(stage, "error", "code=\(code)")
        recorder.write(to: reportURL)
    }

    private static func log(
        _ stage: BridgeDDIProbeStage,
        _ event: String,
        _ detail: String? = nil
    ) {
        var line = "ddi_probe_stage stage=\(stage.rawValue) event=\(event)"
        if let detail { line += " \(detail)" }
        BridgeLog.shared.append(line)
    }

    /// Frees the FFI error and returns only its numeric code. The message is
    /// not logged from this probe: it can contain transport detail or a path.
    private static func describe(
        _ error: UnsafeMutablePointer<IdeviceFfiError>?
    ) -> Int32? {
        guard let error else { return nil }
        let code = error.pointee.code
        idevice_error_free(error)
        return code
    }
}
