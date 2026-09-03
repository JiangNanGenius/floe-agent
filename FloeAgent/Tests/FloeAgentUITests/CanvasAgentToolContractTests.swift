#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
@testable import FloeCore

@Suite("Canvas agent tool contracts")
struct CanvasAgentToolContractTests {
    @Test("Canvas inspection serializes typed connection semantics")
    func inspectionConnectionIncludesKind() throws {
        let connection = CanvasInspectionPage.Connection(
            id: UUID(),
            sourceNodeID: UUID(),
            destinationNodeID: UUID(),
            kind: .source,
            sourcePort: .trailing,
            destinationPort: .leading,
            label: "生成输入"
        )
        let data = try JSONEncoder().encode(connection)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["kind"] as? String == CanvasConnectionKind.source.rawValue)
    }
}
#endif
