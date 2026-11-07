// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct HeavyEditorCommandRequest: Identifiable, Sendable {
  public let id = UUID()
  public let command: String
  public let arguments: EditorJSON
  public let baseRevision: UInt64
}
public struct HeavyEditorResultRequest: Identifiable, Sendable {
  public let id = UUID()
  public let title: String
  public let value: EditorJSON
}
public enum HeavyEditorNativeModal: Identifiable, Sendable {
  case command(HeavyEditorCommandRequest)
  case result(HeavyEditorResultRequest)
  public var id: UUID {
    switch self {
    case .command(let value): value.id
    case .result(let value): value.id
    }
  }
}

extension EditorJSON {
  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
  public var object: [String: EditorJSON] {
    if case .object(let value) = self { return value }
    return [:]
  }
}
