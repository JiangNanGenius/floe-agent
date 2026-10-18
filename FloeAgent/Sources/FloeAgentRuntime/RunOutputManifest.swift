import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// Reads declared deliverables from the existing exact-run event stream.
/// This is metadata, not file authority: callers must also validate the run
/// owner and resolve the immutable snapshot with its size and digest.
public enum RunOutputManifest {
    public static func read(
        runID: UUID,
        store: any RunStore,
        includePartial: Bool = false
    ) async throws -> [ToolArtifactReference] {
        var collected: [ToolArtifactReference] = []
        var seen: [UUID: ToolArtifactReference] = [:]
        var sequence = 0
        var eventCount = 0
        var totalBytes = 0
        while true {
            try Task.checkCancellation()
            let page = try await store.events(runID: runID, afterSequence: sequence, limit: 200)
            guard !page.isEmpty else { return collected }
            for event in page {
                guard event.runID == runID, event.sequence > sequence else {
                    throw FloeError.storageCorrupted("Output event identity or order is invalid")
                }
                sequence = event.sequence
                eventCount += 1
                guard eventCount <= 100_000 else {
                    throw FloeError.validationFailed("This run has too many events to return its files")
                }
                guard event.kind == .toolResult else { continue }
                let payload = try JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))
                guard let encoded = payload["outputFilesJSON"] else { continue }
                guard payload["status"] == "ok" ||
                        (includePartial && ["failed", "cancelled"].contains(payload["status"] ?? "")) else { continue }
                guard encoded.utf8.count <= 65_536 else {
                    throw FloeError.storageCorrupted("Output file metadata exceeds its limit")
                }
                let references = try JSONDecoder().decode([ToolArtifactReference].self, from: Data(encoded.utf8))
                guard references.count <= 32 else {
                    throw FloeError.storageCorrupted("Too many output files in one event")
                }
                for reference in references {
                    try validate(reference, runID: runID)
                    if let previous = seen[reference.id] {
                        guard previous == reference else {
                            throw FloeError.storageCorrupted("Output file identity has conflicting metadata")
                        }
                        continue
                    }
                    guard collected.count < 32 else {
                        throw FloeError.storageCorrupted("Too many output files for this run")
                    }
                    totalBytes += reference.byteCount
                    guard totalBytes <= 1_024 * 1_024 * 1_024 else {
                        throw FloeError.storageCorrupted("Output files exceed the run size limit")
                    }
                    seen[reference.id] = reference
                    collected.append(reference)
                }
            }
        }
    }

    public static func validate(_ reference: ToolArtifactReference, runID: UUID) throws {
        let components = reference.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let validDigest = reference.sha256.utf8.count == 64 && reference.sha256.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
        guard components.count == 4,
              components[0] == "RunOutputs",
              components[1] == Substring(runID.uuidString),
              components[2] == Substring(reference.id.uuidString),
              !components[3].isEmpty, components[3] != ".", components[3] != "..",
              !components[3].contains("\\"), !components[3].contains("\0"),
              components[3].utf8.count <= 255,
              reference.byteCount >= 0, reference.byteCount <= 256 * 1_024 * 1_024,
              !reference.mimeType.isEmpty, reference.mimeType.utf8.count <= 128,
              validDigest else {
            throw FloeError.storageCorrupted("Output file does not belong to the requested run")
        }
    }
}
