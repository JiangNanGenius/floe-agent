// FloeTools — Native delegated-child file-result receipts.
//
// SPDX-License-Identifier: MPL-2.0
//
// A delegated child's toolResult transcript row is written by the runtime,
// never by the model. This receipt is the ONLY bridge from that durable row
// to a parent-visible file card: it names the trusted parent run/task/child/
// call/tool plus the tool's ACTUAL artifacts and sealed RunOutputFile values
// from a successful (`status == .ok`) result. Paths and UUIDs quoted in model
// text, summaries or arbitrary artifact JSON never become an alias or a
// grant.
//
// The runtime's real ownership checks still run later: the App reader checks
// the receipt against the child's durable row and original tool request, and
// every byte read re-enters the existing `RunOutputSnapshotStore` verifier
// (size + streamed SHA-256 under the trusted artifact root). This type adds
// no parallel store, permission, timestamp identity or display authority.

import Foundation
import FloeCore
import FloeModels

/// One bounded receipt for the file outcomes of one successful child call.
/// Version 1 is the frozen inline-transcript shape; `inlineContentReceipt`
/// is its durable member name.
public struct NativeChildFileReceipt: Codable, Sendable, Equatable {
    public static let version = 1
    /// Matches the child transcript entry budget: the receipt must remain
    /// whole inside one 8 KiB row. If it cannot, the runtime records an
    /// incomplete transcript instead of advertising an unreadable ref.
    public static let maximumEncodedBytes = 8 * 1024
    public static let maximumArtifacts = 8
    public static let maximumOutputs = 8

    public var version: Int
    public var parentRunID: UUID
    public var taskID: UUID
    public var childID: UUID
    public var callID: String
    public var tool: String
    public var artifacts: [ToolArtifactReference]
    public var outputs: [RunOutputFile]

    public init(
        parentRunID: UUID,
        taskID: UUID,
        childID: UUID,
        callID: String,
        tool: String,
        artifacts: [ToolArtifactReference],
        outputs: [RunOutputFile]
    ) {
        self.version = Self.version
        self.parentRunID = parentRunID
        self.taskID = taskID
        self.childID = childID
        self.callID = callID
        self.tool = tool
        self.artifacts = Array(artifacts.prefix(Self.maximumArtifacts))
        self.outputs = Array(outputs.prefix(Self.maximumOutputs))
    }

    /// Deterministic encoded size used by the transcript budget decision.
    public var encodedByteCount: Int {
        guard let data = try? Self.encode(self) else { return Int.max }
        return data.count
    }

    static func encode(_ receipt: NativeChildFileReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(receipt)
    }
}

public enum NativeChildFileArtifacts {
    /// Durable toolResult member name carrying the receipt object.
    public static let receiptKey = "inlineContentReceipt"
    /// Upper bound for the whole toolResult envelope before decode. The
    /// durable store already bounds entries to 8 KiB; this is a second
    /// fail-closed bound for callers/tests that read a raw payload.
    public static let maximumEnvelopeBytes = 8 * 1024

    private static let fileWriterTools: Set<String> = [
        "workspace.createFile", "workspace.writeFile", "workspace.applyPatch",
        "workspace.appendFile", "workspace.replaceText",
    ]

    /// Build a receipt from the REAL successful result of one child call.
    /// Only artifacts/outputs that already satisfy their sealed identity are
    /// kept; a result with none yields nil (no card is invented).
    public static func receipt(
        result: ToolResult,
        parentRunID: UUID,
        taskID: UUID,
        childID: UUID,
        callID: String,
        tool: String
    ) -> NativeChildFileReceipt? {
        guard result.callID == callID, result.status == .ok else { return nil }
        let artifacts = result.artifacts
            .filter { accepts($0, runID: parentRunID, tool: tool) }
        let outputs = result.outputFiles
            .filter {
                accepts($0, runID: parentRunID, taskID: taskID,
                        callID: callID, tool: tool)
            }
        guard !artifacts.isEmpty || !outputs.isEmpty,
              artifacts.count <= NativeChildFileReceipt.maximumArtifacts,
              outputs.count <= NativeChildFileReceipt.maximumOutputs else {
            // Never silently hide a real file outcome. A call that advertises
            // more than one bounded receipt can hold is recorded as an
            // incomplete transcript by the caller instead of a partial card.
            return nil
        }
        let receipt = NativeChildFileReceipt(
            parentRunID: parentRunID,
            taskID: taskID,
            childID: childID,
            callID: callID,
            tool: tool,
            artifacts: artifacts,
            outputs: outputs
        )
        // A receipt that cannot fit one transcript entry is not advertised;
        // the caller records the incomplete transcript honestly instead of
        // dropping a file silently or writing a half-object.
        guard receipt.encodedByteCount <= NativeChildFileReceipt.maximumEncodedBytes else {
            return nil
        }
        return receipt
    }

