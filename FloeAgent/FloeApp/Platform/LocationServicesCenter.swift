// FloeApp — Shared location service.
//
// One service owns every CoreLocation interaction the app performs:
//
//  • the single first-launch When-In-Use authorization request,
//  • one-shot current-location fixes for `apple.location.current`,
//  • the optional background assist that lets an explicit, already-authorized
//    weather/nearby task finish while the app is in the background.
//
// There is deliberately NO separate location switch. Background support follows
// the EXISTING honored background capabilities (enhanced background processing,
// Picture-in-Picture, screen feedback). `BackgroundRunCoordinator` decides when
// real local work is executing and whether every window is backgrounded; this
// service owns the session/update lifecycle and the authorization boundary.
//
// The CoreLocation surface sits behind `LocationServiceDriving` so focused
// regressions can drive authorization, fixes, timeouts, cancellation and
// failures without any real permission sheet, GPS or background session.

#if canImport(UIKit) && canImport(CoreLocation)
import Combine
import CoreLocation
import Foundation
import FloeCore
import UIKit

/// One location fix plus its honesty fields. The property names keep the
/// existing `apple.location.current` output shape
/// (`latitude=… longitude=… accuracyMeters=… timestamp=…`).
struct SendableLocation: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy in metres as reported by Core Location. A user who
    /// granted only approximate access simply yields a large value here; it is
    /// reported, never rounded up into a false precision claim.
    var accuracy: Double
    var timestamp: Date
}

/// Honest failure kinds for a one-shot fix. The service maps these onto the
/// existing `FloeError` wording so the tool's failure text stays compatible.
enum LocationFixFailure: Error, Equatable, Sendable {
    case servicesDisabled
    case permissionDenied
    case authorizationUnanswered
    /// A background call arrived with no permission answer yet: only a
    /// foreground app can present the system sheet, so the call fails with
    /// actionable guidance instead of trying (and burning) the one prompt.
    case authorizationNeedsForeground
    /// A background call arrived without a session prepared in the foreground.
    /// The system cannot be relied on to answer it, so the call fails clearly
    /// instead of waiting out the whole fix timeout.
    case backgroundSessionUnavailable
    case timedOut
    case unavailable(String)
    case cancelled
    /// The production service intentionally performs no CoreLocation work in
    /// an App-hosted unit-test process (see `isUnitTestHostProcess`).
    case systemSuppressed
}

/// Events a driver reports back to the service. Every one-shot result carries
/// the request id the service minted, so a late callback from a cancelled or
/// timed-out request can never complete a newer one.
enum LocationDriverEvent: Sendable {
    case authorizationChanged(CLAuthorizationStatus)
    case oneShotResult(id: UInt64, result: Result<SendableLocation, LocationFixFailure>)
    case coarseUpdatesFailed
}

/// The narrow CoreLocation surface the service needs. The production
/// implementation is `CoreLocationDriver`; tests inject a controllable fake.
@MainActor
protocol LocationServiceDriving: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var locationServicesEnabled: Bool { get }
    var onEvent: (@MainActor (LocationDriverEvent) -> Void)? { get set }

    /// Ask the system for When-In-Use access. Callers decide WHEN; the system
    /// shows the prompt at most once per install.
    func requestWhenInUseAuthorization()

    /// Start one tagged one-shot fix. The driver may deliver a result for a
    /// stale id (for example after a slow shutdown of an old manager); the
    /// service ignores anything that is not its current pending request.
    func startOneShotFix(id: UInt64)
    func cancelOneShotFix(id: UInt64)

    /// Prepare the single app-wide background activity session while the app
    /// is still foregrounded. Returns false when the process cannot support
    /// background location honestly (for example the Info.plist background
    /// mode is missing).
    @discardableResult
    func prepareBackgroundActivity() -> Bool
    /// Coarse (≈3 km) standard updates that keep the prepared session honest
    /// while real work finishes in the background. No timer drives this.
    func beginCoarseUpdates()
    func endCoarseUpdates()
    /// Ends updates and invalidates the activity session. A later foreground
    /// preparation may create a new session; an invalidated one never revives.
    func teardownBackgroundActivity()
}

/// Production driver. Managers are created lazily on first use — never from a
/// static initializer or the launch path — so app startup does not block on a
/// location XPC connection.
@MainActor
final class CoreLocationDriver: NSObject, LocationServiceDriving {
    var onEvent: (@MainActor (LocationDriverEvent) -> Void)?

