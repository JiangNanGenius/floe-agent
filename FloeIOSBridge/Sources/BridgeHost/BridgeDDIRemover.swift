import Foundation
import IDevice
import BridgeCore

/// Read-only service queries and the two scoped removal calls used by the
/// prototype DDI gate.
///
/// Only the pinned `idevice` v0.1.68 FFI is used. Every query opens its own
/// service connection; `cryptexd_uninstall` consumes its handle even when the
/// daemon rejects the request, so that handle is never freed. The image-mounter
/// client is not consumed by `UnmountImage` and is released exactly once.
enum BridgeDDIFFI {
    static func queryCryptex(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        installMethod: BridgeDDIInstallMethod
    ) -> BridgeDDICryptexQuery {
        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        guard let error = cryptexd_installed_ddi(adapter, handshake, &installed) else {
            guard let installed else { return .absent }
            // Copy both C strings before freeing: the free function releases
            // the struct and both fields, so the strings must not be freed a
            // second time with idevice_string_free.
            let identifier = installed.pointee.identifier
                .map { String(String(cString: $0).prefix(128)) } ?? ""
            let version = installed.pointee.version
                .map { String(String(cString: $0).prefix(128)) } ?? ""
            cryptexd_free_installed_cryptex(installed)
            guard !identifier.isEmpty else {
                return .unknown(reason: "cryptexd returned an entry without an identifier")
            }
            return .installed(
                BridgeDDICryptexEntry(
                    identifier: identifier,
                    version: version.isEmpty ? nil : version
                )
            )
        }

        let code = error.pointee.code
        let detail = error.pointee.message.map { String(cString: $0) } ?? "code \(code)"
        idevice_error_free(error)
        // A failed call does not produce an output entry; free defensively if a
        // future pin sets one anyway.
        if let installed { cryptexd_free_installed_cryptex(installed) }
        BridgeLog.shared.append("ddi_cryptex_query_failed code=\(code) detail=\"\(detail)\"")
        return BridgeDDIRemovalPolicy.cryptexQueryAfterServiceError(
            code: code,
            installMethod: installMethod
        )
    }

    /// Returns the image mounter's device entries. `DiskImageType` is the
    /// authoritative developer-image field; unrelated images are retained in
    /// the result so callers can record them without treating them as a DDI.
    ///
    /// A successful FFI return is not enough: the array shape, every entry and
    /// every type must be valid before the result can be definitive. A malformed
    /// entry is unknown, never an empty list that could manufacture absence.
    static func queryImages(
        adapter: OpaquePointer,
        handshake: OpaquePointer
    ) -> BridgeDDIImageQuery {
        var client: OpaquePointer?
        if let error = image_mounter_connect_rsd(adapter, handshake, &client) {
            let code = error.pointee.code
            let detail = error.pointee.message.map { String(cString: $0) } ?? "code \(code)"
            idevice_error_free(error)
            if let client { image_mounter_free(client) }
            BridgeLog.shared.append("ddi_image_connect_failed code=\(code) detail=\"\(detail)\"")
            return .unknown(reason: "image-mounter connection failed (code \(code))")
        }
        guard let client else {
            return .unknown(reason: "image-mounter connection returned no client")
        }
        defer { image_mounter_free(client) }

        var devices: UnsafeMutablePointer<plist_t?>?
        var length: UInt = 0
        if let error = image_mounter_copy_devices(client, &devices, &length) {
            let code = error.pointee.code
            let detail = error.pointee.message.map { String(cString: $0) } ?? "code \(code)"
            idevice_error_free(error)
            if let devices { idevice_plist_array_free(devices, length) }
            BridgeLog.shared.append("ddi_image_query_failed code=\(code) detail=\"\(detail)\"")
            return .unknown(reason: "image-mounter query failed (code \(code))")
        }

        guard let devices else {
            // A null array with zero entries is the service's definitive empty
            // list. A null array claiming entries is malformed; there is no
            // allocation to free in that case.
            if length == 0 { return .devices([]) }
            BridgeLog.shared.append("ddi_image_array_invalid reason=null_with_entries")
            return .unknown(
                reason: "image-mounter returned a null device array with \(length) entries"
            )
        }
        // The pinned FFI allocates one contiguous slice for the array, so the
        // original length is the correct argument for the documented free even
        // when the bound rejects the contents.
        defer { idevice_plist_array_free(devices, length) }

        guard length <= UInt(BridgeDDIImageQueryParser.maximumDeviceEntries) else {
            BridgeLog.shared.append("ddi_image_array_invalid reason=count_bound")
            return .unknown(
                reason: "image-mounter returned \(length) entries, over the " +
                    "\(BridgeDDIImageQueryParser.maximumDeviceEntries) entry bound"
            )
        }

        var observations: [BridgeDDIImageObservation] = []
        observations.reserveCapacity(Int(length))
        for index in 0..<Int(length) {
            guard let device = devices[index] else {
                return .unknown(reason: "image-mounter entry \(index) was null")
            }
            guard plist_get_node_type(device) == PLIST_DICT else {
                return .unknown(reason: "image-mounter entry \(index) was not a dictionary")
            }
            let isMounted = plist_dict_get_bool(device, "IsMounted") != 0
            guard let typeNode = plist_dict_get_item(device, "DiskImageType"),
                  plist_get_node_type(typeNode) == PLIST_STRING else {
                observations.append(
                    .image(diskImageType: nil, isMounted: isMounted)
                )
                continue
            }
            var typeCString: UnsafeMutablePointer<CChar>?
            plist_get_string_val(typeNode, &typeCString)
            guard let typeCString else {
                observations.append(
                    .image(diskImageType: nil, isMounted: isMounted)
                )
                continue
            }
            let typeLength = strnlen(typeCString, BridgeDDIImagePolicy.maximumTypeBytes + 1)
            guard typeLength <= BridgeDDIImagePolicy.maximumTypeBytes else {
                plist_mem_free(typeCString)
                return .unknown(reason: "image-mounter entry \(index) has an oversized DiskImageType")
            }
            let type = String(cString: typeCString)
            // plist_get_string_val allocates; plist_mem_free is the documented
            // release, not free().
            plist_mem_free(typeCString)
            observations.append(
                .image(diskImageType: type, isMounted: isMounted)
            )
        }
        // The pinned implementation does not release its outer pointer slice
        // here; with a handful of bounded queries per gate that upstream
        // retention is accepted and recorded rather than worked around with an
        // undocumented call.
        return BridgeDDIImageQueryParser.parse(observations)
    }

