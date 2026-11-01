// FloeApp — model-facing tools for the optional local iOS Bridge automation.
//
// The module owns the action/effect allowlist, protected-surface policy,
// persistent device-input ownership and unknown-outcome rules. This file only
// maps the canonical ToolContext into an IOSAutomationCallContext, consumes
// the runtime authority the canonical approval path already issued and
// projects bounded, secret-free results. It never creates a second approval
// store, never trusts model-provided effect tags and never retries a mutation.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeSecurity
import FloeSkills
import FloeSync
import FloeTools
import FloeIOSAutomation

enum IOSBridgeToolNames {
    static let status = IOSAutomationToolSurface.status.rawValue
    static let pair = IOSAutomationToolSurface.pair.rawValue
    static let observe = IOSAutomationToolSurface.observe.rawValue
    static let control = IOSAutomationToolSurface.control.rawValue
    static let all: Set<String> = [status, pair, observe, control]
}

// MARK: - Arguments

/// Dynamic observe/control arguments: `action` plus exactly the compiled
/// parameter names for that action. The canonical JSON is retained so the
/// runtime authority digest is reconstructed from the approved payload.
struct IOSBridgeToolArguments: Decodable, Sendable {
    let action: IOSAutomationAction
    let params: [String: IOSBridgeJSONValue]
    let canonicalJSON: Data

    init(from decoder: Decoder) throws {
        let value = try IOSBridgeJSONValue(from: decoder)
        guard let object = value.objectValue,
              let rawAction = object["action"]?.stringValue,
              let action = IOSAutomationAction(rawValue: rawAction) else {
            throw FloeError.validationFailed(
                "Local device actions require a valid 'action' argument."
            )
        }
        self.action = action
        self.params = Dictionary(uniqueKeysWithValues: object.filter { $0.key != "action" })
        self.canonicalJSON = value.canonicalData()
    }

    func validate(surface: IOSAutomationToolSurface) throws {
        let actions: [IOSAutomationAction]
        switch surface {
        case .observe: actions = IOSAutomationCatalog.observeActions
        case .control: actions = IOSAutomationCatalog.controlActions
        case .status, .pair:
            throw FloeError.validationFailed("This surface does not accept device actions.")
        }
        guard actions.contains(action) else {
            throw FloeError.validationFailed(
                "'\(action.rawValue)' is not available through \(surface.rawValue)."
            )
        }
        let contract = Dictionary(
            uniqueKeysWithValues: action.parameters.map { ($0.name, $0.kind) }
        )
        for (key, value) in params {
            guard let kind = contract[key] else {
                throw FloeError.validationFailed(
                    "Unsupported parameter '\(key)' for \(action.rawValue)."
                )
            }
            guard !value.isNull else { continue }
            switch kind {
            case .string:
                guard let text = value.stringValue, text.utf8.count <= 32_768 else {
                    throw FloeError.validationFailed("Parameter '\(key)' must be a bounded string.")
                }
            case .number:
                guard value.doubleValue != nil else {
                    throw FloeError.validationFailed("Parameter '\(key)' must be a number.")
                }
            case .integer:
                guard value.intValue != nil else {
                    throw FloeError.validationFailed("Parameter '\(key)' must be an integer.")
                }
            case .boolean:
                guard value.boolValue != nil else {
                    throw FloeError.validationFailed("Parameter '\(key)' must be a boolean.")
                }
            case .object:
                guard value.objectValue != nil else {
                    throw FloeError.validationFailed("Parameter '\(key)' must be an object.")
                }
            case .array:
                guard value.arrayValue != nil else {
                    throw FloeError.validationFailed("Parameter '\(key)' must be an array.")
                }
            }
        }
        for parameter in action.parameters where parameter.required {
            guard let value = params[parameter.name], !value.isNull else {
                throw FloeError.validationFailed(
                    "\(action.rawValue) requires '\(parameter.name)'."
                )
            }
        }
        guard canonicalJSON.count <= toolArgumentsByteLimit(for: surface.rawValue) else {
            throw FloeError.validationFailed("Local device arguments are too large.")
        }
    }
}

// MARK: - Gates

enum IOSBridgeToolGate {
    static func requireStatus(
        _ integration: IOSBridgeIntegration,
        context: ToolContext
    ) async throws {
        try requirePlatform()
        try requireTaskCeiling(context, surface: .status)
        let activation = await integration.skillActivation()
        guard let activation else {
            await fenceIfSkillIdentityInvalid(integration, activation)
            throw FloeError.validationFailed(
                "The optional local automation Skill is not installed. Install it from Skills before using this tool."
            )
        }
        guard IOSBridgeIntegration.toolAvailability(for: activation).status else {
            await fenceIfSkillIdentityInvalid(integration, activation)
            throw FloeError.validationFailed(
                "The optional local automation Skill is disabled. Enable it in Skills before using this tool."
            )
        }
    }

    static func requirePair(
        _ integration: IOSBridgeIntegration,
        context: ToolContext
    ) async throws -> IOSBridgeClient {
        try requirePlatform()
        try requireTaskCeiling(context, surface: .pair)
        try requireMutable(context)
        let activation = await integration.skillActivation()
        guard let activation,
              IOSBridgeIntegration.toolAvailability(for: activation).pair else {
            await fenceIfSkillIdentityInvalid(integration, activation)
            throw FloeError.validationFailed(
                "Pairing is unavailable: install, enable and authorize the local automation Skill from a trusted source first."
            )
        }
        guard let client = await integration.client() else {
            throw FloeError.validationFailed("The local Bridge client is unavailable on this device.")
        }
        return client
    }