    private var _authorizationManager: CLLocationManager?
    private var oneShotRequests: [UInt64: OneShotRequest] = [:]
    private var _updatesManager: CLLocationManager?
    private var activitySession: CLBackgroundActivitySession?

    private struct OneShotRequest {
        let manager: CLLocationManager
        let delegate: OneShotFixDelegate
    }

    /// Request-scoped delegate: each one-shot lives on its own manager, so a
    /// stale delegate can never resolve a different request. The service's
    /// id check is a second belt on the same braces.
    @MainActor
    private final class OneShotFixDelegate: NSObject, @preconcurrency CLLocationManagerDelegate {
        let id: UInt64
        private var deliver: (@MainActor (UInt64, Result<SendableLocation, LocationFixFailure>) -> Void)?
        private var finished = false

        init(
            id: UInt64,
            deliver: @escaping @MainActor (UInt64, Result<SendableLocation, LocationFixFailure>) -> Void
        ) {
            self.id = id
            self.deliver = deliver
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let value = locations.last else { return }
            // A negative horizontal accuracy (or an out-of-range coordinate)
            // is not a fix: ignore it and keep waiting for a valid sample. The
            // service's own timeout still bounds the wait honestly.
            let coordinate = value.coordinate
            guard value.horizontalAccuracy >= 0,
                  coordinate.latitude.isFinite,
                  coordinate.latitude >= -90,
                  coordinate.latitude <= 90,
                  coordinate.longitude.isFinite,
                  coordinate.longitude >= -180,
                  coordinate.longitude <= 180 else { return }
            finish(.success(SendableLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                accuracy: value.horizontalAccuracy,
                timestamp: value.timestamp
            )))
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
            finish(.failure(.unavailable("Location did not become available")))
        }

        func cancel() {
            deliver = nil
            finished = true
        }

        private func finish(_ result: Result<SendableLocation, LocationFixFailure>) {
            guard !finished, let deliver else { return }
            finished = true
            self.deliver = nil
            deliver(id, result)
        }
    }

    var authorizationStatus: CLAuthorizationStatus {
        authorizationManager.authorizationStatus
    }

    var locationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    private var authorizationManager: CLLocationManager {
        if let _authorizationManager { return _authorizationManager }
        let manager = CLLocationManager()
        manager.delegate = self
        _authorizationManager = manager
        return manager
    }

    private var updatesManager: CLLocationManager {
        if let _updatesManager { return _updatesManager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        // Auto-pause is the supported battery-saving behaviour for standard
        // updates; the prepared activity session still keeps the process
        // eligible, and the fix path never relies on a paused stream.
        manager.pausesLocationUpdatesAutomatically = true
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
            // The system indicator is shown truthfully while the background
            // assist is running; nothing here hides it.
            manager.showsBackgroundLocationIndicator = true
        }
        _updatesManager = manager
        return manager
    }

    /// Setting `allowsBackgroundLocationUpdates` without the Info.plist
    /// background mode raises a runtime exception, so the capability is only
    /// claimed when the app actually declares it.
    private static var hasLocationBackgroundMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") == true
    }

    func requestWhenInUseAuthorization() {
        authorizationManager.requestWhenInUseAuthorization()
    }

    func startOneShotFix(id: UInt64) {
        let manager = CLLocationManager()
        // ~100 m is enough for an explicit weather/nearby lookup and avoids
        // claiming more precision than the use needs.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let delegate = OneShotFixDelegate(id: id) { [weak self] id, result in
            guard let self, let request = self.oneShotRequests[id] else { return }
            self.oneShotRequests.removeValue(forKey: id)
            request.manager.delegate = nil
            self.onEvent?(.oneShotResult(id: id, result: result))
        }
        manager.delegate = delegate
        oneShotRequests[id] = OneShotRequest(manager: manager, delegate: delegate)
        manager.requestLocation()
    }

    func cancelOneShotFix(id: UInt64) {
        guard let request = oneShotRequests.removeValue(forKey: id) else { return }
        request.manager.delegate = nil
        request.delegate.cancel()
    }

    func prepareBackgroundActivity() -> Bool {
        if activitySession != nil { return true }
        guard Self.hasLocationBackgroundMode else { return false }
        // The system always vends a session object; it only becomes active for
        // an authorized app with the location background mode, created while
        // the app is foregrounded. That is exactly the documented contract
        // this path relies on.
        activitySession = CLBackgroundActivitySession()
        return true
    }

    func beginCoarseUpdates() {
        updatesManager.startUpdatingLocation()
    }

    func endCoarseUpdates() {
        _updatesManager?.stopUpdatingLocation()
    }

    func teardownBackgroundActivity() {
        _updatesManager?.stopUpdatingLocation()
        _updatesManager?.delegate = nil
        _updatesManager = nil
        activitySession?.invalidate()
        activitySession = nil
    }
}

