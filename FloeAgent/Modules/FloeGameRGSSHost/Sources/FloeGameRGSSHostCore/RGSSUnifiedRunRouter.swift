// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameIDEBridge
import FloeGameRGSS
import FloeGameRunKit
import FloeGameWebKit

/// The product route for one engine/root. Web and guest are both concrete
/// values; `.unavailable` preserves the existing route plan for diagnostics.
public enum RGSSUnifiedRunRoute: Sendable, Equatable {
    case web(GameRunRoutePlan)
    case guest(RGSSGuestRoutePlan)
    case unavailable(GameRunRoutePlan)

    public var isGuest: Bool {
        if case .guest = self { return true }
        return false
    }
}

/// Pure decision mapping used by the router and its regression tests.
public enum RGSSUnifiedRouteMapper {
    public static func map(route: GameRunRoutePlan,
                           guest: RGSSGuestRoutePlan?) -> RGSSUnifiedRunRoute {
        switch route.action {
        case .guestRuntime:
            guard let guest else { return .unavailable(route) }
            return .guest(guest)
        case .unavailable:
            return .unavailable(route)
        default:
            return .web(route)
        }
    }
}

/// Unified route over the existing `GameUnifiedRunPreparer`. It adds the only
/// missing product decision: XP/VX/VX Ace are returned as concrete guest plans
/// instead of the preparer's deliberate `guestRuntimeRequired` failure. Web
/// preparation remains the existing preparer and player.
public actor RGSSUnifiedRunRouter {
    public let preparer: GameUnifiedRunPreparer
    public let stager: RGSSGuestRunStager

    public init(preparer: GameUnifiedRunPreparer, stager: RGSSGuestRunStager) {
        self.preparer = preparer
        self.stager = stager
    }

    /// Route one existing IDE/Space run request. The selection is scoped by
    /// the request's captured project/owner/revision and its explicit nested
    /// root; it never falls back to a global current project.
    public func plan(_ request: GameIDEProjectRunRequest,
                     engineOverride: Bool = false) async throws -> RGSSUnifiedRunRoute {
        let selection = try GameRunSelection(
            context: request.context, root: request.gameRoot?.value ?? ".")
        return try await plan(context: request.context, engine: request.engine,
                              rootRelative: selection.root,
                              engineOverride: engineOverride)
    }

    public func plan(context: GameProjectContext, engine: GameEngineID,
                     rootRelative: String,
                     engineOverride: Bool = false) async throws -> RGSSUnifiedRunRoute {
        let selection = try GameRunSelection(context: context, root: rootRelative)
        let route = try await preparer.plan(context: context, engine: engine,
                                            selection: selection)
        guard RGSSEngineProfiles.isRGSS(engine) else {
            return RGSSUnifiedRouteMapper.map(route: route, guest: nil)
        }
        switch route.action {
        case .guestRuntime:
            let guest = try await stager.inspect(
                context: context, engine: engine, rootRelative: rootRelative,
                engineOverride: engineOverride)
            return .guest(guest)
        case .unavailable:
            return .unavailable(route)
        default:
            return .web(route)
        }
    }

    /// Web only. A caller that received `.guest` must create an
    /// `RGSSGuestPlaySession`; this method never fakes a Web artifact for RGSS.
    public func prepareWeb(_ request: GameWebRunRequest,
                           selection: GameRunSelection?) async throws -> GamePreparedWebRun {
        guard !RGSSEngineProfiles.isRGSS(request.engine) else {
            throw RGSSGuestRunError.invalidRequest(
                "RPG Maker XP/VX/VX Ace use the guest runtime route, not a Web artifact")
        }
        return try await preparer.prepare(request, selection: selection)
    }

    public func cancelWeb(_ request: GameWebRunRequest) async {
        await preparer.cancel(request)
    }

    /// Builds the exact run request from an IDE dispatch after the App has
    /// attached the existing local display and obtained its generation ID.
    public func makeGuestRequest(_ request: GameIDEProjectRunRequest,
                                 displayServiceID: String,
                                 engineOverride: Bool = false) throws -> RGSSGuestRunRequest {
        try RGSSGuestRunRequest(ideRequest: request,
                                displayServiceID: displayServiceID,
                                engineOverride: engineOverride)
    }
}