    static func requireDeviceSurface(
        _ integration: IOSBridgeIntegration,
        context: ToolContext,
        surface: IOSAutomationToolSurface
    ) async throws -> (client: IOSBridgeClient, snapshot: IOSBridgeConnectionSnapshot) {
        try requirePlatform()
        try requireTaskCeiling(context, surface: surface)
        if surface == .control {
            try requireMutable(context)
        }
        let activation = await integration.skillActivation()
        guard let activation else {
            await fenceIfSkillIdentityInvalid(integration, activation)
            throw FloeError.validationFailed(
                "The optional local automation Skill is not installed. Install and configure it from Skills first."
            )
        }
        let usability = IOSBridgeIntegration.toolAvailability(for: activation)
        guard usability.observeControl else {
            await fenceIfSkillIdentityInvalid(integration, activation)
            switch activation.readiness {
            case .locked:
                throw FloeError.validationFailed("Unlock this device and try again; the saved Bridge connection was not deleted.")
            case .invalid:
                throw FloeError.validationFailed("The saved Bridge connection failed validation. Pair or validate it again in Skills.")
            case .needsValidation, .configured, .needsSetup, .needsReconfirmation:
                throw FloeError.validationFailed("Configure and validate the local automation connection in Skills first.")
            case .sourceUnverified:
                throw FloeError.validationFailed("The installed local automation Skill source is not verified. Reinstall it from a trusted source.")
            case .notInstalled:
                throw FloeError.validationFailed("The optional local automation Skill is not installed.")
            case .ready:
                throw FloeError.validationFailed("The local automation Skill is not enabled or authorized.")
            }
        }
        guard let client = await integration.client() else {
            throw FloeError.validationFailed("The local Bridge client is unavailable on this device.")
        }
        // Native dispatch revalidates the real connection state; a cached
        // schema or a previous successful turn is not authority.
        let snapshot = await client.status()
        guard snapshot.status == .ready else {
            throw FloeError.validationFailed(Self.unavailableMessage(snapshot.status))
        }
        return (client, snapshot)
    }

    /// Stale-schema backstop for install/remove/disable/source changes. The
    /// canonical SkillsCenter boundary normally invalidates earlier; this
    /// also covers a remove path that returns before that boundary and any
    /// frozen tool schema from an earlier turn. It deliberately does NOT
    /// fence a merely `needsSetup`/`needsValidation` connection, where a
    /// pairing may legitimately be in progress.
    private static func fenceIfSkillIdentityInvalid(
        _ integration: IOSBridgeIntegration,
        _ activation: IOSBridgeSkillActivation?
    ) async {
        guard activation == nil
                || activation?.enabled == false
                || activation?.grantsAllowed == false
                || activation?.configurationAllowed == false
                || activation?.sourceChanged == true else {
            return
        }
        await integration.skillStateDidChange(skillID: IOSBridgeIntegration.skillID)
    }

    private static func unavailableMessage(_ status: IOSBridgeConnectionStatus) -> String {
        switch status {
        case .ready:
            return "The local Bridge is ready."
        case .lockedCredentials:
            return "Unlock this device and try again; the saved Bridge connection was not deleted."
        case .credentialsUnavailable:
            return "The saved Bridge connection is temporarily unavailable. It was not deleted."
        case .needsPairing, .pairingRecordInvalid:
            return "Pair this device with Bridge in Skills before using local device actions. No device action was sent."
        case .expired, .revoked:
            return "The Bridge pairing expired or was revoked. Pair again in Skills. No device action was sent."
        case .companionMissing, .companionPresenceUnknown, .serviceOff, .serviceUnavailable:
            return "Bridge is not reachable on this device. Open Bridge, then try again. No device action was sent."
        case .incompatibleBridge:
            return "This Bridge version is not supported. Update Bridge. No device action was sent."
        case .engineNotReady:
            return "Bridge is reachable but its automation engine is not ready. Open Bridge and check its setup. No device action was sent."
        case .pairingInProgress, .waitingForOwnerApproval:
            return "Finish the current Bridge pairing before using device actions. No device action was sent."
        case .unsupportedPlatform:
            return "Local device automation is unavailable on this platform."
        case .unknown:
            return "The local Bridge connection could not be verified. No device action was sent."
        }
    }

    private static func requirePlatform() throws {
        guard LocalBridgePlatform.current.supportsIOSAutomation else {
            throw FloeError.validationFailed(
                "Local device automation is available only in Floe on a supported iPhone or iPad."
            )
        }
    }

    private static func requireTaskCeiling(
        _ context: ToolContext,
        surface: IOSAutomationToolSurface
    ) throws {
        guard context.childExecution == nil else {
            throw FloeError.unauthorized
        }
        if let allowed = context.allowedToolNames, !allowed.contains(surface.rawValue) {
            throw FloeError.unauthorized
        }
        if let frozen = context.frozenEffectiveCatalogNames,
           !frozen.contains(surface.rawValue) {
            throw FloeError.unauthorized
        }
    }