extension CoreLocationDriver: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === _authorizationManager else { return }
        onEvent?(.authorizationChanged(manager.authorizationStatus))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Coarse background updates exist to keep the prepared session honest
        // while real work runs. Coordinates are deliberately not read, stored
        // or logged here.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard manager === _updatesManager else { return }
        onEvent?(.coarseUpdatesFailed)
    }
}

/// App-wide owner of authorization, one-shot fixes and the background assist.
///
/// `BackgroundRunCoordinator` pushes three plain facts on every lifecycle
/// transition (see `applyBackgroundLocationInputs`); this service combines
/// them with the live authorization answer. Nothing here polls, fabricates a
/// fix or persists coordinates.
@MainActor
final class LocationServicesCenter: ObservableObject {
    /// Honest background-location state. The app maps these cases to localized
    /// labels; the service itself carries no product copy.
    enum BackgroundState: String, Sendable, Equatable {
        /// No prepared session: no eligible work, support off, or idle.
        case idle
        /// A foreground-prepared activity session is ready for the next
        /// background transition.
        case ready
        /// Coarse updates and the prepared session are keeping real work alive
        /// in the background.
        case active
        /// Support and real work both want background location but the system
        /// will not provide it (revoked permission, missing capability, or a
        /// reported failure). Never a silent success.
        case unavailable
    }

    /// True when this process is an App-hosted unit-test run. The shared
    /// production service then never creates a CoreLocation manager, prompts
    /// for permission or prepares a session, so a test host starts without
    /// touching real permission/GPS. Ordinary App launches never see it, and
    /// tests that exercise the production seam inject a controlled driver.
    static let isUnitTestHostProcess: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    @MainActor private static var _shared: LocationServicesCenter?

    /// The app-wide service. Created lazily on first use (never from a static
    /// initializer), so the launch path never blocks on a location XPC
    /// connection. In an App-hosted unit-test process the shared instance is
    /// created without permission to touch the real system.
    static var shared: LocationServicesCenter {
        if let _shared { return _shared }
        let created = LocationServicesCenter(
            driver: CoreLocationDriver(),
            allowsSystemLocation: !isUnitTestHostProcess
        )
        _shared = created
        return created
    }


    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var backgroundState: BackgroundState = .idle

    private let driver: any LocationServiceDriving
    /// False only for the shared instance inside an App-hosted unit test.
    private let allowsSystemLocation: Bool
    private let fixTimeout: TimeInterval
    private let authorizationWaitTimeout: TimeInterval

    /// Latest facts pushed by `BackgroundRunCoordinator`.
    private var supportEnabled = false
    private var workEligible = false
    /// Fail closed until a real scene reports: a cold or background launch
    /// cannot present a permission sheet.
    private var fullyBackgroundScene = true

    /// Whether the activity session was prepared during THIS foreground run.
    private var sessionPrepared = false
    private var updatesRunning = false

    /// The initial prompt happens at most once per process; a later
    /// `.notDetermined` reading must not re-prompt.
    private var hasRequestedInitialAuthorization = false

    private struct PendingFix {
        let continuation: CheckedContinuation<SendableLocation, any Error>
        let timeoutTask: Task<Void, Never>
    }

    /// One-shot requests keyed by their monotonic id. A result is honored only
    /// for the exact id still present here; everything else is dropped.
    private var pendingFixes: [UInt64: PendingFix] = [:]
    private var nextRequestID: UInt64 = 1

    /// Bounded, cancellable waiters for the first permission answer. Kept
    /// separate from `pendingFixes` so the authorization wait never consumes
    /// the GPS timeout.
    private struct AuthorizationWaiter {
        let continuation: CheckedContinuation<CLAuthorizationStatus, Never>
        let timeoutTask: Task<Void, Never>
    }
    private var authorizationWaiters: [UUID: AuthorizationWaiter] = [:]

