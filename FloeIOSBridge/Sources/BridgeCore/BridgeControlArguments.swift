import Foundation

/// Typed arguments for the generic cross-app automation actions.
///
/// This is a closed schema, not a free-form dictionary: unknown fields are
/// rejected, every action accepts only the fields listed for it, and the
/// normalized value is what travels through the LAN request, the command
/// ledger, the authenticated file envelope and the result binding. Raw input
/// text is never copied into the long-lived ledger; only private digests are
/// retained.
public enum BridgeControlAction {
    public static let activateApp = "activate_app"
    public static let inspectUI = "inspect_ui"
    public static let tap = "tap"
    public static let swipe = "swipe"
    public static let typeText = "type_text"

    public static let all: Set<String> = [
        activateApp,
        inspectUI,
        tap,
        swipe,
        typeText,
    ]
}

public struct BridgeControlParameterError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct BridgeControlParameters: Codable, Equatable, Sendable {
    public var bundleIdentifier: String?
    public var identifier: String?
    public var label: String?
    public var placeholder: String?
    public var normalizedX: Double?
    public var normalizedY: Double?
    public var startNormalizedX: Double?
    public var startNormalizedY: Double?
    public var endNormalizedX: Double?
    public var endNormalizedY: Double?
    public var durationMilliseconds: Int?
    public var text: String?
    public var maxDepth: Int?
    public var maxNodes: Int?
    public var maxStringBytes: Int?
    public var maxTotalBytes: Int?

    /// Decode provenance only. It is never encoded, and a non-empty value is
    /// refused before dispatch so a caller cannot smuggle an untyped field.
    public var unknownKeys: [String]