    private static func requireMutable(_ context: ToolContext) throws {
        guard !context.temporaryReadOnly else {
            throw FloeError.validationFailed("This task is read-only; device control is unavailable.")
        }
        guard context.approvalGrantID != nil else {
            throw FloeError.unauthorized
        }
    }
}

// MARK: - Exact task authority

/// Reuses the canonical runtime authority for this exact call. It never
/// approves anything; it only verifies that the authority the runtime already
/// issued still binds this same in-flight operation.
struct IOSBridgeToolAuthority: IOSAutomationTaskAuthority {
    let toolContext: ToolContext
    let surface: IOSAutomationToolSurface
    let binding: RuntimeAuthorityBinding
    let authorityConsumed: Bool
    /// Re-reads the live installed/enabled/configured state inside the
    /// client authority callback, after the status preflight and before
    /// dispatch. A disable/remove/reset that raced tool start therefore
    /// fails closed at the latest native boundary.
    let liveCheck: @Sendable () async -> Bool

    func authorize(
        _ request: IOSAutomationAuthorizationRequest
    ) async -> IOSAutomationAuthorizationDecision {
        guard request.context.taskID == toolContext.runID,
              request.context.taskGeneration
                == UInt64(max(0, toolContext.executionBindingGeneration ?? 0)),
              request.action.toolSurface == surface,
              request.effect == request.action.effect,
              toolContext.childExecution == nil else {
            return .denied(reason: "The device action does not match this approved task call.")
        }
        if let allowed = toolContext.allowedToolNames,
           !allowed.contains(surface.rawValue) {
            return .denied(reason: "This task does not allow the requested device surface.")
        }
        if let frozen = toolContext.frozenEffectiveCatalogNames,
           !frozen.contains(surface.rawValue) {
            return .denied(reason: "The frozen task catalog does not include this device tool.")
        }
        guard await liveCheck() else {
            return .denied(reason: "The local automation Skill or its validated connection is no longer enabled.")
        }
        if request.effect == .mutating {
            guard !toolContext.temporaryReadOnly else {
                return .denied(reason: "Temporary chat is read-only.")
            }
            guard authorityConsumed, toolContext.runtimeAuthority != nil else {
                return .denied(reason: "This device mutation has no consumed task authority.")
            }
            guard await Self.stillBinds(toolContext: toolContext, binding: binding) else {
                return .denied(reason: "The task authority for this device action is no longer valid.")
            }
        }
        return .allowed
    }

    private static func stillBinds(
        toolContext: ToolContext,
        binding: RuntimeAuthorityBinding
    ) async -> Bool {
        guard let token = toolContext.runtimeAuthority else { return false }
        guard token.runID == binding.runID,
              token.taskID == binding.taskID,
              token.environmentBinding == binding.environmentBinding,
              token.canonicalTarget == binding.canonicalTarget,
              token.toolName == binding.toolName,
              token.operation == binding.operation,
              token.operationID == binding.operationID,
              token.idempotencyKey == binding.idempotencyKey,
              token.baseRevision == binding.baseRevision,
              token.payloadDigest == binding.payloadDigest else {
            return false
        }
        let validation = await RuntimeAuthorityStore.shared.validate(
            token,
            binding: binding
        )
        // The wrapper consumed exactly this binding. `alreadyConsumed` is the
        // expected state for the one same in-flight operation; revoked,
        // expired, unknown and mismatched tokens all fail closed.
        return validation == .valid || validation == .alreadyConsumed
    }
}

/// Builds the per-call context from the canonical ToolContext. IDs come from
/// the runtime (run, generation, client session, call/idempotency keys); none
/// are model arguments.
enum IOSBridgeToolContextFactory {
    struct Prepared {
        let client: IOSBridgeClient
        let call: IOSAutomationCallContext
        let watcher: Task<Void, Never>
    }

    static func make(
        integration: IOSBridgeIntegration,
        client: IOSBridgeClient,
        toolContext: ToolContext,
        surface: IOSAutomationToolSurface,
        canonicalJSON: Data
    ) async throws -> Prepared {
        let generation = UInt64(max(0, toolContext.executionBindingGeneration ?? 0))
        await client.registerTaskGeneration(generation, for: toolContext.runID)
        await integration.recordRunBinding(
            runID: toolContext.runID,
            generation: generation
        )
        let cancellation = IOSAutomationCancellationToken()
        let watcher = cancellation.bridge(from: { toolContext.cancellation.isCancelled })
        let window = await integration.currentExecutionWindow()
        guard !window.isExpired(at: Date()) else {
            watcher.cancel()
            throw FloeError.validationFailed(
                "Device automation is not available in the background right now. Return to Floe and try again."
            )
        }
        let binding = try Self.binding(
            toolContext: toolContext,
            surface: surface,
            canonicalJSON: canonicalJSON
        )
        let liveCheck: @Sendable () async -> Bool = { [weak integration] in
            guard let integration else { return false }
            return await integration.deviceSurfaceIsCurrentlyEnabled(surface)
        }
        let authority: IOSBridgeToolAuthority
        if surface == .control {
            let validation = await toolContext.consumeRuntimeAuthority(binding: binding)
            guard validation == .valid else {
                watcher.cancel()
                throw FloeError.unauthorized
            }
            authority = IOSBridgeToolAuthority(
                toolContext: toolContext,
                surface: surface,
                binding: binding,
                authorityConsumed: true,
                liveCheck: liveCheck
            )
        } else {
            authority = IOSBridgeToolAuthority(
                toolContext: toolContext,
                surface: surface,
                binding: binding,
                authorityConsumed: false,
                liveCheck: liveCheck
            )
        }
        let operationID = toolContext.toolCallID.flatMap {
            IOSBridgeOperationID.isCanonical($0) ? $0 : nil
        }
        let call = IOSAutomationCallContext(
            taskID: toolContext.runID,
            taskGeneration: generation,
            clientSessionID: toolContext.clientSessionID,
            toolCallID: toolContext.toolCallID,
            toolIdempotencyKey: toolContext.toolIdempotencyKey,
            operationID: operationID,
            cancellation: cancellation,
            executionWindow: window,
            authorityOverride: authority
        )
        return Prepared(client: client, call: call, watcher: watcher)
    }

