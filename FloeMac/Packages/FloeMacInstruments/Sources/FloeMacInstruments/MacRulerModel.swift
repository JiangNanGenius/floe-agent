// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox — per-display ruler calibration.
//
// A Mac can move a window between displays with different pixel densities and
// resolutions. A calibration therefore records the actual NSScreen identity,
// its backing scale and its resolution band. Moving to another display
// invalidates the physical readout until the user calibrates there; the ruler
// never assumes a DPI from a Mac model or from its own window size.

import AppKit
import Foundation
import Observation
import FloeToolboxUtilities

public struct MacDisplayIdentity: Equatable, Codable, Sendable {
    @MainActor private static var topologyNonce = UUID()
    @MainActor static func invalidateTopology() { topologyNonce = UUID() }
    public let displayID: UInt32
    public let nativeScale: Double
    public let widthPoints: Double
    public let heightPoints: Double
    public let name: String
    public let modeKey: String
    public let stableID: String
    public let topologyID: UUID?

    public init(displayID: UInt32, nativeScale: Double, size: CGSize, name: String, modeKey: String = "", stableID: String? = nil, topologyID: UUID? = nil) {
        self.displayID = displayID
        self.nativeScale = nativeScale
        self.widthPoints = size.width
        self.heightPoints = size.height
        self.name = name
        self.modeKey = modeKey
        self.stableID = stableID ?? "synthetic:\(displayID):\(name)"
        self.topologyID = topologyID
    }

    @MainActor
    public init?(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let number else { return nil }
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        guard scale.isFinite, scale > 0, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        guard let mode = CGDisplayCopyDisplayMode(number.uint32Value) else { return nil }
        let vendor = CGDisplayVendorNumber(number.uint32Value)
        let model = CGDisplayModelNumber(number.uint32Value)
        let serial = CGDisplaySerialNumber(number.uint32Value)
        let matches = NSScreen.screens.filter { candidate in
            guard let other = candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let id = other.uint32Value
            return CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == model && CGDisplaySerialNumber(id) == serial
        }.count
        let stableID = vendor != 0 && model != 0 && serial != 0 && matches == 1
            ? "display:\(vendor):\(model):\(serial)"
            : "unverified:\(Self.topologyNonce):\(number.uint32Value)"
        self.init(displayID: number.uint32Value,
                  nativeScale: Double(scale),
                  size: size,
                  name: screen.localizedName,
                  modeKey: "\(mode.width)x\(mode.height):\(mode.pixelWidth)x\(mode.pixelHeight):\(mode.refreshRate.bitPattern):\(mode.ioFlags)",
                  stableID: stableID, topologyID: Self.topologyNonce)
    }

    public var isUsable: Bool {
        nativeScale.isFinite && nativeScale > 0
            && widthPoints.isFinite && widthPoints > 0
            && heightPoints.isFinite && heightPoints > 0
            && !name.isEmpty
    }

    /// Resolution band, not window size. Resizing the toolbox window does not
    /// invalidate a physical calibration; changing the display mode does.
    public var viewportKey: String {
        "\(widthPoints.bitPattern)x\(heightPoints.bitPattern):\(modeKey)"
    }
}

public struct MacRulerCalibrationRecord: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let nativeScale: Double
    public let viewportKey: String
    public let displayName: String
    public let stableID: String?
    public let pointsPerMillimeter: Double
    public let timestamp: Date

    public init(calibration: EverydayRulerCalibration, display: MacDisplayIdentity) {
        displayID = display.displayID
        nativeScale = calibration.nativeScale
        viewportKey = calibration.viewportKey
        displayName = display.name
        stableID = display.stableID
        pointsPerMillimeter = calibration.pointsPerMillimeter
        timestamp = calibration.timestamp
    }

    public func calibration(display: MacDisplayIdentity) -> EverydayRulerCalibration? {
        guard isCompatible(with: display) else { return nil }
        return EverydayRulerCalibration(pointsPerMillimeter: pointsPerMillimeter,
                                        nativeScale: nativeScale,
                                        viewportKey: viewportKey,
                                        timestamp: timestamp)
    }

    public func isCompatible(with display: MacDisplayIdentity) -> Bool {
        stableID == display.stableID
            && displayName == display.name
            && viewportKey == display.viewportKey
            && abs(nativeScale - display.nativeScale) < 0.01
            && pointsPerMillimeter.isFinite && pointsPerMillimeter > 0
            && timestamp.timeIntervalSince1970.isFinite
    }
}

