import Foundation
import Testing
@testable import FloeToolboxWorkbenches

#if os(iOS)
@MainActor
struct EnvironmentalServiceTests {
    @Test func pressureHistoryKeepsItsClockAcrossStreamRestarts() {
        let service = ToolboxPressureService()
        service.accept(sample(time: 100, altitude: 0))
        service.accept(sample(time: 102, altitude: 1))
        service.pause()
        service.accept(sample(time: 120, altitude: 0))
        service.accept(sample(time: 121, altitude: 0.5))
        #expect(service.history.values.map(\.timestamp) == [0, 2, 20, 21])
        #expect(service.makeCSV().contains("20.000,"))
    }

    @Test func clearingPressureHistoryStartsANewClockWithoutMovingTheAltitudeReference() {
        let service = ToolboxPressureService()
        service.accept(sample(time: 100, altitude: 0))
        service.accept(sample(time: 102, altitude: 4))
        let baseline = service.zeroBaseline
        service.resetHistory()
        service.accept(sample(time: 110, altitude: 5))
        service.accept(sample(time: 111, altitude: 6))
        #expect(service.history.values.map(\.timestamp) == [0, 1])
        #expect(service.zeroBaseline == baseline)
        #expect(service.displayedAltitude == 6)
    }

    private func sample(time: TimeInterval, altitude: Double) -> ToolboxPressureSample {
        .init(timestamp: time, receivedAt: Date(timeIntervalSince1970: time),
              pressureHpa: 1013, relativeAltitude: altitude)
    }
}
#endif
