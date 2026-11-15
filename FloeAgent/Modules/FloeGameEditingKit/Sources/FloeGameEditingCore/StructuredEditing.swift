// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

extension GameEditingSession {
    /// The DTO must be encoded through the same engine adapter that decoded
    /// it. Generic editor JSON never replaces the engine's native format.
    public func editTileMapDocument(at path: GameRelativePath, binding: GameTileMapBinding?,
                                    summary: GameEditCopy,
                                    _ mutate: (inout EditableTileMap) -> Void) async throws {
        try await editDocument(at: path, summary: summary) { bytes in
            var value = try binding?.decode(bytes) ?? EditableTileMap.decode(bytes)
            mutate(&value)
            return try binding?.encode(value) ?? value.encode()
        }
    }
    public func editNarrativeDocument(at path: GameRelativePath, binding: GameNarrativeBinding?,
                                      summary: GameEditCopy,
                                      _ mutate: (inout NarrativeDocument) -> Void) async throws {
        try await editDocument(at: path, summary: summary) { bytes in
            var value = try binding?.decode(bytes) ?? NarrativeDocument.decode(bytes)
            mutate(&value)
            return try binding?.encode(value) ?? value.encode()
        }
    }
}
