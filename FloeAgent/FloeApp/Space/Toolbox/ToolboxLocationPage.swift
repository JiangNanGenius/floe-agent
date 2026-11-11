// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import FloeToolboxUtilities
import FloeToolboxWorkbenches

@MainActor
private final class ToolboxSavedPlacesCenter: ObservableObject {
    static let shared = ToolboxSavedPlacesCenter()
    @Published private(set) var places: [ToolboxSavedLocation] = []
    @Published private(set) var loadFailed = false
    private let archive: Result<ToolboxLocationArchive, any Error>
    private init() {
        archive = Result {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            return ToolboxLocationArchive(url: root.appendingPathComponent("FloeAgent/Toolbox/locations.json"))
        }
    }
    func load() async {
        do { places = try await archive.get().load(); loadFailed = false }
        catch { loadFailed = true }
    }
    func save(_ name: String, _ fix: ToolboxLocationFix) async throws {
        places = try await archive.get().save(name: name, fix: fix); loadFailed = false
    }
    func remove(_ id: UUID) async throws {
        places = try await archive.get().remove(id: id); loadFailed = false
    }
}

struct ToolboxLocationPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @ObservedObject private var location = LocationServicesCenter.shared
    @ObservedObject private var saved = ToolboxSavedPlacesCenter.shared
    @State private var owner = UUID()
    @State private var requested = false
    private func t(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }

    var body: some View {
        ToolboxLocationWorkbench(fix: fix, phase: phase, precise: location.foregroundPrecise, places: saved.places,
            start: start, pause: pause, refresh: refresh,
            savePlace: { try await saved.save($0, $1) }, removePlace: { try await saved.remove($0) },
            saveNote: saveNote)
            .task {
                location.refreshAuthorizationStatus()
                if requested && scenePhase == .active { location.beginForegroundObservation(owner: owner) }
                await saved.load()
            }
            .onChange(of: scenePhase) { _, value in
                if value == .active { location.refreshAuthorizationStatus(); if requested { location.beginForegroundObservation(owner: owner) } }
                else { location.endForegroundObservation(owner: owner) }
            }
            .onDisappear { location.endForegroundObservation(owner: owner) }
            .safeAreaInset(edge: .bottom) {
                if saved.loadFailed {
                    HStack {
                        Label(t("地点记录未能读取", "Saved places could not be loaded"), systemImage: "exclamationmark.circle")
                        Spacer()
                        Button(t("重试", "Retry")) { Task { await saved.load() } }
                    }.font(.subheadline).padding().background(.bar)
                }
            }
    }

    private var fix: ToolboxLocationFix? {
        location.foregroundLocation.map {
            .init(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracy: $0.accuracy,
                  timestamp: $0.timestamp, altitude: $0.altitude, verticalAccuracy: $0.verticalAccuracy,
                  speed: $0.speed, course: $0.course)
        }
    }
    private var phase: ToolboxLocationPhase {
        if !requested { return location.foregroundLocation == nil ? .idle : .paused }
        return switch location.foregroundState {
        case .idle: .idle
        case .waitingForPermission: .permission
        case .locating: .locating
        case .active: .live
        case .paused: .paused
        case .denied: .denied
        case .servicesDisabled: .disabled
        case .unavailable: .unavailable
        }
    }
    private func start() {
        requested = true
        guard scenePhase == .active else { return }
        location.beginForegroundObservation(owner: owner)
    }
    private func pause() { requested = false; location.endForegroundObservation(owner: owner) }
    private func refresh() {
        requested = true
        guard scenePhase == .active else { return }
        location.refreshForegroundObservation(owner: owner)
    }

    private func saveNote(_ fix: ToolboxLocationFix) async throws {
        let title = t("定位记录", "Location record") + " " + fix.timestamp.formatted(date: .abbreviated, time: .shortened)
        let unknown = t("暂无数据", "Unavailable")
        let altitude = fix.altitude.map { $0.formatted(.number.precision(.fractionLength(1))) + " m" } ?? unknown
        let speed = fix.speed.map { ($0 * 3.6).formatted(.number.precision(.fractionLength(1))) + " km/h" } ?? unknown
        let text = """
        # \(title)

        \(t("坐标", "Coordinates")): \(fix.coordinateText)
        \(t("水平精度", "Horizontal accuracy")): \(fix.horizontalAccuracy.formatted()) m
        \(t("海拔", "Altitude")): \(altitude)
        \(t("速度", "Speed")): \(speed)
        \(t("采样时间", "Sample time")): \(fix.timestamp.ISO8601Format())

        \(fix.mapsURL?.absoluteString ?? "")
        """
        try await ToolboxNotesExport.save(title: title, text: text)
    }
}
#endif
