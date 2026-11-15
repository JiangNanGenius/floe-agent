// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Host-owned progress storage for engines whose bridge exposes a complete JSON
/// snapshot. LOVE/RenPy expose no complete host snapshot and are rejected here;
/// their in-engine saves remain inside the engine runtime.
public actor GamePortableSaveBridge {
    public let profile: GamePortableProfile
    private let repository: FileGameSaveRepository

    public init(directory: URL, projectID: UUID, owner: GameProjectOwner,
                profile: GamePortableProfile) throws {
        guard profile.capabilities.stateSnapshot == .supported else {
            throw GamePortableError.unsupportedCapability("stateSnapshot")
        }
        guard [.rpgMakerMV].contains(profile.engine) else {
            throw GamePortableError.unsupportedCapability("engineSnapshot")
        }
        let maximum = GameWebRuntimePolicy(engine: profile.engine).maximumStateBytes
        self.profile = profile
        self.repository = try FileGameSaveRepository(directory: directory, projectID: projectID,
            owner: owner, maximumStateBytes: maximum)
    }

    public func load() async throws -> GameSaveCheckpoint? {
        try await repository.load()
    }

    public func save(_ state: Data, expectedRevision: UInt64) async throws -> GameSaveCheckpoint {
        let maximum = GameWebRuntimePolicy(engine: profile.engine).maximumStateBytes
        guard state.count <= maximum,
              (try? JSONSerialization.jsonObject(with: state)) != nil else {
            throw GamePortableError.limitExceeded("stateSnapshot")
        }
        return try await repository.save(state, expectedRevision: expectedRevision)
    }
}