    static func binding(
        toolContext: ToolContext,
        surface: IOSAutomationToolSurface,
        canonicalJSON: Data
    ) throws -> RuntimeAuthorityBinding {
        let call = try ToolCall(
            id: toolContext.toolCallID ?? "",
            toolName: surface.rawValue,
            argumentsJSON: canonicalJSON,
            scope: toolContext.scope
        )
        let target = RuntimeAuthorityDigest.canonicalTarget(
            for: call,
            descriptor: ToolCatalog.descriptor(named: surface.rawValue),
            workspaceRootURL: toolContext.workspaceRootURL,
            stagedDocument: toolContext.canvasStagedDocument
        )
        return toolContext.runtimeAuthorityBinding(
            toolName: surface.rawValue,
            operation: "apply",
            canonicalTarget: target,
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: canonicalJSON),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(canonicalJSON)
        )
    }
}

// MARK: - Tools

struct IOSBridgeStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let includeConfiguration: Bool

        init(from decoder: Decoder) throws {
            let value = try IOSBridgeJSONValue(from: decoder)
            guard let object = value.objectValue else {
                throw FloeError.validationFailed("Status arguments must be an object.")
            }
            let unknown = Set(object.keys).subtracting(["include_configuration"])
            guard unknown.isEmpty else {
                throw FloeError.validationFailed("Unsupported status argument.")
            }
            if let raw = object["include_configuration"], raw.isNull == false {
                guard let value = raw.boolValue else {
                    throw FloeError.validationFailed("include_configuration must be a boolean.")
                }
                self.includeConfiguration = value
            } else {
                self.includeConfiguration = true
            }
        }
    }

    static let name = IOSBridgeToolNames.status
    static let toolDescription = "Read the optional local Bridge connection state on THIS iPhone/iPad without changing it. Returns whether the device is supported, Bridge is reachable, a pairing exists, the engine is ready and the Skill configuration readiness. No key, token or secret is returned. Use before pairing or when a local device action reports that Bridge is unavailable."
    static let parametersJSON = #"{"type":"object","properties":{"include_configuration":{"type":"boolean","description":"Include the installed local automation Skill's configuration readiness. Defaults to true."}},"additionalProperties":false}"#
    // Readiness can authenticate with the saved local connection, so it
    // participates in the task's existing credential permission ceiling.
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    private let integration: IOSBridgeIntegration

    init(integration: IOSBridgeIntegration) {
        self.integration = integration
    }

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await IOSBridgeToolGate.requireStatus(integration, context: context)
        guard let client = await integration.client() else {
            throw FloeError.validationFailed("The local Bridge client is unavailable on this device.")
        }
        let snapshot = await client.status()
        let configuration = args.includeConfiguration
            ? await integration.configurationStatus()
            : nil
        return try IOSBridgeToolOutput.status(
            snapshot: snapshot,
            configuration: configuration
        )
    }
}

