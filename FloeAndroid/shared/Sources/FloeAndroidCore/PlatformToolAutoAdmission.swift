// SPDX-License-Identifier: MPL-2.0
//
// G08 trusted ordinary-automatic admission snapshot (Full-only seam).
//
// The trusted Full App host publishes the durable user-selected ceilings it
// already enforces (`DeviceAccessHost.autoAdmissionJson`, delivered through
// `PlatformToolHostPump.setAutoAdmission` / the
// `floe_platform_tool_set_auto_admission` C export) for the SAME live native
// root epoch. This file owns:
//
//   * the CLOSED admission snapshot model and its strict parser
//     (`version` 1, `packageManagement`, `fileWrites`, `fileRootIds` and the
//     optional `advancedTools` opt-in set — nothing else is accepted);
//   * the pure eligibility rule consulted by the ordinary automatic task
//     policy BEFORE any model review or human escalation, so an actually
//     eligible side-effecting platform call receives a REAL canonical
//     approval grant (task/run/call/epoch-bound through the existing
//     pipeline) instead of a fabricated host id.
//
// Authority notes:
//   * the snapshot is a host statement about DURABLE USER SETTINGS, never
//     model input; a malformed or stale publication is refused and leaves
//     auto-approval fail-closed (interactive gate stays authoritative);
//   * eligibility never widens the ceilings: package tools need the package
//     ceiling, file mutations need the write ceiling AND the exact selected
//     root, advanced tools must be individually listed AND bound+available;
//   * protected/system targets stay refused per item by the host backend;
//     this layer only admits the ordinary category ceiling;
//   * there is no parallel permission database here: grants are issued only
//     by the canonical `ApprovalPolicy` pipeline in FloeSecurity.
import CoreFoundation
import Foundation
import FloeSecurity

// MARK: - Snapshot model

/// ONE trusted durable-ceiling snapshot for the live epoch.
public struct PlatformToolAutoAdmission: Sendable, Equatable {
    /// Durable user app-management ceiling (stage/install/uninstall/forceStop).
    public let packageManagement: Bool
    /// Durable user global file-write ceiling.
    public let fileWrites: Bool
    /// Exact selected writable file root ids (catalog tokens, never paths).
    public let fileRootIds: Set<String>
    /// Optional advanced opted-in tools for this epoch (default empty).
    public let advancedTools: Set<String>

    public init(
        packageManagement: Bool,
        fileWrites: Bool,
        fileRootIds: Set<String>,
        advancedTools: Set<String> = []
    ) {
        self.packageManagement = packageManagement
        self.fileWrites = fileWrites
        self.fileRootIds = fileRootIds
        self.advancedTools = advancedTools
    }

    /// Ordinary package-management operations admitted by the ceiling.
    public func admitsPackageOperation(_ toolName: String) -> Bool {
        PlatformToolAutoAdmissionParser.packageManagementTools.contains(toolName)
            && packageManagement
    }

    /// Selected-root file mutations admitted by the ceiling. The exact root
    /// named by the call must be part of the durable selection. (The tool
    /// name itself is validated by the eligibility rule.)
    public func admitsFileOperation(root: String) -> Bool {
        fileWrites && fileRootIds.contains(root)
    }

    /// Advanced tools admitted only by their individual opt-in.
    public func admitsAdvancedTool(_ toolName: String) -> Bool {
        advancedTools.contains(toolName)
    }
}

// MARK: - Parser

public enum PlatformToolAutoAdmissionError: Error, Equatable {
    case oversized
    case malformed(String)

    /// Stable bounded diagnostic token for mailbox counters (never carries
    /// model content or host paths).
    public var code: String {
        switch self {
        case .oversized: return "oversized"
        case .malformed(let field): return "malformed:\(String(field.prefix(64)))"
        }
    }
}

public enum PlatformToolAutoAdmissionParser {
    public static let version = 1
    /// `DeviceAccessHost.autoAdmissionJson` already bounds its root list;
    /// these caps are the Swift-side contract on the wire.
    public static let maximumRootIds = 32
    public static let maximumRootIdCharacters = 64
    /// Settled ABI maxItems: exactly the six closed advanced names.
    public static let maximumAdvancedTools = 6

    /// Closed ordinary package-management ceiling tools.
    public static let packageManagementTools: Set<String> = [
        "system.packages.stage",
        "system.packages.install",
        "system.packages.uninstall",
        "system.packages.forceStop",
    ]

    /// Closed selected-root file mutation ceiling tools.
    public static let fileWriteTools: Set<String> = [
        "system.files.write",
        "system.files.move",
        "system.files.delete",
    ]

    /// Closed advanced ceiling tools the host may opt into per epoch. This
    /// is the exact settled ABI set: no phone/external-send names and no
    /// generic prefix can ever be admitted through this channel.
    public static let advancedToolNames: Set<String> = [
        "system.packages.setEnabled",
        "system.packages.removeForUser",
        "system.packages.restore",
        "system.permissions.manage",
        "system.appOps.manage",
        "system.settings.write",
    ]

    private static let allowedKeys: Set<String> = [
        "version", "packageManagement", "fileWrites", "fileRootIds", "advancedTools",
    ]

