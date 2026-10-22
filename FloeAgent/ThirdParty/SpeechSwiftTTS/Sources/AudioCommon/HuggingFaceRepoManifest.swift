import Foundation
import os

#if canImport(CryptoKit)
import CryptoKit
#endif

/// One file in a HuggingFace repository, as reported by the Hub tree API.
public struct RepoFile: Sendable, Equatable {
    /// Repo-relative path. May contain `/` for files inside CoreML bundle
    /// directories, e.g. `AudioEncoder.mlmodelc/coremldata.bin`.
    public let path: String

    /// Content size in bytes.
    public let size: Int64

    /// SHA-256 of the file *content*, present for LFS-backed files.
    ///
    /// `nil` for files stored as plain git blobs. Those carry an `oid` too,
    /// but it is a git blob hash (`sha1("blob <len>\0" + content)`), not a
    /// hash of the content alone, so it cannot be compared against a digest
    /// of the bytes we wrote. Plain blobs are configs and tokenizers — small
    /// enough that a size check is adequate — while every multi-GB weight
    /// file is LFS-backed and does get verified.
    public let sha256: String?

    public init(path: String, size: Int64, sha256: String?) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// The file listing of a repository at a given revision.
///
/// Resolving a whole repo in one request replaces the previous per-file `HEAD`
/// fan-out (plus a `Range: bytes=0-0` probe whenever Xet-backed storage omitted
/// `Content-Length`). It also supplies sizes without callers hand-maintaining
/// `expectedSizes` tables that go stale on re-export.
public struct RepoManifest: Sendable {
    public let modelId: String
    public let revision: String
    public let files: [RepoFile]

    public init(modelId: String, revision: String, files: [RepoFile]) {
        self.modelId = modelId
        self.revision = revision
        self.files = files
    }

    /// Files matching any of `globs`.
    ///
    /// Uses `fnmatch` with no flags, which is exactly what `HubApi.snapshot`
    /// does internally. In particular `FNM_PATHNAME` is *not* set, so `*`
    /// crosses `/` — that is what makes `encoder.mlmodelc/**` select a whole
    /// CoreML bundle and `*.safetensors` select shards in subdirectories.
    /// Matching identical semantics is what lets the download path change
    /// underneath 30-odd callers without changing which files they get.
    public func matching(globs: [String]) -> [RepoFile] {
        guard !globs.isEmpty else { return files }
        return files.filter { file in
            globs.contains { glob in fnmatch(glob, file.path, 0) == 0 }
        }
    }

    public func file(at path: String) -> RepoFile? {
        files.first { $0.path == path }
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}

extension HuggingFaceDownloader {

    // MARK: - Manifest

    /// Fetch the file listing for `modelId`, following pagination.
    ///
    /// `?recursive=true` returns files inside directories (CoreML bundles are
    /// directories of files), and `?expand=true` adds the `lfs` object that
    /// carries the content SHA-256.
    public static func fetchManifest(
        modelId: String,
        revision: String = "main"
    ) async throws -> RepoManifest {
        let endpoint = (resolvedEndpoint() ?? "https://huggingface.co")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let escapedRevision = revision.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? revision
        guard var next = URL(
            string: "\(endpoint)/api/models/\(modelId)/tree/\(escapedRevision)"
                + "?recursive=true&expand=true")
        else {
            throw DownloadError.failedToDownload("\(modelId): invalid tree URL")
        }

        var files: [RepoFile] = []
        var seen = Set<String>()
        // The API pages via a cursor in a `Link` header. Bound the walk so a
        // malformed or self-referential `next` link can't spin forever.
        for _ in 0..<maxManifestPages {
            let request = makeHubRequest(url: next, timeout: 30)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DownloadError.failedToDownload(
                    "\(modelId): missing HTTP response for tree listing")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DownloadError.failedToDownload(
                    "\(modelId): tree listing HTTP \(http.statusCode)")
            }

            for file in try parseTreePage(data, modelId: modelId)
            where seen.insert(file.path).inserted {
                files.append(file)
            }

            guard let link = headerString(http, "Link"),
                  let following = nextPageURL(fromLinkHeader: link)
            else {
                return RepoManifest(modelId: modelId, revision: revision, files: files)
            }
            next = following
        }

