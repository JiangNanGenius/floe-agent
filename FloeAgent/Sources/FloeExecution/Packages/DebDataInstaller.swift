// FloeExecution — Data-only .deb extraction.
// Extracts the data.tar payload of a Debian package into a destination
// directory after rejecting any payload that contains native executables.
// Maintenance scripts are never executed; iOS has no dpkg and no root.
// Decompression uses the bundled CPython (tarfile/gzip/lzma/zstandard)
// through the same in-process interpreter as exec.localPython.

import Foundation
import FloeCore
import FloeTools

public struct DebDataInstaller: Sendable {
    public struct Result: Sendable {
        public var packageName: String?
        public var packageVersion: String?
        public var fileCount: Int
        public var skippedEntries: Int
    }

    public enum ExtractionError: Error, CustomStringConvertible {
        case nativePayload
        case unsupportedCompression(String)
        case unsafePath(String)
        case limitsExceeded(String)

        public var description: String {
            switch self {
            case .nativePayload:
                return "This .deb contains native executables. iOS cannot run them; use an approved remote host instead."
            case .unsupportedCompression(let detail):
                return "Unsupported data payload compression: \(detail)"
            case .unsafePath(let path):
                return "Unsafe path in archive: \(path)"
            case .limitsExceeded(let detail):
                return "Archive limits exceeded: \(detail)"
            }
        }
    }

    private let python: LocalPythonService
    private let maximumEntries = 5_000
    private let maximumExpandedBytes = 256 * 1024 * 1024

    public init(python: LocalPythonService) {
        self.python = python
    }

    /// Extracts `debURL` into `destinationDirectory` (workspace-relative
    /// resolution is the caller's responsibility). Throws `ExtractionError`
    /// on native payloads or unsafe archives.
    @discardableResult
    public func extract(
        debURL: URL,
        destinationDirectory: URL,
        cancellation: CancellationToken?
    ) async throws -> Result {
        let attributes = try FileManager.default.attributesOfItem(atPath: debURL.path)
        guard ((attributes[.size] as? NSNumber)?.int64Value ?? Int64.max) <= 64 * 1024 * 1024 else {
            throw ExtractionError.limitsExceeded("archive exceeds 64 MiB")
        }
        let data = try Data(floeContentsOf: debURL)
        let members = try ArArchiveReader.read(data)
        guard !ArArchiveReader.containsNativeExecutable(members) else {
            throw ExtractionError.nativePayload
        }
        guard let dataMember = members.first(where: { $0.name.hasPrefix("data.tar") }) else {
            throw ExtractionError.unsupportedCompression("no data.tar member found")
        }
        _ = members.first(where: { $0.name.hasPrefix("control.tar") })
        guard let url = Bundle.module.url(forResource: "deb_extract", withExtension: "py") else {
            throw FloeError.invalidConfiguration("Missing Debian extraction resource")
        }
        let script = try String(contentsOf: url, encoding: .utf8)
        let input: [String: Any] = [
            "payloadBase64": dataMember.data.base64EncodedString(),
            "name": dataMember.name,
            "destination": destinationDirectory.path,
            "maxEntries": maximumEntries,
            "maxExpandedBytes": maximumExpandedBytes,
            "skipLinks": true
        ]
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let request = ScriptExecutionRequest(script: script, inputJSON: inputJSON, timeout: 60, maxOutputBytes: 64 * 1024)
        let outcome = await python.run(request, cancellation: cancellation)
        switch outcome {
        case .ok(_, let stdout, let stderr, _, _, _):
            let parsed = Self.parse(stdout)
            if let error = parsed.error { throw ExtractionError.unsafePath(error) }
            return Result(
                packageName: parsed.packageName,
                packageVersion: parsed.packageVersion,
                fileCount: parsed.fileCount,
                skippedEntries: parsed.skippedEntries
            )
        case .jsException(let message, _):
            if message.contains("native") { throw ExtractionError.nativePayload }
            throw ExtractionError.unsupportedCompression(message)
        case .timedOut:
            throw ExtractionError.limitsExceeded("extraction timed out")
        case .cancelled:
            throw FloeError.cancelled
        }
    }

    private struct Parsed {
        var packageName: String?
        var packageVersion: String?
        var fileCount: Int = 0
        var skippedEntries: Int = 0
        var error: String?
    }

    private static func parse(_ stdout: String) -> Parsed {
        var parsed = Parsed()
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "package": parsed.packageName = parts[1]
            case "version": parsed.packageVersion = parts[1]
            case "files": parsed.fileCount = Int(parts[1]) ?? 0
            case "skipped": parsed.skippedEntries = Int(parts[1]) ?? 0
            case "error": parsed.error = parts[1]
            default: break
            }
        }
        return parsed
    }

}