struct IOSBridgePairTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let clientName: String?
        let replaceExisting: Bool
        let canonicalJSON: Data

        init(from decoder: Decoder) throws {
            let value = try IOSBridgeJSONValue(from: decoder)
            guard let object = value.objectValue else {
                throw FloeError.validationFailed("Pairing arguments must be an object.")
            }
            let unknown = Set(object.keys).subtracting(["client_name", "replace_existing"])
            guard unknown.isEmpty else {
                throw FloeError.validationFailed("Unsupported pairing argument.")
            }
            if let raw = object["client_name"], raw.isNull == false {
                guard let name = raw.stringValue else {
                    throw FloeError.validationFailed("client_name must be a string.")
                }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...IOSBridgeProtocol.clientNameMaximumBytes).contains(trimmed.utf8.count),
                      !trimmed.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
                    throw FloeError.validationFailed(
                        "client_name must be 1...\(IOSBridgeProtocol.clientNameMaximumBytes) printable UTF-8 bytes."
                    )
                }
                self.clientName = trimmed
            } else {
                self.clientName = nil
            }
            if let raw = object["replace_existing"], raw.isNull == false {
                guard let value = raw.boolValue else {
                    throw FloeError.validationFailed("replace_existing must be a boolean.")
                }
                self.replaceExisting = value
            } else {
                self.replaceExisting = false
            }
            self.canonicalJSON = value.canonicalData()
        }
    }

    static let name = IOSBridgeToolNames.pair
    static let toolDescription = "Pair Floe with the optional local Bridge companion on THIS iPhone/iPad. Bridge asks its owner to approve the request. client_name is only a display label. replace_existing replaces an existing unexpired local pairing after owner approval. This creates a device-bound connection for the installed local automation Skill; it does not install Bridge, grant tool permissions or revoke any Bridge client."
    static let parametersJSON = #"{"type":"object","properties":{"client_name":{"type":"string","maxLength":128,"description":"Optional display name shown in Bridge's owner-approval prompt. Defaults to the device name."},"replace_existing":{"type":"boolean","description":"Replace an existing unexpired local pairing after Bridge owner approval. Defaults to false."}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials, .networkAccess]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    private let integration: IOSBridgeIntegration

    init(integration: IOSBridgeIntegration) {
        self.integration = integration
    }

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let client = try await IOSBridgeToolGate.requirePair(integration, context: context)
        // Pairing is a setup mutation, not a device action, but it still uses
        // the exact approved call's runtime authority and the same native
        // task/generation bookkeeping as the other mutating surface.
        let binding = try IOSBridgeToolContextFactory.binding(
            toolContext: context,
            surface: .pair,
            canonicalJSON: args.canonicalJSON
        )
        let validation = await context.consumeRuntimeAuthority(binding: binding)
        guard validation == .valid else {
            throw FloeError.unauthorized
        }
        let generation = UInt64(max(0, context.executionBindingGeneration ?? 0))
        await client.registerTaskGeneration(generation, for: context.runID)
        await integration.recordRunBinding(
            runID: context.runID,
            generation: generation
        )
        // Pairing owns a long owner-approval window; a cancelled tool call
        // must not leave a pairing running after the task is gone.
        let cancellationWatch = Task {
            while !Task.isCancelled {
                if context.cancellation.isCancelled {
                    await client.cancelPairing()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { cancellationWatch.cancel() }
        let name: String
        if let given = args.clientName {
            name = given
        } else {
            name = await integration.defaultClientName
        }
        do {
            let result = try await client.pair(
                clientName: name,
                replaceExisting: args.replaceExisting
            )
            let configuration = await integration.validateBridgeConnection()
            return try IOSBridgeToolOutput.pair(
                result: result,
                configuration: configuration
            )
        } catch let error as IOSBridgeError {
            throw FloeError.validationFailed(
                "Pairing did not complete (\(error.canonicalCode)): \(error.userMessage)"
            )
        } catch {
            throw FloeError.validationFailed("Pairing did not complete. Nothing was claimed as paired.")
        }
    }
}

struct IOSBridgeObserveTool: AgentTool {
    typealias Arguments = IOSBridgeToolArguments

    static let name = IOSBridgeToolNames.observe
    static let toolDescription = "Observe the current screen of THIS iPhone/iPad through the optional local Bridge companion. Read-only actions: device_info, page_source, screen_text, screenshot, is_locked, list_apps, resolve_app, find_element, wait. Coordinates are POINTS; a screenshot result returns a verified image artifact plus point/pixel scale and never a base64 body. Requires the installed, enabled local automation Skill with a current validated pairing. Use ios.bridge.control for taps, text, scrolling or app/window changes."
    static let parametersJSON = IOSBridgeToolSchema.observe
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider, .accessesCredentials]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    private let integration: IOSBridgeIntegration

    init(integration: IOSBridgeIntegration) {
        self.integration = integration
    }

    func validate(_ args: Arguments) throws {
        try args.validate(surface: .observe)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let gate = try await IOSBridgeToolGate.requireDeviceSurface(
            integration,
            context: context,
            surface: .observe
        )
        let prepared = try await IOSBridgeToolContextFactory.make(
            integration: integration,
            client: gate.client,
            toolContext: context,
            surface: .observe,
            canonicalJSON: args.canonicalJSON
        )
        defer { prepared.watcher.cancel() }
        let params = try await integration.prepareParameters(args, context: context)
        let receipt = await prepared.client.perform(
            args.action,
            params: params,
            context: prepared.call
        )
        return try IOSBridgeToolOutput.make(receipt: receipt, action: args.action)
    }
}

struct IOSBridgeControlTool: AgentTool {
    typealias Arguments = IOSBridgeToolArguments

    static let name = IOSBridgeToolNames.control
    static let toolDescription = "Control the current screen of THIS iPhone/iPad through the optional local Bridge companion. Actions: tap, double_tap, long_press, swipe, page, collect, scroll_to_element, scroll, type, clear_text, home, lock, unlock, open_url, launch_app, activate_app, terminate_app, tap_element, find_and_tap, drag. collect and scroll_to_element move the live UI and are mutating. One task holds the device input until it finishes, is cancelled or its bounded window expires. A mutation is never retried automatically; after an unknown outcome observe the screen first. type.text is not echoed, and a normalized credential reference may be used only as the entire text value for an authorized local call."
    static let parametersJSON = IOSBridgeToolSchema.control
    static let riskLabels: Set<RiskLabel> = [
        .controlsGUI, .sendsDataToProvider, .accessesCredentials
    ]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    private let integration: IOSBridgeIntegration

    init(integration: IOSBridgeIntegration) {
        self.integration = integration
    }

