// FloeAndroidWorkspaceTools — grant binding + proof model.
//
// Android-owned (job-ade884c46eb84ec1). The binding is minted ONLY by the
// native Core authority (FloeAndroidCore/LinuxWorkspaceAuthority.swift) from
// the accepted Root, the original Run/ToolContext and the persisted
// conversation/workspace ownership. Metadata JSON can never mint a grant:
// every binding carries a standard HMAC-SHA256 proof (process secret) over
// the COMPLETE canonical scope — every identity, the root epoch, the grant
// id, the exact canonical Core root path AND the exact budgets — and a
// binding whose proof fails is refused before any file byte is read or
// written. Parsing is strict: exact field sets, finite integer-typed
// numbers (booleans and fractions are refused), canonical uppercase owner
// UUID strings (the same "owner IDs ride UNCHANGED" rule as the shell
// mailbox). The workspace ROOT PATH never leaves the Core process: the
// runtime side addresses entries only by opaque relative paths + index.
//
// `rootEpoch` is the ACTUAL accepted native root epoch
// (G02NativeRootEpoch.readback), re-checked at session begin, finish and
// periodically during long operations; a changed epoch fences the session and
// nothing further is applied.

import Foundation
import Crypto

public struct WorkspaceGrantBinding: Sendable, Equatable {
    /// Stable project identity: SHA256 mapping of the trusted canonical Core
    /// workspace root (the SAME mapping `LinuxShellProjectMapping` produces
    /// for shell.start). Not random, never "first project", never temp.
    public var projectID: UUID
    /// The original runtime-issued run identity, unchanged.
    public var runID: UUID
    /// The original conversation identity when the run carries one.
    public var conversationID: UUID?
    /// The ORIGINAL persisted workspace identity that resolved to
    /// `workspaceRootPath` (conversation ownership or explicit binding).
    /// Re-checked against the workspace store during long sessions.
    public var workspaceID: UUID
    /// Durable-job ownership scope (Main integration contract 2026-10-22):
    /// the ORIGINAL captured host toolCallID, ONLY for the exact shape
    /// `jobs.<jobUUID>`, plus the job identity parsed from it. Ordinary
    /// (in-run) grants carry nil for both. A terminal PARENT run alone never
    /// revokes a job-scoped grant; job settlement/cancellation does (the
    /// Core authority re-verifies the ORIGINAL job row + live processor
    /// ownership on every currency check).
    public var toolCallID: String?
    public var jobID: UUID?
    /// The accepted native root epoch at mint time (strictly positive).
    public var rootEpoch: UInt64
    /// Opaque grant lifetime id (host-generated; ties binder to session).
    public var grantID: String
    /// Canonical Core workspace root (absolute; CORE-process-only, never
    /// crosses the Binder, never enters model/tool JSON).
    public var workspaceRootPath: String
    /// Short non-reversible fingerprint for logs/receipts.
    public var workspaceFingerprint: String
    /// Process-secret HMAC-SHA256 proof over all fields above.
    public var proof: String
    public var budgets: WorkspaceTransferBudgets

    public init(projectID: UUID, runID: UUID, conversationID: UUID?, workspaceID: UUID,
                toolCallID: String? = nil, jobID: UUID? = nil,
                rootEpoch: UInt64, grantID: String, workspaceRootPath: String,
                workspaceFingerprint: String, proof: String, budgets: WorkspaceTransferBudgets) {
        self.projectID = projectID
        self.runID = runID
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.toolCallID = toolCallID
        self.jobID = jobID
        self.rootEpoch = rootEpoch
        self.grantID = grantID
        self.workspaceRootPath = workspaceRootPath
        self.workspaceFingerprint = workspaceFingerprint
        self.proof = proof
        self.budgets = budgets
    }

    public var dictionaryValue: [String: Any] {
        var object: [String: Any] = [
            "version": 1,
            "projectID": projectID.uuidString,
            "runID": runID.uuidString,
            "workspaceID": workspaceID.uuidString,
            "rootEpoch": rootEpoch,
            "grantID": grantID,
            "workspaceFingerprint": workspaceFingerprint,
            "proof": proof,
            "budgets": budgets.dictionaryValue,
        ]
        object["conversationID"] = conversationID?.uuidString
        object["toolCallID"] = toolCallID
        object["jobID"] = jobID?.uuidString
        return object
    }