    public init(
        bundleIdentifier: String? = nil,
        identifier: String? = nil,
        label: String? = nil,
        placeholder: String? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        startNormalizedX: Double? = nil,
        startNormalizedY: Double? = nil,
        endNormalizedX: Double? = nil,
        endNormalizedY: Double? = nil,
        durationMilliseconds: Int? = nil,
        text: String? = nil,
        maxDepth: Int? = nil,
        maxNodes: Int? = nil,
        maxStringBytes: Int? = nil,
        maxTotalBytes: Int? = nil,
        unknownKeys: [String] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.identifier = identifier
        self.label = label
        self.placeholder = placeholder
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.startNormalizedX = startNormalizedX
        self.startNormalizedY = startNormalizedY
        self.endNormalizedX = endNormalizedX
        self.endNormalizedY = endNormalizedY
        self.durationMilliseconds = durationMilliseconds
        self.text = text
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxStringBytes = maxStringBytes
        self.maxTotalBytes = maxTotalBytes
        self.unknownKeys = unknownKeys
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bundleIdentifier
        case identifier
        case label
        case placeholder
        case normalizedX
        case normalizedY
        case startNormalizedX
        case startNormalizedY
        case endNormalizedX
        case endNormalizedY
        case durationMilliseconds
        case text
        case maxDepth
        case maxNodes
        case maxStringBytes
        case maxTotalBytes
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        self.unknownKeys = any.allKeys
            .map(\.stringValue)
            .filter { !known.contains($0) }
            .sorted()

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        self.identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        self.normalizedX = try container.decodeIfPresent(Double.self, forKey: .normalizedX)
        self.normalizedY = try container.decodeIfPresent(Double.self, forKey: .normalizedY)
        self.startNormalizedX = try container.decodeIfPresent(Double.self, forKey: .startNormalizedX)
        self.startNormalizedY = try container.decodeIfPresent(Double.self, forKey: .startNormalizedY)
        self.endNormalizedX = try container.decodeIfPresent(Double.self, forKey: .endNormalizedX)
        self.endNormalizedY = try container.decodeIfPresent(Double.self, forKey: .endNormalizedY)
        self.durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
        self.maxNodes = try container.decodeIfPresent(Int.self, forKey: .maxNodes)
        self.maxStringBytes = try container.decodeIfPresent(Int.self, forKey: .maxStringBytes)
        self.maxTotalBytes = try container.decodeIfPresent(Int.self, forKey: .maxTotalBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        try container.encodeIfPresent(normalizedX, forKey: .normalizedX)
        try container.encodeIfPresent(normalizedY, forKey: .normalizedY)
        try container.encodeIfPresent(startNormalizedX, forKey: .startNormalizedX)
        try container.encodeIfPresent(startNormalizedY, forKey: .startNormalizedY)
        try container.encodeIfPresent(endNormalizedX, forKey: .endNormalizedX)
        try container.encodeIfPresent(endNormalizedY, forKey: .endNormalizedY)
        try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(maxDepth, forKey: .maxDepth)
        try container.encodeIfPresent(maxNodes, forKey: .maxNodes)
        try container.encodeIfPresent(maxStringBytes, forKey: .maxStringBytes)
        try container.encodeIfPresent(maxTotalBytes, forKey: .maxTotalBytes)
    }

    public var hasText: Bool { text != nil }

    public var containsSensitiveInput: Bool { text != nil }

    /// The exactly-one explicit selector, if this validated protocol exposes
    /// one. A nil value means the caller relies on the engine's verified
    /// focused-field path.
    public var textTarget: BridgeUITextTarget? {
        if let identifier { return .identifier(identifier) }
        if let label { return .label(label) }
        if let placeholder { return .placeholder(placeholder) }
        if let x = normalizedX, let y = normalizedY {
            return .point(normalizedX: x, normalizedY: y)
        }
        return nil
    }

    /// Canonical JSON used only for private content/result digests. Text is
    /// included only when `includeText` is true; the result digest replaces it
    /// with its byte count so a short secret is not exposed through a
    /// dictionary-guessable hash in a result payload.
    public func canonicalData(includeText: Bool) -> Data? {
        var object: [String: Any] = [:]
        if let bundleIdentifier { object["bundleIdentifier"] = bundleIdentifier }
        if let identifier { object["identifier"] = identifier }
        if let label { object["label"] = label }
        if let placeholder { object["placeholder"] = placeholder }
        if let normalizedX { object["normalizedX"] = normalizedX }
        if let normalizedY { object["normalizedY"] = normalizedY }
        if let startNormalizedX { object["startNormalizedX"] = startNormalizedX }
        if let startNormalizedY { object["startNormalizedY"] = startNormalizedY }
        if let endNormalizedX { object["endNormalizedX"] = endNormalizedX }
        if let endNormalizedY { object["endNormalizedY"] = endNormalizedY }
        if let durationMilliseconds { object["durationMilliseconds"] = durationMilliseconds }
        if let text {
            if includeText {
                object["text"] = text
            } else {
                object["textUTF8Bytes"] = text.utf8.count
            }
        }
        if let maxDepth { object["maxDepth"] = maxDepth }
        if let maxNodes { object["maxNodes"] = maxNodes }
        if let maxStringBytes { object["maxStringBytes"] = maxStringBytes }
        if let maxTotalBytes { object["maxTotalBytes"] = maxTotalBytes }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Non-secret canonical summary carried in accepted responses and results.
    /// Text is represented only by its UTF-8 byte count.
    public func summaryJSON() -> String? {
        guard let data = canonicalData(includeText: false) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum BridgeControlArguments {
    public static let defaultMaxDepth = BridgeUITreeLimits.defaultMaxDepth
    public static let defaultMaxNodes = BridgeUITreeLimits.defaultMaxNodes
    public static let defaultMaxStringBytes = BridgeUITreeLimits.defaultMaxStringBytes
    public static let defaultMaxTotalBytes = BridgeUITreeLimits.defaultMaxTotalBytes
    public static let defaultSwipeDurationMilliseconds = 300
    public static let maximumTextUTF8Bytes = 4_096
    /// JSON escaping expands each valid input byte by at most six bytes.
    /// Leave bounded room for the typed envelope around a maximum-size input.
    public static let maximumSerializedCommandBytes = 32_768

    public static func isGenericAction(_ action: String) -> Bool {
        BridgeControlAction.all.contains(action)
    }

    /// Validates and normalizes one action's parameters. Defaults are filled
    /// here so the request, command envelope, ledger digest and engine result
    /// all describe the same effective arguments.
    public static func validate(
        action: String,
        parameters: BridgeControlParameters?
    ) -> Result<BridgeControlParameters, BridgeControlParameterError> {
        guard BridgeControlAction.all.contains(action) else {
            if parameters == nil { return .success(BridgeControlParameters()) }
            return .failure(BridgeControlParameterError(
                code: "parameters_not_applicable",
                message: "This action does not accept typed parameters."
            ))
        }
        guard var parameters else {
            return .failure(BridgeControlParameterError(
                code: "parameters_required",
                message: "This action requires typed parameters."
            ))
        }
        guard parameters.unknownKeys.isEmpty else {
            return .failure(BridgeControlParameterError(
                code: "unknown_parameters",
                message: "Unknown parameter field(s): \(parameters.unknownKeys.joined(separator: ", "))."
            ))
        }
        guard var bundleIdentifier = parameters.bundleIdentifier else {
            return .failure(BridgeControlParameterError(
                code: "invalid_bundle_identifier",
                message: "A bundle identifier is required."
            ))
        }
        bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBundleIdentifier(bundleIdentifier) else {
            return .failure(BridgeControlParameterError(
                code: "invalid_bundle_identifier",
                message: "The bundle identifier is not a valid installed-app identifier."
            ))
        }
        parameters.bundleIdentifier = bundleIdentifier

        let allowed: Set<String>
        switch action {
        case BridgeControlAction.activateApp:
            allowed = ["bundleIdentifier"]
        case BridgeControlAction.tap:
            allowed = ["bundleIdentifier", "identifier", "normalizedX", "normalizedY"]
        case BridgeControlAction.swipe:
            allowed = ["bundleIdentifier", "startNormalizedX", "startNormalizedY",
                       "endNormalizedX", "endNormalizedY", "durationMilliseconds"]
        case BridgeControlAction.typeText:
            allowed = ["bundleIdentifier", "identifier", "label", "placeholder",
                       "normalizedX", "normalizedY", "text"]
        case BridgeControlAction.inspectUI:
            allowed = ["bundleIdentifier", "maxDepth", "maxNodes",
                       "maxStringBytes", "maxTotalBytes"]
        default:
            allowed = []
        }
        let extra = presentFields(parameters).subtracting(allowed)
        guard extra.isEmpty else {
            return .failure(BridgeControlParameterError(
                code: "parameters_not_applicable",
                message: "This action does not accept: \(extra.sorted().joined(separator: ", "))."
            ))
        }

        if action != BridgeControlAction.inspectUI,
           isForbiddenAutomationBundle(bundleIdentifier) {
            return .failure(BridgeControlParameterError(
                code: "forbidden_target",
                message: "System lock, passcode and authentication surfaces are not automated."
            ))
        }

        switch action {
        case BridgeControlAction.activateApp:
            break

        case BridgeControlAction.tap:
            let hasIdentifier = parameters.identifier != nil
            let hasX = parameters.normalizedX != nil
            let hasY = parameters.normalizedY != nil
            if hasIdentifier && (hasX || hasY) {
                return .failure(BridgeControlParameterError(
                    code: "ambiguous_arguments",
                    message: "Tap accepts either an identifier or normalized coordinates, not both."
                ))
            }
            if hasIdentifier {
                guard let identifier = parameters.identifier,
                      isValidIdentifier(identifier) else {
                    return .failure(BridgeControlParameterError(
                        code: "invalid_identifier",
                        message: "The accessibility identifier is empty or too long."
                    ))
                }
            } else if hasX && hasY {
                guard validUnit(parameters.normalizedX), validUnit(parameters.normalizedY),
                      let x = parameters.normalizedX, let y = parameters.normalizedY else {
                    return .failure(BridgeControlParameterError(
                        code: "invalid_coordinates",
                        message: "Tap coordinates must be finite values between 0 and 1."
                    ))
                }
                parameters.normalizedX = x
                parameters.normalizedY = y
            } else {
                return .failure(BridgeControlParameterError(
                    code: "ambiguous_arguments",
                    message: "Tap requires exactly one of an identifier or both normalized coordinates."
                ))
            }

        case BridgeControlAction.swipe:
            guard validUnit(parameters.startNormalizedX),
                  validUnit(parameters.startNormalizedY),
                  validUnit(parameters.endNormalizedX),
                  validUnit(parameters.endNormalizedY),
                  let startX = parameters.startNormalizedX,
                  let startY = parameters.startNormalizedY,
                  let endX = parameters.endNormalizedX,
                  let endY = parameters.endNormalizedY else {
                return .failure(BridgeControlParameterError(
                    code: "invalid_coordinates",
                    message: "Swipe requires four finite normalized coordinates between 0 and 1."
                ))
            }
            let distance = hypot(endX - startX, endY - startY)
            guard distance >= 0.01 else {
                return .failure(BridgeControlParameterError(
                    code: "invalid_coordinates",
                    message: "Swipe start and end must differ by at least 1% of the app frame."
                ))
            }
            let duration = parameters.durationMilliseconds
                ?? defaultSwipeDurationMilliseconds
            guard (50...2_000).contains(duration) else {
                return .failure(BridgeControlParameterError(
                    code: "invalid_duration",
                    message: "Swipe duration must be between 50 and 2000 milliseconds."
                ))
            }
            parameters.durationMilliseconds = duration
            parameters.startNormalizedX = startX
            parameters.startNormalizedY = startY
            parameters.endNormalizedX = endX
            parameters.endNormalizedY = endY

        case BridgeControlAction.typeText:
            guard let text = parameters.text else {
                return .failure(BridgeControlParameterError(
                    code: "invalid_text",
                    message: "Text input requires text."
                ))
            }
            guard !text.isEmpty, text.utf8.count <= maximumTextUTF8Bytes,
                  !text.utf8.contains(0) else {
                return .failure(BridgeControlParameterError(
                    code: "invalid_text",
                    message: "Text must be 1...\(maximumTextUTF8Bytes) UTF-8 bytes without NUL."
                ))
            }
            if let identifier = parameters.identifier,
               !isValidIdentifier(identifier) {
                return .failure(BridgeControlParameterError(
                    code: "invalid_identifier",
                    message: "The accessibility identifier is empty or too long."
                ))
            }
            let hasIdentifier = parameters.identifier != nil
            let hasLabel = parameters.label != nil
            let hasPlaceholder = parameters.placeholder != nil
            let hasX = parameters.normalizedX != nil
            let hasY = parameters.normalizedY != nil
            var selectorCount = 0
            if hasIdentifier { selectorCount += 1 }
            if hasLabel { selectorCount += 1 }
            if hasPlaceholder { selectorCount += 1 }
            if hasX || hasY { selectorCount += 1 }
            guard selectorCount <= 1 else {
                return .failure(BridgeControlParameterError(
                    code: "ambiguous_arguments",
                    message: "Text input accepts at most one field selector: identifier, label, placeholder or both normalized coordinates."
                ))
            }
            if hasX != hasY {
                return .failure(BridgeControlParameterError(
                    code: "ambiguous_arguments",
                    message: "Text input coordinates require both normalizedX and normalizedY."
                ))
            }
            if let label = parameters.label,
               !isValidTextFieldSelector(label) {
                return .failure(BridgeControlParameterError(
                    code: "invalid_selector",
                    message: "The field label must be 1...512 UTF-8 bytes without NUL."
                ))
            }
            if let placeholder = parameters.placeholder,
               !isValidTextFieldSelector(placeholder) {
                return .failure(BridgeControlParameterError(
                    code: "invalid_selector",
                    message: "The field placeholder must be 1...512 UTF-8 bytes without NUL."
                ))
            }
            if hasX && hasY {
                guard validUnit(parameters.normalizedX), validUnit(parameters.normalizedY),
                      let x = parameters.normalizedX, let y = parameters.normalizedY else {
                    return .failure(BridgeControlParameterError(
                        code: "invalid_coordinates",
                        message: "Text input coordinates must be finite values between 0 and 1."
                    ))
                }
                parameters.normalizedX = x
                parameters.normalizedY = y
            }

        case BridgeControlAction.inspectUI:
            let depth = parameters.maxDepth ?? defaultMaxDepth
            let nodes = parameters.maxNodes ?? defaultMaxNodes
            let stringBytes = parameters.maxStringBytes ?? defaultMaxStringBytes
            let totalBytes = parameters.maxTotalBytes ?? defaultMaxTotalBytes
            guard (1...BridgeUITreeLimits.maximumMaxDepth).contains(depth),
                  (1...BridgeUITreeLimits.maximumMaxNodes).contains(nodes),
                  (BridgeUITreeLimits.minimumMaxStringBytes...BridgeUITreeLimits.maximumMaxStringBytes).contains(stringBytes),
                  (BridgeUITreeLimits.minimumMaxTotalBytes...BridgeUITreeLimits.maximumMaxTotalBytes).contains(totalBytes) else {
                return .failure(BridgeControlParameterError(
                    code: "invalid_bounds",
                    message: "UI bounds must be depth 1...\(BridgeUITreeLimits.maximumMaxDepth), nodes 1...\(BridgeUITreeLimits.maximumMaxNodes), string bytes \(BridgeUITreeLimits.minimumMaxStringBytes)...\(BridgeUITreeLimits.maximumMaxStringBytes) and total bytes \(BridgeUITreeLimits.minimumMaxTotalBytes)...\(BridgeUITreeLimits.maximumMaxTotalBytes)."
                ))
            }
            parameters.maxDepth = depth
            parameters.maxNodes = nodes
            parameters.maxStringBytes = stringBytes
            parameters.maxTotalBytes = totalBytes

        default:
            break
        }
        return .success(parameters)
    }

    public static func contentDigest(action: String,
                                     parameters: BridgeControlParameters?) -> String {
        var data = Data("floe-control-content-v1\n".utf8)
        data.append(Data(action.utf8))
        data.append(0)
        if let canonical = parameters?.canonicalData(includeText: true) {
            data.append(canonical)
        }
        return BridgeAtomicFile.sha256(data)
    }

    /// The non-secret digest placed in the result. It deliberately replaces
    /// raw text with its byte count; the private content digest is only kept in
    /// the in-memory ledger.
    public static func resultDigest(action: String,
                                    parameters: BridgeControlParameters?) -> String {
        var data = Data("floe-control-result-v1\n".utf8)
        data.append(Data(action.utf8))
        data.append(0)
        if let canonical = parameters?.canonicalData(includeText: false) {
            data.append(canonical)
        }
        return BridgeAtomicFile.sha256(data)
    }

    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (3...155).contains(bytes.count),
              value.contains("."),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("..") else {
            return false
        }
        for byte in bytes {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                continue
            default:
                return false
            }
        }
        return true
    }

    public static func isForbiddenAutomationBundle(_ value: String) -> Bool {
        let candidate = value.lowercased()
        if candidate == "com.apple.springboard" ||
            candidate.hasPrefix("com.apple.springboard.") {
            return true
        }
        let blocked: Set<String> = [
            "com.apple.authenticationservicesui",
            "com.apple.authkitui",
            "com.apple.passcodeui",
            "com.apple.passcodeui.remoteviewservice",
        ]
        return blocked.contains(candidate)
    }

    public static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        return true
    }

    /// Labels and placeholders are matched exactly against the snapshot. They
    /// may contain ordinary UI punctuation and spaces, but not NUL and not an
    /// unbounded payload.
    public static func isValidTextFieldSelector(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...512).contains(bytes.count) else { return false }
        return !bytes.contains(0)
    }

