// FloeIOSAutomation — guarded action execution.
//
// Order of checks: platform, native allowlist/effect, operation id, task
// generation, execution window, injected credential, persistent task input
// ownership plus a separate in-flight lease, live foreground verification,
// protected-target policy, existing task authority, then one sealed RPC.
// There is no automatic retry.

import Foundation

extension IOSBridgeClient {
    public func perform(
        _ action: IOSAutomationAction,
        params: IOSBridgeJSONValue = .object([:]),
        target: IOSAutomationTarget? = nil,
        context: IOSAutomationCallContext,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let startedAt = configuration.clock.now()
        guard configuration.platformAllowsLocalAutomation else {
            return notSent(
                action: action,
                operationID: context.operationID ?? IOSBridgeOperationID.make(),
                startedAt: startedAt,
                error: .unsupportedPlatform
            )
        }
        guard action.isModelExposed else {
            return notSent(
                action: action,
                operationID: context.operationID ?? IOSBridgeOperationID.make(),
                startedAt: startedAt,
                error: .actionNotAllowed("The \(action.rawValue) method is internal to the connection service.")
            )
        }
        guard params.objectValue != nil else {
            return notSent(
                action: action,
                operationID: context.operationID ?? IOSBridgeOperationID.make(),
                startedAt: startedAt,
                error: .invalidArguments("Bridge params must be a JSON object.")
            )
        }
        let operationID: String
        if let requested = context.operationID {
            guard IOSBridgeOperationID.isCanonical(requested) else {
                return notSent(
                    action: action,
                    operationID: requested,
                    startedAt: startedAt,
                    error: .invalidArguments("The operation identifier is not canonical.")
                )
            }
            operationID = requested
        } else if let durable = context.toolIdempotencyKey,
                  IOSBridgeOperationID.isCanonical(durable) {
            operationID = durable
        } else {
            operationID = IOSBridgeOperationID.make()
        }
        let effect = action.effect
        let startingEpoch = lifecycleEpoch
        expireDeviceInputOwnerIfNeeded(at: startedAt)
        if effect == .mutating, pairingPhase != nil {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .deviceBusy
            )
        }

