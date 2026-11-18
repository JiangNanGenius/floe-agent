// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox — location.
//
// The model owns one foreground Core Location source and a small saved-place
// archive. It never starts a second background session, never uses a cached
// location as a new fix, and stops updates when the user pauses or the tool
// leaves the screen. Tests inject a fake source; no permission sheet or real
// location is used by the test suite.

import CoreLocation
import Foundation
import Observation
import FloeToolboxUtilities

public enum MacLocationAuthorization: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

public enum MacLocationPhase: String, Equatable, Sendable {
    case idle
    case permission
    case locating
    case live
    case paused
    case denied
    case restricted
    case disabled
    case unavailable
}

public enum MacLocationFailure: Error, Equatable, Sendable {
    case servicesDisabled
    case denied
    case restricted
    case temporarilyUnavailable
    case unavailable(String)
}

public enum MacLocationSourceEvent: Equatable, Sendable {
    case authorizationChanged(MacLocationAuthorization)
    case precisionChanged(Bool)
    case fix(token: UUID, ToolboxLocationFix)
    case failure(token: UUID, MacLocationFailure)
}

/// Narrow Core Location surface. The production implementation is
/// `CoreLocationMacSource`; tests use a controllable fake. No CLLocation type
/// crosses this seam.
@MainActor
public protocol MacLocationSource: AnyObject {
    var authorization: MacLocationAuthorization { get }
    var precise: Bool { get }
    var servicesEnabled: Bool { get }
    var onEvent: (@MainActor (MacLocationSourceEvent) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func start(token: UUID)
    func stop()
}

public enum MacLocationSystem {
    /// A read-only service-state query. It does not request permission and
    /// does not create a manager or start an update stream.
    public static func serviceEnabled() -> Bool {
        CLLocationManager.locationServicesEnabled()
    }
}

enum MacLocationCallbackGate {
    static func accepts(sender: AnyObject, active: AnyObject?, startedAt: Date?, timestamp: Date, now: Date) -> Bool {
        guard let active, sender === active, let startedAt else { return false }
        return timestamp >= startedAt && timestamp <= now.addingTimeInterval(1)
            && now.timeIntervalSince(timestamp) <= 15
    }
}

@MainActor
public final class CoreLocationMacSource: NSObject, MacLocationSource, @preconcurrency CLLocationManagerDelegate {
    public var onEvent: (@MainActor (MacLocationSourceEvent) -> Void)?

    private let manager: CLLocationManager
    private var activeToken: UUID?
    private var activeManager: CLLocationManager?
    private var startedAt: Date?

    public override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
    }

    public var authorization: MacLocationAuthorization {
        Self.map(manager.authorizationStatus)
    }

    public var precise: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    public var servicesEnabled: Bool {
        MacLocationSystem.serviceEnabled()
    }

    public func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    public func start(token: UUID) {
        stop()
        let stream = CLLocationManager()
        stream.delegate = self
        stream.desiredAccuracy = kCLLocationAccuracyBest
        stream.distanceFilter = kCLDistanceFilterNone
        stream.pausesLocationUpdatesAutomatically = false
        stream.allowsBackgroundLocationUpdates = false
        activeToken = token
        startedAt = Date()
        activeManager = stream
        stream.startUpdatingLocation()
    }

    public func stop() {
        activeToken = nil
        startedAt = nil
        let stream = activeManager
        activeManager = nil
        stream?.stopUpdatingLocation()
        stream?.delegate = nil
    }

    /// Explicit teardown for the window that owns the view. Releasing the
    /// delegate prevents a late system callback from touching a closed view.
    public func shutdown() {
        stop()
        manager.delegate = nil
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager || manager === activeManager else { return }
        onEvent?(.authorizationChanged(Self.map(manager.authorizationStatus)))
        onEvent?(.precisionChanged(manager.accuracyAuthorization == .fullAccuracy))
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let token = activeToken, let value = locations.last,
              MacLocationCallbackGate.accepts(sender: manager, active: activeManager,
                                               startedAt: startedAt, timestamp: value.timestamp, now: Date()) else { return }
        let fix = ToolboxLocationFix(
            latitude: value.coordinate.latitude,
            longitude: value.coordinate.longitude,
            horizontalAccuracy: value.horizontalAccuracy,
            timestamp: value.timestamp,
            altitude: value.altitude,
            verticalAccuracy: value.verticalAccuracy,
            speed: value.speed,
            course: value.course)
        guard fix.isFresh(at: Date()) else { return }
        onEvent?(.precisionChanged(manager.accuracyAuthorization == .fullAccuracy))
        onEvent?(.fix(token: token, fix))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard manager === activeManager, let token = activeToken else { return }
        let failure: MacLocationFailure
        switch (error as? CLError)?.code {
        case .denied:
            failure = .denied
        case .locationUnknown:
            failure = .temporarilyUnavailable
        default:
            // Do not surface a localized system diagnostic that may contain a
            // path or another app's identifier. The phase is actionable enough.
            failure = .unavailable("system location error")
        }
        onEvent?(.failure(token: token, failure))
    }

