import SwiftUI
import FloeToolboxUtilities
import FloeToolboxWorkbenches

@main struct LocationPreviewApp: App {
    var body: some Scene { WindowGroup { LocationPreviewRoot() } }
}

private struct LocationPreviewRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var center = LocationServicesCenter.shared
    @State private var places: [ToolboxSavedLocation] = []
    @State private var owner = UUID()
    @State private var requested = false
    private let arguments = ProcessInfo.processInfo.arguments
    private var fixture: Bool { arguments.contains("--location-fixture") }
    private static let archive = ToolboxLocationArchive(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocationPreview/places.json"))
    private var fix: ToolboxLocationFix? {
        if fixture { return .init(latitude: -33.8568, longitude: 151.2153, horizontalAccuracy: 12, timestamp: Date(timeIntervalSince1970: 1_790_000_000), altitude: 12, verticalAccuracy: 8, speed: 1.2, course: 45) }
        return center.foregroundLocation.map { .init(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracy: $0.accuracy, timestamp: $0.timestamp, altitude: $0.altitude, verticalAccuracy: $0.verticalAccuracy, speed: $0.speed, course: $0.course) }
    }
    private var phase: ToolboxLocationPhase {
        if fixture { return .paused }
        return switch center.foregroundState {
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
    var body: some View {
        NavigationStack {
            ToolboxLocationWorkbench(fix: fix, phase: phase, precise: !fixture && center.foregroundPrecise, places: places,
                start: { if !fixture { requested = true; center.beginForegroundObservation(owner: owner) } },
                pause: { requested = false; center.endForegroundObservation(owner: owner) },
                refresh: { if !fixture { requested = true; center.refreshForegroundObservation(owner: owner) } },
                savePlace: { name, value in places = try await Self.archive.save(name: name, fix: value) },
                removePlace: { id in places = try await Self.archive.remove(id: id) })
                .navigationTitle("定位与地图").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) {
                    if fixture { Text("合成界面样例 · 非设备定位 / Synthetic UI fixture · Not a device fix").font(.caption).padding(8).frame(maxWidth: .infinity).background(.yellow.opacity(0.15)) }
                }
        }
        .frame(maxWidth: arguments.contains("--compact") ? 390 : .infinity).frame(maxWidth: .infinity)
        .preferredColorScheme(arguments.contains("--dark") ? .dark : nil)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        .environment(\.dynamicTypeSize, arguments.contains("--large-text") ? .accessibility2 : .large)
        .onAppear { center.applyBackgroundLocationInputs(supportEnabled: false, workEligible: false, fullyBackgroundScene: false) }
        .onChange(of: scenePhase) { _, value in
            center.applyBackgroundLocationInputs(supportEnabled: false, workEligible: false, fullyBackgroundScene: value != .active)
            if value == .active && requested { center.beginForegroundObservation(owner: owner) }
            else if value != .active { center.endForegroundObservation(owner: owner) }
        }
        .task { places = (try? await Self.archive.load()) ?? [] }
        .onDisappear { center.endForegroundObservation(owner: owner) }
    }
}
