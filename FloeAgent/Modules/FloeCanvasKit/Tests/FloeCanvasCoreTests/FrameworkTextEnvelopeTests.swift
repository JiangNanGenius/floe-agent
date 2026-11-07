import XCTest
@testable import FloeCanvasCore

final class FrameworkTextEnvelopeTests: XCTestCase {
    func testBodyEditKeepsUnknownFieldsAndNativeAssetsVerbatim() throws {
        let payload = try JSONFidelity.parse(Data(#"{"kind":"scene3D","text":"before","asset":{"contentHash":"original"},"scene3D":{"futureGeometry":[1,2,3]},"future":{"precise":900719925474099312345}}"#.utf8))
        let node = CanvasNodeSnapshot(content: .unknown(kind: "floe.framework.node", payload: payload),
            frame: .init(center: .zero, size: .init(width: 300, height: 200)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "Native", pages: [page])
        let edit = CanvasEditBatch(pageID: page.id, scope: .selectedNodes([node.id]),
            operations: [.updateContent(nodeID: node.id, content: .text("after"))])
        let result = try CanvasEditEngine.apply(edit, to: snapshot).snapshot
        guard case .object(var expected) = payload else { return XCTFail("Object fixture") }
        expected["text"] = .string("after")
        XCTAssertEqual(result.pages[0].nodes[0].content, .unknown(kind: "floe.framework.node", payload: .object(expected)))
        let denied = CanvasEditBatch(pageID: page.id, scope: .selectedNodes([]), operations: edit.operations)
        XCTAssertThrowsError(try CanvasEditEngine.apply(denied, to: snapshot))
        var locked = snapshot
        locked.pages[0].nodes[0].isLocked = true
        XCTAssertThrowsError(try CanvasEditEngine.apply(edit, to: locked))
    }
}