    /// Opens the service first (read-only setup) and enters the gate only
    /// immediately before the uninstall FFI. Returns false when cancellation
    /// prevented the call. `cryptexd_uninstall` consumes the client, so the
    /// client is freed only on the not-entered paths.
    static func uninstallCryptex(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        identifier: String,
        version: String?,
        gate: BridgeDDIMutationGate
    ) throws -> Bool {
        var client: OpaquePointer?
        try check("Connecting to cryptexd for removal") {
            cryptexd_connect_rsd(adapter, handshake, &client)
        }
        guard let client else {
            throw BridgeDDIMountError.ffi("Connecting to cryptexd for removal", "no client")
        }

        switch gate.beginMutation() {
        case .cancelledBeforeEntry:
            cryptexd_free(client)
            return false
        case .alreadyEntered:
            cryptexd_free(client)
            throw BridgeDDIMountError.ffi(
                "Uninstalling the DDI cryptex",
                "the mutation gate was already entered"
            )
        case .entered:
            break
        }

        // From here the handle is consumed by cryptexd_uninstall on every path
        // that reaches the daemon. Never call cryptexd_free, including on error.
        let error: UnsafeMutablePointer<IdeviceFfiError>? = identifier.withCString { identifierPointer in
            if let version {
                return version.withCString { versionPointer in
                    cryptexd_uninstall(client, identifierPointer, versionPointer)
                }
            }
            return cryptexd_uninstall(client, identifierPointer, nil)
        }
        if let error {
            throw ffiError("Uninstalling the DDI cryptex", error)
        }
        return true
    }

    /// Opens the image-mounter service first and enters the gate immediately
    /// before the unmount FFI. UnmountImage does not consume the client, so the
    /// client is released exactly once on every path.
    static func unmountDeveloperImage(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        path: String,
        gate: BridgeDDIMutationGate
    ) throws -> Bool {
        var client: OpaquePointer?
        try check("Connecting to the image mounter for removal") {
            image_mounter_connect_rsd(adapter, handshake, &client)
        }
        guard let client else {
            throw BridgeDDIMountError.ffi("Connecting to the image mounter for removal", "no client")
        }
        // UnmountImage does not consume the client.
        defer { image_mounter_free(client) }

        switch gate.beginMutation() {
        case .cancelledBeforeEntry:
            return false
        case .alreadyEntered:
            throw BridgeDDIMountError.ffi(
                "Unmounting the developer image",
                "the mutation gate was already entered"
            )
        case .entered:
            break
        }
        try check("Unmounting the developer image at \(path)") {
            path.withCString { pathPointer in
                image_mounter_unmount_image(client, pathPointer)
            }
        }
        return true
    }

