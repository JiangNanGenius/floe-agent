import Foundation
import IDevice
import BridgeCore

/// On-device DDI mount, adapted from the pinned iCTRL Apache-2.0 implementation
/// (`iCTRLApp/DDI/DDIMounter.swift`, revision c1e4268859ba858d1579f7b846a56cb40641b7f6).
/// The sequencing and FFI calls are retained; the tunnel is now this app's own
/// packet-tunnel extension and the pairing input is a Keychain record staged
/// only for the duration of the worker thread.
///
/// The worker owns the scoped native deadline/cancellation boundary. Every
/// borrowed future is dropped by Rust before synchronous FFI returns. Its
/// callback context, pairing record, buffers and handles stay alive until then.
/// A marker survives uncertain remote effects and allows read-only recovery.
@MainActor
final class BridgeDDIManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case queryingDevice
        case uploading(Double)
        case finalizing
        case mounted
        case failed(String)
    }

    enum RemovalPhase: Equatable {
        case idle
        case connecting
        case removing
        case verifying
        case removed
        case alreadyAbsent
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var removalPhase: RemovalPhase = .idle
    @Published private(set) var lastReport: [String: Any] = [:]
    @Published private(set) var lastRemovalReport: BridgeDDIRemovalReport?

    /// Owns the whole blocking call, not only a published phase. A rejected
    /// concurrent call returns without ending the live worker's lifetime.
    private let workerLifetime = BridgeDDIWorkerLifetime()

    /// A removal worker and a mount worker may never overlap: both own the
    /// reflector, the staged pairing record and the device service connection.
    var isRunning: Bool {
        workerLifetime.isActive
    }

    func mount(pairingPath: URL,
               method: BridgeDDIInstallMethod,
               imageDirectory: URL,
               trace: BridgeDDIInstallTrace?,
               gate: BridgeDDIMutationGate,
               progress: @escaping @Sendable (Double) -> Void) async throws -> [String: Any] {
        guard workerLifetime.begin() else { throw BridgeDDIMountError.busy }
        defer { workerLifetime.end() }
        phase = .connecting
        lastReport = [:]
        let started = Date()

        do {
            let report = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                let thread = Thread {
                    do {
                        let result = try BridgeDDIWorker.mount(
                            pairingPath: pairingPath,
                            method: method,
                            imageDirectory: imageDirectory,
                            trace: trace,
                            gate: gate
                        ) { fraction in
                            progress(fraction)
                            Task { @MainActor in
                                guard self.isRunning, !gate.isCancelled else { return }
                                if fraction < 1 { self.phase = .uploading(fraction) }
                            }
                        }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.stackSize = 4 * 1024 * 1024
                thread.name = "org.floeagent.iosbridge.ddi.mount"
                thread.qualityOfService = .userInitiated
                thread.start()
            }

            var enriched = report
            enriched["durationSeconds"] = Date().timeIntervalSince(started)
            // Close the race where Stop arrives after the worker's final gate
            // check but before this method resumes. The device may have been
            // mutated, but no success is claimed; the next probe observes it.
            if gate.isCancelled && report["cancelled"] as? Bool != true {
                enriched["cancelled"] = true
                enriched["mutationAttempted"] = gate.didEnterMutation
                enriched["cancelNote"] = "after-worker-return"
            }
            lastReport = enriched
            // A cancelled worker must never leave the UI in a mounted state.
            if enriched["cancelled"] as? Bool == true {
                phase = .idle
            } else {
                phase = .mounted
            }
            return enriched
        } catch {
            // The continuation only throws after the worker thread has
            // returned, so there is no overlapping worker. A cancelled worker
            // returns to idle; a real failure remains retryable.
            let cancelled = gate.isCancelled
            phase = cancelled ? .idle : .failed(error.localizedDescription)
            var failure: [String: Any] = [
                "phase": cancelled ? "cancelled" : "failed",
                "error": error.localizedDescription,
                "durationSeconds": Date().timeIntervalSince(started),
            ]
            if cancelled {
                failure["cancelled"] = true
                failure["mutationAttempted"] = gate.didEnterMutation
            }
            lastReport = failure
            throw error
        }
    }

    /// Runs the prototype-only removal on the same dedicated-thread pattern as
    /// the mount. The caller stages the pairing file, keeps it alive until this
    /// method returns, and owns generation/cancellation decisions. A failed
    /// removal is returned as a structured report, not a throw, so the
    /// pre/post evidence is never lost.
    func remove(
        pairingPath: URL,
        installMethod: BridgeDDIInstallMethod,
        generation: UInt64,
        gate: BridgeDDIMutationGate
    ) async -> BridgeDDIRemovalReport {
        // A rejected concurrent call must not touch removalPhase,
        // lastRemovalReport or workerLifetime: the live worker still owns them.
        guard workerLifetime.begin() else {
            BridgeLog.shared.append("ddi_remove_busy generation=\(generation)")
            return BridgeDDIRemovalReport.busy(
                generation: generation,
                installMethod: installMethod
            )
        }
        defer { workerLifetime.end() }

        removalPhase = .connecting
        var report = await withCheckedContinuation { (continuation: CheckedContinuation<BridgeDDIRemovalReport, Never>) in
            let thread = Thread {
                let result = BridgeDDIRemover.remove(
                    pairingPath: pairingPath,
                    installMethod: installMethod,
                    generation: generation,
                    gate: gate
                )
                continuation.resume(returning: result)
            }
            thread.stackSize = 4 * 1024 * 1024
            thread.name = "org.floeagent.iosbridge.ddi.remove"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        // A Stop that lands after the worker's final report check but before
        // this method resumes still forces a logical cancellation.
        _ = BridgeDDIRemovalCancellation.apply(to: &report, gate: gate)
        lastRemovalReport = report
        switch report.outcome {
        case .removed:
            removalPhase = .removed
        case .alreadyAbsent:
            removalPhase = .alreadyAbsent
        case .cancelled:
            removalPhase = .idle
        case .failed, .preStateUnknown, .verificationFailed:
            removalPhase = .failed(report.errorMessage ?? report.outcome.rawValue)
        }
        return report
    }

    /// Runs the read-only stage probe on the same worker lifetime and dedicated
    /// 4 MiB thread as mount/removal. Returns nil when another DDI operation
    /// owns the lifetime; the caller must not modify that operation's state.
    /// A cancellation that arrives before a read call is entered prevents that
    /// call; a read already inside the FFI keeps its inputs until it returns.
    func probeStages(
        pairingPath: URL,
        imageDirectory: URL,
        reportURL: URL,
        gate: BridgeDDIMutationGate,
        recorder: BridgeDDIStageProbeRecorder
    ) async -> BridgeDDIStageProbeReport? {
        guard workerLifetime.begin() else { return nil }
        defer { workerLifetime.end() }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<BridgeDDIStageProbeReport, Never>) in
            let thread = Thread {
                let report = BridgeDDIStageProbeWorker.probe(
                    pairingPath: pairingPath,
                    imageDirectory: imageDirectory,
                    reportURL: reportURL,
                    recorder: recorder,
                    gate: gate
                )
                continuation.resume(returning: report)
            }
            thread.stackSize = 4 * 1024 * 1024
            thread.name = "org.floeagent.iosbridge.ddi.probe"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func markFailed(_ message: String) {
        phase = .failed(message)
    }
}

/// Callbacks are invoked only on the dedicated native-call thread. Stop is
/// sampled by Rust at most every 25ms while an async stage is pending.
private final class BridgeDDINativeContext {
    let gate: BridgeDDIMutationGate
    let trace: BridgeDDIInstallTrace?
    init(gate: BridgeDDIMutationGate, trace: BridgeDDIInstallTrace?) {
        self.gate = gate
        self.trace = trace
    }
}

enum BridgeDDIWorker {
    static func mount(
        pairingPath: URL,
        method: BridgeDDIInstallMethod,
        imageDirectory: URL,
        trace: BridgeDDIInstallTrace?,
        gate: BridgeDDIMutationGate,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> [String: Any] {
        BridgeLog.shared.append("ddi_mount_begin method=\(method.rawValue)")
        let crypto = cryptoProviderStatus()

        guard floe_ddi_abi_version() == BridgeDDINativePolicy.abiVersion else {
            throw BridgeDDIMountError.verificationFailed("The native DDI component is incompatible.")
        }
        let context = Unmanaged.passRetained(BridgeDDINativeContext(gate: gate, trace: trace))
        let scope = floe_ddi_scope_begin(
            BridgeDDINativePolicy.defaultTimeoutMilliseconds,
            { pointer in
                guard let pointer else { return true }
                return Unmanaged<BridgeDDINativeContext>.fromOpaque(pointer).takeUnretainedValue().gate.isCancelled
            },
            { code, pointer in
                guard let pointer else { return }
                let context = Unmanaged<BridgeDDINativeContext>.fromOpaque(pointer).takeUnretainedValue()
                guard !context.gate.isCancelled else { return }
                context.trace?.nativeStage(code)
            },
            context.toOpaque()
        )
        guard scope == 0 else {
            context.release()
            throw BridgeDDIMountError.busy
        }
        defer {
            // Scope teardown fences every callback before releasing context.
            let stop = floe_ddi_scope_stop_reason()
            if stop == 1 { trace?.finish(.timedOut, errorCode: "native-deadline") }
            else if stop == 2 { trace?.finish(.cancelled, errorCode: "native-cancelled") }
            floe_ddi_scope_end()
            context.release()
        }
        let recovery = BridgeDDIRecoveryState()
        let legacyDirectories = [imageDirectory] + BridgeDDIInstallMethod.allCases.map {
            BridgePaths.ddiDirectory.appendingPathComponent($0.mirrorFolder, isDirectory: true)
        }
        try recovery.migrateLegacyMarkers(in: legacyDirectories)
        let needsReconciliation = try recovery.requiresReconciliation()

        if gate.isCancelled {
            BridgeLog.shared.append("ddi_mount_cancelled stage=before-session")
            return cancelledMountReport(
                method: method,
                mutationAttempted: false,
                note: "before-session"
            )
        }

        var pairing: OpaquePointer?
        try check("Reading the RemotePairing record") {
            rp_pairing_file_read(pairingPath.path, &pairing)
        }
        defer { if let pairing { rp_pairing_file_free(pairing) } }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = BridgeTransport.remotePairingPort.bigEndian
        guard BridgeTransport.peerAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw BridgeDDIMountError.transport("The peer address is not valid IPv4.")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        _ = try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { socketAddress in
                try check("Connecting to the device debug service") {
                    tunnel_create_rppairing(
                        socketAddress,
                        idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                        "FloeBridge",
                        pairing,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        guard let adapter, let handshake else {
            throw BridgeDDIMountError.transport("The tunnel returned no RSD handles.")
        }

        // Both service queries must be definitive before an install can be
        // attributed to this app. A failed query is unknown, never absence.
        let preCryptex = BridgeDDIFFI.queryCryptex(
            adapter: adapter,
            handshake: handshake,
            installMethod: method
        )
        let preImage = BridgeDDIFFI.queryImages(adapter: adapter, handshake: handshake)
        let localBefore = BridgeDDIProbe.status()
        let preState = BridgeDDIRemovalPolicy.classifyPreState(
            cryptex: preCryptex,
            image: preImage,
            probeMounted: localBefore.mounted,
            installMethod: method
        )
        let preStateFields: [String: Any] = [
            "preCryptex": preCryptex.summary,
            "preImage": preImage.summary,
            "preImageTypes": preImage.developerImages.map { $0.diskImageType },
            "preProbeMounted": localBefore.mounted,
        ]
        BridgeLog.shared.append(
            "ddi_service_prestate cryptex=\(preCryptex.summary) image=\(preImage.summary) " +
            "localMounted=\(localBefore.mounted)"
        )

        // The read-only query can be long. Stop between the query and the
        // install must not leave an install behind.
        if gate.isCancelled {
            BridgeLog.shared.append("ddi_mount_cancelled stage=after-pre-query")
            return cancelledMountReport(
                method: method,
                mutationAttempted: false,
                preStateFields: preStateFields,
                note: "after-pre-query"
            )
        }

        switch preState {
        case .alreadyMounted(let reason):
            if needsReconciliation && localBefore.mounted && localBefore.xctestReadable {
                try? recovery.clearResolvedMarker(legacyDirectories: legacyDirectories)
            }
            var report: [String: Any] = [
                "method": method.rawValue,
                "alreadyMounted": true,
                "preState": "preexisting",
                "preStateReason": reason,
                "preStateVerifiedAbsent": false,
                "mountedImageCount": preImage.developerImages.count,
                "engineReady": false,
                "cryptoProviderRequired": crypto["required"] as? Bool ?? false,
                "cryptoProviderAbortRisk": crypto["providerAbortRisk"] as? Bool ?? false,
                "crypto": crypto,
            ]
            report.merge(preStateFields) { _, new in new }
            BridgeLog.shared.append(
                "ddi_mount_already_present method=\(method.rawValue) reason=\"\(reason)\""
            )
            return report
        case .unknown(let reason):
            BridgeLog.shared.append("ddi_prestate_unknown reason=\"\(reason)\"")
            throw BridgeDDIMountError.preStateUnknown(reason)
        case .absent:
            break
        }

        guard !needsReconciliation else {
            throw BridgeDDIMountError.verificationFailed(
                "The previous install needs read-only recovery. Its device effect is uncertain; no second install was sent."
            )
        }

        let mutationAttempted: Bool
        do {
            try recovery.markUnresolved()
            mutationAttempted = try performMutation(
                method: method,
                adapter: adapter,
                handshake: handshake,
                imageDirectory: imageDirectory,
                trace: trace,
                progress: progress,
                gate: gate
            )
        } catch {
            if !gate.didEnterMutation {
                try? recovery.clearResolvedMarker(legacyDirectories: legacyDirectories)
                throw error
            }
            // Native has dropped the install future. Give only read-only
            // reconciliation a separate bounded budget, preserving uncertainty.
            let stopReason = floe_ddi_scope_stop_reason()
            if stopReason == 1 { trace?.finish(.timedOut, errorCode: "native-deadline") }
            if stopReason == 2 { trace?.finish(.cancelled, errorCode: "native-cancelled") }
            floe_ddi_scope_reconcile()
            let postCryptex = BridgeDDIFFI.queryCryptex(adapter: adapter, handshake: handshake, installMethod: method)
            let postImage = BridgeDDIFFI.queryImages(adapter: adapter, handshake: handshake)
            let postProbe = BridgeDDIProbe.status()
            let remotePresent = postCryptex.installedEntry != nil || postImage.hasDeveloperDiskImage
            if remotePresent && postProbe.mounted && postProbe.xctestReadable {
                try? recovery.clearResolvedMarker(legacyDirectories: legacyDirectories)
            }
            BridgeLog.shared.append("ddi_reconciliation remotePresent=\(remotePresent) xctestReadable=\(postProbe.xctestReadable) nativeStop=\(stopReason)")
            if gate.isCancelled {
                return cancelledMountReport(method: method, mutationAttempted: true,
                    preStateFields: preStateFields, postProbe: postProbe,
                    note: "native-cancelled-reconciled-read-only", mutationError: "native-install-interrupted")
            }
            throw BridgeDDIMountError.verificationFailed(
                stopReason == 1
                    ? "The install reached its time limit. Device state was checked without sending another install."
                    : "The install failed. Device state was checked without sending another install."
            )
        }

        if !mutationAttempted {
            try? recovery.clearResolvedMarker(legacyDirectories: legacyDirectories)
            BridgeLog.shared.append("ddi_mount_cancelled stage=before-mutation")
            return cancelledMountReport(
                method: method,
                mutationAttempted: false,
                preStateFields: preStateFields,
                note: "before-mutation"
            )
        }

        if gate.isCancelled {
            // The FFI entered and returned, but Stop arrived while it was in
            // flight. Record the post fact without claiming a successful mount.
            let postProbe = BridgeDDIProbe.status()
            BridgeLog.shared.append("ddi_mount_cancelled stage=after-mutation")
            return cancelledMountReport(
                method: method,
                mutationAttempted: true,
                preStateFields: preStateFields,
                postProbe: postProbe,
                note: "after-mutation"
            )
        }

        // Do not infer readiness from the image installer's success. Probe the
        // framework file from the app's own process; the coordinator still
        // requires a real test entry before calling the engine ready.
        let postCryptex = BridgeDDIFFI.queryCryptex(adapter: adapter, handshake: handshake, installMethod: method)
        let postImage = BridgeDDIFFI.queryImages(adapter: adapter, handshake: handshake)
        let probe = BridgeDDIProbe.status()
        guard probe.mounted, probe.xctestReadable,
              postCryptex.installedEntry != nil || postImage.hasDeveloperDiskImage else {
            throw BridgeDDIMountError.verificationFailed(
                "The mount call returned but XCTest.framework is not readable at any known DDI path."
            )
        }
        try? recovery.clearResolvedMarker(legacyDirectories: legacyDirectories)
        var report: [String: Any] = [
            "postCryptex": postCryptex.summary,
            "postImage": postImage.summary,
            "method": method.rawValue,
            "alreadyMounted": false,
            "preState": "absent",
            "preStateVerifiedAbsent": true,
            "mountedImageCount": preImage.developerImages.count,
            "xctestPath": probe.xctestPath as Any,
            "xctestBytes": probe.xctestBytes,
            "xctestReadable": probe.xctestReadable,
            "layout": probe.layout?.rawValue as Any,
            "engineReady": false,
            "cryptoProviderRequired": crypto["required"] as? Bool ?? false,
            "cryptoProviderAbortRisk": crypto["providerAbortRisk"] as? Bool ?? false,
            "crypto": crypto,
        ]
        report.merge(preStateFields) { _, new in new }
        BridgeLog.shared.append("ddi_mount_complete method=\(method.rawValue) layout=\(probe.layout?.rawValue ?? "unknown")")
        return report
    }

    /// Enters the one-shot mutation gate at the last possible point. Asset
    /// loading, image reads and ECID lookup remain read-only and cancellable.
    private static func performMutation(
        method: BridgeDDIInstallMethod,
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        imageDirectory: URL,
        trace: BridgeDDIInstallTrace?,
        progress: @escaping @Sendable (Double) -> Void,
        gate: BridgeDDIMutationGate
    ) throws -> Bool {
        if gate.isCancelled { return false }
        switch method {
        case .cryptex:
            return try installCryptex(
                adapter: adapter,
                handshake: handshake,
                imageDirectory: imageDirectory,
                trace: trace,
                gate: gate
            )
        case .personalized:
            return try mountPersonalized(
                adapter: adapter,
                handshake: handshake,
                imageDirectory: imageDirectory,
                trace: trace,
                progress: progress,
                gate: gate
            )
        }
    }

    /// A cancelled mount bridge report that can never be mistaken for an
    /// on-device provenance claim. `preStateVerifiedAbsent` stays false because
    /// this call did not complete an install.
    private static func cancelledMountReport(
        method: BridgeDDIInstallMethod,
        mutationAttempted: Bool,
        preStateFields: [String: Any] = [:],
        postProbe: BridgeDDIProbe.Status? = nil,
        note: String,
        mutationError: String? = nil
    ) -> [String: Any] {
        var report: [String: Any] = [
            "method": method.rawValue,
            "cancelled": true,
            "mutationAttempted": mutationAttempted,
            "alreadyMounted": false,
            "preState": "cancelled",
            "preStateVerifiedAbsent": false,
            "mountedImageCount": 0,
            "engineReady": false,
            "cancelNote": note,
        ]
        report.merge(preStateFields) { _, new in new }
        if let postProbe {
            report["postProbeMounted"] = postProbe.mounted
            report["postXCTestReadable"] = postProbe.xctestReadable
            report["postProbeLayout"] = postProbe.layout?.rawValue as Any
        }
        if let mutationError {
            report["mutationError"] = String(mutationError.prefix(512))
        }
        return report
    }

    /// The pinned idevice build (v0.1.68, d32c8189) needs no rustls provider for
    /// this DDI route, so there is nothing to prime.
    ///
    /// - TSS is plain HTTP (`http://gs.apple.com/TSS/controller?action=2`) and is
    ///   sent through the crate's own HTTP/1.1 client. If a request were ever
    ///   redirected to HTTPS, `http::tls_connect` installs the process default
    ///   provider itself before building its rustls config.
    /// - The RemotePairing tunnel uses the crate's in-tree TLS-PSK code, not
    ///   rustls.
    /// - RSD, cryptexd and the image mounter are plain streams over that tunnel.
    ///
    /// This status covers provider initialization only. TSS network, ticket and
    /// protocol failures remain ordinary mount errors and are not predicted
    /// here. The earlier attempt parsed our stored RemotePairing record with the
    /// lockdown pairing parser; that parser requires certificate fields the
    /// record does not have, so it returned before `idevice_start_session` and
    /// never installed anything. Reporting it as an unresolved TSS abort risk
    /// was wrong for this pin.
    static func cryptoProviderStatus() -> [String: Any] {
        BridgeLog.shared.append("crypto_provider_not_required route=pinned_ddi_v0.1.68")
        return [
            "required": false,
            "attempted": false,
            "installed": false,
            "providerAbortRisk": false,
            "scope": "provider initialization only; other TSS or transport failures remain ordinary mount errors",
            "reason": "no rustls provider leg in the pinned v0.1.68 DDI route (plain-HTTP TSS, TLS-PSK RemotePairing)",
        ]
    }

    /// The pinned algorithm runs inside the native scope. Its observed phase
    /// callbacks, whole-operation deadline and Stop are enforced before return.
    private static func installCryptex(adapter: OpaquePointer,
                                       handshake: OpaquePointer,
                                       imageDirectory: URL,
                                       trace: BridgeDDIInstallTrace?,
                                       gate: BridgeDDIMutationGate) throws -> Bool {
        let counts = BridgeDDIAssetByteCounts.measure(directory: imageDirectory, method: .cryptex)
        trace?.assetsBegan(counts)
        BridgeLog.shared.append("ddi_assets_begin method=cryptex \(counts.summary)")

        var assets: OpaquePointer?
        let assetsStarted = Date()
        let assetsError = cryptex1_assets_load(imageDirectory.path, &assets)
        let assetsMilliseconds = milliseconds(since: assetsStarted)
        if let error = assetsError {
            let code = error.pointee.code
            let message = "Native DDI error"
            idevice_error_free(error)
            trace?.finish(.failed, errorCode: "assets-\(code)")
            BridgeLog.shared.append(
                "ddi_assets_error method=cryptex code=\(code) durationMs=\(assetsMilliseconds)"
            )
            BridgeLog.shared.append("ddi_ffi_error operation=\"Reading the DDI cryptex files\" code=\(code)")
            throw BridgeDDIMountError.ffi(
                "Reading the DDI cryptex files",
                ffiDetail(message, code: code)
            )
        }
        guard let assets else {
            trace?.finish(.failed, errorCode: "assets-missing")
            BridgeLog.shared.append(
                "ddi_assets_error method=cryptex code=missing durationMs=\(assetsMilliseconds)"
            )
            throw BridgeDDIMountError.ffi("Reading the DDI cryptex files", "no assets were loaded")
        }
        defer { cryptex1_assets_free(assets) }
        trace?.assetsLoaded()
        BridgeLog.shared.append(
            "ddi_assets_complete method=cryptex durationMs=\(assetsMilliseconds) " +
                "totalBytes=\(counts.total)"
        )

        guard !gate.isCancelled else {
            trace?.finish(.cancelled, errorCode: "before-mutation")
            return false
        }
        switch gate.beginMutation() {
        case .entered:
            break
        case .cancelledBeforeEntry:
            trace?.finish(.cancelled, errorCode: "before-mutation")
            return false
        case .alreadyEntered:
            trace?.finish(.failed, errorCode: "gate-already-entered")
            throw BridgeDDIMountError.verificationFailed(
                "The DDI mutation gate was already entered; no install was issued."
            )
        }

        trace?.installEntered()
        BridgeLog.shared.append("ddi_install_entered method=cryptex")
        let installStarted = Date()
        let installError = cryptexd_install_ddi(adapter, handshake, assets, nil)
        let installMilliseconds = milliseconds(since: installStarted)
        if let error = installError {
            let code = error.pointee.code
            let message = "Native DDI error"
            idevice_error_free(error)
            let stop = floe_ddi_scope_stop_reason()
            if stop == 1 { trace?.finish(.timedOut, errorCode: "native-deadline") }
            else if stop == 2 { trace?.finish(.cancelled, errorCode: "native-cancelled") }
            else { trace?.installFailed(code: code) }
            BridgeLog.shared.append(
                "ddi_install_error method=cryptex code=\(code) durationMs=\(installMilliseconds)"
            )
            BridgeLog.shared.append("ddi_ffi_error operation=\"Installing the DDI cryptex\" code=\(code)")
            throw BridgeDDIMountError.ffi(
                "Installing the DDI cryptex",
                ffiDetail(message, code: code)
            )
        }
        trace?.installReturned()
        BridgeLog.shared.append(
            "ddi_install_returned method=cryptex durationMs=\(installMilliseconds)"
        )
        return true
    }

    private static func mountPersonalized(adapter: OpaquePointer,
                                          handshake: OpaquePointer,
                                          imageDirectory: URL,
                                          trace: BridgeDDIInstallTrace?,
                                          progress: @escaping @Sendable (Double) -> Void,
                                          gate: BridgeDDIMutationGate) throws -> Bool {
        let image = try Data(contentsOf: imageDirectory.appendingPathComponent("Image.dmg"), options: .mappedIfSafe)
        let trustCache = try Data(contentsOf: imageDirectory.appendingPathComponent("Image.dmg.trustcache"), options: .mappedIfSafe)
        let manifest = try Data(contentsOf: imageDirectory.appendingPathComponent("BuildManifest.plist"), options: .mappedIfSafe)

        let ecid = try uniqueChipID(adapter: adapter, handshake: handshake)

        var client: OpaquePointer?
        try check("Opening the image mounter") {
            image_mounter_connect_rsd(adapter, handshake, &client)
        }
        defer { if let client { image_mounter_free(client) } }
        guard let client else {
            throw BridgeDDIMountError.ffi("Opening the image mounter", "no client")
        }

        guard !gate.isCancelled else { return false }
        switch gate.beginMutation() {
        case .entered:
            break
        case .cancelledBeforeEntry:
            return false
        case .alreadyEntered:
            throw BridgeDDIMountError.verificationFailed(
                "The DDI mutation gate was already entered; no image mount was issued."
            )
        }

        final class ProgressBox: @unchecked Sendable {
            let report: @Sendable (Double) -> Void
            init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        }
        let box = Unmanaged.passRetained(ProgressBox(progress))
        defer { box.release() }

        trace?.installEntered()
        BridgeLog.shared.append("ddi_install_entered method=personalized")
        let installStarted = Date()
        do {
            _ = try image.withUnsafeBytes { imageBytes in
                try trustCache.withUnsafeBytes { trustBytes in
                    try manifest.withUnsafeBytes { manifestBytes in
                        try check("Mounting the image") {
                            image_mounter_mount_personalized_with_callback_rsd(
                                client,
                                adapter,
                                handshake,
                                imageBytes.bindMemory(to: UInt8.self).baseAddress,
                                image.count,
                                trustBytes.bindMemory(to: UInt8.self).baseAddress,
                                trustCache.count,
                                manifestBytes.bindMemory(to: UInt8.self).baseAddress,
                                manifest.count,
                                nil,
                                ecid,
                                { progressValue, total, context in
                                    guard let context, total > 0 else { return }
                                    let box = Unmanaged<ProgressBox>.fromOpaque(context)
                                        .takeUnretainedValue()
                                    box.report(Double(progressValue) / Double(total))
                                },
                                box.toOpaque()
                            )
                        }
                    }
                }
            }
        } catch {
            trace?.finish(.failed, errorCode: "image-mounter")
            BridgeLog.shared.append(
                "ddi_install_error method=personalized code=image-mounter " +
                    "durationMs=\(milliseconds(since: installStarted))"
            )
            throw error
        }
        trace?.installReturned()
        BridgeLog.shared.append(
            "ddi_install_returned method=personalized durationMs=\(milliseconds(since: installStarted))"
        )
        return true
    }

    private static func uniqueChipID(adapter: OpaquePointer, handshake: OpaquePointer) throws -> UInt64 {
        var client: OpaquePointer?
        try check("Connecting to lockdownd") {
            lockdownd_connect_rsd(adapter, handshake, &client)
        }
        defer { if let client { lockdownd_client_free(client) } }
        guard let client else {
            throw BridgeDDIMountError.ffi("Connecting to lockdownd", "no client")
        }
        var value: plist_t?
        try check("Reading UniqueChipID") {
            lockdownd_get_value(client, "UniqueChipID", nil, &value)
        }
        defer { if let value { plist_free(value) } }
        guard let value else {
            throw BridgeDDIMountError.ffi("Reading UniqueChipID", "no value")
        }
        var ecid: UInt64 = 0
        plist_get_uint_val(value, &ecid)
        guard ecid != 0 else {
            throw BridgeDDIMountError.ffi("Reading UniqueChipID", "device returned 0")
        }
        return ecid
    }

    @discardableResult
    private static func check(_ operation: String,
                              _ body: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws -> Bool {
        guard let error = body() else { return true }
        let message = "Native DDI error"
        let code = error.pointee.code
        idevice_error_free(error)
        BridgeLog.shared.append("ddi_ffi_error operation=\"\(operation)\" code=\(code)")
        throw BridgeDDIMountError.ffi(operation, ffiDetail(message, code: code))
    }

    /// Converts an FFI message into the existing operator-facing detail with
    /// the same transport/image-hint wording used by `check`.
    private static func ffiDetail(_ message: String, code: Int32) -> String {
        var detail = "\(message) (code \(code))"
        if message.contains("device socket io failed") || message.contains("connect:") {
            detail += ". The reflector is not reaching the device debug service; confirm the tunnel is connected and the peer address route is present."
        }
        if message.contains("ImageMountFailed") {
            detail += ". The device rejected the image; it usually does not match this OS build or the download is incomplete."
        }
        return detail
    }

    private static func milliseconds(since start: Date) -> Int {
        let seconds = Date().timeIntervalSince(start)
        guard seconds.isFinite else { return 0 }
        return max(0, Int(min(seconds, 86_400) * 1000))
    }
}

enum BridgeDDIMountError: LocalizedError {
    case busy
    case transport(String)
    case ffi(String, String)
    case verificationFailed(String)
    /// Both pre-install service queries did not produce a trustworthy state.
    /// Nothing was installed and no on-device provenance may be claimed.
    case preStateUnknown(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "A DDI operation is already running."
        case .transport(let message):
            return "Transport unavailable: \(message)"
        case .ffi(let operation, let message):
            return "\(operation) failed: \(message)"
        case .verificationFailed(let message):
            return message
        case .preStateUnknown(let reason):
            return "The DDI state could not be verified before installing, so nothing was installed. \(reason)"
        }
    }

    /// Stable startup code for the coordinator's failure record.
    var startupCode: String {
        switch self {
        case .preStateUnknown:
            return "ddi-pre-state-unknown"
        default:
            return "ddi-mount-failed"
        }
    }
}