public enum MacRulerStoreError: Error, Equatable, Sendable {
    case corrupt
    case invalid
    case capacity
    case changed
}

private struct MacRulerCalibrationFile: Codable, Equatable, Sendable {
    var version: Int
    var records: [MacRulerCalibrationRecord]
}

public actor MacRulerCalibrationStore {
    public static let maximumRecords = 16
    public static let maximumFileBytes = 65_536

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [MacRulerCalibrationRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumFileBytes else { throw MacRulerStoreError.corrupt }
        let data = try Data(contentsOf: url)
        let file: MacRulerCalibrationFile
        do {
            file = try JSONDecoder().decode(MacRulerCalibrationFile.self, from: data)
        } catch {
            throw MacRulerStoreError.corrupt
        }
        guard file.version == 1, file.records.count <= Self.maximumRecords,
              Set(file.records.compactMap(\.stableID)).count == file.records.compactMap(\.stableID).count,
              file.records.allSatisfy({ record in
                  record.pointsPerMillimeter.isFinite && record.pointsPerMillimeter > 0
                      && record.nativeScale.isFinite && record.nativeScale > 0
                      && !record.viewportKey.isEmpty
                      && record.timestamp.timeIntervalSince1970.isFinite
              }) else {
            throw MacRulerStoreError.corrupt
        }
        return file.records
    }

    public func save(_ records: [MacRulerCalibrationRecord]) throws {
        guard records.count <= Self.maximumRecords,
              Set(records.compactMap(\.stableID)).count == records.compactMap(\.stableID).count,
              records.allSatisfy({ $0.pointsPerMillimeter.isFinite && $0.pointsPerMillimeter > 0 }) else {
            throw MacRulerStoreError.invalid
        }
        let data = try JSONEncoder().encode(MacRulerCalibrationFile(version: 1, records: records))
        guard data.count <= Self.maximumFileBytes else { throw MacRulerStoreError.invalid }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// One actor turn owns the complete read-modify-write. Runtime display IDs
    /// can be reused by another monitor, so only the stable identity selects a
    /// record. Records without a stable identity are preserved.
    public func upsert(_ record: MacRulerCalibrationRecord) throws -> [MacRulerCalibrationRecord] {
        guard let identity = record.stableID, !identity.isEmpty else { throw MacRulerStoreError.invalid }
        var values = try load()
        values.removeAll { $0.stableID == identity }
        guard values.count < Self.maximumRecords else { throw MacRulerStoreError.capacity }
        values.append(record)
        try save(values)
        return values
    }

    public func remove(stableID: String) throws -> [MacRulerCalibrationRecord] {
        guard !stableID.isEmpty else { throw MacRulerStoreError.invalid }
        var values = try load()
        values.removeAll { $0.stableID == stableID }
        if values.isEmpty { try clear() } else { try save(values) }
        return values
    }

    public static func obsoleteUnverifiedIDs(_ records: [MacRulerCalibrationRecord],
                                             currentTopology: UUID) -> Set<String> {
        Set(records.compactMap { record in
            guard let identity = record.stableID else { return nil }
            let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "unverified",
                  let topology = UUID(uuidString: String(parts[1])),
                  UInt32(parts[2]) != nil, topology != currentTopology else { return nil }
            return identity
        })
    }

    /// Reject if the reviewed set changed before commit. Reliable, legacy and
    /// current-topology records never match this explicit cleanup.
    public func removeObsoleteUnverified(expected: Set<String>, currentTopology: UUID) throws -> [MacRulerCalibrationRecord] {
        let values = try load()
        let actual = Self.obsoleteUnverifiedIDs(values, currentTopology: currentTopology)
        guard !actual.isEmpty, actual == expected else { throw MacRulerStoreError.changed }
        let retained = values.filter { record in
            guard let identity = record.stableID else { return true }
            return !actual.contains(identity)
        }
        if retained.isEmpty { try clear() } else { try save(retained) }
        return retained
    }
}

public enum MacRulerStorageFailure: Equatable, Sendable {
    case load
    case corrupt
    case save
    case clear
    case invalid
    case capacity
}

public enum MacRulerReferencePreset: String, CaseIterable, Identifiable, Sendable {
    case creditCard
    case idCard
    case a4
    case custom

    public var id: String { rawValue }

    public func title(_ locale: Locale) -> String {
        switch self {
        case .creditCard: macToolboxText("银行卡（85.60 毫米）", "Bank card (85.60 mm)", locale)
        case .idCard: macToolboxText("身份证（85.60 毫米）", "ID card (85.60 mm)", locale)
        case .a4: macToolboxText("A4 纸短边（210 毫米）", "A4 short edge (210 mm)", locale)
        case .custom: macToolboxText("自定义长度", "Custom length", locale)
        }
    }
}

@MainActor
@Observable
public final class MacRulerModel {
    public var markA = CGPoint(x: 90, y: 200)
    public var markB = CGPoint(x: 300, y: 200)
    public var vertex = CGPoint(x: 200, y: 240)
    public var armEnd1 = CGPoint(x: 120, y: 170)
    public var armEnd2 = CGPoint(x: 290, y: 160)
    public var referencePreset: MacRulerReferencePreset = .creditCard
    public var customReferenceMillimeters = "100"

    public private(set) var display: MacDisplayIdentity?
    public private(set) var calibration: MacRulerCalibrationRecord?
    private var localStorageFailure: MacRulerStorageFailure?
    public var storageFailure: MacRulerStorageFailure? { activity?.rulerFailure ?? localStorageFailure }
    public private(set) var records: [MacRulerCalibrationRecord] = []
    public private(set) var storageIsReady = false

    public let store: MacRulerCalibrationStore
    private let activity: MacInstrumentActivityCoordinator?
    private let loadRecords: @Sendable () async throws -> [MacRulerCalibrationRecord]
    private let upsertRecord: @Sendable (MacRulerCalibrationRecord) async throws -> [MacRulerCalibrationRecord]
    private let removeRecord: @Sendable (String) async throws -> [MacRulerCalibrationRecord]
    private var loadGeneration = UUID()
    private var hasPlacedMarks = false
    private var lastBounds: CGSize?
    private var storageIsUnsafe = false

    public init(store: MacRulerCalibrationStore = MacRulerModel.defaultStore,
                activity: MacInstrumentActivityCoordinator? = nil,
                loadRecords: (@Sendable () async throws -> [MacRulerCalibrationRecord])? = nil,
                upsertRecord: (@Sendable (MacRulerCalibrationRecord) async throws -> [MacRulerCalibrationRecord])? = nil,
                removeRecord: (@Sendable (String) async throws -> [MacRulerCalibrationRecord])? = nil) {
        self.store = store
        self.activity = activity
        self.loadRecords = loadRecords ?? { try await store.load() }
        self.upsertRecord = upsertRecord ?? { try await store.upsert($0) }
        self.removeRecord = removeRecord ?? { try await store.remove(stableID: $0) }
    }

    public static var defaultStore: MacRulerCalibrationStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return MacRulerCalibrationStore(url: root.appendingPathComponent("FloeAgent/Toolbox/MacRulerCalibration.json"))
    }

    public static let handleHitSize: CGFloat = 44

    public var referenceMillimetres: Double? {
        switch referencePreset {
        case .creditCard, .idCard: return 85.60
        case .a4: return 210
        case .custom:
            let text = customReferenceMillimeters.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = text.contains(".") ? text : text.replacingOccurrences(of: ",", with: ".")
            return Double(normalized).flatMap { $0.isFinite && (0.1...1000).contains($0) ? $0 : nil }
        }
    }

    public var pointsPerMillimeter: Double? {
        guard let display, let calibration, calibration.isCompatible(with: display) else { return nil }
        return calibration.pointsPerMillimeter
    }

    public var isCurrentDisplayCalibrated: Bool { pointsPerMillimeter != nil }

    public var calibrationDisplayName: String? { calibration?.displayName }

    public var obsoleteUnverifiedIDs: Set<String> {
        guard let topology = display?.topologyID else { return [] }
        return MacRulerCalibrationStore.obsoleteUnverifiedIDs(records, currentTopology: topology)
    }

    public func invalidateDisplay() {
        loadGeneration = UUID()
        storageIsReady = false
        display = nil
        calibration = nil
    }

    public func load(display newDisplay: MacDisplayIdentity?) async {
        let generation = UUID()
        loadGeneration = generation
        storageIsReady = false
        display = newDisplay
        do {
            let loaded = try await loadRecords()
            guard loadGeneration == generation else { return }
            records = loaded
            storageIsUnsafe = false
            localStorageFailure = nil
        } catch MacRulerStoreError.corrupt {
            guard loadGeneration == generation else { return }
            records = []
            storageIsUnsafe = true
            localStorageFailure = .corrupt
        } catch {
            guard loadGeneration == generation else { return }
            records = []
            storageIsUnsafe = true
            localStorageFailure = .load
        }
        storageIsReady = true
        refreshCurrentCalibration()
    }

    public func calibrate(separation: CGFloat) async {
        let token = activity?.begin()
        guard activity == nil || token != nil else { return }
        defer { if let token { activity?.finish(token) } }
        await performCalibration(separation: separation)
    }

    public func requestCalibration(separation: CGFloat) {
        if let activity { activity.enqueue { [self] in await performCalibration(separation: separation) } }
        else { Task { await performCalibration(separation: separation) } }
    }

    private func performCalibration(separation: CGFloat) async {
        guard storageIsReady, activity?.rulerFailure == nil,
              let display, let referenceMillimetres, separation.isFinite, separation >= 10 else { return }
        do {
            let value = try EverydayRulerGeometry.calibrate(
                knownMillimeters: referenceMillimetres,
                measuredPoints: Double(separation),
                nativeScale: display.nativeScale,
                viewportKey: display.viewportKey)
            let record = MacRulerCalibrationRecord(calibration: value, display: display)
            var updated = records.filter { $0.stableID != display.stableID }
            updated.append(record)
            calibration = record
            guard !storageIsUnsafe else { records = updated; return }
            localStorageFailure = nil
            do {
                records = try await upsertRecord(record)
            } catch MacRulerStoreError.capacity {
                calibration = nil
                localStorageFailure = .capacity
                activity?.recordRulerFailure(.capacity)
            } catch {
                // Keep the calibration for this session; only persistence failed.
                records = updated
                localStorageFailure = .save
                activity?.recordRulerFailure(.save)
            }
        } catch {
            localStorageFailure = .invalid
        }
    }

    public func clearCalibration() async {
        let token = activity?.begin()
        guard activity == nil || token != nil else { return }
        defer { if let token { activity?.finish(token) } }
        await performClearCalibration()
    }

    public func requestClearCalibration() {
        if let activity { activity.enqueue { [self] in await performClearCalibration() } }
        else { Task { await performClearCalibration() } }
    }

    private func performClearCalibration() async {
        guard storageIsReady, activity?.rulerFailure == nil, let display else { return }
        records.removeAll { $0.stableID == display.stableID }
        calibration = nil
        guard !storageIsUnsafe else { return }
        do {
            records = try await removeRecord(display.stableID)
            localStorageFailure = nil
        } catch {
            localStorageFailure = .clear
            activity?.recordRulerFailure(.clear)
        }
    }

    public func acknowledgeStorageFailureAfterReload() async {
        guard let display else { return }
        await load(display: display)
        guard storageIsReady, !storageIsUnsafe else { return }
        localStorageFailure = nil
        activity?.acknowledgeRulerFailure()
    }

    public func acknowledgeCapacityWithoutSaving() {
        guard storageFailure == .capacity else { return }
        localStorageFailure = nil
        activity?.acknowledgeRulerFailure()
    }

    public func requestRemoveObsoleteUnverified(expected: Set<String>) {
        guard storageFailure == .capacity, let topology = display?.topologyID else { return }
        guard !expected.isEmpty else { return }
        let operation: @MainActor () async -> Void = { [self] in
            do {
                records = try await store.removeObsoleteUnverified(expected: expected, currentTopology: topology)
                localStorageFailure = nil
                activity?.acknowledgeRulerFailure()
            } catch MacRulerStoreError.changed {
                // No write occurred; refresh the review set without hiding the
                // capacity warning or authorizing deletion of new entries.
                if let refreshed = try? await store.load() { records = refreshed }
            } catch {
                localStorageFailure = .clear
                activity?.recordRulerFailure(.clear)
            }
        }
        if let activity { activity.enqueue(operation) }
        else { Task { await operation() } }
    }

    public func beginRecalibration() {
        calibration = nil
        if !storageIsUnsafe { localStorageFailure = nil }
    }

    public func millimeters(points: Double) -> Double? {
        guard let pointsPerMillimeter, points.isFinite, points >= 0 else { return nil }
        return points / pointsPerMillimeter
    }

    public func angleDegrees() -> Double? {
        try? EverydayRulerGeometry.angleDegrees(vertex: vertex, first: armEnd1, second: armEnd2)
    }

    public func placeMarks(in bounds: CGSize) {
        guard Self.isUsableBounds(bounds) else { return }
        if !hasPlacedMarks {
            let y = Self.distanceTrackY(in: bounds)
            markA = CGPoint(x: bounds.width * 0.25, y: y)
            markB = CGPoint(x: bounds.width * 0.75, y: y)
            vertex = CGPoint(x: bounds.width / 2, y: bounds.height * 0.55)
            armEnd1 = CGPoint(x: bounds.width * 0.2, y: bounds.height * 0.3)
            armEnd2 = CGPoint(x: bounds.width * 0.8, y: bounds.height * 0.32)
            hasPlacedMarks = true
        }
        clampMarks(in: bounds)
    }

    public func resetMarks() {
        hasPlacedMarks = false
        if let lastBounds { placeMarks(in: lastBounds) }
    }

    public func clampMarks(in bounds: CGSize) {
        guard Self.isUsableBounds(bounds) else { return }
        if !hasPlacedMarks {
            placeMarks(in: bounds)
            return
        }
        lastBounds = bounds
        let inset = Self.handleHitSize / 2
        let clamp: (CGPoint) -> CGPoint = {
            CGPoint(x: min(max($0.x, inset), bounds.width - inset),
                    y: min(max($0.y, inset), bounds.height - inset))
        }
        let forward = markB.x >= markA.x
        let span = min(abs(markB.x - markA.x), bounds.width - inset * 2)
        let start = min(max(min(markA.x, markB.x), inset), bounds.width - inset - span)
        let y = Self.distanceTrackY(in: bounds)
        markA = CGPoint(x: forward ? start : start + span, y: y)
        markB = CGPoint(x: forward ? start + span : start, y: y)
        vertex = clamp(vertex)
        armEnd1 = clamp(armEnd1)
        armEnd2 = clamp(armEnd2)
    }

    public static func isUsableBounds(_ bounds: CGSize) -> Bool {
        bounds.width.isFinite && bounds.height.isFinite
            && bounds.width >= handleHitSize * 2 && bounds.height >= handleHitSize * 2
    }

    public static func distanceTrackY(in bounds: CGSize) -> CGFloat {
        let stripHeight: CGFloat = min(110, max(84, bounds.height * 0.3))
        let inset = handleHitSize / 2
        return min(max(stripHeight + (bounds.height - stripHeight) / 2, inset), max(inset, bounds.height - inset))
    }

    private func refreshCurrentCalibration() {
        guard let display else {
            calibration = nil
            return
        }
        calibration = records.first { $0.isCompatible(with: display) }
    }
}
