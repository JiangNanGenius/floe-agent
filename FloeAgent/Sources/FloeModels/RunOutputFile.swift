// FloeModels — Stable run-owned user-file output receipt (S3-D).
//
// A `RunOutputFile` is a durable, sealed statement that ONE concrete run
// produced ONE user-facing output file. It never points at a live workspace
// file: `relativePath` is always the canonical app-storage snapshot under
// `RunOutputs/<runID>/<outputID>/<displayName>`, whose bytes are frozen at
// publication. Later edits or deletion of the workspace original cannot
// change the saved run bytes; readers re-verify size and SHA-256 at retrieval.
//
// Ownership is runtime authority, never model text: the runtime seals the
// identity fields (runID/taskID/environmentID/producerCallID/producerTool)
// from its real call and run context before persistence, and re-derives
// `outputID` from (runID, producer call id, slot). A tool or model quoting a
// path or namespace grants nothing. Screenshots, diffs, VNC frames and MCP
// resource artifacts are NOT user outputs; they never enter this transport.
//
// There is deliberately no timestamp field: duplicate receipts must compare
// metadata-equal for idempotency, and per-retry times would make the same
// snapshot look different.

import Foundation
import FloeCore

/// Explicit role of a receipt inside `ToolResult.outputFiles`. Only genuine
/// user outputs are transportable; ordinary artifacts keep using
/// `ToolArtifactReference` and can never be relabeled by namespace inference.
public enum RunOutputRole: String, Sendable, Codable, Hashable {
    /// A real user-facing output file produced by this exact run.
    case userFile
}

/// One sealed user-file receipt for one run output snapshot.
public struct RunOutputFile: Sendable, Codable, Hashable, Identifiable {
    /// Canonical app-storage namespace prefix for stable run outputs.
    public static let namespacePrefix = "RunOutputs"

    // Field ceilings keep receipts bounded for the durable event payload.
    public static let maximumSlotCharacters = 128
    public static let maximumDisplayNameUTF8Bytes = 255
    public static let maximumProducerToolCharacters = 256
    public static let maximumProducerCallIDCharacters = 256
    public static let maximumMimeTypeCharacters = 128
    public static let maximumUTICharacters = 128

    /// Stable output identity within one producer call:
    /// lowercase SHA-256 over (runID ‖ producerCallID ‖ slot). Deterministic —
    /// there is no random fallback identity.
    public var outputID: String
    /// Logical output slot chosen by the trusted producer within this call
    /// (e.g. "image", "document", "page-2"). Retained so the runtime can
    /// re-derive `outputID` from its own real call binding.
    public var slot: String
    /// The exact run that produced this output. Sealed by the runtime.
    public var runID: UUID
    /// Conversation/task identity the run belongs to. Sealed by the runtime;
    /// nil only where the runtime itself has no task binding.
    public var taskID: UUID?
    /// Explicit execution environment identity, sealed from the runtime's
    /// frozen run configuration. nil is allowed only when the run genuinely
    /// has no environment binding (native/base context) — never an inferred
    /// first environment or workspace.
    public var environmentID: String?
    /// Provider call id of the actual producing tool call. Sealed by the runtime.
    public var producerCallID: String
    /// Catalog name of the actual producing tool. Sealed by the runtime.
    public var producerTool: String
    /// Canonical snapshot path relative to the Floe artifact root:
    /// `RunOutputs/<runID UUIDString>/<outputID>/<displayName>`.
    public var relativePath: String
    /// Display basename (single path component, bounded, never hidden).
    public var displayName: String
    /// MIME type captured at the producer's commit boundary.
    public var mimeType: String
    /// Optional uniform type identifier supplied by the trusted producer.
    public var uti: String?
    /// Byte count measured at commit.
    public var byteCount: Int
    /// Lowercase 64-hex SHA-256 of the snapshot bytes at commit.
    public var sha256: String
    /// Explicit user-output role.
    public var role: RunOutputRole

    public var id: String { outputID }

