import CoreLocation
import Foundation
import Testing
@testable import FloeToolboxQualification

@MainActor
private final class LocationDriverFixture: ForegroundLocationDriving {
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var locationServicesEnabled = true
    var onEvent: (@MainActor (LocationDriverEvent) -> Void)?
    var started: [UUID] = []
    var stopped: [UUID] = []
    var prompts = 0
    func requestWhenInUseAuthorization() { prompts += 1 }
    func startOneShotFix(id: UInt64) {}
    func cancelOneShotFix(id: UInt64) {}
    func prepareBackgroundActivity() -> Bool { true }
    func beginCoarseUpdates() {}
    func endCoarseUpdates() {}
    func teardownBackgroundActivity() {}
    func startForegroundUpdates(id: UUID) { started.append(id) }
    func stopForegroundUpdates(id: UUID) { stopped.append(id) }
}

@MainActor
private func makeCenter(_ driver: LocationDriverFixture) -> LocationServicesCenter {
    let center = LocationServicesCenter(driver: driver)
    center.applyBackgroundLocationInputs(supportEnabled: false, workEligible: false, fullyBackgroundScene: false)
    return center
}

@Test @MainActor func visibleOwnersShareOneStreamAndLateCallbacksCannotReviveIt() throws {
    let driver = LocationDriverFixture(), first = UUID(), second = UUID()
    let center = makeCenter(driver)
    center.beginForegroundObservation(owner: first)
    center.beginForegroundObservation(owner: second)
    #expect(driver.started.count == 1)
    let original = try #require(driver.started.first)
    let fix = SendableLocation(latitude: -33.8, longitude: 151.2, accuracy: 10, timestamp: .now)
    driver.onEvent?(.foregroundLocation(id: original, value: fix))
    #expect(center.foregroundLocation == fix && center.foregroundState == .active)
    center.endForegroundObservation(owner: first)
    #expect(driver.stopped.isEmpty)
    center.endForegroundObservation(owner: second)
    #expect(driver.stopped == [original] && center.foregroundState == .paused)
    center.beginForegroundObservation(owner: first)
    #expect(driver.started.count == 2)
    driver.onEvent?(.foregroundLocation(id: original, value: .init(latitude: 0, longitude: 0, accuracy: 1, timestamp: .now)))
    #expect(center.foregroundLocation == fix)
    center.endForegroundObservation(owner: first)
}

@Test @MainActor func backgroundAndRevokedAccessStopForegroundObservation() throws {
    let driver = LocationDriverFixture(), owner = UUID()
    let center = makeCenter(driver)
    center.beginForegroundObservation(owner: owner)
    let original = try #require(driver.started.first)
    driver.onEvent?(.foregroundLocation(id: original, value: .init(latitude: 1, longitude: 2, accuracy: 3, timestamp: .now)))
    center.applyBackgroundLocationInputs(supportEnabled: false, workEligible: false, fullyBackgroundScene: true)
    #expect(driver.stopped == [original])
    driver.onEvent?(.foregroundLocation(id: original, value: .init(latitude: 9, longitude: 8, accuracy: 3, timestamp: .now)))
    #expect(center.foregroundLocation?.latitude == 1)
    center.applyBackgroundLocationInputs(supportEnabled: false, workEligible: false, fullyBackgroundScene: false)
    #expect(driver.started.count == 2)
    driver.authorizationStatus = .denied
    driver.onEvent?(.authorizationChanged(.denied))
    #expect(center.foregroundLocation == nil && center.foregroundState == .denied)
    #expect(driver.stopped.count == 2)
    center.endForegroundObservation(owner: owner)
}

@Test @MainActor func approximatePermissionClearsPreviousPreciseFixAndInvalidFixIsIgnored() throws {
    let driver = LocationDriverFixture(), owner = UUID()
    let center = makeCenter(driver)
    center.beginForegroundObservation(owner: owner)
    let id = try #require(driver.started.first)
    driver.onEvent?(.foregroundLocation(id: id, value: .init(latitude: 1, longitude: 2, accuracy: 3, timestamp: .now)))
    driver.accuracyAuthorization = .reducedAccuracy
    center.refreshAuthorizationStatus()
    #expect(center.foregroundLocation == nil && !center.foregroundPrecise)
    driver.onEvent?(.foregroundLocation(id: id, value: .init(latitude: .nan, longitude: 2, accuracy: 3, timestamp: .now)))
    #expect(center.foregroundLocation == nil)
    driver.onEvent?(.foregroundLocation(id: id, value: .init(latitude: 1, longitude: 2, accuracy: 3, timestamp: .now.addingTimeInterval(-40))))
    #expect(center.foregroundLocation == nil)
    center.endForegroundObservation(owner: owner)
}

@Test @MainActor func observationDoesNotStartUntilPermissionAndForegroundAreAvailable() {
    let driver = LocationDriverFixture(), owner = UUID()
    driver.authorizationStatus = .notDetermined
    let center = makeCenter(driver)
    center.beginForegroundObservation(owner: owner)
    #expect(driver.started.isEmpty && driver.prompts == 1)
    driver.authorizationStatus = .authorizedWhenInUse
    driver.onEvent?(.authorizationChanged(.authorizedWhenInUse))
    #expect(driver.started.count == 1)
    center.endForegroundObservation(owner: owner)
}