    /// Parse the host-facing metadata ONLY, strictly. `workspaceRootPath` is
    /// attached separately by the Core authority (it is absent from every
    /// wire object); JSON from outside the Core process cannot inject it.
    /// Nil on ANY shape deviation — a malformed or widened object is a
    /// refusal, never a partial binding.
    public static func from(dictionary: [String: Any], workspaceRootPath: String) -> WorkspaceGrantBinding? {
        let optionalKeys: Set<String> = ["conversationID", "toolCallID", "jobID"]
        let requiredKeys: Set<String> = ["version", "projectID", "runID", "workspaceID", "rootEpoch",
                                         "grantID", "workspaceFingerprint", "proof", "budgets"]
        let keys = Set(dictionary.keys)
        guard keys.isSubset(of: requiredKeys.union(optionalKeys)),
              keys.isSuperset(of: requiredKeys) else { return nil }
        guard WorkspaceStrict.integer(dictionary["version"], min: 1, max: 1) == 1 else { return nil }
        guard let projectID = WorkspaceStrict.canonicalUUID(dictionary["projectID"]),
              let runID = WorkspaceStrict.canonicalUUID(dictionary["runID"]),
              let workspaceID = WorkspaceStrict.canonicalUUID(dictionary["workspaceID"]) else { return nil }
        var conversationID: UUID?
        if dictionary["conversationID"] != nil {
            guard let parsed = WorkspaceStrict.canonicalUUID(dictionary["conversationID"]) else { return nil }
            conversationID = parsed
        }
        guard let epoch = WorkspaceStrict.integer(dictionary["rootEpoch"], min: 1, max: Int64(Int64.max)) else {
            return nil
        }
        guard let grantID = dictionary["grantID"] as? String,
              grantID.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil else { return nil }
        guard let fingerprint = dictionary["workspaceFingerprint"] as? String,
              fingerprint.range(of: "^[0-9a-f]{8,16}$", options: .regularExpression) != nil else { return nil }
        guard let proof = dictionary["proof"] as? String,
              proof.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        guard let budgetsObject = dictionary["budgets"] as? [String: Any],
              let budgets = WorkspaceTransferBudgets.from(dictionary: budgetsObject) else { return nil }
        // Job scope: BOTH fields or NEITHER. The toolCallID must carry the
        // exact durable-job shape and its UUID must equal jobID; anything
        // else (a lone jobID, a foreign call string) is a refusal.
        var toolCallID: String?
        var jobID: UUID?
        let hasCall = dictionary["toolCallID"] != nil
        let hasJob = dictionary["jobID"] != nil
        guard hasCall == hasJob else { return nil }
        if hasCall {
            guard let call = dictionary["toolCallID"] as? String,
                  call.utf8.count <= 64,
                  call.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }),
                  let rawJob = dictionary["jobID"] as? String, let parsedJob = UUID(uuidString: rawJob),
                  call.lowercased().hasPrefix("jobs.") else { return nil }
            let embedded = String(call.dropFirst("jobs.".count))
            guard UUID(uuidString: embedded)?.uuidString == parsedJob.uuidString else { return nil }
            toolCallID = call
            jobID = parsedJob
        }
        return WorkspaceGrantBinding(projectID: projectID, runID: runID, conversationID: conversationID,
                                     workspaceID: workspaceID, toolCallID: toolCallID, jobID: jobID,
                                     rootEpoch: UInt64(epoch), grantID: grantID,
                                     workspaceRootPath: workspaceRootPath, workspaceFingerprint: fingerprint,
                                     proof: proof, budgets: budgets)
    }
}

// MARK: - Strict scalar parsing (shared)

public enum WorkspaceStrict {
    /// Finite integer: real numbers must be integral, booleans are refused
    /// (JSON true is an NSNumber whose doubleValue is 1 — it must never
    /// silently become a budget or epoch), NaN/infinity are refused.
    public static func integer(_ value: Any?, min: Int64, max: Int64) -> Int64? {
        if value is Bool { return nil }
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(),
              double >= Double(min), double <= Double(max) else { return nil }
        let converted = number.int64Value
        guard converted >= min, converted <= max, Double(converted) == double else { return nil }
        return converted
    }

    /// Canonical Swift/Apple UUID string (uppercase, dash form). Owner IDs
    /// ride UNCHANGED; a lowercase Java-normalized echo is refused here, per
    /// the shell lane identity rule.
    public static func canonicalUUIDString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        guard let uuid = UUID(uuidString: text), uuid.uuidString == text else { return nil }
        return text
    }

    public static func canonicalUUID(_ value: Any?) -> UUID? {
        canonicalUUIDString(value).flatMap(UUID.init(uuidString:))
    }
}