    func validate(_ args: Arguments) throws {
        try args.validate(surface: .control)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let gate = try await IOSBridgeToolGate.requireDeviceSurface(
            integration,
            context: context,
            surface: .control
        )
        let prepared = try await IOSBridgeToolContextFactory.make(
            integration: integration,
            client: gate.client,
            toolContext: context,
            surface: .control,
            canonicalJSON: args.canonicalJSON
        )
        defer { prepared.watcher.cancel() }
        let params = try await integration.prepareParameters(args, context: context)
        let receipt = await prepared.client.perform(
            args.action,
            params: params,
            context: prepared.call
        )
        return try IOSBridgeToolOutput.make(receipt: receipt, action: args.action)
    }
}

// MARK: - JSON Schema (from the compiled contract, never Skill text)

enum IOSBridgeToolSchema {
    static let observe = schema(for: IOSAutomationCatalog.observeActions)
    static let control = schema(for: IOSAutomationCatalog.controlActions)

    private static func schema(for actions: [IOSAutomationAction]) -> String {
        let actionNode: [String: Any] = [
            "type": "string",
            "enum": actions.map(\.rawValue),
            "description": "Exact Bridge method. Effects and allowed parameters come from the compiled catalog."
        ]
        var properties: [String: Any] = ["action": actionNode]
        for action in actions {
            for parameter in action.parameters where properties[parameter.name] == nil {
                var node = schemaNode(for: parameter.kind)
                node["description"] = parameterDescription(parameter.name)
                properties[parameter.name] = node
            }
        }
        let object: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": ["action"],
            "additionalProperties": false
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return #"{"type":"object","additionalProperties":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func schemaNode(for kind: IOSAutomationParameter.Kind) -> [String: Any] {
        switch kind {
        case .string: return ["type": "string"]
        case .number: return ["type": "number"]
        case .integer: return ["type": "integer"]
        case .boolean: return ["type": "boolean"]
        case .object: return ["type": "object"]
        case .array: return ["type": "array", "items": ["type": "object"]]
        }
    }

    private static func parameterDescription(_ name: String) -> String {
        switch name {
        case "element_id":
            return "Stable element reference from page_source, screen_text or find_element."
        case "ref":
            return "Stable element reference from a previous observation."
        case "bundle_id":
            return "Installed app bundle identifier."
        case "text":
            return "Bounded text. Never echoed. A normalized ⟨credential:id⟩ reference is resolved only as the entire value for an authorized local control call."
        case "url":
            return "Absolute URL or third-party app deep link."
        case "x", "y", "from_x", "from_y", "to_x", "to_y":
            return "Point coordinate in the screenshot's point space (pixel / scale)."
        case "points":
            return "Array of drag points with point-space coordinates."
        case "settle":
            return "Wait for the UI to settle after the action."
        case "settle_timeout":
            return "Bounded settle timeout in seconds."
        case "direction":
            return "Swipe/page/scroll direction."
        case "distance":
            return "Distance in points."
        case "duration":
            return "Duration in seconds."
        case "format":
            return "Screenshot encoding: png or jpeg."
        case "quality":
            return "JPEG quality from 0 to 1."
        case "scale":
            return "Requested screenshot scale."
        case "match", "element_type":
            return "Optional element matching criteria."
        case "filter", "max_depth", "max_elements", "max_children", "enhanced", "visible_only":
            return "Bounded accessibility-tree filtering."
        case "pages", "min_length", "fresh", "source":
            return "Bounded paging controls for collect."
        case "clear", "submit", "fast", "via":
            return "Typing/input options."
        case "country":
            return "App-store country hint."
        default:
            return "See the compiled local Bridge action contract."
        }
    }
}

// MARK: - Results

enum IOSBridgeToolOutput {
    static func status(
        snapshot: IOSBridgeConnectionSnapshot,
        configuration: SkillConfigurationStatus?
    ) throws -> ToolExecutionOutput {
        var object: [String: Any] = [
            "status": "ok",
            "connection": snapshot.status.bridgeToolStateKey,
            "guidance": guidance(snapshot.status),
            "paired": snapshot.status.isPaired,
            "requiresPairing": snapshot.status.requiresPairing
        ]
        if let info = snapshot.info {
            object["protocolVersion"] = info.protocolVersion
            object["engineState"] = info.engineState.wireValue
        }
        if let expiresAt = snapshot.clientExpiresAt {
            object["clientExpiresAt"] = expiresAt.ISO8601Format()
        }
        object["sensitiveInputGranted"] = snapshot.sensitiveInputGranted
        if let configuration {
            object["configurationReadiness"] = configuration.readiness.rawValue
            object["readyForDeviceActions"] = configuration.readiness == .ready
                && snapshot.status == .ready
        }
        return try json(object)
    }

    static func pair(
        result: IOSBridgePairingResult,
        configuration: SkillConfigurationStatus?
    ) throws -> ToolExecutionOutput {
        var object: [String: Any] = [
            "status": "ok",
            "clientName": result.clientName,
            "tokenID": result.tokenID,
            "expiresAt": result.expiresAt.ISO8601Format(),
            "replacedExisting": result.replacedExisting
        ]
        if let configuration {
            object["configurationReadiness"] = configuration.readiness.rawValue
            object["readyForDeviceActions"] = configuration.readiness == .ready
        } else {
            object["configurationReadiness"] = "unavailable"
        }
        return try json(object)
    }

