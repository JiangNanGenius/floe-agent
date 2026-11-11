import SwiftUI
import FloeToolboxCore
import FloeToolboxUI
import FloeToolboxUtilities
import FloeToolboxWorkbenches

@main
struct ToolboxQualificationApp: App {
    var body: some Scene { WindowGroup { QualificationRoot() } }
}

private struct QualificationRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: ToolboxTool?
    private let arguments = ProcessInfo.processInfo.arguments
    private var compact: Bool { arguments.contains("--compact") }
    var body: some View {
        NavigationStack {
            ToolboxHomeView(availability: Dictionary(uniqueKeysWithValues: ToolboxTool.allCases.map { ($0, .available) })) { selection = $0 }
                .navigationDestination(item: $selection) { tool in
                    destination(tool).navigationTitle(tool.title(in: .current)).navigationBarTitleDisplayMode(.inline)
                }
        }
        .frame(maxWidth: compact ? 390 : .infinity)
        .frame(maxWidth: .infinity)
        .preferredColorScheme(arguments.contains("--dark") ? .dark : nil)
        .environment(\.dynamicTypeSize, arguments.contains("--large-text") ? .accessibility2 : .large)
        .onAppear {
            LocationServicesCenter.shared.applyBackgroundLocationInputs(supportEnabled: false, workEligible: false, fullyBackgroundScene: false)
            if let index = arguments.firstIndex(of: "--tool"), arguments.indices.contains(index + 1) {
                selection = ToolboxTool(rawValue: arguments[index + 1])
            }
        }
        .onChange(of: scenePhase) { _, value in
            LocationServicesCenter.shared.applyBackgroundLocationInputs(supportEnabled: false, workEligible: false, fullyBackgroundScene: value != .active)
        }
    }
    @ViewBuilder private func destination(_ tool: ToolboxTool) -> some View {
        switch tool {
        #if !TOOLBOX_LOCATION_ONLY
        case .level: ToolboxLevelView()
        case .motion: ToolboxMotionView()
        case .compass: ToolboxCompassView()
        case .ruler: ToolboxRulerView()
        case .measure: ToolboxSpatialMeasurementView()
        case .calculator: ToolboxCalculatorView()
        case .photoMeasure: QualificationPhoto(fixture: arguments.contains("--photo-fixture"))
        case .timer: ToolboxTimerView()
        #if !TOOLBOX_FIRST_BATCH_ONLY
        case .barometer: ToolboxPressureView()
        case .sound: ToolboxSoundView()
        case .magnifier: ToolboxMagnifierView()
        case .scanner: QualificationScanner(fixture: arguments.contains("--scanner-fixture"))
        #endif
        #endif
        case .location: QualificationLocation(fixture: arguments.contains("--location-fixture"))
        default: ContentUnavailableView("Existing App tool", systemImage: tool.symbol)
        }
    }
}

private struct QualificationLocation: View {
    @ObservedObject private var center = LocationServicesCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = UUID()
    @State private var requested = false
    @State private var places: [ToolboxSavedLocation] = []
    let fixture: Bool
    private static let archive = ToolboxLocationArchive(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ToolboxQualification/places.json"))
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
        ToolboxLocationWorkbench(fix: fix, phase: phase, precise: !fixture && center.foregroundPrecise, places: places,
            start: { requested = true; if !fixture { center.beginForegroundObservation(owner: owner) } },
            pause: { requested = false; center.endForegroundObservation(owner: owner) },
            refresh: { if !fixture { requested = true; center.refreshForegroundObservation(owner: owner) } },
            savePlace: { name, fix in places = try await Self.archive.save(name: name, fix: fix) },
            removePlace: { id in places = try await Self.archive.remove(id: id) })
        .safeAreaInset(edge: .top) {
            if fixture { Text("合成界面样例 · 非设备定位 / Synthetic UI fixture · Not a device fix").font(.caption).padding(8).frame(maxWidth: .infinity).background(.yellow.opacity(0.15)) }
        }
        .task { places = (try? await Self.archive.load()) ?? [] }
        .onChange(of: scenePhase) { _, value in
            if value == .active && requested && !fixture { center.beginForegroundObservation(owner: owner) }
            else { center.endForegroundObservation(owner: owner) }
        }
        .onDisappear { center.endForegroundObservation(owner: owner) }
    }
}