    /// Strict, closed parser for the trusted admission snapshot. Any unknown
    /// key, wrong type, bad token or oversize body refuses the WHOLE
    /// publication: a partially-trusted ceiling is never applied.
    public static func parse(_ data: Data) throws -> PlatformToolAutoAdmission {
        guard data.count <= PlatformToolHostLimits.maximumAutoAdmissionBytes else {
            throw PlatformToolAutoAdmissionError.oversized
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            throw PlatformToolAutoAdmissionError.malformed("body")
        }
        for key in object.keys where !allowedKeys.contains(key) {
            throw PlatformToolAutoAdmissionError.malformed("key:\(key)")
        }
        guard let version = strictInt(object["version"]), version == Self.version else {
            throw PlatformToolAutoAdmissionError.malformed("version")
        }
        guard let packageManagement = strictBool(object["packageManagement"]) else {
            throw PlatformToolAutoAdmissionError.malformed("packageManagement")
        }
        guard let fileWrites = strictBool(object["fileWrites"]) else {
            throw PlatformToolAutoAdmissionError.malformed("fileWrites")
        }
        let fileRootIds = try parseRootIds(object["fileRootIds"])
        let advancedTools = try parseAdvancedTools(object["advancedTools"])
        return PlatformToolAutoAdmission(
            packageManagement: packageManagement,
            fileWrites: fileWrites,
            fileRootIds: fileRootIds,
            advancedTools: advancedTools)
    }

    private static func parseRootIds(_ value: Any?) throws -> Set<String> {
        guard let list = value as? [Any] else {
            throw PlatformToolAutoAdmissionError.malformed("fileRootIds")
        }
        guard list.count <= maximumRootIds else {
            throw PlatformToolAutoAdmissionError.malformed("fileRootIds:count")
        }
        var roots: Set<String> = []
        for item in list {
            guard let root = item as? String,
                  !root.isEmpty,
                  root.count <= maximumRootIdCharacters,
                  isValidRootId(root),
                  roots.insert(root).inserted else {
                throw PlatformToolAutoAdmissionError.malformed("fileRootIds:token")
            }
        }
        return roots
    }

    /// One selected-root catalog token. Either a plain token (ASCII
    /// alnum/`_`/`-`) or the REAL `FileRootCatalog.appDataId` form
    /// (`appdata:` + 16 lowercase SHA-256 hex, a digest reference to an
    /// App-normalized app-data path — never a path itself, so it grants no
    /// path or unknown-content authority). Anything else refuses.
    static func isValidRootId(_ root: String) -> Bool {
        if root.hasPrefix(Self.appDataIdPrefix) {
            let hex = root.dropFirst(Self.appDataIdPrefix.count)
            guard hex.count == Self.appDataIdHexCharacters else { return false }
            return hex.allSatisfy { character in
                ("0"..."9").contains(character) || ("a"..."f").contains(character)
            }
        }
        return root.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_" || scalar == "-")
        }
    }

    private static let appDataIdPrefix = "appdata:"
    private static let appDataIdHexCharacters = 16

    private static func parseAdvancedTools(_ value: Any?) throws -> Set<String> {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            throw PlatformToolAutoAdmissionError.malformed("advancedTools")
        }
        guard list.count <= maximumAdvancedTools else {
            throw PlatformToolAutoAdmissionError.malformed("advancedTools:count")
        }
        var tools: Set<String> = []
        for item in list {
            guard let tool = item as? String,
                  advancedToolNames.contains(tool),
                  tools.insert(tool).inserted else {
                throw PlatformToolAutoAdmissionError.malformed("advancedTools:token")
            }
        }
        return tools
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }
}

// MARK: - Eligibility (ordinary automatic task mode)

/// Pure trusted-admission eligibility consulted by the ordinary automatic
/// task policy before any model review or human escalation. This NEVER
/// issues authority: it only reports whether the trusted host published the
/// durable ceiling covering this exact call for the CURRENT live epoch.
public enum PlatformToolAutomaticAdmission {

    /// Production gate: ONE mailbox snapshot combines bound+available+
    /// admission+live epoch under a single lock hold, so an eligibility
    /// decision can never mix state from two generations.
    public static func admits(_ action: ProposedAction) -> Bool {
        admits(
            action,
            admissionForTool: {
                PlatformToolHostMailbox.shared
                    .autoAdmissionEligibilitySnapshot(named: $0)
            })
    }

    /// Pure rule over one injected per-tool snapshot (unit tests / review).
    static func admits(
        _ action: ProposedAction,
        admissionForTool: @Sendable (String) -> PlatformToolAutoAdmission?
    ) -> Bool {
        let tool = action.toolCall.toolName
        enum Kind { case package, file, advanced }
        let kind: Kind
        if PlatformToolAutoAdmissionParser.packageManagementTools.contains(tool) {
            kind = .package
        } else if PlatformToolAutoAdmissionParser.fileWriteTools.contains(tool) {
            kind = .file
        } else if PlatformToolAutoAdmissionParser.advancedToolNames.contains(tool) {
            kind = .advanced
        } else {
            // Never a generic prefix or unknown-name bypass: only the closed
            // ceiling sets above can be admitted at all.
            return false
        }
        // The single snapshot already proves: tool installed AND published
        // as available, mailbox bound to the CURRENT live epoch, and the
        // admission belongs to that same epoch. Anything else keeps the
        // actual gate.
        guard let admission = admissionForTool(tool) else { return false }
        switch kind {
        case .package:
            return admission.admitsPackageOperation(tool)
        case .file:
            guard let root = rootArgument(in: action.toolCall.argumentsJSON) else {
                return false
            }
            return admission.admitsFileOperation(root: root)
        case .advanced:
            return admission.admitsAdvancedTool(tool)
        }
    }

    /// The exact `root` argument of a file mutation call. Missing, non-string
    /// or out-of-contract values fail closed (never admitted). Exact
    /// membership in the parsed `fileRootIds` set is the authority check, so
    /// a malformed token can never match.
    private static func rootArgument(in argumentsJSON: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: argumentsJSON)
                as? [String: Any],
              let root = object["root"] as? String,
              !root.isEmpty,
              root.count <= PlatformToolAutoAdmissionParser.maximumRootIdCharacters
        else { return nil }
        return root
    }
}
