// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

extension GameEditingSession {
    /// Reads a parameter document through the engine codec (if any). The
    /// session stores engine-native bytes; only the form sees JSON.
    public func parameterDocument(at path: GameRelativePath,
                                  binding: GameParameterBinding?,
                                  schema: GameParameterSchema) async throws -> ParameterDocument {
        let bytes = try await documentBytes(at: path)
        let jsonBytes = try binding.map { try $0.decodeDataToJSON(bytes) } ?? bytes
        return try ParameterDocument(bytes: jsonBytes, schema: schema)
    }

    /// Applies one parameter-form edit and writes engine-native bytes back.
    /// Unknown fields are preserved by the structural JSON edit; undo/history
    /// compare the original and re-encoded engine bytes.
    public func editParameterDocument(at path: GameRelativePath,
                                      binding: GameParameterBinding?,
                                      schema: GameParameterSchema,
                                      summary: GameEditCopy,
                                      _ mutate: (inout ParameterDocument) throws -> Void) async throws {
        try await editDocument(at: path, summary: summary) { bytes in
            let jsonBytes = try binding.map { try $0.decodeDataToJSON(bytes) } ?? bytes
            var document = try ParameterDocument(bytes: jsonBytes, schema: schema)
            try mutate(&document)
            let editedJSON = try document.serialized()
            if let binding {
                return try binding.encodeJSONToData(editedJSON)
            }
            return editedJSON
        }
    }
}