    init(
        driver: any LocationServiceDriving,
        allowsSystemLocation: Bool = true,
        fixTimeout: TimeInterval = 15,
        authorizationWaitTimeout: TimeInterval = 10
    ) {
        self.driver = driver
        self.allowsSystemLocation = allowsSystemLocation
        self.fixTimeout = fixTimeout
        self.authorizationWaitTimeout = authorizationWaitTimeout
        // Do not touch CoreLocation here: the shared service may be created
        // from an early lifecycle callback, and a manager construction blocks
        // on a location XPC connection. The first real read happens at the
        // first rendered-launch request or an explicit status refresh.
        self.authorizationStatus = .notDetermined
        driver.onEvent = { [weak self] event in
            self?.handleDriverEvent(event)
        }
    }

    // MARK: - Authorization

    /// Only a foreground app with Location Services on can present the system
    /// permission sheet. This uses the coordinator-pushed scene fact (never a
    /// directly queried UIApplication state), so controlled-driver tests stay
    /// deterministic.
    private var canPresentAuthorizationRequest: Bool {
        allowsSystemLocation && driver.locationServicesEnabled && !fullyBackgroundScene
    }

    /// Reads the live authorization answer for status UI. Never prompts.
    func refreshAuthorizationStatus() {
        guard allowsSystemLocation else { return }
        let status = driver.authorizationStatus
        if status != authorizationStatus {
            handleAuthorizationChange(status)
        }
        if !driver.locationServicesEnabled {
            for id in Array(pendingFixes.keys) {
                resolveFix(id: id, with: .failure(.servicesDisabled))
            }
        }
        // Availability can change without the authorization enum changing
        // (Location Services switched off globally, a prior failure clearing);
        // re-evaluate the honest state on every explicit status read.
        reconcileBackgroundLifecycle()
    }

    /// The first active rendered launch asks for When-In-Use access after setup
    /// readiness. Denied/restricted never re-prompts, and this process asks at
    /// most once. The system itself shows the sheet at most once per install.
    func requestInitialAuthorizationIfNeeded() {
        guard allowsSystemLocation else { return }
        refreshAuthorizationStatus()
        // Location Services off or a truly backgrounded app cannot present a
        // system request. Leave the one-shot prompt for the next real
        // foreground launch instead of consuming it here.
        guard canPresentAuthorizationRequest,
              !hasRequestedInitialAuthorization,
              authorizationStatus == .notDetermined else { return }
        hasRequestedInitialAuthorization = true
        driver.requestWhenInUseAuthorization()
    }

    // MARK: - One-shot fixes

    /// One current fix for an explicit location/weather/nearby step in a real
    /// task. Waits (bounded) for the initial permission answer before the GPS
    /// window starts; the 15-second fix timeout measures only that window.
    func currentLocation() async throws -> SendableLocation {
        // A request cancelled before it starts must not touch the system.
        if Task.isCancelled { throw FloeError.cancelled }
        guard allowsSystemLocation else { throw floeError(for: .systemSuppressed) }
        guard driver.locationServicesEnabled else { throw floeError(for: .servicesDisabled) }

        var status = driver.authorizationStatus
        if status != authorizationStatus { authorizationStatus = status }
        if status == .denied || status == .restricted {
            throw floeError(for: .permissionDenied)
        }
        if status == .notDetermined {
            guard canPresentAuthorizationRequest else {
                throw floeError(for: .authorizationNeedsForeground)
            }
            requestWhenInUseAuthorizationIfAvailable()
            status = await awaitAuthorizationAnswer()
            if Task.isCancelled { throw FloeError.cancelled }
            if status == .denied || status == .restricted {
                throw floeError(for: .permissionDenied)
            }
            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                throw floeError(for: .authorizationUnanswered)
            }
        }
        // A backgrounded app needs the session that was prepared while it was
        // still foregrounded (and kept because real work is eligible). Without
        // it, fail with guidance instead of a silent 15-second timeout.
        if fullyBackgroundScene, !sessionPrepared {
            throw floeError(for: .backgroundSessionUnavailable)
        }