    public init(
        outputID: String,
        slot: String,
        runID: UUID,
        taskID: UUID?,
        environmentID: String?,
        producerCallID: String,
        producerTool: String,
        relativePath: String,
        displayName: String,
        mimeType: String,
        uti: String?,
        byteCount: Int,
        sha256: String,
        role: RunOutputRole
    ) {
        self.outputID = outputID
        self.slot = slot
        self.runID = runID
        self.taskID = taskID
        self.environmentID = environmentID
        self.producerCallID = producerCallID
        self.producerTool = producerTool
        self.relativePath = relativePath
        self.displayName = displayName
        self.mimeType = mimeType
        self.uti = uti
        self.byteCount = byteCount
        self.sha256 = sha256
        self.role = role
    }

    /// Deterministic stable identity for one logical output slot of one real
    /// call. The same run/call/slot always derives the same identity; any
    /// different slot or call derives a different one.
    public static func derivedOutputID(runID: UUID, producerCallID: String, slot: String) -> String {
        var identity = Data(runID.uuidString.utf8)
        identity.append(Data([0x1F]))
        identity.append(Data(producerCallID.utf8))
        identity.append(Data([0x1F]))
        identity.append(Data(slot.utf8))
        return FloeDigest.sha256Hex(identity)
    }

    /// Canonical snapshot path for a sealed receipt shape.
    public static func canonicalRelativePath(
        runID: UUID, outputID: String, displayName: String
    ) -> String {
        "\(namespacePrefix)/\(runID.uuidString)/\(outputID)/\(displayName)"
    }

    /// True when `name` is a safe single-component display basename:
    /// non-empty, no separators, no traversal, no control characters, no
    /// leading dot (hidden/staging collision), ≤255 UTF-8 bytes.
    public static func isValidDisplayName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name.utf8.count <= maximumDisplayNameUTF8Bytes,
              !name.hasPrefix("."),
              name != ".", name != ".." else { return false }
        for character in name.unicodeScalars {
            if character == "/" || character == "\\" || character.value == 0 { return false }
            if character.value < 0x20 || character.value == 0x7F { return false }
        }
        return true
    }

    /// True for lowercase 64-hex SHA-256.
    public static func isValidSHA256Hex(_ digest: String) -> Bool {
        guard digest.utf8.count == 64 else { return false }
        for scalar in digest.unicodeScalars {
            let isHex = (0x30...0x39).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
            if !isHex { return false }
        }
        return true
    }

    /// True when `value` is a bounded, control-character-free text field.
    public static func isValidBoundedField(_ value: String, maximumCharacters: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumCharacters else { return false }
        for scalar in value.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            return false
        }
        return true
    }

    /// Structural self-validation of the receipt shape used by the runtime
    /// seal, the snapshot store and readers: canonical path for its own
    /// identity, valid digest, bounded fields, explicit role, sane size.
    /// It does not check on-disk bytes (readers verify digests at retrieval).
    public var isCanonicalForCurrentRun: Bool {
        guard role == .userFile else { return false }
        guard byteCount >= 0 else { return false }
        guard Self.isValidSHA256Hex(sha256) else { return false }
        guard Self.isValidDisplayName(displayName) else { return false }
        guard Self.isValidBoundedField(slot, maximumCharacters: Self.maximumSlotCharacters) else { return false }
        guard Self.isValidBoundedField(producerCallID, maximumCharacters: Self.maximumProducerCallIDCharacters) else { return false }
        guard Self.isValidBoundedField(producerTool, maximumCharacters: Self.maximumProducerToolCharacters) else { return false }
        guard Self.isValidBoundedField(mimeType, maximumCharacters: Self.maximumMimeTypeCharacters) else { return false }
        if let uti, !Self.isValidBoundedField(uti, maximumCharacters: Self.maximumUTICharacters) { return false }
        guard relativePath == Self.canonicalRelativePath(
            runID: runID, outputID: outputID, displayName: displayName
        ) else { return false }
        return true
    }

    /// True when this receipt's OWN identity fields are internally
    /// consistent: outputID equals the deterministic derivation from the
    /// sealed run/call/slot. The runtime seal uses this after overwriting
    /// identity, so a tool cannot mint a stable slot identity that survives
    /// under a different call.
    public var hasRuntimeConsistentIdentity: Bool {
        outputID == Self.derivedOutputID(
            runID: runID, producerCallID: producerCallID, slot: slot
        )
    }
}