    private static func map(_ status: CLAuthorizationStatus) -> MacLocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedAlways: .authorized
        @unknown default: .denied
        }
    }
}

@MainActor
@Observable
public final class MacLocationModel {
    public private(set) var phase: MacLocationPhase = .idle
    public private(set) var fix: ToolboxLocationFix?
    public private(set) var precise = true
    public private(set) var places: [ToolboxSavedLocation] = []
    public private(set) var placesFailure: MacInstrumentNotice?
    private var localOperationNotice: MacInstrumentNotice?
    public var operationNotice: MacInstrumentNotice? { activity?.locationFailure ?? localOperationNotice }
    public private(set) var saving = false
    public var draftPlaceName = ""
    public private(set) var successfulSaveSequence = 0
    public private(set) var lastSavedName: String?

    private let source: any MacLocationSource
    private let archive: ToolboxLocationArchive
    private let activity: MacInstrumentActivityCoordinator?
    private let loadOperation: @Sendable () async throws -> [ToolboxSavedLocation]
    private let saveOperation: @Sendable (String, ToolboxLocationFix) async throws -> [ToolboxSavedLocation]
    private var placesRevision: UInt64 = 0
    private var activeToken: UUID?
    private var wantsUpdates = false
    private var didRequestAuthorization = false

    public init(source: any MacLocationSource = CoreLocationMacSource(),
                archive: ToolboxLocationArchive = MacLocationModel.defaultArchive,
                activity: MacInstrumentActivityCoordinator? = nil,
                loadOperation: (@Sendable () async throws -> [ToolboxSavedLocation])? = nil,
                saveOperation: (@Sendable (String, ToolboxLocationFix) async throws -> [ToolboxSavedLocation])? = nil) {
        self.source = source
        self.archive = archive
        self.activity = activity
        self.loadOperation = loadOperation ?? { try await archive.load() }
        self.saveOperation = saveOperation ?? { name, fix in try await archive.save(name: name, fix: fix) }
        source.onEvent = { [weak self] event in self?.receive(event) }
    }

    public func activateLifecycle() {
        activity?.registerLocationStop { [weak self] in self?.stop() }
    }

    public static var defaultArchive: ToolboxLocationArchive {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return ToolboxLocationArchive(url: root.appendingPathComponent("FloeAgent/Toolbox/locations.json"))
    }

    public var isUpdating: Bool { phase == .locating || phase == .live }

    /// Starts a foreground observation. A not-determined app asks the system
    /// once; a denied/restricted app never retries silently. Starting from an
    /// already-authorized state begins updates immediately.
    public func start() {
        guard activity?.acceptsNewWork != false else { return }
        wantsUpdates = true
        guard source.servicesEnabled else {
            wantsUpdates = false
            phase = .disabled
            return
        }
        switch source.authorization {
        case .denied:
            wantsUpdates = false
            phase = .denied
        case .restricted:
            wantsUpdates = false
            phase = .restricted
        case .notDetermined:
            phase = .permission
            if !didRequestAuthorization {
                didRequestAuthorization = true
                source.requestWhenInUseAuthorization()
            }
        case .authorized:
            beginUpdates()
        }
    }

    /// Stops sampling and retains the last real fix as a paused reading. The
    /// next explicit Start resumes with a fresh token.
    public func pause() {
        wantsUpdates = false
        stopStream()
        phase = fix == nil ? .idle : .paused
    }

    /// Stops sampling and clears the active state. The last real fix is kept
    /// only for the current view session, not turned into a new location.
    public func stop() {
        wantsUpdates = false
        stopStream()
        phase = .idle
    }

    /// Requests one new foreground observation. The old token is stopped
    /// before the new one starts, so a late callback cannot complete it.
    public func refresh() {
        guard activity?.acceptsNewWork != false else { return }
        wantsUpdates = true
        stopStream()
        guard source.servicesEnabled else {
            wantsUpdates = false
            phase = .disabled
            return
        }
        switch source.authorization {
        case .authorized: beginUpdates()
        case .notDetermined:
            phase = .permission
            if !didRequestAuthorization {
                didRequestAuthorization = true
                source.requestWhenInUseAuthorization()
            }
        case .denied: wantsUpdates = false; phase = .denied
        case .restricted: wantsUpdates = false; phase = .restricted
        }
    }

    /// Called when the location tool leaves the screen or the window closes.
    public func shutdown() {
        wantsUpdates = false
        stopStream()
        source.onEvent = nil
        if let concrete = source as? CoreLocationMacSource { concrete.shutdown() }
        phase = .idle
    }

    public func clearOperationNotice() {
        localOperationNotice = nil
        activity?.acknowledgeLocationFailure()
    }

