import SwiftUI
import FloeToolboxCore
import FloeToolboxUI
import FloeToolboxUtilities
import FloeToolboxDiagnostics
import FloeToolboxIPInformation
#if DEBUG
@testable import FloeToolboxWorkbenches
#else
import FloeToolboxWorkbenches
#endif

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
        .preferredColorScheme(arguments.contains("--dark") ? .dark : (arguments.contains("--light") ? .light : nil))
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
        case .level:
            #if DEBUG
            if arguments.contains("--level-fixture-flat") || arguments.contains("--level-fixture-upright") {
                QualificationLevelGauge(upright: arguments.contains("--level-fixture-upright"))
            } else { ToolboxLevelView() }
            #else
            ToolboxLevelView()
            #endif
        case .motion: ToolboxMotionView()
        case .compass: ToolboxCompassView()
        case .ruler: ToolboxRulerView()
        case .measure: ToolboxSpatialMeasurementView()
        case .calculator: ToolboxCalculatorView()
        case .photoMeasure: QualificationPhoto(fixture: arguments.contains("--photo-fixture"))
        case .timer: ToolboxTimerView()
        case .traceroute:
            QualificationTraceroute(usesRetainedData: arguments.contains("--ip-default-data"))
        #if !TOOLBOX_FIRST_BATCH_ONLY
        case .barometer: ToolboxPressureView()
        case .sound: ToolboxSoundView()
        case .magnifier: ToolboxMagnifierView()
        case .scanner: QualificationScanner(fixture: arguments.contains("--scanner-fixture"))
        case .qr: QualificationQR(fixture: arguments.contains("--qr-fixture"), linkFixture: arguments.contains("--qr-link-fixture"))
        #endif
        #endif
        case .location: QualificationLocation(fixture: arguments.contains("--location-fixture"))
        default: ContentUnavailableView("Existing App tool", systemImage: tool.symbol)
        }
    }
}

#if !TOOLBOX_LOCATION_ONLY
@MainActor
private struct QualificationTraceroute: View {
    @StateObject private var context: QualificationIPContext
    let usesRetainedData: Bool

    init(usesRetainedData: Bool) {
        self.usesRetainedData = usesRetainedData
        _context = StateObject(wrappedValue: QualificationIPContext(usesRetainedData: usesRetainedData))
    }

    var body: some View {
        Group {
            if let model = context.model {
                DiagnosticWorkbenchView(model: model, ipInformationSettings: AnyView(IPInformationSettingsShell(owner: context.owner)))
            } else {
                ContentUnavailableView("Unable to prepare network check", systemImage: "network")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 4) {
                Text("真实网络检查 · 仅 8.8.8.8 / Live check, limited to 8.8.8.8")
                if let model = context.model { QualificationTraceCounter(model: model) }
                if usesRetainedData {
                    Text("留存正式 DB-IP 数据 · 资格宿主 / Retained production DB-IP data in qualification host")
                    Button(context.installing ? "正在安装资料…" : "安装留存正式资料") {
                        Task { await context.installRetainedData() }
                    }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .disabled(context.installing)
                    .accessibilityIdentifier("qualification.traceroute.installRetained")
                    if let receipt = context.installReceipt {
                        Text(receipt).accessibilityIdentifier("qualification.traceroute.installReceipt")
                    }
                }
            }
            .font(.caption).padding(8).frame(maxWidth: .infinity)
            .background(.yellow.opacity(0.15))
        }
        .onDisappear { if let model = context.model { Task { await model.close() } } }
    }
}

@MainActor private struct QualificationTraceCounter: View {
    @ObservedObject var model: DiagnosticWorkbenchModel
    var body: some View {
        Text("Live hops: \(model.rows.count)").accessibilityIdentifier("qualification.traceroute.count")
    }
}

@MainActor private final class QualificationIPRelay {
    weak var model: DiagnosticWorkbenchModel?
}

@MainActor private final class QualificationIPContext: ObservableObject {
    let owner: IPInformationAppOwner
    let model: DiagnosticWorkbenchModel?
    @Published var installing = false
    @Published var installReceipt: String?

    init(usesRetainedData: Bool) {
        let relay = QualificationIPRelay()
        let folder = usesRetainedData ? "real" : "empty"
        let databaseOwner = IPInformationAppOwner(storageRoot: URL.applicationSupportDirectory
            .appendingPathComponent("ToolboxQualification/IP/" + folder, isDirectory: true),
            onDatabaseChanged: { relay.model?.refreshIPInformation() })
        owner = databaseOwner
        let lease = SessionLease(ownerID: UUID())
        let service = DiagnosticService(lease: lease) { observed, target, operation in
            guard observed == lease, target == "8.8.8.8" else { return false }
            if case .traceroute = operation { return true }
            return false
        }
        model = try? DiagnosticWorkbenchModel(tool: .traceroute, service: service, ipInformation: databaseOwner.tracerouteProvider())
        model?.target = "8.8.8.8"
        relay.model = model
    }

    func installRetainedData() async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while case .loading = owner.phase, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready(let database) = owner.phase else { installReceipt = "Database loader unavailable"; return }
        let seed = URL.applicationSupportDirectory.appendingPathComponent("ToolboxQualification/IPSeed", isDirectory: true)
        do {
            let id = try await database.startImport(city: seed.appendingPathComponent("city.mmdb"),
                asn: seed.appendingPathComponent("asn.mmdb"), versionLabel: "2026-11",
                source: "DB-IP Lite", attribution: "IP Geolocation by DB-IP.com · CC BY 4.0",
                licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/"))
            let metadata = try await database.waitForUpdate(id)
            installReceipt = "Installed: \(metadata.releaseLabel) · \(metadata.source)"
        } catch {
            installReceipt = "Install failed: \(error.localizedDescription)"
        }
    }
}
#endif

#if DEBUG && !TOOLBOX_LOCATION_ONLY
/// Only the production drawing component is fed synthetic display values.
/// The App's sensor service and calibration path are never substituted.
private struct QualificationLevelGauge: View {
    let upright: Bool
    var body: some View {
        VStack(spacing: 24) {
            Text("合成仪表样例 · 非传感器读数 / Synthetic gauge, not a sensor reading")
                .font(.caption).padding(8).frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.15))
            Group {
                if upright {
                    InstrumentLevelBarCanvas(position: InstrumentMath.barBubblePosition(angleDegrees: 3), level: false, active: true)
                } else {
                    InstrumentLevelBubbleCanvas(bubble: (x: 0.18, y: -0.12), level: false, active: true)
                }
            }
            .frame(maxWidth: upright ? 620 : 460)
            .frame(height: upright ? 140 : 420)
            .padding(24)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("qualification.level.gauge")
    }
}
#endif

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