    static func make(
        receipt: IOSAutomationReceipt,
        action: IOSAutomationAction
    ) throws -> ToolExecutionOutput {
        switch receipt.outcome {
        case .outcomeUnknown(let unknown):
            throw ToolExecutionOutcomeUnknownError(
                reference: receipt.operationID,
                message: "\(unknown.message) \(receipt.diagnosticSummary). Inspect the device screen before deciding whether any further action is needed. This operation is not retried automatically."
            )
        case .cancelled:
            throw CancellationError()
        case .fenced:
            throw FloeError.validationFailed(
                "The device action was fenced before it completed. \(receipt.diagnosticSummary)."
            )
        case .failed(let error), .notSent(let error):
            throw FloeError.validationFailed(
                "\(receipt.diagnosticSummary): \(error.userMessage)"
            )
        case .succeeded:
            break
        }

        if action == .screenshot {
            let made = try IOSBridgeScreenshotArtifact.make(from: receipt.result)
            var metadata = made.metadata
            metadata["operationID"] = receipt.operationID
            metadata["usedInputLease"] = receipt.usedInputLease
            return try json(metadata, artifacts: [made.artifact])
        }

        var object: [String: Any] = [
            "status": "ok",
            "action": action.rawValue,
            "effect": receipt.effect.rawValue,
            "operationID": receipt.operationID,
            "usedInputLease": receipt.usedInputLease
        ]
        if let result = receipt.result {
            object["result"] = result.toolJSONObject
        }
        return try json(object)
    }

    struct Projection: Sendable {
        let data: Data
        let fullData: Data
        let omitted: Bool
        let originalByteCount: Int
    }

    private static let omissionNote = "The summary is shortened. The full result is available."

    /// Bounded valid JSON for display only. The admitted full JSON goes to
    /// the existing runtime capture/request-budget/paging path; this producer
    /// must never discard it merely because the display summary is shorter.
    static func boundedProjection(
        _ object: [String: Any],
        maximumBytes: Int = 64 * 1_024
    ) throws -> Projection {
        let full = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard full.count > maximumBytes else {
            return Projection(data: full, fullData: full, omitted: false, originalByteCount: full.count)
        }
        var bounded = object
        _ = bounded.removeValue(forKey: "result")
        bounded["resultOmitted"] = true
        bounded["resultByteCount"] = full.count
        bounded["note"] = omissionNote
        var data = try JSONSerialization.data(withJSONObject: bounded, options: [.sortedKeys])
        if data.count > maximumBytes {
            // A non-result field was itself oversized: retain a small valid
            // envelope rather than emitting invalid or over-budget JSON.
            let minimal: [String: Any] = [
                "status": object["status"] ?? "ok",
                "action": object["action"] ?? "unknown",
                "operationID": object["operationID"] ?? "",
                "resultOmitted": true,
                "resultByteCount": full.count,
                "note": omissionNote
            ]
            data = try JSONSerialization.data(withJSONObject: minimal, options: [.sortedKeys])
        }
        return Projection(data: data, fullData: full, omitted: true, originalByteCount: full.count)
    }

    private static func json(
        _ object: [String: Any],
        artifacts: [ToolArtifactReference] = []
    ) throws -> ToolExecutionOutput {
        let projection = try boundedProjection(object)
        var output = ToolExecutionOutput(
            summary: String(decoding: projection.data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(projection.fullData),
            exitStatus: 0,
            artifacts: artifacts,
            maximumSummaryCharacters: 65_536,
            capturedOutput: String(decoding: projection.fullData, as: UTF8.self)
        )
        output.summaryTruncated = projection.omitted
        return output
    }

    private static func guidance(_ status: IOSBridgeConnectionStatus) -> String {
        switch status {
        case .ready:
            return "The local Bridge is reachable, paired and its automation engine is ready."
        case .unsupportedPlatform:
            return "Local device automation is unavailable on this platform."
        case .companionMissing:
            return "The Bridge companion is not installed on this device."
        case .companionPresenceUnknown, .serviceUnavailable:
            return "Bridge is not reachable. Open Bridge on this device, then check again."
        case .serviceOff:
            return "Bridge is installed but not running. Open Bridge, then check again."
        case .incompatibleBridge:
            return "This Bridge version uses an unsupported protocol. Update Bridge."
        case .needsPairing:
            return "No local pairing exists yet. Pair with Bridge; its owner must approve."
        case .pairingInProgress:
            return "A pairing request is in progress."
        case .waitingForOwnerApproval:
            return "Open Bridge on this device and approve the pairing request."
        case .lockedCredentials:
            return "Unlock this device; the saved Bridge connection was not deleted."
        case .credentialsUnavailable:
            return "The saved Bridge connection is temporarily unavailable. It was not deleted."
        case .pairingRecordInvalid:
            return "The saved pairing is invalid. Pair again."
        case .expired:
            return "The pairing expired. Pair again and approve in Bridge."
        case .revoked:
            return "Bridge no longer recognizes this pairing. Pair again."
        case .engineNotReady:
            return "Bridge is reachable and paired, but its automation engine is not ready."
        case .unknown:
            return "The Bridge connection could not be verified."
        }
    }
}

extension IOSBridgeConnectionStatus {
    var bridgeToolStateKey: String {
        switch self {
        case .unknown: return "unknown"
        case .unsupportedPlatform: return "unsupported_platform"
        case .companionMissing: return "companion_missing"
        case .companionPresenceUnknown: return "companion_presence_unknown"
        case .serviceOff: return "service_off"
        case .serviceUnavailable: return "service_unavailable"
        case .incompatibleBridge(let version): return "incompatible_bridge:\(version)"
        case .needsPairing: return "needs_pairing"
        case .pairingInProgress: return "pairing_in_progress"
        case .waitingForOwnerApproval: return "waiting_for_owner_approval"
        case .lockedCredentials: return "locked_credentials"
        case .credentialsUnavailable: return "credentials_unavailable"
        case .pairingRecordInvalid: return "pairing_record_invalid"
        case .expired: return "expired"
        case .revoked: return "revoked"
        case .engineNotReady: return "engine_not_ready"
        case .ready: return "ready"
        }
    }
}

extension IOSBridgeJSONValue {
    /// Foundation representation for bounded JSONSerialization output. Only
    /// non-secret action results use this projection.
    var toolJSONObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.toolJSONObject)
        case .object(let values): return values.mapValues(\.toolJSONObject)
        }
    }
}

