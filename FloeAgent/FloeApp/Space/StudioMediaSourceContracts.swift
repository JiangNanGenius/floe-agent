// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace
import FloeMusicCore
import FloeMedia
import FloeWorkbench

struct StudioMediaImportInput: Codable, Sendable {
    struct Source: Codable, Sendable { let workspacePath: String; let expectedSHA256: String? }
    let expectedRevision: Int64
    let source: Source
}
struct StudioFrameSequenceInput: Codable, Sendable {
    let expectedRevision: Int64
    let source: StudioMediaImportInput.Source?
    var pixelProgram: StudioPixelProgram? = nil
    let width: Int
    let height: Int
    let frameRate: Int
    let frameCount: Int

    var specification: StudioFrameSequenceEncoder.Specification {
        .init(width: width, height: height, frameRate: frameRate, frameCount: frameCount,
              expectedSHA256: source?.expectedSHA256)
    }

    func sourceDigest() throws -> String {
        if let digest = source?.expectedSHA256 { return digest }
        guard let pixelProgram else { throw FloeError.validationFailed("Frame source is missing.") }
        return StudioToolOutput.hash(try StudioToolOutput.data(pixelProgram))
    }
}
struct StudioAudioInspectInput: Codable, Sendable {
    let assetID: MusicAssetID?
    let sourceID: String?
    let startSeconds: Double?
    let endSeconds: Double?
    let bins: Int?
    let offset: Int?
    let limit: Int?
    init(assetID: MusicAssetID? = nil, sourceID: String? = nil, startSeconds: Double? = nil,
         endSeconds: Double? = nil, bins: Int? = nil, offset: Int? = nil, limit: Int? = nil) {
        self.assetID = assetID; self.sourceID = sourceID; self.startSeconds = startSeconds
        self.endSeconds = endSeconds; self.bins = bins; self.offset = offset; self.limit = limit
    }
    var listsSources: Bool { assetID == nil && sourceID == nil }
}
enum StudioMediaSourceContracts {
    static let hostToolIDs: Set<String> = ["media.import"]
    static let videoHostToolIDs: Set<String> = ["media.import", "video.importFrames"]
    static let musicHostToolIDs: Set<String> = ["music.import"]
    static let pixelProgramGuide = #"pixelProgram, for example {"nodes":[{"op":"x"},{"op":"y"},{"op":"time"},{"op":"sine","inputs":[2]}],"red":0,"green":1,"blue":3}. x and y are normalized from the top-left, time is seconds, constant takes value, sine/cosine/absolute/fract take one earlier node index, and add/subtract/multiply/divide/minimum/maximum/step take two. red/green/blue are node indices and outputs are clipped to 0...1. Use up to 32 nodes and 300 million pixel-node evaluations per clip. The receipt hashes the pixel program when no source file was used."#
    private static func object(_ json: String, allowed: Set<String>) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              Set(value.keys).isSubset(of: allowed) else {
            throw FloeError.validationFailed("Use one object with the documented source fields from studio.read.")
        }
        return value
    }
    static func decodeImport(_ json: String) throws -> StudioMediaImportInput {
        var value = try object(json, allowed: ["expectedRevision", "source"])
        let revision = try StudioMediaToolContract.decode(String(decoding: JSONSerialization.data(withJSONObject:
            ["expectedRevision": value["expectedRevision"] ?? NSNull()]), as: UTF8.self))
        guard let expected = revision.expectedRevision else { throw MediaPreparedCoreError.documentChanged }
        value["expectedRevision"] = expected
        guard let source = value["source"] as? [String: Any], Set(source.keys).isSubset(of: ["workspacePath", "expectedSHA256"]) else {
            throw FloeError.validationFailed("source requires workspacePath and optional expectedSHA256. Host paths and arbitrary source tokens are not accepted.")
        }
        let input = try JSONDecoder().decode(StudioMediaImportInput.self, from: JSONSerialization.data(withJSONObject: value))
        let path = input.source.workspacePath
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("://"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw FloeError.validationFailed("workspacePath must name an explicit task-relative media file.")
        }
        if let digest = input.source.expectedSHA256 {
            guard digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw FloeError.validationFailed("expectedSHA256 must be lowercase 64-hex SHA256.") }
        }
        return input
    }
    static func decodeFrames(_ json: String) throws -> StudioFrameSequenceInput {
        var value = try object(json, allowed: ["expectedRevision", "source", "pixelProgram", "width", "height", "frameRate", "frameCount"])
        let revisionOnly = try JSONSerialization.data(withJSONObject: ["expectedRevision": value["expectedRevision"] ?? NSNull()])
        let revision = try StudioMediaToolContract.decode(String(decoding: revisionOnly, as: UTF8.self))
        guard let expected = revision.expectedRevision else { throw MediaPreparedCoreError.documentChanged }
        value["expectedRevision"] = expected
        let input = try JSONDecoder().decode(StudioFrameSequenceInput.self, from: JSONSerialization.data(withJSONObject: value))
        _ = try input.specification.validate()
        switch (input.source, input.pixelProgram) {
        case (.some, nil):
            let sourceJSON = try JSONSerialization.data(withJSONObject: ["expectedRevision": expected, "source": value["source"] ?? NSNull()])
            guard try decodeImport(String(decoding: sourceJSON, as: UTF8.self)).source.expectedSHA256 != nil else {
                throw FloeError.validationFailed("Frame input requires the task file's SHA256.")
            }
        case (nil, .some(let program)):
            try program.validate(width: input.width, height: input.height, frameCount: input.frameCount)
        default:
            throw FloeError.validationFailed("Choose one frame source: source or pixelProgram.")
        }
        return input
    }
    static func workspaceURL(_ path: String, context: ToolContext) throws -> URL {
        guard !context.temporaryReadOnly, let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("Import requires this saved task's authorized workspace.")
        }
        try context.cancellation.throwIfCancelled()
        try context.authorizeWorkspacePath(path)
        let guarder = WorkspacePathGuard(rootURL: root, maxReadBytes: 2_147_483_648), canonical = guarder.rootURL
        // Check the requested spelling before WorkspacePathGuard resolves it;
        // an in-root symlink alias must not erase the no-follow source rule.
        let original = try PersonalPreviewFile(root: canonical, url: canonical.appendingPathComponent(path), maximumBytes: 2_147_483_648)
        let url = try guarder.resolve(path)
        guard original.url == url.standardizedFileURL else { throw FloeError.validationFailed("Import source must be the original regular task file, not a link") }
        try original.validate()
        guard url.path.hasPrefix(canonical.path + "/") else { throw FloeError.validationFailed("Import source must stay inside this task workspace.") }
        try context.authorizeWorkspacePath(String(url.path.dropFirst(canonical.path.count + 1)))
        try guarder.assertReadableSize(url)
        return url
    }
    static func decodeAudio(_ json: String?) throws -> StudioAudioInspectInput {
        var value = try object(json ?? "{}", allowed: ["assetID", "sourceID", "startSeconds", "endSeconds", "bins", "offset", "limit"])
        if let raw = value["assetID"] as? String { value["assetID"] = ["rawValue": raw] }
        if let id = value["assetID"], !(id is NSNull) {
            guard let wrapped = id as? [String: Any], Set(wrapped.keys) == ["rawValue"],
                  let raw = wrapped["rawValue"] as? String, !raw.isEmpty, raw.utf8.count <= 1_024,
                  !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw FloeError.validationFailed("assetID must be the actual Music asset ID from this work. Use sourceID for other native sources.")
            }
        }
        let input = try JSONDecoder().decode(StudioAudioInspectInput.self, from: JSONSerialization.data(withJSONObject: value))
        guard input.assetID == nil || input.sourceID == nil else { throw FloeError.validationFailed("Choose sourceID or the legacy Music assetID, not both.") }
        if let sourceID = input.sourceID {
            guard sourceID.range(of: "^audio_[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw FloeError.validationFailed("sourceID must be an opaque ID returned by this work's audioSources. Host paths are not accepted.")
            }
        }
        if input.listsSources {
            guard input.startSeconds == nil, input.endSeconds == nil, input.bins == nil,
                  (0...100_000).contains(input.offset ?? 0), (1...64).contains(input.limit ?? 32) else {
                throw FloeError.validationFailed("Without a source, inspectAudio only lists sources using offset and limit (1...64). No waveform is generated.")
            }
        } else {
            guard input.offset == nil, input.limit == nil else { throw FloeError.validationFailed("offset/limit are only for listing audio sources.") }
            try AudioWaveformInspector.validate(startSeconds: input.startSeconds, endSeconds: input.endSeconds, bins: input.bins)
        }
        return input
    }
}
#endif