    public func loadPlaces() async {
        let revision = placesRevision
        do {
            let loaded = try await loadOperation()
            guard revision == placesRevision else { return }
            places = loaded
            placesFailure = nil
        } catch {
            guard revision == placesRevision else { return }
            places = []
            placesFailure = MacInstrumentNotice(
                zh: "地点记录无法读取，原文件已保留。请修复或移除该文件后重试。",
                en: "Saved places could not be read. The original file was preserved. Repair or remove it and try again.")
        }
    }

    public func savePlace(_ rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fix, !name.isEmpty, !saving, operationNotice == nil else { return }
        let token = activity?.begin()
        guard activity == nil || token != nil else { return }
        defer { if let token { activity?.finish(token) } }
        saving = true
        placesRevision &+= 1
        await performSavePlace(name, fix: fix)
    }

    @discardableResult
    public func requestSavePlace(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fix, !trimmed.isEmpty, !saving, operationNotice == nil else { return false }
        saving = true
        placesRevision &+= 1
        if let activity {
            guard activity.enqueue({ [self] in await performSavePlace(trimmed, fix: fix) }) else {
                saving = false
                return false
            }
            return true
        }
        Task { await performSavePlace(trimmed, fix: fix) }
        return true
    }

    private func performSavePlace(_ name: String, fix: ToolboxLocationFix) async {
        defer { saving = false; placesRevision &+= 1 }
        do {
            places = try await saveOperation(name, fix)
            localOperationNotice = nil
            placesFailure = nil
            lastSavedName = name
            successfulSaveSequence += 1
            if draftPlaceName.trimmingCharacters(in: .whitespacesAndNewlines) == name {
                draftPlaceName = ""
            }
        } catch ToolboxLocationArchive.ArchiveError.archiveFull {
            recordFailure(MacInstrumentNotice(
                zh: "最多保存 200 个地点。请先删除不再需要的标记。",
                en: "You can save up to 200 places. Remove an unneeded place first."))
        } catch ToolboxLocationArchive.ArchiveError.invalidLocation {
            recordFailure(MacInstrumentNotice(
                zh: "地点名称或位置数据无效，请检查后重试。",
                en: "The place name or location data is invalid. Check it and try again."))
        } catch {
            await loadPlaces()
            recordFailure(MacInstrumentNotice(
                zh: "无法确认地点是否保存，地点可能已创建。请先检查列表，再决定是否重试。",
                en: "The place may have been saved, but the result could not be confirmed. Check the list before retrying."))
        }
    }

    public func removePlace(id: UUID) async {
        guard !saving, operationNotice == nil else { return }
        let token = activity?.begin()
        guard activity == nil || token != nil else { return }
        defer { if let token { activity?.finish(token) } }
        saving = true
        placesRevision &+= 1
        await performRemovePlace(id: id)
    }

    public func requestRemovePlace(id: UUID) {
        guard !saving, operationNotice == nil else { return }
        saving = true
        placesRevision &+= 1
        if let activity {
            if !activity.enqueue({ [self] in await performRemovePlace(id: id) }) { saving = false }
        }
        else { Task { await performRemovePlace(id: id) } }
    }

    private func performRemovePlace(id: UUID) async {
        defer { saving = false; placesRevision &+= 1 }
        do {
            places = try await archive.remove(id: id)
            localOperationNotice = nil
            placesFailure = nil
        } catch {
            await loadPlaces()
            recordFailure(MacInstrumentNotice(
                zh: "无法确认地点是否删除。请先检查列表，再决定是否重试。",
                en: "The removal could not be confirmed. Check the list before retrying."))
        }
    }

    private func recordFailure(_ notice: MacInstrumentNotice) {
        localOperationNotice = notice
        activity?.recordLocationFailure(notice)
    }

    private func beginUpdates() {
        guard activity?.acceptsNewWork != false else { return }
        if activeToken != nil { stopStream() }
        let token = UUID()
        activeToken = token
        phase = .locating
        source.start(token: token)
    }

    private func stopStream() {
        activeToken = nil
        source.stop()
    }

    private func receive(_ event: MacLocationSourceEvent) {
        switch event {
        case .authorizationChanged(let authorization):
            precise = source.precise
            switch authorization {
            case .authorized:
                if wantsUpdates, activeToken == nil, phase == .permission || phase == .idle || phase == .paused {
                    beginUpdates()
                }
            case .denied:
                wantsUpdates = false
                stopStream()
                phase = .denied
            case .restricted:
                wantsUpdates = false
                stopStream()
                phase = .restricted
            case .notDetermined:
                if wantsUpdates { phase = .permission }
            }
        case .precisionChanged(let value):
            precise = value
        case .fix(let token, let value):
            guard wantsUpdates, token == activeToken, value.isValid else { return }
            fix = value
            phase = .live
        case .failure(let token, let failure):
            guard token == activeToken else { return }
            wantsUpdates = false
            stopStream()
            switch failure {
            case .servicesDisabled: phase = .disabled
            case .denied: phase = .denied
            case .restricted: phase = .restricted
            case .temporarilyUnavailable, .unavailable: phase = .unavailable
            }
        }
    }
}