// MARK: - Verified screenshot artifact

enum IOSBridgeScreenshotArtifact {
    /// Prefer a dedicated namespace. Until the shared verified-image allowlist
    /// includes it, reuse the already vetted screenshot namespace so the
    /// artifact can be loaded and attached instead of silently disappearing.
    static var namespace: String {
        VerifiedToolImageArtifact.namespaces.contains("IOSBridgeArtifacts")
            ? "IOSBridgeArtifacts" : "VNCArtifacts"
    }

    static func make(
        from result: IOSBridgeJSONValue?,
        root: URL? = nil,
        now: Date = Date()
    ) throws -> (artifact: ToolArtifactReference, metadata: [String: Any]) {
        guard let object = result?.objectValue,
              let base64 = object["data"]?.stringValue,
              base64.utf8.count <= 16 * 1_024 * 1_024,
              let data = Data(base64Encoded: base64, options: []),
              !data.isEmpty,
              data.count <= VerifiedToolImageArtifact.maximumStoredImageBytes else {
            throw FloeError.validationFailed("The Bridge screenshot result was invalid.")
        }
        let format = (object["format"]?.stringValue ?? "").lowercased()
        let mimeType: String
        let fileExtension: String
        switch format {
        case "png":
            mimeType = "image/png"
            fileExtension = "png"
        case "jpeg", "jpg":
            mimeType = "image/jpeg"
            fileExtension = "jpg"
        default:
            throw FloeError.validationFailed("The Bridge screenshot format is not supported.")
        }
        if let declaredBytes = object["bytes"]?.intValue, declaredBytes != data.count {
            throw FloeError.validationFailed("The Bridge screenshot size does not match its receipt.")
        }
        let rootURL: URL
        if let root {
            rootURL = root
        } else {
            rootURL = try applicationSupportRoot()
        }
        let directory = rootURL.appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        cleanup(directory: directory, now: now)
        let id = UUID()
        let filename = "\(id.uuidString).\(fileExtension)"
        let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        let digest = FloeDigest.sha256Hex(data)
        let artifact = ToolArtifactReference(
            id: id,
            relativePath: "\(namespace)/\(filename)",
            mimeType: mimeType,
            byteCount: data.count,
            sha256: digest
        )
        // Prove the shared verified-image boundary can load these exact bytes
        // before advertising the image. A rejected artifact fails honestly.
        _ = try VerifiedToolImageArtifact.load(artifact, root: rootURL)
        var metadata: [String: Any] = [
            "status": "ok",
            "action": IOSAutomationAction.screenshot.rawValue,
            "mimeType": mimeType,
            "byteCount": data.count,
            "sha256": digest,
            "artifactPath": artifact.relativePath,
            "imageAttached": true
        ]
        for key in [
            "pixel_width", "pixel_height", "point_width", "point_height",
            "scale", "scope", "scoped_to", "hint", "quality"
        ] {
            if let value = object[key], !value.isNull {
                metadata[key] = value.toolJSONObject
            }
        }
        return (artifact, metadata)
    }

    private static func applicationSupportRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func cleanup(directory: URL, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(40) {
            try? FileManager.default.removeItem(at: file)
        }
        for file in sorted {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Registration

@MainActor
func registerIOSBridgeTools(
    integration: IOSBridgeIntegration,
    registry: ToolRunnerRegistry = .shared
) {
    guard LocalBridgePlatform.current.supportsIOSAutomation else { return }
    ToolCatalog.register(IOSBridgeStatusTool.self)
    ToolCatalog.register(IOSBridgePairTool.self)
    ToolCatalog.register(IOSBridgeObserveTool.self)
    ToolCatalog.register(IOSBridgeControlTool.self)
    registry.register(IOSBridgeStatusTool(integration: integration))
    registry.register(IOSBridgePairTool(integration: integration))
    registry.register(IOSBridgeObserveTool(integration: integration))
    registry.register(IOSBridgeControlTool(integration: integration))
}
#endif
