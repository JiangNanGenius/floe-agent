// FloeLocalModelCatalog — structural integrity of an installed MLX snapshot.
//
// SPDX-License-Identifier: MPL-2.0
//
// An MLX container load failure hands back a generic engine error whose code
// identifies nothing (MLX.MLXError code 0 covers missing files, damaged
// weights, an unsupported architecture and a GPU allocation failure alike).
// The repair slice therefore needs a deterministic check that runs *before*
// MLX is asked to build a graph, so the two very different user situations —
// "the snapshot on disk is broken" and "the device cannot fit this model" —
// produce different errors instead of the same "code 0".
//
// This type is deliberately cheap and side-effect free: it reads each file's
// header, compares the recorded tensor extents with the real file size, and
// (when a catalog entry is supplied) compares the real size with the pinned
// artifact size. It never maps weights, never allocates the model, and never
// deletes anything. An empty problem list means "no deterministic problem was
// found", which is not a proof that a snapshot is healthy.

import Foundation

public enum LocalModelSnapshotIntegrity {
    public enum Problem: Sendable, Equatable {
        case missingArtifact(String)
        case sizeMismatch(artifact: String, expected: Int64, actual: Int64)
        case unreadable(artifact: String, detail: String)
        case truncatedHeader(artifact: String)
        case invalidHeader(artifact: String)
        case tensorOutOfBounds(artifact: String, tensor: String)
        case unsupportedModelType(String)

        /// Short, user-presentable reason. No paths beyond the artifact's
        /// relative name, no absolute sandbox locations.
        public var summary: String {
            switch self {
            case .missingArtifact(let artifact):
                return "model file is missing: \(artifact)"
            case .sizeMismatch(let artifact, let expected, let actual):
                return "model file \(artifact) has \(actual) bytes, expected \(expected) (incomplete or replaced snapshot)"
            case .unreadable(let artifact, let detail):
                return "model file \(artifact) is unreadable: \(detail)"
            case .truncatedHeader(let artifact):
                return "model file \(artifact) is truncated before its metadata"
            case .invalidHeader(let artifact):
                return "model file \(artifact) has invalid safetensors metadata"
            case .tensorOutOfBounds(let artifact, let tensor):
                return "model file \(artifact) references tensor '\(tensor)' beyond the end of the file"
            case .unsupportedModelType(let type):
                return "model config declares unsupported model_type '\(type)'"
            }
        }
    }

    /// Validates one safetensors file. Returns nil when nothing deterministic
    /// is wrong. Only a bounded header prefix is read.
    public static func safetensorsProblem(_ url: URL) -> Problem? {
        let artifact = url.lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .missingArtifact(artifact)
        }
        defer { try? handle.close() }
        let size = Int64(max(0, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else {
            return .truncatedHeader(artifact: artifact)
        }
        let headerLength = prefix.enumerated().reduce(UInt64(0)) { partial, item in
            partial | (UInt64(item.element) << UInt64(item.offset * 8))
        }
        guard headerLength > 1, headerLength <= 256 * 1024 * 1024 else {
            return .invalidHeader(artifact: artifact)
        }
        let dataStart = Int64(8) + Int64(headerLength)
        guard dataStart <= size else { return .truncatedHeader(artifact: artifact) }
        guard let header = try? handle.read(upToCount: Int(headerLength)),
              let json = try? JSONSerialization.jsonObject(with: header),
              let object = json as? [String: Any] else {
            return .invalidHeader(artifact: artifact)
        }
        for (name, value) in object where name != "__metadata__" {
            guard let tensor = value as? [String: Any],
                  let offsets = tensor["data_offsets"] as? [Any],
                  offsets.count == 2,
                  let start = (offsets[0] as? NSNumber)?.int64Value,
                  let end = (offsets[1] as? NSNumber)?.int64Value else { continue }
            guard start >= 0, end >= start, dataStart + end <= size else {
                return .tensorOutOfBounds(artifact: artifact, tensor: name)
            }
        }
        return nil
    }

    /// Deterministic problems for an installed snapshot. `entry` enables the
    /// pinned-size comparison; a nil entry still checks structure and the
    /// required `config.json` model type.
    public static func problems(directory: URL, entry: LocalModelCatalogEntry?) -> [Problem] {
        var problems: [Problem] = []
        let fileManager = FileManager.default
        if let entry {
            for artifact in entry.artifacts {
                let file = directory.appendingPathComponent(artifact.path)
                guard fileManager.fileExists(atPath: file.path) else {
                    problems.append(.missingArtifact(artifact.path))
                    continue
                }
                let actual = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if actual != artifact.byteCount {
                    problems.append(.sizeMismatch(artifact: artifact.path, expected: artifact.byteCount, actual: actual))
                    continue
                }
                if artifact.path.lowercased().hasSuffix(".safetensors"), let problem = safetensorsProblem(file) {
                    problems.append(problem)
                }
            }
        } else if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in enumerator where file.pathExtension.lowercased() == "safetensors" {
                if let problem = safetensorsProblem(file) { problems.append(problem) }
            }
        }

        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any] else {
            problems.append(.missingArtifact("config.json"))
            return problems
        }
        let supportedModelTypes: Set<String> = ["qwen3_5", "qwen3_5_moe", "gemma4", "gemma4_unified"]
        if let modelType = object["model_type"] as? String, !supportedModelTypes.contains(modelType) {
            problems.append(.unsupportedModelType(modelType))
        }
        return problems
    }
}