// MARK: - Proof

/// Recomputes/compares the binding proof with a standard HMAC-SHA256 over a
/// process secret key (`Crypto.HMAC<SHA256>`). The MAC message is a
/// canonical, separator-unambiguous serialization of the FULL grant scope:
/// version, every identity (project, run, conversation, workspace), the root
/// epoch, the grant id, the exact canonical Core root, AND the exact
/// canonical budgets JSON (sorted keys). Changing any budget number,
/// identity or path invalidates the proof. Lives on the Core side only.
public struct WorkspaceGrantProof {
    private let key: SymmetricKey

    public init(secret: Data) {
        precondition(secret.count >= 32, "grant proof secret must be at least 32 bytes")
        self.key = SymmetricKey(data: secret)
    }

    public static func random() -> WorkspaceGrantProof {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...UInt8.max) }
        return WorkspaceGrantProof(secret: Data(bytes))
    }

    /// Canonical message encoding. Every field is labeled and NUL-separated:
    /// no identity/path string can re-shape the message into a different
    /// field layout (paths cannot contain NUL; identities are canonical).
    public func message(projectID: UUID, runID: UUID, conversationID: UUID?, workspaceID: UUID,
                        toolCallID: String?, jobID: UUID?,
                        rootEpoch: UInt64, grantID: String, workspaceRootPath: String,
                        budgetsJSON: String) -> Data {
        var text = "FloeWorkspaceGrant.v1"
        text += "\u{00}p=" + projectID.uuidString
        text += "\u{00}r=" + runID.uuidString
        text += "\u{00}c=" + (conversationID?.uuidString ?? "-")
        text += "\u{00}w=" + workspaceID.uuidString
        text += "\u{00}t=" + (toolCallID ?? "-")
        text += "\u{00}j=" + (jobID?.uuidString ?? "-")
        text += "\u{00}e=\(rootEpoch)"
        text += "\u{00}g=" + grantID
        text += "\u{00}b=" + budgetsJSON
        text += "\u{00}s=" + workspaceRootPath
        return Data(text.utf8)
    }

    public func compute(projectID: UUID, runID: UUID, conversationID: UUID?, workspaceID: UUID,
                        toolCallID: String? = nil, jobID: UUID? = nil,
                        rootEpoch: UInt64, grantID: String, workspaceRootPath: String,
                        budgetsJSON: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: message(projectID: projectID, runID: runID, conversationID: conversationID,
                         workspaceID: workspaceID, toolCallID: toolCallID, jobID: jobID,
                         rootEpoch: rootEpoch, grantID: grantID,
                         workspaceRootPath: workspaceRootPath, budgetsJSON: budgetsJSON),
            using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical budgets serialization used inside the message: the SAME
    /// sorted-key JSON both sides produce for the same field values.
    public static func canonicalBudgets(_ budgets: WorkspaceTransferBudgets) -> String {
        let object = budgets.dictionaryValue
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "invalid"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Constant-time comparison: XOR-fold over equal-length hex bytes; any
    /// length or byte difference yields a non-zero fold.
    public func matches(_ binding: WorkspaceGrantBinding) -> Bool {
        let expected = compute(projectID: binding.projectID, runID: binding.runID,
                               conversationID: binding.conversationID, workspaceID: binding.workspaceID,
                               toolCallID: binding.toolCallID, jobID: binding.jobID,
                               rootEpoch: binding.rootEpoch,
                               grantID: binding.grantID, workspaceRootPath: binding.workspaceRootPath,
                               budgetsJSON: Self.canonicalBudgets(binding.budgets))
        let left = Array(expected.utf8)
        let right = Array(binding.proof.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

// MARK: - JSON helpers (bounded)

public enum WorkspaceWireJSON {
    /// Encode with an exact byte cap (control headers are small and bounded;
    /// no huge Binder JSON anywhere in this protocol).
    public static func encodeBounded(_ object: [String: Any], limit: Int) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= limit else {
            throw WorkspaceTransferError.malformed
        }
        return data
    }

    public static func decodeObject(_ data: Data, limit: Int) throws -> [String: Any] {
        guard data.count <= limit,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw WorkspaceTransferError.malformed
        }
        return dictionary
    }
}

public enum WorkspaceWireLimits {
    /// One control header/reply JSON object (UTF-8 bytes).
    public static let maximumControlBytes = 65_536
    /// One workspace-relative path carried inside a control header.
    public static let maximumPathBytes = 4_096
    /// Bounded refusal/status code strings.
    public static let maximumCodeChars = 64
}
