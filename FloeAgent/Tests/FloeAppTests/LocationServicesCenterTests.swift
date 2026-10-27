// FloeAppTests — LocationServicesCenter behavior.
//
// A controllable driver stands in for Core Location: no real permission sheet,
// GPS, background session or Simulator TCC is touched. The tests exercise the
// actual production service decisions (authorization wait, request identity,
// timeout, cancellation, background assist lifecycle) and the real
// `apple.location.current` tool seam.
//
// The suite is serialized because the tool-seam cases temporarily swap the
// shared service through `setSharedForTesting`; Swift Testing can interleave
// otherwise-independent async tests even on the main actor.

#if canImport(UIKit) && canImport(CoreLocation)
import CoreLocation
import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeApp

@MainActor
private final class FakeLocationDriver: LocationServiceDriving {
    private var storedAuthorizationStatus: CLAuthorizationStatus
    private var storedLocationServicesEnabled = true
    var onEvent: (@MainActor (LocationDriverEvent) -> Void)?

    /// Counts real "system reads". The shared production service must not
    /// consult CoreLocation during construction or an idle, no-work reconcile.
    private(set) var authorizationStatusReadCount = 0
    private(set) var locationServicesEnabledReadCount = 0

    var authorizationStatus: CLAuthorizationStatus {
        get {
            authorizationStatusReadCount += 1
            return storedAuthorizationStatus
        }
        set { storedAuthorizationStatus = newValue }
    }

    var locationServicesEnabled: Bool {
        get {
            locationServicesEnabledReadCount += 1
            return storedLocationServicesEnabled
        }
        set { storedLocationServicesEnabled = newValue }
    }

    private(set) var authorizationRequestCount = 0
    private(set) var startedFixIDs: [UInt64] = []
    private(set) var cancelledFixIDs: [UInt64] = []
    /// Models the real request-scoped manager: once a fix delivered, a late
    /// cancel is a no-op and is not counted as a cancellation of live work.
    private var liveFixIDs: Set<UInt64> = []
    private(set) var prepareCount = 0
    private(set) var beginUpdatesCount = 0
    private(set) var endUpdatesCount = 0
    private(set) var teardownCount = 0
    var prepareSucceeds = true

    init(status: CLAuthorizationStatus) {
        storedAuthorizationStatus = status
    }

    func requestWhenInUseAuthorization() {
        authorizationRequestCount += 1
    }

    func startOneShotFix(id: UInt64) {
        startedFixIDs.append(id)
        liveFixIDs.insert(id)
    }

    func cancelOneShotFix(id: UInt64) {
        guard liveFixIDs.remove(id) != nil else { return }
        cancelledFixIDs.append(id)
    }

    func prepareBackgroundActivity() -> Bool {
        prepareCount += 1
        return prepareSucceeds
    }

    func beginCoarseUpdates() { beginUpdatesCount += 1 }
    func endCoarseUpdates() { endUpdatesCount += 1 }
    func teardownBackgroundActivity() { teardownCount += 1 }

    // MARK: - Test controls

    func deliverAuthorization(_ status: CLAuthorizationStatus) {
        storedAuthorizationStatus = status
        onEvent?(.authorizationChanged(status))
    }

    func deliverFix(id: UInt64, location: SendableLocation) {
        // A real delegate only fires once; the id leaves the live set either
        // way so a later cancel is correctly a no-op.
        liveFixIDs.remove(id)
        onEvent?(.oneShotResult(id: id, result: .success(location)))
    }

    func failFix(id: UInt64) {
        liveFixIDs.remove(id)
        onEvent?(.oneShotResult(id: id, result: .failure(.unavailable("no fix"))))
    }

    func failUpdates() {
        onEvent?(.coarseUpdatesFailed)
    }
}

