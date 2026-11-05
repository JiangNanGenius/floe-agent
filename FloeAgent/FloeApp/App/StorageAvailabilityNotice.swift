#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

// Keep device-capacity APIs in the App that owns this feature and its privacy
// declaration. Shared FloeCore is also linked by extensions without this UI.
private extension DeviceStorageAvailability {
    static func read(at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Self {
        // Currently free bytes; reclaimable capacity does not prove a write
        // can succeed right now. A failed measurement remains unknown.
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity {
            return Self(availableBytes: Int64(bytes))
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return Self(availableBytes: (attributes?[.systemFreeSize] as? NSNumber)?.int64Value)
    }
}

private func storageAvailabilityProbe() -> DeviceStorageAvailability {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-ui-testing"), arguments.contains("--ui-test-low-storage") {
        // Only the measurement is synthetic. The ordinary root, banner,
        // details and settings navigation still render, without filling disk.
        return .init(availableBytes: 192 * 1_024 * 1_024)
    }
    #endif
    return .read()
}

/// In-memory warning state: still works when the settings/database cannot
/// write. It neither prevents reads nor deletes anything to reclaim space.
@MainActor
final class StorageAvailabilityCenter: ObservableObject {
    @Published private(set) var snapshot: DeviceStorageAvailability
    @Published private(set) var writeFailed = false
    @Published private(set) var dismissedLevel: DeviceStorageAvailability.Level?
    private let probe: () -> DeviceStorageAvailability

    init(probe: @escaping () -> DeviceStorageAvailability = { storageAvailabilityProbe() }) {
        self.probe = probe
        snapshot = probe()
    }

    var showsNotice: Bool {
        guard writeFailed || snapshot.level != .normal else { return false }
        return dismissedLevel.map { snapshot.level > $0 } ?? true
    }

    func refresh(writeFailed: Bool = false) {
        snapshot = probe()
        self.writeFailed = writeFailed
        if writeFailed || snapshot.level == .normal { dismissedLevel = nil }
    }

    func dismiss() { dismissedLevel = snapshot.level }

    var message: String {
        if let available = snapshot.formattedAvailable {
            return FloeL10n.l(writeFailed ? "storage.capacity.write_failed_bytes" : "storage.capacity.low_bytes", available)
        }
        return FloeL10n.l("storage.capacity.write_failed")
    }
}

struct StorageAvailabilityNotice: ViewModifier {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var center = StorageAvailabilityCenter()
    @State private var showsDetails = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if center.showsNotice {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("storage.capacity.title").font(.subheadline.weight(.semibold))
                            Text(center.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("storage.capacity.help") { showsDetails = true }
                            .font(.subheadline)
                        Button { center.dismiss() } label: {
                            Image(systemName: "xmark")
                                .frame(minWidth: 32, minHeight: 44)
                        }
                        .accessibilityLabel(Text("storage.capacity.dismiss"))
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("storage.capacity.notice")
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    center.refresh()
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                } while !Task.isCancelled
            }
            .onReceive(NotificationCenter.default.publisher(for: StorageSpaceFailure.notification)
                .receive(on: DispatchQueue.main)) { _ in
                center.refresh(writeFailed: true)
            }
            .sheet(isPresented: $showsDetails) {
                NavigationStack {
                    Form {
                        Section {
                            Text(center.message)
                            Text("storage.capacity.guidance")
                        }
                        if environment.persistenceReady {
                            Section {
                                NavigationLink("storage.capacity.manage_floe") {
                                    DataManagementView(environment: environment,
                                                       conversationCenter: environment.conversationCenter)
                                }
                            }
                        }
                        Section {
                            Button("storage.capacity.check_again") { center.refresh() }
                        } footer: {
                            Text("storage.capacity.no_auto_delete")
                        }
                    }
                    .navigationTitle("storage.capacity.title")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("action.done") { showsDetails = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
    }
}
#endif