    /// Decode ONE durable child toolResult row. The envelope's call/tool must
    /// agree with the receipt, the receipt must match the EXACT durable child
    /// and its parent run/task, and the original tool request map must prove
    /// this call/tool pair existed before the result row. Every contained
    /// artifact/output must independently re-satisfy its sealed contract.
    public static func decode(
        payloadJSON: String,
        parentRunID: UUID,
        taskID: UUID,
        childID: UUID,
        originalRequestTools: [String: String]
    ) -> NativeChildFileReceipt? {
        struct Envelope: Decodable {
            var tool: String
            var callID: String
            var status: String
            var outcomeUnknown: String?
            var inlineContentReceipt: NativeChildFileReceipt?
        }
        guard payloadJSON.utf8.count <= maximumEnvelopeBytes,
              let envelope = try? JSONDecoder().decode(
                  Envelope.self, from: Data(payloadJSON.utf8)) else {
            return nil
        }
        // Only a successful, known outcome can advertise files. A denied,
        // failed, cancelled or unknown result is never rewritten as success.
        guard envelope.status == "ok",
              envelope.outcomeUnknown == "false",
              let receipt = envelope.inlineContentReceipt,
              receipt.version == NativeChildFileReceipt.version,
              receipt.parentRunID == parentRunID,
              receipt.taskID == taskID,
              receipt.childID == childID,
              !receipt.callID.isEmpty,
              receipt.callID == envelope.callID,
              receipt.tool == envelope.tool,
              originalRequestTools[receipt.callID] == receipt.tool,
              receipt.artifacts.count <= NativeChildFileReceipt.maximumArtifacts,
              receipt.outputs.count <= NativeChildFileReceipt.maximumOutputs,
              receipt.artifacts.allSatisfy({
                  accepts($0, runID: parentRunID, tool: receipt.tool)
              }),
              receipt.outputs.allSatisfy({
                  accepts($0, runID: parentRunID, taskID: taskID,
                          callID: receipt.callID, tool: receipt.tool)
              }),
              !receipt.artifacts.isEmpty || !receipt.outputs.isEmpty,
              receipt.encodedByteCount <= NativeChildFileReceipt.maximumEncodedBytes else {
            return nil
        }
        return receipt
    }

    /// True when a durable result row claims an inline receipt at all. Used
    /// by the reader to distinguish a legacy result (no claim) from a
    /// malformed/failed receipt (counted rejected, never silently ignored).
    public static func advertisesReceipt(payloadJSON: String) -> Bool {
        payloadJSON.utf8.count <= maximumEnvelopeBytes
            && payloadJSON.contains("\"\(receiptKey)\"")
    }

    // MARK: - Acceptance

    /// One Floe-owned artifact exactly as the Android producers write it.
    public static func accepts(_ artifact: ToolArtifactReference, runID: UUID, tool: String) -> Bool {
        let parts = artifact.relativePath.split(
            separator: "/", omittingEmptySubsequences: false)
        guard artifact.byteCount > 0,
              !artifact.relativePath.contains("\\"),
              !artifact.relativePath.unicodeScalars.contains(where: {
                  $0.value < 32 || $0.value == 127
              }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              RunOutputFile.isValidSHA256Hex(artifact.sha256.lowercased()) else {
            return false
        }
        let digest = artifact.sha256.lowercased()
        if fileWriterTools.contains(tool) {
            let suffix: String
            switch artifact.mimeType {
            case "text/x-diff": suffix = ".diff"
            case "application/vnd.floe.file-preview+json": suffix = ".preview.json"
            default: return false
            }
            return artifact.byteCount <= 512 * 1024
                && parts.count == 3
                && parts[0] == "ChangeArtifacts"
                && parts[1] == Substring(runID.uuidString)
                && parts[2] == Substring(digest + suffix)
        }
        // Verified raster evidence from the App's own producers. The filename
        // shape and MIME must agree, and the bytes stay digest-addressed.
        if tool.hasPrefix("browser.") {
            return parts.count == 2 && parts[0] == "BrowserArtifacts"
                && artifact.mimeType == "image/jpeg"
                && artifact.byteCount <= 8 * 1024 * 1024
                && isUUIDJPEG(parts[1])
        }
        if tool.hasPrefix("vnc.") || tool.hasPrefix("rdp.") {
            let namespace = tool.hasPrefix("vnc.") ? "VNCArtifacts" : "RDPArtifacts"
            return parts.count == 2 && parts[0] == Substring(namespace)
                && artifact.mimeType == "image/png"
                && artifact.byteCount <= 16 * 1024 * 1024
                && isUUIDPNG(parts[1])
        }
        if parts.count == 2, parts[0] == "GeneratedImages",
           artifact.byteCount <= 8 * 1024 * 1024 {
            let name = String(parts[1])
            let extensionOfName = (name as NSString).pathExtension.lowercased()
            let expected: String?
            switch artifact.mimeType {
            case "image/png": expected = "png"
            case "image/jpeg": expected = "jpg"
            case "image/webp": expected = "webp"
            default: expected = nil
            }
            return expected != nil && extensionOfName == expected
                && !name.contains("\\") && !name.hasPrefix(".")
        }
        return false
    }

    /// One sealed user output must re-prove its ENTIRE runtime identity
    /// against this exact child call. No outputID/path/UUID in model text or
    /// another call's record can be relabelled into this child's card.
    public static func accepts(
        _ output: RunOutputFile,
        runID: UUID,
        taskID: UUID,
        callID: String,
        tool: String
    ) -> Bool {
        output.runID == runID
            && output.taskID == taskID
            && output.producerCallID == callID
            && output.producerTool == tool
            && output.role == .userFile
            && output.isCanonicalForCurrentRun
            && output.hasRuntimeConsistentIdentity
    }

    private static func isUUIDJPEG(_ component: Substring) -> Bool {
        let name = String(component)
        guard name.lowercased().hasSuffix(".jpg"),
              let id = UUID(uuidString: String(name.dropLast(4))) else { return false }
        return name == id.uuidString.lowercased() + ".jpg"
    }

    private static func isUUIDPNG(_ component: Substring) -> Bool {
        let name = String(component)
        guard name.lowercased().hasSuffix(".png"),
              let id = UUID(uuidString: String(name.dropLast(4))) else { return false }
        return name == id.uuidString.lowercased() + ".png"
    }
}