@Suite("FloeApp.LocationServicesCenter", .serialized)
@MainActor
struct LocationServicesCenterTests {
    private func makeService(
        status: CLAuthorizationStatus,
        fixTimeout: TimeInterval = 15,
        authorizationWaitTimeout: TimeInterval = 10
    ) -> (LocationServicesCenter, FakeLocationDriver) {
        let driver = FakeLocationDriver(status: status)
        let service = LocationServicesCenter(
            driver: driver,
            fixTimeout: fixTimeout,
            authorizationWaitTimeout: authorizationWaitTimeout
        )
        // The service starts without touching CoreLocation; the status read is
        // what a real first-rendered launch / Settings open performs.
        service.refreshAuthorizationStatus()
        return (service, driver)
    }

    /// Bounded wait for a cooperatively scheduled state change; never a fixed
    /// guess about how many run-loop turns an await needs.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A real scene reported foreground, so the system sheet may be shown.
    private func enterForeground(_ service: LocationServicesCenter) {
        service.applyBackgroundLocationInputs(
            supportEnabled: false, workEligible: false, fullyBackgroundScene: false
        )
    }

    private func sample(
        latitude: Double = -33.86,
        longitude: Double = 151.20,
        accuracy: Double = 65,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SendableLocation {
        SendableLocation(
            latitude: latitude,
            longitude: longitude,
            accuracy: accuracy,
            timestamp: timestamp
        )
    }

    @Test("Continuous location waits through an unknown fix but stops on denied access")
    func continuousFailureClassification() {
        #expect(!CoreLocationDriver.shouldStopCoarseUpdates(after:
            NSError(domain: kCLErrorDomain, code: CLError.Code.locationUnknown.rawValue)))
        #expect(CoreLocationDriver.shouldStopCoarseUpdates(after:
            NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue)))
        #expect(CoreLocationDriver.shouldStopCoarseUpdates(after:
            NSError(domain: "test.unrelated", code: CLError.Code.locationUnknown.rawValue)))
    }

    // MARK: - Authorization

    @Test("The initial prompt is asked at most once and never after a denial")
    func initialPromptIsAskedOnce() {
        let (service, driver) = makeService(status: .notDetermined)
        enterForeground(service)
        service.requestInitialAuthorizationIfNeeded()
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 1)

        driver.deliverAuthorization(.denied)
        #expect(service.authorizationStatus == .denied)
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 1)

        // The Settings status read never prompts, even when it changes state.
        service.refreshAuthorizationStatus()
        #expect(driver.authorizationRequestCount == 1)
    }

    @Test("A one-shot waits for the permission answer before asking for a fix")
    func oneShotWaitsForAuthorization() async throws {
        let (service, driver) = makeService(status: .notDetermined)
        enterForeground(service)
        let expected = sample()
        let task = Task { try await service.currentLocation() }
        try await waitUntil { driver.authorizationRequestCount == 1 }
        // The GPS request must not start while the permission sheet is
        // unanswered; the authorization wait is separate from the fix timeout.
        #expect(driver.startedFixIDs.isEmpty)

        driver.deliverAuthorization(.authorizedWhenInUse)
        try await waitUntil { driver.startedFixIDs.count == 1 }
        driver.deliverFix(id: driver.startedFixIDs[0], location: expected)
        let value = try await task.value
        #expect(value == expected)
        #expect(driver.startedFixIDs.count == 1)
    }

    @Test("A denied answer fails the one-shot honestly without a GPS request")
    func deniedAuthorizationFailsHonestly() async throws {
        let (service, driver) = makeService(status: .notDetermined)
        enterForeground(service)
        let task = Task { try await service.currentLocation() }
        try await waitUntil { driver.authorizationRequestCount == 1 }
        driver.deliverAuthorization(.denied)
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected an honest permission failure")
            return
        }
        #expect(error as? FloeError == .validationFailed("Location permission was denied"))
        #expect(driver.startedFixIDs.isEmpty)
    }

    @Test("An unanswered permission wait is bounded, not a hang")
    func unansweredAuthorizationIsBounded() async throws {
        let (service, driver) = makeService(
            status: .notDetermined,
            authorizationWaitTimeout: 0.05
        )
        enterForeground(service)
        let result = await Task { try await service.currentLocation() }.result
        guard case .failure(let error) = result else {
            Issue.record("expected an unanswered-permission failure")
            return
        }
        #expect(error as? FloeError == .validationFailed("Location permission was not answered in time"))
        #expect(driver.startedFixIDs.isEmpty)
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 1)
    }

    // MARK: - Request identity, cancellation, timeout

    @Test("A cancelled request's late result cannot complete the next request")
    func staleResultCannotCompleteNewRequest() async throws {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        enterForeground(service)
        let first = Task { try await service.currentLocation() }
        try await waitUntil { driver.startedFixIDs.count == 1 }
        let firstID = driver.startedFixIDs[0]
        first.cancel()
        try await waitUntil { driver.cancelledFixIDs.contains(firstID) }

        let second = Task { try await service.currentLocation() }
        try await waitUntil { driver.startedFixIDs.count == 2 }
        let secondID = driver.startedFixIDs[1]
        #expect(firstID != secondID)

        // A slow delegate from the cancelled request arrives late.
        driver.deliverFix(id: firstID, location: sample(latitude: 1, longitude: 1))
        let firstResult = await first.result
        guard case .failure = firstResult else {
            Issue.record("the cancelled request must not resolve as a success")
            return
        }
        let expected = sample(latitude: 2, longitude: 3, accuracy: 120)
        driver.deliverFix(id: secondID, location: expected)
        let secondValue = try await second.value
        #expect(secondValue == expected)
    }

    @Test("A pre-cancelled request never reaches the driver")
    func preCancelledRequestNeverStarts() async {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        enterForeground(service)
        let task = Task { try await service.currentLocation() }
        task.cancel()
        let result = await task.result
        guard case .failure = result else {
            Issue.record("a pre-cancelled request must not succeed")
            return
        }
        #expect(driver.startedFixIDs.isEmpty)
    }

    @Test("A fix timeout resumes once, cleans up, and a retry is a fresh request")
    func timeoutThenRetry() async throws {
        let (service, driver) = makeService(
            status: .authorizedWhenInUse,
            fixTimeout: 0.05
        )
        enterForeground(service)
        let first = Task { try await service.currentLocation() }
        try await waitUntil { driver.startedFixIDs.count == 1 }
        let firstID = driver.startedFixIDs[0]
        let firstResult = await first.result
        guard case .failure(let error) = firstResult else {
            Issue.record("expected a timeout failure")
            return
        }
        #expect(error as? FloeError == .syncUnavailable(
            "Location did not become available within 0.05 seconds"
        ))
        #expect(driver.cancelledFixIDs.contains(firstID))

        // A fix arriving after the timeout is stale and must not resolve
        // anything, let alone the next request.
        driver.deliverFix(id: firstID, location: sample(latitude: 9, longitude: 9))

        let second = Task { try await service.currentLocation() }
        try await waitUntil { driver.startedFixIDs.count == 2 }
        let expected = sample(latitude: 5, longitude: 6, accuracy: 80)
        driver.deliverFix(id: driver.startedFixIDs[1], location: expected)
        let secondValue = try await second.value
        #expect(secondValue == expected)
    }

    // MARK: - Background assist lifecycle

    @Test("A foreground preparation becomes an active coarse assist in the background")
    func foregroundPrepareThenBackgroundActivate() {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        #expect(service.backgroundState == .ready)
        #expect(driver.prepareCount == 1)
        #expect(driver.beginUpdatesCount == 0)

        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        #expect(service.backgroundState == .active)
        #expect(driver.beginUpdatesCount == 1)
        #expect(driver.prepareCount == 1)
    }

    @Test("Work appearing only after the app is already backgrounded never fakes a session")
    func coldBackgroundWorkDoesNotPrepare() {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        #expect(service.backgroundState == .idle)
        #expect(driver.prepareCount == 0)
        #expect(driver.beginUpdatesCount == 0)
    }

    @Test("Foreground return stops updates and the session, then re-arms in the foreground")
    func foregroundReturnStopsThenRearms() {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        #expect(service.backgroundState == .ready)
        #expect(driver.endUpdatesCount == 1)
        #expect(driver.teardownCount == 1)
        // Re-armed for the next exit while the user is back in the app.
        #expect(driver.prepareCount == 2)
    }

    @Test("Last work ending or support turning off stops the assist immediately")
    func workOrSupportEndStopsAssist() {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        #expect(service.backgroundState == .active)

        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: false, fullyBackgroundScene: true
        )
        #expect(service.backgroundState == .idle)
        #expect(driver.endUpdatesCount == 1)
        #expect(driver.teardownCount == 1)

        // Support itself off (all existing capability flags off).
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: false, workEligible: true, fullyBackgroundScene: false
        )
        #expect(service.backgroundState == .idle)
        #expect(driver.prepareCount == 2) // foreground arms only, never a session while off
    }

    @Test("A revoked permission clears an active assist and never retries by itself")
    func revokedAuthorizationClearsAssist() {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        #expect(service.backgroundState == .active)

        driver.deliverAuthorization(.denied)
        #expect(service.authorizationStatus == .denied)
        #expect(service.backgroundState == .unavailable)
        #expect(driver.endUpdatesCount == 1)
        #expect(driver.teardownCount == 1)

        // Re-applying the same inputs cannot prepare a session again while the
        // permission is revoked.
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        #expect(service.backgroundState == .unavailable)
        #expect(driver.prepareCount == 1)
    }

    @Test("A coarse-update failure is reported once without an automatic retry")
    func updatesFailureIsHonest() {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        driver.failUpdates()
        #expect(service.backgroundState == .unavailable)
        #expect(driver.endUpdatesCount == 1)
        #expect(driver.teardownCount == 1)
        #expect(driver.prepareCount == 1)
    }

    @Test("A missing background capability is an honest unavailable, not a success")
    func missingBackgroundCapabilityIsHonest() {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        driver.prepareSucceeds = false
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        #expect(service.backgroundState == .unavailable)
        #expect(driver.beginUpdatesCount == 0)
    }

    @Test("Turning support off never cancels a valid in-flight one-shot")
    func supportOffKeepsInFlightFix() async throws {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        let task = Task { try await service.currentLocation() }
        try await waitUntil { driver.startedFixIDs.count == 1 }

        service.applyBackgroundLocationInputs(
            supportEnabled: false, workEligible: true, fullyBackgroundScene: false
        )
        #expect(service.backgroundState == .idle)
        #expect(driver.teardownCount == 1)

        let expected = sample(latitude: 7, longitude: 8, accuracy: 90)
        driver.deliverFix(id: driver.startedFixIDs[0], location: expected)
        let value = try await task.value
        #expect(value == expected)
        #expect(driver.cancelledFixIDs.isEmpty)
    }

    @Test("Construction and idle no-work inputs perform no CoreLocation reads")
    func deferredStartupDoesNotTouchCoreLocation() {
        let driver = FakeLocationDriver(status: .authorizedWhenInUse)
        let service = LocationServicesCenter(driver: driver)
        // Constructing the service never touches CoreLocation.
        #expect(driver.authorizationStatusReadCount == 0)
        #expect(driver.locationServicesEnabledReadCount == 0)

        // Root's initial scene-phase reconciles, before persistence readiness
        // and before any real work exists: still no CoreLocation reads.
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: false, fullyBackgroundScene: true
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: false, fullyBackgroundScene: false
        )
        #expect(driver.authorizationStatusReadCount == 0)
        #expect(driver.locationServicesEnabledReadCount == 0)
        #expect(service.backgroundState == .idle)

        // Only the explicit first-rendered-launch / Settings read starts the
        // CoreLocation work.
        service.refreshAuthorizationStatus()
        #expect(driver.authorizationStatusReadCount == 1)
        #expect(service.authorizationStatus == .authorizedWhenInUse)
    }

    // MARK: - Permission requestability

    @Test("A background call without permission gives guidance and never burns the first prompt")
    func backgroundCallWithoutPermissionKeepsPrompt() async throws {
        let (service, driver) = makeService(status: .notDetermined)
        service.applyBackgroundLocationInputs(
            supportEnabled: false, workEligible: false, fullyBackgroundScene: true
        )
        let result = await Task { try await service.currentLocation() }.result
        guard case .failure(let error) = result else {
            Issue.record("a background call cannot present a permission sheet")
            return
        }
        #expect(error as? FloeError == .validationFailed(
            "Location access is not allowed yet. Open Floe and allow location access, then try again."
        ))
        #expect(driver.authorizationRequestCount == 0)
        #expect(driver.startedFixIDs.isEmpty)
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 0)

        // The next real foreground launch still gets its one prompt.
        enterForeground(service)
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 1)
    }

    @Test("An authorized background call without a prepared session fails clearly")
    func backgroundCallWithoutPreparedSessionIsHonest() async throws {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        // Work is eligible and the app is backgrounded, but no foreground
        // preparation ever happened (cold/background start): no session.
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        #expect(service.backgroundState == .idle)

        let result = await Task { try await service.currentLocation() }.result
        guard case .failure(let error) = result else {
            Issue.record("a background call without a prepared session cannot succeed")
            return
        }
        #expect(error as? FloeError == .validationFailed(
            "Background location is unavailable for this task. Keep Floe open while it runs and try again."
        ))
        #expect(driver.startedFixIDs.isEmpty)
    }

    @Test("Global Location Services off never consumes the first prompt")
    func locationServicesOffKeepsPrompt() {
        let (service, driver) = makeService(status: .notDetermined)
        driver.locationServicesEnabled = false
        enterForeground(service)
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 0)

        driver.locationServicesEnabled = true
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 1)
    }

    @Test("Revocation resolves the in-flight fix and a late success cannot resurrect it")
    func revocationResolvesInFlightFix() async throws {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        enterForeground(service)
        let task = Task { try await service.currentLocation() }
        try await waitUntil { driver.startedFixIDs.count == 1 }
        let fixID = driver.startedFixIDs[0]

        driver.deliverAuthorization(.denied)
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("revoked permission must not report a fix")
            return
        }
        #expect(error as? FloeError == .validationFailed("Location permission was denied"))
        #expect(driver.cancelledFixIDs.contains(fixID))

        // A slow delegate result from the request-scoped manager arrives after
        // the revocation: ignored, exactly once, with no second continuation.
        driver.deliverFix(id: fixID, location: sample(latitude: 4, longitude: 4))
        let settled = await task.result
        if case .success = settled {
            Issue.record("a late success resurrected a revoked request")
        }
    }

    @Test("Refreshing authorization drains an existing fix even without a delegate event")
    func refreshedRevocationDrainsFix() async throws {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        enterForeground(service)
        let request = Task { try await service.currentLocation() }
        try await waitUntil { driver.startedFixIDs.count == 1 }
        let requestID = driver.startedFixIDs[0]
        driver.authorizationStatus = .denied
        service.refreshAuthorizationStatus()
        guard case .failure(let error) = await request.result else {
            Issue.record("Refreshed revocation must end the active request")
            return
        }
        #expect(error as? FloeError == .validationFailed("Location permission was denied"))
        #expect(driver.cancelledFixIDs.contains(requestID))
        driver.deliverFix(id: requestID, location: sample())
        #expect(service.authorizationStatus == .denied)
    }

    // MARK: - Production tool seam

    #if DEBUG
    @Test("A background one-shot completes and the real tool keeps its output shape")
    func backgroundToolOutputShape() async throws {
        let (service, driver) = makeService(status: .authorizedWhenInUse)

        // Foreground: active work prepares the session. Background: coarse
        // updates keep it honest without any timer.
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: false
        )
        service.applyBackgroundLocationInputs(
            supportEnabled: true, workEligible: true, fullyBackgroundScene: true
        )
        #expect(service.backgroundState == .active)

        let expected = sample(
            latitude: -33.87,
            longitude: 151.21,
            accuracy: 2_500, // approximate (reduced-accuracy) fix is reported as-is
            timestamp: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let runID = UUID()
        let conversationID = UUID()
        let task = Task {
            try await AppleCurrentLocationTool(locationService: service).execute(
                AppleCurrentLocationTool.Arguments(),
                context: ToolContext(
                    runID: runID,
                    cancellation: CancellationToken(),
                    conversationID: conversationID
                )
            )
        }
        try await waitUntil { driver.startedFixIDs.count == 1 }
        driver.deliverFix(id: driver.startedFixIDs[0], location: expected)
        let output = try await task.value

        // Same identity and output shape as before the fix: the existing
        // weather/search tools consume this line inside the SAME task.
        #expect(AppleCurrentLocationTool.name == "apple.location.current")
        #expect(output.exitStatus == 0)
        #expect(output.summary.hasPrefix("status=ok "))
        #expect(output.summary.contains("latitude=-33.87"))
        #expect(output.summary.contains("longitude=151.21"))
        #expect(output.summary.contains("accuracyMeters=2500.0"))
        #expect(output.summary.contains("timestamp="))
        // The one-shot never disturbed the background assist.
        #expect(service.backgroundState == .active)
        #expect(driver.teardownCount == 0)
    }

    @Test("The tool reports an honest failure instead of a fabricated fix")
    func toolFailureIsHonest() async {
        let (service, driver) = makeService(status: .denied)

        let result = await Task {
            try await AppleCurrentLocationTool(locationService: service).execute(
                AppleCurrentLocationTool.Arguments(),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }.result
        guard case .failure(let error) = result else {
            Issue.record("a denied permission must not produce a fix")
            return
        }
        #expect(error as? FloeError == .validationFailed("Location permission was denied"))
        #expect(driver.startedFixIDs.isEmpty)
    }

    // MARK: - Temporary chat: existing authorization only, never a prompt

    @Test("A conversational temporary-chat read with existing authorization returns the fix without any prompt")
    func temporaryReadUsesExistingAuthorizationWithoutPrompt() async throws {
        let (service, driver) = makeService(status: .authorizedWhenInUse)
        enterForeground(service)
        let expected = sample()
        let task = Task {
            try await AppleCurrentLocationTool(locationService: service).execute(
                AppleCurrentLocationTool.Arguments(),
                context: ToolContext(
                    runID: UUID(),
                    publicWebOnly: true,
                    cancellation: CancellationToken(),
                    temporaryReadOnly: true
                )
            )
        }
        try await waitUntil { driver.startedFixIDs.count == 1 }
        driver.deliverFix(id: driver.startedFixIDs[0], location: expected)
        let output = try await task.value
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("latitude=-33.86"))
        // The temporary path never asked the system for authorization.
        #expect(driver.authorizationRequestCount == 0)
    }

    @Test("A conversational temporary-chat read before any authorization answer fails with guidance, no prompt, no GPS")
    func temporaryReadNeverConsumesTheSystemPrompt() async {
        let (service, driver) = makeService(status: .notDetermined)
        enterForeground(service)
        let result = await Task {
            try await AppleCurrentLocationTool(locationService: service).execute(
                AppleCurrentLocationTool.Arguments(),
                context: ToolContext(
                    runID: UUID(),
                    publicWebOnly: true,
                    cancellation: CancellationToken(),
                    temporaryReadOnly: true
                )
            )
        }.result
        guard case .failure(let error) = result else {
            Issue.record("an unanswered conversational read must fail honestly")
            return
        }
        #expect(error as? FloeError == .validationFailed(
            "Location access has not been allowed in Floe yet. Open Floe and allow location access, then try again."
        ))
        #expect(driver.authorizationRequestCount == 0)
        #expect(driver.startedFixIDs.isEmpty)
        // The one system prompt is still available to the ordinary flow.
        service.requestInitialAuthorizationIfNeeded()
        #expect(driver.authorizationRequestCount == 1)
    }

    @Test("The direct service seam refuses a no-request conversational read before any answer")
    func currentLocationCanRefuseAuthorizationRequests() async {
        let (service, driver) = makeService(status: .notDetermined)
        enterForeground(service)
        let result = await Task {
            try await service.currentLocation(allowsAuthorizationRequest: false)
        }.result
        guard case .failure(let error) = result else {
            Issue.record("a no-request read before any answer must fail honestly")
            return
        }
        #expect(error as? FloeError == .validationFailed(
            "Location access has not been allowed in Floe yet. Open Floe and allow location access, then try again."
        ))
        #expect(driver.authorizationRequestCount == 0)
        #expect(driver.startedFixIDs.isEmpty)
    }
    #endif
}
#endif