    private static func presentFields(_ parameters: BridgeControlParameters) -> Set<String> {
        var fields = Set<String>()
        if parameters.bundleIdentifier != nil { fields.insert("bundleIdentifier") }
        if parameters.identifier != nil { fields.insert("identifier") }
        if parameters.label != nil { fields.insert("label") }
        if parameters.placeholder != nil { fields.insert("placeholder") }
        if parameters.normalizedX != nil { fields.insert("normalizedX") }
        if parameters.normalizedY != nil { fields.insert("normalizedY") }
        if parameters.startNormalizedX != nil { fields.insert("startNormalizedX") }
        if parameters.startNormalizedY != nil { fields.insert("startNormalizedY") }
        if parameters.endNormalizedX != nil { fields.insert("endNormalizedX") }
        if parameters.endNormalizedY != nil { fields.insert("endNormalizedY") }
        if parameters.durationMilliseconds != nil { fields.insert("durationMilliseconds") }
        if parameters.text != nil { fields.insert("text") }
        if parameters.maxDepth != nil { fields.insert("maxDepth") }
        if parameters.maxNodes != nil { fields.insert("maxNodes") }
        if parameters.maxStringBytes != nil { fields.insert("maxStringBytes") }
        if parameters.maxTotalBytes != nil { fields.insert("maxTotalBytes") }
        return fields
    }

    private static func validUnit(_ value: Double?) -> Bool {
        guard let value, value.isFinite else { return false }
        return value >= 0 && value <= 1
    }
}
