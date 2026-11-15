// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSSHostCore
import FloeGameRunKit

final class RGSSUnifiedRouteTests: XCTestCase {
    func testGuestRuntimeBecomesConcreteGuestRoute() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let base = try RGSSGuestTestSupport.temporaryDirectory("rgss-route")
        let stager = RGSSGuestRunStager(layout: try RGSSGuestRunLayout(baseDirectory: base))
        let guest = try await stager.inspect(context: context, engine: .rpgMakerXP,
                                             rootRelative: ".")
        let route = GameRunRoutePlan(
            engine: .rpgMakerXP, action: .guestRuntime,
            routeID: "guest.rgss-rpgMakerXP", entry: nil,
            prerequisites: [.guestRuntime(id: "rgss-rpgMakerXP", detail: "Tapir")],
            notes: [])
        XCTAssertEqual(RGSSUnifiedRouteMapper.map(route: route, guest: guest), .guest(guest))
    }

    func testGuestRuntimeWithoutAGuestPlanStaysUnavailable() {
        let route = GameRunRoutePlan(
            engine: .rpgMakerXP, action: .guestRuntime,
            routeID: "guest.rgss-rpgMakerXP", entry: nil,
            prerequisites: [.guestRuntime(id: "rgss-rpgMakerXP", detail: "Tapir")],
            notes: [])
        XCTAssertEqual(RGSSUnifiedRouteMapper.map(route: route, guest: nil), .unavailable(route))
    }

    func testStaticWebStaysWebEvenWhenAGuestPlanExists() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let base = try RGSSGuestTestSupport.temporaryDirectory("rgss-route")
        let stager = RGSSGuestRunStager(layout: try RGSSGuestRunLayout(baseDirectory: base))
        let guest = try await stager.inspect(context: context, engine: .rpgMakerXP,
                                             rootRelative: ".")
        let route = GameRunRoutePlan(
            engine: .phaser, action: .staticWeb, routeID: "static.phaser",
            entry: try GameRelativePath("index.html"), prerequisites: [], notes: [])
        XCTAssertEqual(RGSSUnifiedRouteMapper.map(route: route, guest: guest), .web(route))
    }
}