        let requestID = nextRequestID
        nextRequestID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Re-check right before starting: the cancellation handler may
                // have fired while the caller was suspended in the auth wait.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: FloeError.cancelled)
                    return
                }
                let timeout = self.fixTimeout
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.resolveFix(id: requestID, with: .failure(.timedOut))
                }
                pendingFixes[requestID] = PendingFix(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                driver.startOneShotFix(id: requestID)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveFix(id: requestID, with: .failure(.cancelled))
            }
        }
    }

    private func requestWhenInUseAuthorizationIfAvailable() {
        // The one-shot path may be the first real location use (for example a
        // user who skipped the initial launch). Only a foreground, requestable
        // state consumes the single prompt; denied/restricted never arrives
        // here and a backgrounded app is rejected by the caller.
        guard canPresentAuthorizationRequest,
              !hasRequestedInitialAuthorization else { return }
        hasRequestedInitialAuthorization = true
        driver.requestWhenInUseAuthorization()
    }

    private func awaitAuthorizationAnswer() async -> CLAuthorizationStatus {
        if driver.authorizationStatus != .notDetermined {
            return driver.authorizationStatus
        }
        let waiterID = UUID()
        let timeout = authorizationWaitTimeout
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The answer may have landed while the caller was suspended.
                let latest = driver.authorizationStatus
                if latest != .notDetermined {
                    continuation.resume(returning: latest)
                    return
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.resolveAuthorizationWaiter(id: waiterID, status: .notDetermined)
                }
                authorizationWaiters[waiterID] = AuthorizationWaiter(
                    continuation: continuation, timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveAuthorizationWaiter(id: waiterID, status: .notDetermined)
            }
        }
    }

    /// Resumes exactly one waiter. `.notDetermined` is the bounded-wait
    /// expiry/cancellation answer, so the stored continuation type stays
    /// non-optional and no optional-vs-nonoptional mismatch exists.
    private func resolveAuthorizationWaiter(id: UUID, status: CLAuthorizationStatus) {
        guard let waiter = authorizationWaiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: status)
    }

    private func resolveFix(
        id: UInt64,
        with result: Result<SendableLocation, LocationFixFailure>
    ) {
        guard let pending = pendingFixes.removeValue(forKey: id) else {
            // Stale, cancelled or timed-out identity: never resolve a newer
            // request from here.
            return
        }
        pending.timeoutTask.cancel()
        driver.cancelOneShotFix(id: id)
        switch result {
        case .success(let value):
            // A success that arrives after a revocation is not a valid fix
            // anymore: report the honest permission failure instead.
            guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
                pending.continuation.resume(throwing: floeError(for: .permissionDenied))
                return
            }
            guard driver.locationServicesEnabled else {
                pending.continuation.resume(throwing: floeError(for: .servicesDisabled))
                return
            }
            pending.continuation.resume(returning: value)
        case .failure(let failure):
            pending.continuation.resume(throwing: floeError(for: failure))
        }
    }

    // MARK: - Background assist lifecycle

    /// The single input seam from `BackgroundRunCoordinator`: the honored
    /// background-support decision (OR of the existing capabilities), whether
    /// real local work is executing, and whether every window is backgrounded.
    func applyBackgroundLocationInputs(
        supportEnabled: Bool,
        workEligible: Bool,
        fullyBackgroundScene: Bool
    ) {
        let changed = self.supportEnabled != supportEnabled
            || self.workEligible != workEligible
            || self.fullyBackgroundScene != fullyBackgroundScene
        self.supportEnabled = supportEnabled
        self.workEligible = workEligible
        self.fullyBackgroundScene = fullyBackgroundScene
        guard changed else { return }
        reconcileBackgroundLifecycle()
    }

    private func reconcileBackgroundLifecycle() {
        guard allowsSystemLocation else {
            backgroundState = .idle
            return
        }
        guard supportEnabled, workEligible else {
            // Last work ended or every supporting capability is off: stop
            // immediately, in the background too.
            stopBackgroundAssist()
            backgroundState = .idle
            return
        }
        if authorizationStatus == .notDetermined {
            // Only now is the live answer worth an XPC read: real work wants
            // the assist. Idle paths stay free of CoreLocation work.
            let live = driver.authorizationStatus
            if live != .notDetermined { authorizationStatus = live }
        }
        guard driver.locationServicesEnabled else {
            stopBackgroundAssist()
            backgroundState = .unavailable
            return
        }
        switch authorizationStatus {
        case .denied, .restricted:
            stopBackgroundAssist()
            backgroundState = .unavailable
            return
        case .notDetermined:
            // The user has not answered yet: nothing is prepared and nothing
            // is claimed.
            stopBackgroundAssist()
            backgroundState = .idle
            return
        default:
            break
        }
        if fullyBackgroundScene {
            // A background session may only become active when it was created
            // while the app was in the foreground. A cold launch or restored
            // stale work never fabricates one here.
            guard sessionPrepared else {
                stopBackgroundAssist()
                backgroundState = .idle
                return
            }
            if !updatesRunning {
                driver.beginCoarseUpdates()
                updatesRunning = true
            }
            backgroundState = .active
        } else {
            // Foreground return stops the coarse stream and the background
            // session; while real work, support and authorization are still
            // present, re-arm a fresh foreground session so the next exit
            // stays eligible. No timer drives any of this.
            if updatesRunning {
                driver.endCoarseUpdates()
                updatesRunning = false
            }
            // Only a real return from the active background assist tears the
            // session down; a repeated foreground reconcile leaves the
            // already-prepared session alone.
            if backgroundState == .active, sessionPrepared {
                driver.teardownBackgroundActivity()
                sessionPrepared = false
            }
            if !sessionPrepared {
                guard driver.prepareBackgroundActivity() else {
                    backgroundState = .unavailable
                    return
                }
                sessionPrepared = true
            }
            backgroundState = .ready
        }
    }

    private func stopBackgroundAssist() {
        if updatesRunning {
            driver.endCoarseUpdates()
            updatesRunning = false
        }
        if sessionPrepared {
            driver.teardownBackgroundActivity()
            sessionPrepared = false
        }
    }

    // MARK: - Driver events

    private func handleDriverEvent(_ event: LocationDriverEvent) {
        switch event {
        case .authorizationChanged(let status):
            handleAuthorizationChange(status)
        case .oneShotResult(let id, let result):
            resolveFix(id: id, with: result)
        case .coarseUpdatesFailed:
            // Honest failure: clear the assist and do not start a retry loop.
            // A later real transition (new foreground preparation, a new run,
            // or a settings change) re-evaluates from scratch.
            stopBackgroundAssist()
            backgroundState = supportEnabled && workEligible ? .unavailable : .idle
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        if status != .notDetermined {
            for id in Array(authorizationWaiters.keys) {
                resolveAuthorizationWaiter(id: id, status: status)
            }
        }
        switch status {
        case .denied, .restricted:
            // Revocation clears the assist immediately AND resolves every
            // outstanding one-shot with an honest permission failure. Unlike
            // a support toggle, revoked permission makes a later fix
            // meaningless, so a slow delegate result cannot resurrect it.
            stopBackgroundAssist()
            backgroundState = supportEnabled && workEligible ? .unavailable : .idle
            for id in Array(pendingFixes.keys) {
                resolveFix(id: id, with: .failure(.permissionDenied))
            }
        case .notDetermined:
            break
        default:
            reconcileBackgroundLifecycle()
        }
    }

    // MARK: - Error mapping

    /// Keeps the existing tool-facing failure wording (and error cases) for
    /// the situations the previous broker already reported.
    private func floeError(for failure: LocationFixFailure) -> FloeError {
        switch failure {
        case .servicesDisabled:
            return .validationFailed("Location Services are disabled")
        case .permissionDenied:
            return .validationFailed("Location permission was denied")
        case .authorizationUnanswered:
            return .validationFailed("Location permission was not answered in time")
        case .authorizationNeedsForeground:
            return .validationFailed(
                "Location access is not allowed yet. Open Floe and allow location access, then try again."
            )
        case .backgroundSessionUnavailable:
            return .validationFailed(
                "Background location is unavailable for this task. Keep Floe open while it runs and try again."
            )
        case .timedOut:
            return .syncUnavailable(
                "Location did not become available within \(Self.secondsText(fixTimeout)) seconds"
            )
        case .unavailable(let reason):
            return .syncUnavailable(reason)
        case .cancelled:
            return .cancelled
        case .systemSuppressed:
            return .validationFailed("Location is unavailable in this process")
        }
    }

    private static func secondsText(_ seconds: TimeInterval) -> String {
        String(format: "%g", seconds)
    }
}
#endif