        throw DownloadError.failedToDownload(
            "\(modelId): tree listing exceeded \(maxManifestPages) pages")
    }

    /// Upper bound on tree-listing pages. The API returns 1000 entries per page
    /// by default; no repository here is within two orders of magnitude of the
    /// resulting cap, so hitting this means something is wrong, not large.
    static let maxManifestPages = 64

    /// Parse one page of `/api/models/{id}/tree/{rev}`.
    ///
    /// Directory entries are dropped — `recursive=true` lists both the
    /// directories and the files inside them, and only the files are
    /// downloadable.
    static func parseTreePage(_ data: Data, modelId: String) throws -> [RepoFile] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.failedToDownload("\(modelId): malformed tree listing")
        }
        return entries.compactMap { entry in
            guard (entry["type"] as? String) == "file",
                  let path = entry["path"] as? String,
                  !path.isEmpty
            else { return nil }

            let lfs = entry["lfs"] as? [String: Any]
            // For LFS files the authoritative content size lives on the `lfs`
            // object; the outer `size` agrees in practice but the LFS pointer
            // is what the CDN actually serves.
            let size = (lfs?["size"] as? NSNumber)?.int64Value
                ?? (entry["size"] as? NSNumber)?.int64Value
                ?? 0
            let sha256 = (lfs?["oid"] as? String).flatMap { oid -> String? in
                let trimmed = oid.hasPrefix("sha256:") ? String(oid.dropFirst(7)) : oid
                return trimmed.count == 64 ? trimmed.lowercased() : nil
            }
            return RepoFile(path: path, size: size, sha256: sha256)
        }
    }

    /// Extract the `rel="next"` URL from a `Link` header.
    static func nextPageURL(fromLinkHeader header: String) -> URL? {
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";")
            guard segments.count >= 2 else { continue }
            let isNext = segments.dropFirst().contains { segment in
                let value = segment.trimmingCharacters(in: .whitespaces)
                return value == "rel=\"next\"" || value == "rel=next"
            }
            guard isNext else { continue }
            let raw = segments[0].trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("<"), raw.hasSuffix(">") else { continue }
            return URL(string: String(raw.dropFirst().dropLast()))
        }
        return nil
    }

    static func headerString(_ response: HTTPURLResponse, _ key: String) -> String? {
        for (rawKey, rawValue) in response.allHeaderFields
        where String(describing: rawKey).caseInsensitiveCompare(key) == .orderedSame {
            return String(describing: rawValue)
        }
        return nil
    }

    // MARK: - Weight selection

    static let safetensorsIndexName = "model.safetensors.index.json"

    /// Narrow a selection to the shards a sharded bundle actually uses.
    ///
    /// A `*.safetensors` glob is wrong for repositories that publish both
    /// layouts. `aufklarer/VoxCPM2-MLX-bf16` ships `model-00001` + `model-00002`
    /// (4.96 GB together, the pair named by the index) *and* a consolidated
    /// `model.safetensors` holding the same tensors, so globbing fetches
    /// 9.9 GB to load 4.96 GB of it.
    ///
    /// When an index is present its `weight_map` is authoritative: those are
    /// the files the loader will open. Any other `.safetensors` in the
    /// selection is a redundant copy and is dropped. Non-weight files pass
    /// through untouched, and a repo without an index is left alone.
    static func applyingShardIndex(
        to selection: [RepoFile],
        indexData: Data
    ) -> [RepoFile] {
        guard let json = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String]
        else { return selection }

        let shards = Set(weightMap.values)
        guard !shards.isEmpty else { return selection }

        return selection.filter { file in
            guard file.path.hasSuffix(".safetensors") else { return true }
            return shards.contains(file.path)
        }
    }

    static let consolidatedWeightsName = "model.safetensors"

    /// Delete a consolidated weights file left behind by an earlier over-fetch.
    ///
    /// Selecting weights from the shard index stops *new* caches acquiring the
    /// duplicate, but does nothing for caches that already have it — and the
    /// cost there is not just disk. `CommonWeightLoader.loadAllSafetensors`
    /// merges every `.safetensors` in the directory, so a cache holding both
    /// the shards and the consolidated copy reads and allocates the same
    /// tensors twice on every load.
    ///
    /// The check is deliberately narrow, because "delete weight files the index
    /// doesn't name" would be wrong: repositories legitimately ship extra
    /// weights beside a sharded model — Fish Audio's `codec.safetensors` sits
    /// next to an index naming only the model shards, and removing it would
    /// break loading. So only the exact name `model.safetensors` is ever
    /// considered, only when the index omits it, only when at least one shard
    /// is actually present, and only once its header proves every tensor it
    /// holds is also named by the index. Anything unproven is left alone.
    static func removeRedundantConsolidatedWeights(in directory: URL, indexData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String]
        else { return }

        let shards = Set(weightMap.values)
        guard !shards.isEmpty, !shards.contains(consolidatedWeightsName) else { return }

        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(consolidatedWeightsName)
        guard fm.fileExists(atPath: candidate.path) else { return }

        // Never remove the only weights present.
        guard shards.allSatisfy({ fm.fileExists(atPath: directory.appendingPathComponent($0).path) })
        else { return }

        guard let tensors = safetensorsTensorNames(at: candidate),
              !tensors.isEmpty,
              tensors.isSubset(of: Set(weightMap.keys))
        else {
            AudioLog.download.debug(
                "Leaving \(consolidatedWeightsName) in \(directory.path): not provably redundant")
            return
        }

        do {
            try fm.removeItem(at: candidate)
            AudioLog.download.notice(
                "Removed redundant \(consolidatedWeightsName, privacy: .public) from \(directory.path, privacy: .public): its tensors are all supplied by the indexed shards")
        } catch {
            AudioLog.download.debug("Could not remove \(candidate.path): \(error)")
        }
    }

    /// Tensor names declared in a safetensors header, or `nil` if unreadable.
    ///
    /// The format is a little-endian `UInt64` header length followed by that
    /// many bytes of JSON mapping tensor name to dtype/shape/offsets, so the
    /// names can be read without touching the tensor data.
    static func safetensorsTensorNames(at url: URL) -> Set<String>? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let lengthBytes = try? handle.read(upToCount: 8), lengthBytes.count == 8 else {
            return nil
        }
        let headerLength = UInt64(littleEndian: lengthBytes.withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        })
        guard headerLength > 0, headerLength <= maxSafetensorsHeaderBytes else { return nil }

        guard let headerBytes = try? handle.read(upToCount: Int(headerLength)),
              headerBytes.count == Int(headerLength),
              let header = try? JSONSerialization.jsonObject(with: headerBytes) as? [String: Any]
        else { return nil }

        return Set(header.keys.filter { $0 != "__metadata__" })
    }

    /// Sanity bound on the header length read from an untrusted file, so a
    /// corrupt value can't make us allocate arbitrarily.
    static let maxSafetensorsHeaderBytes: UInt64 = 128 * 1_024 * 1_024

    /// Fetch and parse the shard index, returning `nil` when the repo has none
    /// or it can't be read. A missing index is the normal single-file case, not
    /// an error.
    static func fetchShardIndex(
        modelId: String,
        manifest: RepoManifest
    ) async -> Data? {
        guard manifest.file(at: safetensorsIndexName) != nil else { return nil }
        guard let url = try? resolveURL(modelId: modelId, file: safetensorsIndexName) else {
            return nil
        }
        let request = makeHubRequest(url: url, timeout: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            AudioLog.download.debug("Could not fetch shard index for \(modelId)")
            return nil
        }
        return data
    }

    // MARK: - Integrity

    /// Streaming SHA-256 of a file, or `nil` if it can't be read.
    ///
    /// Read in bounded chunks so hashing a multi-GB shard does not pull it
    /// into memory.
    static func fileSHA256(at url: URL) -> String? {
        #if canImport(CryptoKit)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: shaChunkBytes), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    static let shaChunkBytes = 4 * 1_024 * 1_024

    /// SHA-256 of an in-memory buffer, in the lowercase hex form the Hub
    /// publishes. Used as the reference in tests for the streaming hash.
    static func sha256Hex(of data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}
