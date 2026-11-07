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
struct StudioAudioInspectInput: Codable, Sendable {
    let assetID: MusicAssetID
    let startSeconds: Double?
    let endSeconds: Double?
    let bins: Int?
}
enum StudioMediaSourceContracts {
    static let hostToolIDs: Set<String> = ["media.import"]
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
    static func workspaceURL(_ path: String, context: ToolContext) throws -> URL {
        guard !context.temporaryReadOnly, let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("Import requires this saved task's authorized workspace.")
        }
        try context.cancellation.throwIfCancelled()
        try context.authorizeWorkspacePath(path)
        let guarder = WorkspacePathGuard(rootURL: root, maxReadBytes: 2_147_483_648)
        let url = try guarder.resolve(path), canonical = guarder.rootURL
        guard url.path.hasPrefix(canonical.path + "/") else { throw FloeError.validationFailed("Import source must stay inside this task workspace.") }
        try context.authorizeWorkspacePath(String(url.path.dropFirst(canonical.path.count + 1)))
        try guarder.assertReadableSize(url)
        return url
    }
    static func decodeAudio(_ json: String?) throws -> StudioAudioInspectInput {
        var value = try object(json ?? "{}", allowed: ["assetID", "startSeconds", "endSeconds", "bins"])
        // Both forms identify the same native ID; the read example encodes
        // the actual MusicAssetID wrapper from the saved document.
        if let raw = value["assetID"] as? String { value["assetID"] = ["rawValue": raw] }
        guard let id = value["assetID"] as? [String: Any], Set(id.keys) == ["rawValue"] else {
            throw FloeError.validationFailed("inspectAudio requires an actual assetID from this music document.")
        }
        let input = try JSONDecoder().decode(StudioAudioInspectInput.self, from: JSONSerialization.data(withJSONObject: value))
        try AudioWaveformInspector.validate(startSeconds: input.startSeconds, endSeconds: input.endSeconds, bins: input.bins)
        return input
    }
}
#endif
