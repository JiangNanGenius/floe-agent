import XCTest
@testable import FloeManufacturingCore

final class CuttingLawRegressionTests: XCTestCase {
    private func config() -> TurningCuttingParameters {
        .init(spindleMode:.constantSurfaceSpeed,feedMode:.mmPerRevolution,
              spindleRPM:2400,surfaceSpeedMPerMinute:60 * .pi,maxSpindleRPM:3000,feedMMPerRevolution:0.1)
    }
    private func path(_ points:[[Double]], _ kind:String = "turning-profile", feed:Double? = nil) -> ManufacturingResult.Path {
        .init(kind:kind,points:points,feedMMPerMinute:feed)
    }
    private func plan(_ points:[[Double]], settings:TurningCuttingParameters? = nil, feed:Double = 120) throws -> CuttingTimeline {
        try .plan(paths:[path(points)],turning:settings ?? config(),legacyTurningFeed:feed,maxSegments:100)
    }
    func testFixedRPMUsesLimitedSpeedToConvertPerRevolution() throws {
        var settings = config(); settings.spindleMode = .fixedRPM
        settings.maxSpindleRPM = 1200; settings.feedMMPerRevolution = 0.2
        let result = try plan([[10,0,0],[10,0,24]],settings:settings)
        XCTAssertEqual(result.totalSeconds,6,accuracy:1e-10)
        let sample = try result.sample(atSeconds:3)
        XCTAssertEqual(try XCTUnwrap(sample.rpm),1200,accuracy:1e-10)
        XCTAssertEqual(sample.feedMMPerMinute,240,accuracy:1e-10)
        XCTAssertTrue(result.segments.allSatisfy(\.spindleLimited))
    }
    func testRadiusIsConvertedToDiameterExactlyOnce() throws {
        var settings = config(); settings.maxSpindleRPM = 10000
        let result = try plan([[10,0,0],[10,0,30]],settings:settings)
        XCTAssertEqual(result.totalSeconds,6,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(result.sample(atSeconds:0).rpm),3000,accuracy:1e-10)
    }
    func testCSSCrossingCapIntegratesAndReplaysNonuniformly() throws {
        let result = try plan([[20,0,0],[0,0,0]])
        // Outer r20→10 is 3 seconds; capped r10→0 is 2 seconds.
        XCTAssertEqual(result.totalSeconds,5,accuracy:1e-10)
        let halfway = try result.sample(atSeconds:2.5)
        XCTAssertEqual(halfway.pointMM[0],sqrt(150),accuracy:1e-9)
        XCTAssertNotEqual(halfway.pointMM[0],10,accuracy:1e-6)
        XCTAssertEqual(try result.sample(atSeconds:0).pointMM,[20,0,0])
        let end = try result.sample(atSeconds:result.totalSeconds)
        XCTAssertEqual(end.pointMM,[0,0,0])
        XCTAssertEqual(try XCTUnwrap(end.rpm),3000,accuracy:1e-10)
        let roundTrip = try JSONDecoder().decode(CuttingTimeline.self,from:JSONEncoder().encode(result))
        XCTAssertEqual(try roundTrip.sample(atSeconds:2.5),halfway)
    }
    func testCSSLimitEndpointWorksInBothDirections() throws {
        XCTAssertEqual(try plan([[20,0,0],[10,0,0]]).totalSeconds,3,accuracy:1e-10)
        XCTAssertEqual(try plan([[10,0,0],[20,0,0]]).totalSeconds,3,accuracy:1e-10)
        XCTAssertEqual(try plan([[10,0,0],[0,0,0]]).totalSeconds,2,accuracy:1e-10)
        XCTAssertEqual(try plan([[0,0,0],[10,0,0]]).totalSeconds,2,accuracy:1e-10)
    }
    func testCSSStillUpdatesRPMWithPerMinuteFeed() throws {
        var settings = config(); settings.feedMode = .mmPerMinute; settings.maxSpindleRPM = 10000
        let result = try plan([[10,0,0],[20,0,0]],settings:settings)
        XCTAssertEqual(result.totalSeconds,5,accuracy:1e-10)
        let sample = try result.sample(atSeconds:2.5)
        XCTAssertEqual(sample.pointMM[0],15,accuracy:1e-9)
        XCTAssertEqual(try XCTUnwrap(sample.rpm),2000,accuracy:1e-9)
        XCTAssertEqual(sample.feedMMPerMinute,120,accuracy:1e-10)
    }
    func testMillingUsesAllThreeCoordinates() throws {
        let result = try CuttingTimeline.plan(paths:[path([[0,0,0],[3,4,0]],"milling-slot",feed:60)],
            turning:config(),legacyTurningFeed:120,maxSegments:10)
        XCTAssertEqual(result.totalDistanceMM,5,accuracy:1e-10)
        XCTAssertEqual(result.totalSeconds,5,accuracy:1e-10)
        let sample = try result.sample(atSeconds:2.5)
        XCTAssertEqual(sample.pointMM[0],1.5,accuracy:1e-9)
        XCTAssertEqual(sample.pointMM[1],2,accuracy:1e-9)
        XCTAssertNil(sample.rpm)
    }
    func testDisconnectedPathsDoNotFabricateRapidMovesOrACTime() throws {
        var settings = config(); settings.feedMode = .mmPerMinute
        let paths = [path([[10,0,0],[10,0,10]]),path([[50,0,100],[50,0,110]]),path([[0,0,0],[20,30,40]],"ac-motion")]
        let result = try CuttingTimeline.plan(paths:paths,turning:settings,legacyTurningFeed:60,maxSegments:10)
        XCTAssertEqual(result.totalSeconds,20,accuracy:1e-10)
        XCTAssertEqual(result.totalDistanceMM,20,accuracy:1e-10)
        XCTAssertEqual(result.excludedPathIndices,[2])
    }
    func testCancellationBudgetAndInvalidGeometryReject() throws {
        XCTAssertThrowsError(try CuttingTimeline.plan(paths:[path([[20,0,0],[0,0,0]])],
            turning:config(),legacyTurningFeed:120,maxSegments:1))
        XCTAssertThrowsError(try CuttingTimeline.plan(paths:[path([[10,0,0],[10,0,5]])],
            turning:config(),legacyTurningFeed:120,maxSegments:10,checkCancellation:{ throw ManufacturingError.cancelled }))
        XCTAssertThrowsError(try plan([[-10,0,0],[10,0,10]]))
        XCTAssertThrowsError(try plan([[10,1,0],[10,1,10]]))
        XCTAssertThrowsError(try plan([[10,0,0],[10,0,0]]))
    }
    func testMalformedDecodedTimelineThrowsInsteadOfIndexingMissingCoordinates() throws {
        var result = try plan([[10,0,0],[10,0,10]])
        result.segments[0].startPointMM = [10]
        let decoded = try JSONDecoder().decode(CuttingTimeline.self,from:JSONEncoder().encode(result))
        XCTAssertThrowsError(try decoded.sample(atSeconds:1))
    }
}