    @discardableResult
    static func check(
        _ operation: String,
        _ body: () -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> Bool {
        guard let error = body() else { return true }
        throw ffiError(operation, error)
    }

    private static func ffiError(
        _ operation: String,
        _ error: UnsafeMutablePointer<IdeviceFfiError>
    ) -> BridgeDDIMountError {
        let code = error.pointee.code
        let message = error.pointee.message.map { String(cString: $0) } ?? "code \(code)"
        idevice_error_free(error)
        BridgeLog.shared.append("ddi_ffi_error operation=\"\(operation)\" code=\(code)")
        var detail = "\(message) (code \(code))"
        if message.contains("device socket io failed") || message.contains("connect:") {
            detail += ". The reflector is not reaching the device debug service; confirm the tunnel is connected and the peer route is present."
        }
        return BridgeDDIMountError.ffi(operation, detail)
    }
}

/// Blocking removal worker. The caller supplies the staged pairing file and
/// keeps it alive until this function returns; `BridgeDDIManager` runs it on a
/// dedicated 4 MiB thread, never on a Swift concurrency executor. The shared
/// mutation gate is checked after the read-only pre-query and immediately
/// before the single uninstall/unmount call; a mutation already inside the FFI
/// cannot be aborted, so the report retains that fact and post-state evidence.
enum BridgeDDIRemover {
    static func remove(
        pairingPath: URL,
        installMethod: BridgeDDIInstallMethod,
        generation: UInt64,
        gate: BridgeDDIMutationGate
    ) -> BridgeDDIRemovalReport {
        let started = Date()
        var report = BridgeDDIRemovalReport(
            generation: generation,
            installMethod: installMethod,
            mutationAttempted: false
        )
        BridgeLog.shared.append(
            "ddi_remove_begin method=\(installMethod.rawValue) generation=\(generation)"
        )

        if gate.isCancelled {
            report.notes.append("cancelledBeforeSession=true")
            finish(&report, gate: gate, started: started)
            return report
        }

        do {
            let session = try openSession(pairingPath: pairingPath)
            defer { close(session) }

            if gate.isCancelled {
                report.notes.append("cancelledAfterSession=true")
                finish(&report, gate: gate, started: started)
                return report
            }

            // Fresh service connections for the pre-state. These calls do not
            // write anything; a failed query is evidence, not absence.
            let preCryptex = BridgeDDIFFI.queryCryptex(
                adapter: session.adapter,
                handshake: session.handshake,
                installMethod: installMethod
            )
            let preImage = BridgeDDIFFI.queryImages(
                adapter: session.adapter,
                handshake: session.handshake
            )
            let preProbe = BridgeDDIProbe.status()
            report.preCryptex = preCryptex.summary
            report.preImageState = preImage.summary
            report.preImages = imageSummary(preImage)
            report.preProbeMounted = preProbe.mounted
            BridgeLog.shared.append(
                "ddi_remove_pre cryptex=\(preCryptex.summary) " +
                "image=\(preImage.summary) localMounted=\(preProbe.mounted)"
            )

            let plan = BridgeDDIRemovalPolicy.removalPlan(
                cryptex: preCryptex,
                image: preImage,
                probeMounted: preProbe.mounted,
                installMethod: installMethod
            )
            report.action = actionDescription(plan)

            // The read-only pre-query can be long. A Stop between the query and
            // the mutation must leave no device call behind.
            if gate.isCancelled {
                report.notes.append("cancelledAfterPreQuery=true")
                BridgeLog.shared.append("ddi_remove_cancelled stage=after-pre-query")
                finish(&report, gate: gate, started: started)
                return report
            }

            switch plan {
            case .failClosed(let reason):
                report.outcome = .preStateUnknown
                report.errorCode = "pre-state-unknown"
                report.errorMessage = reason
                report.remoteAbsent = false
                report.localProbeAbsent = !preProbe.mounted
                report.notes.append("postQuerySkipped=pre-state-unknown")
                BridgeLog.shared.append("ddi_remove_fail_closed reason=\"\(reason)\"")
                finish(&report, gate: gate, started: started)
                return report

            case .alreadyAbsent:
                report.outcome = .alreadyAbsent
                report.remoteAbsent = true
                report.localProbeAbsent = !preProbe.mounted
                report.postCryptex = preCryptex.summary
                report.postImageState = preImage.summary
                report.postImages = report.preImages
                report.postProbeMounted = preProbe.mounted
                report.postXCTestReadable = preProbe.xctestReadable
                report.notes.append("postStateFromPreQuery=true")
                BridgeLog.shared.append("ddi_remove_already_absent")
                finish(&report, gate: gate, started: started)
                return report

            case .uninstallCryptex, .unmountDeveloperImage:
                // The FFI wrapper opens its service connection first and
                // enters the gate immediately before the actual uninstall or
                // unmount call. A Stop during connection setup still prevents
                // the mutation and returns false.
                var mutationAttempted = false
                do {
                    switch plan {
                    case .uninstallCryptex(let identifier, let version):
                        if case .installed(let entry) = preCryptex {
                            report.cryptexIdentifier = entry.identifier
                            report.cryptexVersion = entry.version
                        }
                        mutationAttempted = try BridgeDDIFFI.uninstallCryptex(
                            adapter: session.adapter,
                            handshake: session.handshake,
                            identifier: identifier,
                            version: version,
                            gate: gate
                        )
                    case .unmountDeveloperImage(let path, _):
                        mutationAttempted = try BridgeDDIFFI.unmountDeveloperImage(
                            adapter: session.adapter,
                            handshake: session.handshake,
                            path: path,
                            gate: gate
                        )
                    case .alreadyAbsent, .failClosed:
                        // Both were handled above before any mutation.
                        break
                    }
                } catch {
                    // Preserve the actual post-state even when the mutation
                    // call failed. The outcome stays failed; it never becomes
                    // a removal claim.
                    report.mutationAttempted = gate.didEnterMutation
                    let described = describe(error)
                    report.notes.append("mutationFailureCode=\(described.code)")
                    report.outcome = .failed
                    report.errorCode = described.code
                    report.errorMessage = described.message
                    applyPostState(
                        &report,
                        adapter: session.adapter,
                        handshake: session.handshake,
                        installMethod: installMethod
                    )
                    report.notes.append("postStateAfterFailedMutation=true")
                    BridgeLog.shared.append(
                        "ddi_remove_failed code=\(described.code) detail=\"\(described.message)\""
                    )
                    finish(&report, gate: gate, started: started)
                    return report
                }
                report.mutationAttempted = mutationAttempted
                if !mutationAttempted {
                    report.notes.append("mutationNotAttempted=cancelled")
                    if !gate.isCancelled {
                        report.outcome = .failed
                        report.errorCode = "mutation-not-entered"
                        report.errorMessage = "The removal mutation did not enter."
                    }
                    BridgeLog.shared.append("ddi_remove_cancelled stage=before-mutation")
                    finish(&report, gate: gate, started: started)
                    return report
                }
            }

            // Re-query on fresh connections. A successful call is not proof;
            // both service views plus local readability must agree.
            applyPostState(
                &report,
                adapter: session.adapter,
                handshake: session.handshake,
                installMethod: installMethod
            )
            if report.remoteAbsent == true && report.localProbeAbsent == true {
                report.outcome = .removed
            } else {
                report.outcome = .verificationFailed
                report.errorCode = "verification-failed"
                report.errorMessage = "Removal returned but DDI absence was not fully verified."
            }
            finish(&report, gate: gate, started: started)
            return report
        } catch {
            let described = describe(error)
            report.outcome = .failed
            report.errorCode = described.code
            report.errorMessage = described.message
            report.remoteAbsent = false
            BridgeLog.shared.append(
                "ddi_remove_failed code=\(described.code) detail=\"\(described.message)\""
            )
            finish(&report, gate: gate, started: started)
            return report
        }
    }