        if context.cancellation.isCancelled {
            return cancelled(action: action, operationID: operationID, startedAt: startedAt)
        }
        if let latest = taskGenerations[context.taskID] {
            if context.taskGeneration < latest {
                return notSent(
                    action: action,
                    operationID: operationID,
                    startedAt: startedAt,
                    error: .staleTaskGeneration
                )
            }
        } else {
            taskGenerations[context.taskID] = context.taskGeneration
        }
        if context.executionWindow.isExpired(at: startedAt) {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .executionWindowExpired
            )
        }

        let credentialRevision = await credentialWriter.currentRevision()
        let record: IOSBridgePairingRecord
        do {
            record = try await loadRecord()
        } catch let error as IOSBridgeError {
            return notSent(action: action, operationID: operationID, startedAt: startedAt, error: error)
        } catch {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .credentialStoreUnavailable
            )
        }

        let declaredTarget = resolvedTarget(target, params: params)
        var foregroundBundleID: String?
        var leaseToken: UUID?
        var ownershipCreated = false
        var didDispatch = false
        defer {
            if let leaseToken {
                releaseInFlightLease(leaseToken)
            }
            // A first call that was denied before any device dispatch did not
            // start a control sequence. Keep ownership once dispatched (or
            // once an earlier call already owned it); otherwise a following
            // task must not be blocked by a call that never reached the device.
            if ownershipCreated && !didDispatch {
                releaseDeviceInputOwnershipIfOwnedBy(context)
            }
        }

        if effect == .mutating {
            do {
                ownershipCreated = try acquireDeviceInputOwnership(context: context)
                leaseToken = try acquireInFlightLease(action: action, context: context)
            } catch let error as IOSBridgeError {
                return notSent(action: action, operationID: operationID, startedAt: startedAt, error: error)
            } catch {
                return notSent(
                    action: action,
                    operationID: operationID,
                    startedAt: startedAt,
                    error: .inputBusy
                )
            }
        }

        // App switch and URL actions carry their target explicitly.
        if action.carriesExplicitControlTarget {
            switch action {
            case .openURL:
                guard let url = declaredTarget.url else {
                    return notSent(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        error: .invalidArguments("open_url requires a URL.")
                    )
                }
                if configuration.policy.urlDenialReason(url) != nil {
                    return notSent(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        error: .protectedTarget
                    )
                }
            case .launchApp, .activateApp, .terminateApp:
                guard let bundle = declaredTarget.bundleIdentifier, !bundle.isEmpty else {
                    return notSent(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        error: .invalidArguments("\(action.rawValue) requires a bundle identifier.")
                    )
                }
                if configuration.policy.mutationDenialReason(bundleIdentifier: bundle) != nil {
                    return notSent(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        error: .protectedTarget
                    )
                }
            default:
                break
            }
        }

        // A declared bundle on any mutating action is checked before dispatch,
        // even when the live foreground check also runs.
        if effect == .mutating,
           let bundle = declaredTarget.bundleIdentifier,
           configuration.policy.mutationDenialReason(bundleIdentifier: bundle) != nil {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .protectedTarget
            )
        }
        if effect == .readOnly,
           let bundle = declaredTarget.bundleIdentifier,
           configuration.policy.readDenialReason(bundleIdentifier: bundle) != nil {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .protectedTarget
            )
        }

        if action.requiresForegroundVerification,
           configuration.policy.requiresForegroundVerification {
            do {
                let liveBundle = try await preflightForeground(
                    record: record,
                    context: context
                )
                foregroundBundleID = liveBundle
                if let declared = declaredTarget.bundleIdentifier,
                   declared.caseInsensitiveCompare(liveBundle) != .orderedSame {
                    return notSent(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        error: .targetNotForeground
                    )
                }
                if configuration.policy.mutationDenialReason(bundleIdentifier: liveBundle) != nil {
                    return notSent(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        error: .protectedTarget
                    )
                }
            } catch let error as IOSBridgeError {
                return notSent(
                    action: action,
                    operationID: operationID,
                    startedAt: startedAt,
                    error: error
                )
            } catch {
                return notSent(
                    action: action,
                    operationID: operationID,
                    startedAt: startedAt,
                    error: .protectedTargetUnknown
                )
            }
        }

        let authorizationRequest = IOSAutomationAuthorizationRequest(
            action: action,
            effect: effect,
            declaredTarget: declaredTarget,
            foregroundBundleIdentifier: foregroundBundleID,
            context: context
        )
        let authority = context.authorityOverride ?? configuration.authority
        let decision = await authority.authorize(authorizationRequest)
        if case .denied(let reason) = decision {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .authorityDenied(reason: reason)
            )
        }

        if context.cancellation.isCancelled {
            return cancelled(action: action, operationID: operationID, startedAt: startedAt)
        }
        if lifecycleEpoch != startingEpoch {
            return receipt(
                action: action,
                effect: effect,
                operationID: operationID,
                outcome: .fenced,
                result: nil,
                startedAt: startedAt,
                usedInputLease: leaseToken != nil
            )
        }
        if let latest = taskGenerations[context.taskID], context.taskGeneration < latest {
            return receipt(
                action: action,
                effect: effect,
                operationID: operationID,
                outcome: .fenced,
                result: nil,
                startedAt: startedAt,
                usedInputLease: leaseToken != nil
            )
        }
        if context.executionWindow.isExpired(at: configuration.clock.now()) {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .executionWindowExpired
            )
        }
        if effect == .mutating, pairingPhase != nil {
            return notSent(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .deviceBusy
            )
        }

        didDispatch = true
        do {
            let result = try await sendRPC(
                record: record,
                method: action.wireMethod,
                params: params,
                timeout: max(1, timeout ?? configuration.rpcTimeout),
                cancellation: context.cancellation,
                operationID: operationID,
                requestID: operationID
            )
            if context.cancellation.isCancelled {
                if effect == .mutating {
                    return outcomeUnknown(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        reason: .cancelledAfterDispatch
                    )
                }
                return cancelled(action: action, operationID: operationID, startedAt: startedAt)
            }
            if lifecycleEpoch != startingEpoch {
                if effect == .mutating {
                    return outcomeUnknown(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        reason: .lifecycleFencedAfterDispatch
                    )
                }
                return receipt(
                    action: action,
                    effect: effect,
                    operationID: operationID,
                    outcome: .fenced,
                    result: nil,
                    startedAt: startedAt,
                    usedInputLease: leaseToken != nil
                )
            }
            if let latest = taskGenerations[context.taskID],
               context.taskGeneration < latest {
                if effect == .mutating {
                    return outcomeUnknown(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        reason: .taskGenerationChangedAfterDispatch
                    )
                }
                return receipt(
                    action: action,
                    effect: effect,
                    operationID: operationID,
                    outcome: .fenced,
                    result: nil,
                    startedAt: startedAt,
                    usedInputLease: leaseToken != nil
                )
            }
            if context.executionWindow.isExpired(at: configuration.clock.now()) {
                if effect == .mutating {
                    return outcomeUnknown(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        reason: .applicationBackgrounded
                    )
                }
                return receipt(
                    action: action,
                    effect: effect,
                    operationID: operationID,
                    outcome: .fenced,
                    result: nil,
                    startedAt: startedAt,
                    usedInputLease: leaseToken != nil
                )
            }
            await touchCredentialIfNeeded(record, expectedRevision: credentialRevision)
            return receipt(
                action: action,
                effect: effect,
                operationID: operationID,
                outcome: .succeeded,
                result: result,
                startedAt: startedAt,
                usedInputLease: leaseToken != nil
            )
        } catch let error as IOSBridgeError {
            if effect == .mutating {
                if error.isDefiniteNonExecution {
                    return notSent(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        error: error
                    )
                }
                if error == .cancelled {
                    return outcomeUnknown(
                        action: action,
                        operationID: operationID,
                        startedAt: startedAt,
                        reason: .cancelledAfterDispatch
                    )
                }
                return outcomeUnknown(
                    action: action,
                    operationID: operationID,
                    startedAt: startedAt,
                    reason: unknownReason(for: error)
                )
            }
            if error.isDefiniteNonExecution {
                return notSent(
                    action: action,
                    operationID: operationID,
                    startedAt: startedAt,
                    error: error
                )
            }
            if error == .cancelled {
                return cancelled(action: action, operationID: operationID, startedAt: startedAt)
            }
            if error == .serviceFenced {
                return receipt(
                    action: action,
                    effect: effect,
                    operationID: operationID,
                    outcome: .fenced,
                    result: nil,
                    startedAt: startedAt,
                    usedInputLease: leaseToken != nil
                )
            }
            return failed(action: action, operationID: operationID, startedAt: startedAt, error: error)
        } catch {
            if effect == .mutating {
                return outcomeUnknown(
                    action: action,
                    operationID: operationID,
                    startedAt: startedAt,
                    reason: .requestMayHaveBeenSent
                )
            }
            return failed(
                action: action,
                operationID: operationID,
                startedAt: startedAt,
                error: .unexpected("The Bridge action failed unexpectedly.")
            )
        }
    }

    public func readBridgeConfiguration() async -> IOSAutomationReceipt {
        let startedAt = configuration.clock.now()
        let operationID = "status-\(UUID().uuidString.lowercased())"
        guard configuration.platformAllowsLocalAutomation else {
            return notSent(
                action: .config,
                operationID: operationID,
                startedAt: startedAt,
                error: .unsupportedPlatform
            )
        }
        do {
            let record = try await loadRecord()
            let value = try await sendRPC(
                record: record,
                method: IOSAutomationAction.config.wireMethod,
                params: .object([:]),
                timeout: configuration.rpcTimeout,
                cancellation: nil,
                operationID: nil,
                requestID: operationID
            )
            return receipt(
                action: .config,
                effect: .readOnly,
                operationID: operationID,
                outcome: .succeeded,
                result: value,
                startedAt: startedAt,
                usedInputLease: false
            )
        } catch let error as IOSBridgeError {
            return notSent(
                action: .config,
                operationID: operationID,
                startedAt: startedAt,
                error: error
            )
        } catch {
            return notSent(
                action: .config,
                operationID: operationID,
                startedAt: startedAt,
                error: .unexpected("The Bridge configuration read failed.")
            )
        }
    }

    // MARK: - Helpers

    private func resolvedTarget(
        _ explicit: IOSAutomationTarget?,
        params: IOSBridgeJSONValue
    ) -> IOSAutomationTarget {
        var target = explicit ?? IOSAutomationTarget()
        let object = params.objectValue ?? [:]
        if target.bundleIdentifier == nil,
           let bundle = object["bundle_id"]?.stringValue,
           !bundle.isEmpty {
            target.bundleIdentifier = bundle
        }
        if target.url == nil,
           let text = object["url"]?.stringValue,
           let url = URL(string: text) {
            target.url = url
        }
        return target
    }

    private func preflightForeground(
        record: IOSBridgePairingRecord,
        context: IOSAutomationCallContext
    ) async throws -> String {
        let requestID = "preflight-\(UUID().uuidString.lowercased())"
        let value = try await sendRPC(
            record: record,
            method: IOSAutomationAction.pageSource.wireMethod,
            params: .object([
                "max_depth": .int(1),
                "max_elements": .int(1),
                "max_children": .int(1),
            ]),
            timeout: min(configuration.rpcTimeout, 15),
            cancellation: context.cancellation,
            operationID: nil,
            requestID: requestID
        )
        guard let object = value.objectValue,
              let bundle = object["bundle_id"]?.stringValue,
              !bundle.isEmpty else {
            throw IOSBridgeError.protectedTargetUnknown
        }
        return bundle
    }

    /// Establishes or verifies persistent task-level input ownership. Returns
    /// true only when this call created the ownership, so a pre-dispatch
    /// denial can release it without clearing an already-established sequence.
    @discardableResult
    private func acquireDeviceInputOwnership(
        context: IOSAutomationCallContext
    ) throws -> Bool {
        let now = configuration.clock.now()
        expireDeviceInputOwnerIfNeeded(at: now)
        if var owner = deviceInputOwner {
            guard owner.taskID == context.taskID,
                  owner.taskGeneration == context.taskGeneration else {
                throw IOSBridgeError.inputBusy
            }
            if let deadline = context.executionWindow.deadline {
                owner.expiresAt = max(owner.expiresAt ?? deadline, deadline)
                deviceInputOwner = owner
            }
            return false
        }
        deviceInputOwner = DeviceInputOwnerState(
            taskID: context.taskID,
            taskGeneration: context.taskGeneration,
            acquiredAt: now,
            expiresAt: context.executionWindow.deadline
        )
        return true
    }

    private func releaseDeviceInputOwnershipIfOwnedBy(
        _ context: IOSAutomationCallContext
    ) {
        guard let owner = deviceInputOwner,
              owner.taskID == context.taskID,
              owner.taskGeneration == context.taskGeneration else {
            return
        }
        deviceInputOwner = nil
    }

    /// Serializes mutations that are actually in flight. Persistent ownership
    /// above is deliberately not cleared when this per-call lease ends.
    private func acquireInFlightLease(
        action: IOSAutomationAction,
        context: IOSAutomationCallContext
    ) throws -> UUID {
        if activeLease != nil {
            throw IOSBridgeError.inputBusy
        }
        let lease = InputLease(
            token: UUID(),
            taskID: context.taskID,
            taskGeneration: context.taskGeneration,
            action: action,
            cancellation: context.cancellation
        )
        activeLease = lease
        return lease.token
    }

    private func releaseInFlightLease(_ token: UUID) {
        guard activeLease?.token == token else { return }
        activeLease = nil
    }

    private func unknownReason(for error: IOSBridgeError) -> IOSAutomationUnknownReason {
        switch error {
        case .executionTimedOut:
            return .serverReportedTimeout
        case .operationOutcomeUnknown, .operationAlreadyCompleted:
            return .serverReportedUnknown
        case .serviceFenced:
            return .serverReportedFenced
        case .timedOut, .connectionLost:
            return .requestMayHaveBeenSent
        case .cancelled:
            return .cancelledAfterDispatch
        default:
            return .responseUnreadable
        }
    }

    private func receipt(
        action: IOSAutomationAction,
        effect: IOSAutomationEffect,
        operationID: String,
        outcome: IOSAutomationReceiptOutcome,
        result: IOSBridgeJSONValue?,
        startedAt: Date,
        usedInputLease: Bool
    ) -> IOSAutomationReceipt {
        IOSAutomationReceipt(
            action: action,
            effect: effect,
            operationID: operationID,
            outcome: outcome,
            result: result,
            startedAt: startedAt,
            completedAt: configuration.clock.now(),
            usedInputLease: usedInputLease
        )
    }

    private func notSent(
        action: IOSAutomationAction,
        operationID: String,
        startedAt: Date,
        error: IOSBridgeError
    ) -> IOSAutomationReceipt {
        receipt(
            action: action,
            effect: action.effect,
            operationID: operationID,
            outcome: .notSent(error),
            result: nil,
            startedAt: startedAt,
            usedInputLease: activeLease != nil
        )
    }

    private func failed(
        action: IOSAutomationAction,
        operationID: String,
        startedAt: Date,
        error: IOSBridgeError
    ) -> IOSAutomationReceipt {
        receipt(
            action: action,
            effect: action.effect,
            operationID: operationID,
            outcome: .failed(error),
            result: nil,
            startedAt: startedAt,
            usedInputLease: activeLease != nil
        )
    }

    private func cancelled(
        action: IOSAutomationAction,
        operationID: String,
        startedAt: Date
    ) -> IOSAutomationReceipt {
        receipt(
            action: action,
            effect: action.effect,
            operationID: operationID,
            outcome: .cancelled,
            result: nil,
            startedAt: startedAt,
            usedInputLease: activeLease != nil
        )
    }

    private func outcomeUnknown(
        action: IOSAutomationAction,
        operationID: String,
        startedAt: Date,
        reason: IOSAutomationUnknownReason
    ) -> IOSAutomationReceipt {
        let unknown = IOSAutomationUnknownOutcome(
            operationID: operationID,
            reason: reason,
            message: Self.unknownMessage(reason),
            recovery: .observeScreenFirst
        )
        return receipt(
            action: action,
            effect: action.effect,
            operationID: operationID,
            outcome: .outcomeUnknown(unknown),
            result: nil,
            startedAt: startedAt,
            usedInputLease: activeLease != nil
        )
    }

    private static func unknownMessage(_ reason: IOSAutomationUnknownReason) -> String {
        switch reason {
        case .requestMayHaveBeenSent:
            return "Bridge did not return a completion receipt; the action may already have taken effect."
        case .responseUnreadable:
            return "Bridge's completion receipt could not be verified; the action may already have taken effect."
        case .cancelledAfterDispatch:
            return "The task was cancelled after dispatch; the action may already have taken effect."
        case .lifecycleFencedAfterDispatch:
            return "The app lifecycle changed after dispatch; the action may already have taken effect."
        case .taskGenerationChangedAfterDispatch:
            return "The task generation changed after dispatch; the action may already have taken effect."
        case .serverReportedUnknown:
            return "Bridge reports that the action may already have taken effect."
        case .serverReportedTimeout:
            return "Bridge did not finish in time; the action may already have taken effect."
        case .serverReportedFenced:
            return "Bridge fenced the action; it may already have taken effect."
        case .applicationBackgrounded:
            return "The execution window ended after dispatch; the action may already have taken effect."
        }
    }
}
