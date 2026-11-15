// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct RGSSSaveStats: Codable, Equatable, Sendable {
    public let frames: Int
    public init(frames: Int) { self.frames = max(0, frames) }
}

public struct RGSSSaveFile: Codable, Equatable, Sendable {
    public let name: String
    public let bytes: Int
    public let data: String
    public let sha256: String?

    public init(name: String, bytes: Int, data: String, sha256: String? = nil) {
        self.name = name; self.bytes = bytes; self.data = data; self.sha256 = sha256
    }
}

/// Virtual RGSS save-file preservation. This captures the game's Save*.rxdata
/// files, not a live emulator/VM snapshot and not arbitrary game state.
public struct RGSSSaveEnvelope: Codable, Equatable, Sendable {
    public static let format = "floe-rgss-saves"
    public static let version = 1

    public let format: String
    public let version: Int
    public let engine: GameEngineID
    public let files: [RGSSSaveFile]
    public let truncated: Bool
    public let stats: RGSSSaveStats?

    public init(format: String = RGSSSaveEnvelope.format, version: Int = RGSSSaveEnvelope.version,
                engine: GameEngineID, files: [RGSSSaveFile], truncated: Bool = false,
                stats: RGSSSaveStats? = nil) {
        self.format = format
        self.version = version
        self.engine = engine
        self.files = files
        self.truncated = truncated
        self.stats = stats
    }

    public static func decode(_ data: Data, expectedEngine: GameEngineID? = nil,
                              maximumBytes: Int = RGSSWebRuntimeRequirements.stateLimitBytes) throws -> RGSSSaveEnvelope {
        guard data.count <= maximumBytes else {
            throw RGSSRuntimeError.saveStateTooLarge(expected: maximumBytes, actual: data.count)
        }
        let value: RGSSSaveEnvelope
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RGSSRuntimeError.invalidSaveState("JSON decode failed") }
        try value.validate(maximumBytes: maximumBytes)
        if let expectedEngine, value.engine != expectedEngine {
            throw RGSSRuntimeError.invalidSaveState("engine mismatch")
        }
        return value
    }

    public func validate(maximumBytes: Int = RGSSWebRuntimeRequirements.stateLimitBytes) throws {
        guard format == Self.format, version == Self.version else {
            throw RGSSRuntimeError.invalidSaveState("unsupported format/version")
        }
        guard RGSSEngineProfiles.isRGSS(engine) else {
            throw RGSSRuntimeError.invalidSaveState("not an RGSS engine")
        }
        guard files.count <= 40 else { throw RGSSRuntimeError.invalidSaveState("too many save files") }
        var names = Set<String>()
        var total = 0
        for file in files {
            guard file.name.range(of: #"^Save[^/\\]*\.(rxdata|rvdata|rvdata2)$"#,
                                  options: [.regularExpression, .caseInsensitive]) != nil,
                  file.name.utf8.count <= 128,
                  !file.name.contains(".."), names.insert(file.name.lowercased()).inserted else {
                throw RGSSRuntimeError.invalidSaveState("unsafe or duplicate save name")
            }
            guard file.bytes >= 0, file.bytes <= RGSSWebRuntimeRequirements.maximumSaveBinaryBytes,
                  let decoded = Data(base64Encoded: file.data, options: []) else {
                throw RGSSRuntimeError.invalidSaveState("invalid save payload")
            }
            guard decoded.count == file.bytes else {
                throw RGSSRuntimeError.invalidSaveState("save byte count mismatch")
            }
            if let digest = file.sha256,
               digest != RGSSRuntimePack.digest(decoded) {
                throw RGSSRuntimeError.invalidSaveState("save digest mismatch")
            }
            total += decoded.count
            guard total <= RGSSWebRuntimeRequirements.maximumSaveBinaryBytes else {
                throw RGSSRuntimeError.saveStateTooLarge(expected: RGSSWebRuntimeRequirements.maximumSaveBinaryBytes, actual: total)
            }
        }
        let encodedCount = (try? JSONEncoder().encode(self).count) ?? (maximumBytes + 1)
        guard encodedCount <= maximumBytes else {
            throw RGSSRuntimeError.saveStateTooLarge(expected: maximumBytes, actual: encodedCount)
        }
    }

    public func fileBytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in files {
            guard let bytes = Data(base64Encoded: file.data, options: []) else {
                throw RGSSRuntimeError.invalidSaveState("invalid save payload")
            }
            result[file.name] = bytes
        }
        return result
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Existing bounded/CAS save service, scoped to the explicit project and owner.
/// It stores the virtual save envelope only; source revisions are separate.
public actor RGSSProgressRepository {
    private let store: FileGameSaveRepository

    public init(directory: URL, projectID: UUID, owner: GameProjectOwner) throws {
        store = try FileGameSaveRepository(directory: directory, projectID: projectID,
                                           owner: owner,
                                           maximumStateBytes: RGSSWebRuntimeRequirements.stateLimitBytes)
    }

    public func load() async throws -> (envelope: RGSSSaveEnvelope, revision: UInt64)? {
        guard let checkpoint = try await store.load() else { return nil }
        let envelope = try RGSSSaveEnvelope.decode(checkpoint.state)
        return (envelope, checkpoint.revision)
    }

    public func save(_ envelope: RGSSSaveEnvelope, expectedRevision: UInt64) async throws -> UInt64 {
        let data = try envelope.encoded()
        let checkpoint = try await store.save(data, expectedRevision: expectedRevision)
        return checkpoint.revision
    }
}