    // MARK: - Session

    private struct Session {
        var adapter: OpaquePointer
        var handshake: OpaquePointer
    }

    private static func openSession(pairingPath: URL) throws -> Session {
        var pairing: OpaquePointer?
        try BridgeDDIFFI.check("Reading the RemotePairing record") {
            rp_pairing_file_read(pairingPath.path, &pairing)
        }
        defer { if let pairing { rp_pairing_file_free(pairing) } }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = BridgeTransport.remotePairingPort.bigEndian
        guard BridgeTransport.peerAddress.withCString({
            inet_pton(AF_INET, $0, &address.sin_addr)
        }) == 1 else {
            throw BridgeDDIMountError.transport("The peer address is not valid IPv4.")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        _ = try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { socketAddress in
                try BridgeDDIFFI.check("Connecting to the device debug service") {
                    tunnel_create_rppairing(
                        socketAddress,
                        idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                        "FloeBridgeRemove",
                        pairing,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }
        guard let adapter, let handshake else {
            throw BridgeDDIMountError.transport("The tunnel returned no RSD handles.")
        }
        return Session(adapter: adapter, handshake: handshake)
    }

    private static func close(_ session: Session) {
        rsd_handshake_free(session.handshake)
        adapter_free(session.adapter)
    }

    // MARK: - Verification details

    private static func applyPostState(
        _ report: inout BridgeDDIRemovalReport,
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        installMethod: BridgeDDIInstallMethod
    ) {
        let postCryptex = BridgeDDIFFI.queryCryptex(
            adapter: adapter,
            handshake: handshake,
            installMethod: installMethod
        )
        let postImage = BridgeDDIFFI.queryImages(adapter: adapter, handshake: handshake)
        let postProbe = probeAfterRemoval()
        report.postCryptex = postCryptex.summary
        report.postImageState = postImage.summary
        report.postImages = imageSummary(postImage)
        report.postProbeMounted = postProbe.status.mounted
        report.postXCTestReadable = postProbe.status.xctestReadable
        report.remoteAbsent = BridgeDDIRemovalPolicy.cryptexAbsenceIsTrustworthy(
            postCryptex,
            installMethod: installMethod
        ) && postImage.isDefinitive && !postImage.hasDeveloperDiskImage
        report.localProbeAbsent = !postProbe.status.mounted
        report.notes.append("localProbeSamples=\(postProbe.samples)")
        BridgeLog.shared.append(
            "ddi_remove_post cryptex=\(postCryptex.summary) image=\(postImage.summary) " +
            "localMounted=\(postProbe.status.mounted) remoteAbsent=\(report.remoteAbsent == true) " +
            "localAbsent=\(report.localProbeAbsent == true)"
        )
    }

    private static func probeAfterRemoval() -> (status: BridgeDDIProbe.Status, samples: Int) {
        var status = BridgeDDIProbe.status()
        var samples = 1
        while status.mounted && samples < 6 {
            Thread.sleep(forTimeInterval: 0.5)
            status = BridgeDDIProbe.status()
            samples += 1
        }
        return (status, samples)
    }

    private static func imageSummary(_ query: BridgeDDIImageQuery) -> [String] {
        guard let devices = query.deviceList else { return [] }
        return devices.prefix(16).map { "\($0.diskImageType):\($0.isMounted)" }
    }

    private static func actionDescription(_ plan: BridgeDDIRemovalPlan) -> String {
        switch plan {
        case .uninstallCryptex(let identifier, let version):
            return "uninstall-cryptex:\(identifier):\(version ?? "all-versions")"
        case .unmountDeveloperImage(let path, let type):
            return "unmount-developer-image:\(path):\(type)"
        case .alreadyAbsent:
            return "already-absent"
        case .failClosed:
            return "fail-closed"
        }
    }

    private static func describe(_ error: Error) -> (code: String, message: String) {
        let bounded = { (value: String) in String(value.prefix(512)) }
        guard let error = error as? BridgeDDIMountError else {
            return ("unexpected", bounded(error.localizedDescription))
        }
        switch error {
        case .busy:
            return ("busy", bounded(error.localizedDescription))
        case .transport:
            return ("transport", bounded(error.localizedDescription))
        case .ffi:
            return ("ffi", bounded(error.localizedDescription))
        case .verificationFailed:
            return ("verification", bounded(error.localizedDescription))
        case .preStateUnknown:
            return ("pre-state-unknown", bounded(error.localizedDescription))
        }
    }

    private static func finish(
        _ report: inout BridgeDDIRemovalReport,
        gate: BridgeDDIMutationGate,
        started: Date
    ) {
        report.finishedAt = BridgeClock.timestamp()
        report.durationSeconds = Date().timeIntervalSince(started)
        _ = BridgeDDIRemovalCancellation.apply(to: &report, gate: gate)
    }
}
