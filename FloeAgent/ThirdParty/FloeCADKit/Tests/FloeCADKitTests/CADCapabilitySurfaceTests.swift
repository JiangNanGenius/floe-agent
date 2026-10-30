// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeCAD

final class CADCapabilitySurfaceTests: XCTestCase {
    func testUnimplementedModelTargetsAreNotOfferedByCommandSearch() {
        let registry = CommandRegistry()
        for id in ["model.wrap", "model.offsetFace", "model.offsetEdge"] {
            XCTAssertNil(registry.command(id: id), "A reserved name is not an executable command")
            XCTAssertFalse(CommandRegistry.all.contains { $0.id == id })
        }
        for id in ["model.extrude", "model.revolve", "model.sweep", "model.loft", "model.deleteFace", "model.replaceFace"] {
            XCTAssertNotNil(registry.command(id: id))
        }
        XCTAssertFalse(registry.search("wrap").contains { $0.id == "model.wrap" })
    }
}
