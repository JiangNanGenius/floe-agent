// FloeApp — Real signed-template Shortcut import for scheduled-task setup.
//
// SPDX-License-Identifier: MPL-2.0
//
// Hands the app's bundled Apple-SIGNED Shortcuts template file to the system
// so the Shortcuts app shows its own "Add Shortcut" confirmation (Apple
// Support "Share shortcuts": a shared shortcut FILE is opened by the
// recipient and added with user confirmation; the local `shortcuts sign
// --mode anyone` CLI produces that importable file). There is NO public API
// that installs a shortcut, attaches an automation, or detects a completed
// install for a third-party app, and this code never claims otherwise:
//
//   • availability distinguishes `.ready(digest:)` (a signed template is in
//     the bundle) from `.noTemplate` (it is not — the manual ShortcutsLink
//     path is then the entire UI, exactly as before);
//   • attempt evidence records only what Floe itself did (file prepared →
//     opened by the system, or handed to the user via the share sheet, or
//     cancelled/failed). None of these mean "installed";
//   • a separate USER-CONFIRMED mark stores only the person's own tap in
//     Floe saying they added the automation. The app cannot verify it and
//     never infers it.
//
// Three events are MONITORING evidence and persist a silent monitoring row
// in `task_schedule_cleanup_reminders` through the shared cleanup store:
// the system import page actually opened, the share handoff actually
// completed, or the user explicitly confirmed the setup. Failed/cancelled
// imports record nothing durable, and a never-configured plan never gets a
// row — so ordinary deletes stay silent. Monitoring is what later lets the
// permanent delete or the one-shot's terminal retirement open ONE honest
// cleanup reminder; undoing the display confirmation does not erase a real
// handoff that already happened.
//
// Nothing here touches the schedule or occurrence lifecycle: it cannot
// enable, arm, launch or gate anything.

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import FloeCore
import FloeModels
import FloePersistence

/// Locating and digesting the bundled signed template. The file is a build
/// input produced OUTSIDE this app (see the template recipe: on-device
/// Shortcuts build + `shortcuts sign --mode anyone`), committed as an opaque
/// resource.
enum FloeScheduleShortcutTemplate {
    static let resourceName = "FloeScheduledTask"
    static let fileExtension = "shortcut"

    static func bundledURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: fileExtension)
    }

    /// Short display digest (first 8 hex of SHA-256) so an attempt is
    /// attributable to a template revision without claiming validation of
    /// Apple's signature, which only the receiving system can perform.
    static func digestPrefix(of data: Data) -> String {
        String(FloeDigest.sha256Hex(data).prefix(8))
    }
}

/// What Floe itself observed during one import handoff. The vocabulary is
/// deliberately closed and honest: there is NO "installed"/"imported" case,
/// because no supported API reports the user's confirmation inside
/// Shortcuts. `userConfirmed` is stored separately as the person's OWN mark.
enum TaskScheduleImportAttemptState: String, Codable, CaseIterable, Hashable {
    case filePrepared
    case importFlowOpened
    case handedOffToUser
    case cancelled
    case failed
}

struct TaskScheduleImportAttempt: Codable, Hashable {
    var state: TaskScheduleImportAttemptState
    var date: Date
    var templateDigest: String?
}

/// The per-schedule UI trail shown under the import button: the last
/// observed handoff plus the separate user-confirmed mark. Kept in the
/// existing app-group defaults suite (same suite the Shortcuts draft
/// handoff used) because it is DISPLAY evidence; the durable monitoring
/// authority for the cleanup lifecycle is the SQLite row written through
/// `TaskScheduleCleanupReminderStore.recordSetup`. It is evidence, never
/// lifecycle.
struct TaskScheduleSetupEvidenceRecord: Codable, Hashable {
    var attempt: TaskScheduleImportAttempt?
    var userConfirmedSetup: Bool = false
    var userConfirmedAt: Date?
}

enum TaskScheduleSetupEvidenceStore {
    static let suiteName = "group.org.floeagent.ios"
    private static func key(_ scheduleID: UUID) -> String {
        "floe.scheduleSetup.evidence.\(scheduleID.uuidString)"
    }

    static func load(scheduleID: UUID, defaults: UserDefaults?) -> TaskScheduleSetupEvidenceRecord? {
        guard let data = defaults?.data(forKey: key(scheduleID)) else { return nil }
        return try? JSONDecoder().decode(TaskScheduleSetupEvidenceRecord.self, from: data)
    }

    static func store(
        _ record: TaskScheduleSetupEvidenceRecord?, for scheduleID: UUID, defaults: UserDefaults?
    ) {
        guard let defaults else { return }
        guard let record,
              let data = try? JSONEncoder().encode(record) else {
            defaults.removeObject(forKey: key(scheduleID))
            return
        }
        defaults.set(data, forKey: key(scheduleID))
    }
}

/// Identifiable wrapper so SwiftUI can present the share sheet from an
/// item binding when the direct file open is refused.
struct FloeShortcutShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// View model behind the setup sheet's import control. All system contact
/// is injectable so the state machine is testable without UIKit.
@MainActor
final class TaskScheduleShortcutImport: ObservableObject {
    enum Availability: Hashable {
        case noTemplate
        case ready(digest: String?)
    }

    @Published private(set) var availability: Availability = .noTemplate
    @Published private(set) var evidence: TaskScheduleSetupEvidenceRecord?
    /// Set when the direct open was refused and the documented share-sheet
    /// handoff should run; cleared when it completes.
    @Published private(set) var shareItem: FloeShortcutShareItem?

    var scheduleID: UUID?
    private var scheduleTitle = ""
    private var cleanupStore: TaskScheduleCleanupReminderStore?

    // MARK: Injected seams (production defaults; tests replace them)

    /// Where the template bytes come from. Production reads the bundle URL.
    var templateReader: (() -> Data?)?
    var tempWriter: ((Data, String) -> URL?)?
    var fileOpener: ((URL) async -> Bool)?
    var defaults: UserDefaults?

    init(templateReader: (() -> Data?)? = nil,
         tempWriter: ((Data, String) -> URL?)? = nil,
         fileOpener: ((URL) async -> Bool)? = nil,
         defaults: UserDefaults? = nil) {
        self.templateReader = templateReader
        self.tempWriter = tempWriter
        self.fileOpener = fileOpener
        self.defaults = defaults
    }

    /// Re-reads the template availability and the durable display evidence
    /// for ONE schedule, and binds the cleanup store used for monitoring
    /// writes; called when the sheet appears.
    func refresh(
        scheduleID: UUID,
        title: String,
        cleanupStore: TaskScheduleCleanupReminderStore? = nil
    ) {
        self.scheduleID = scheduleID
        self.scheduleTitle = title
        self.cleanupStore = cleanupStore
        let defaults = self.defaults ?? UserDefaults(suiteName: TaskScheduleSetupEvidenceStore.suiteName)
        let read = templateReader ?? {
            guard let url = FloeScheduleShortcutTemplate.bundledURL() else { return nil }
            return try? Data(contentsOf: url)
        }
        if let data = read() {
            availability = .ready(digest: FloeScheduleShortcutTemplate.digestPrefix(of: data))
        } else {
            availability = .noTemplate
        }
        evidence = TaskScheduleSetupEvidenceStore.load(scheduleID: scheduleID, defaults: defaults)
    }

    /// The one import handoff. Never claims an install: at best it records
    /// that the SYSTEM was given the signed file.
    func presentImport() async {
        guard case .ready = availability, let scheduleID else { return }
        let read = templateReader ?? {
            guard let url = FloeScheduleShortcutTemplate.bundledURL() else { return nil }
            return try? Data(contentsOf: url)
        }
        guard let data = read() else {
            record(.failed)
            return
        }
        let digest = FloeScheduleShortcutTemplate.digestPrefix(of: data)
        let write = tempWriter ?? { bytes, name in Self.stageTemplate(bytes, name: name) }
        // Shortcuts uses the filename as the new shortcut's visible name.
        // Keep the attempt identity in its directory, not in that title.
        let name = FloeScheduleShortcutTemplate.resourceName + "."
            + FloeScheduleShortcutTemplate.fileExtension
        guard let tempURL = write(data, name) else {
            record(.failed)
            return
        }
        record(.filePrepared, digest: digest)
        let open = fileOpener ?? { url in await UIApplication.shared.open(url) }
        if await open(tempURL) {
            record(.importFlowOpened, digest: digest)
            await monitor(.importFlowOpened)
            return
        }
        // Documented recipient path for a file the app itself cannot open:
        // the share sheet, where the user saves/opens the file and completes
        // the system's Add Shortcut confirmation.
        shareItem = FloeShortcutShareItem(url: tempURL)
    }

    /// Called by the sheet when the share UI finishes. `completed` is the
    /// user picking an app AND the activity returning success — it still
    /// only means the file was HANDED OVER, not installed. Re-entrant safe:
    /// once the item is cleared (completion path), a follow-up dismiss
    /// callback cannot double-record.
    func finishShareSheet(completed: Bool) async {
        guard shareItem != nil else { return }
        shareItem = nil
        record(completed ? .handedOffToUser : .cancelled)
        if completed {
            await monitor(.handedOffToUser)
        }
    }

    /// The person's own confirmation that they added the system automation
    /// (imported template or manual setup). Stored as a distinct display
    /// flag; the attempt state is left exactly as observed. It also (re-)
    /// starts monitoring — an explicit confirmation IS handoff evidence.
    func markSetupConfirmedByUser() async {
        guard let scheduleID else { return }
        var record = evidence ?? TaskScheduleSetupEvidenceRecord()
        record.userConfirmedSetup = true
        record.userConfirmedAt = Date()
        evidence = record
        persist(record)
        await monitor(.userConfirmed)
    }

    /// Clears only the display confirmation. A monitoring row created by
    /// THIS confirmation stays: the honest reading is that the person said
    /// the automation exists; taking back a tap label cannot un-hand-off
    /// what the system was given. (Only the user's cleanup-side choices —
    /// dismiss/removed on an OPEN reminder — move a visible row.)
    func undoSetupConfirmation() {
        guard let scheduleID, var record = evidence else { return }
        record.userConfirmedSetup = false
        record.userConfirmedAt = nil
        evidence = record
        persist(record)
    }

    /// A new isolated directory prevents retries from overwriting a file
    /// still owned by the system importer. The readable basename survives
    /// the handoff as the shortcut title.
    static func stageTemplate(_ bytes: Data, name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeShortcutImport-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    // MARK: - Internals

    /// Durable monitoring write — best-effort and invisible to ordinary
    /// UI. Without a bound store (pre-integration hosts, no App
    /// Environment), nothing is persisted; no schedule/occurrence row is
    /// ever touched.
    private func monitor(_ source: TaskScheduleSetupSource) async {
        guard let cleanupStore, let scheduleID else { return }
        try? await cleanupStore.recordSetup(
            scheduleID: scheduleID,
            title: scheduleTitle.isEmpty ? scheduleID.uuidString : scheduleTitle,
            source: source,
            at: Date())
    }

    private func record(
        _ state: TaskScheduleImportAttemptState, digest: String? = nil
    ) {
        guard let scheduleID else { return }
        var current = evidence ?? TaskScheduleSetupEvidenceRecord()
        current.attempt = TaskScheduleImportAttempt(
            state: state,
            date: Date(),
            templateDigest: digest ?? current.attempt?.templateDigest
                ?? (availability.digestPrefixIfReady))
        evidence = current
        persist(current)
    }

    private func persist(_ record: TaskScheduleSetupEvidenceRecord) {
        guard let scheduleID else { return }
        let defaults = self.defaults ?? UserDefaults(suiteName: TaskScheduleSetupEvidenceStore.suiteName)
        TaskScheduleSetupEvidenceStore.store(record, for: scheduleID, defaults: defaults)
    }
}

private extension TaskScheduleShortcutImport.Availability {
    var digestPrefixIfReady: String? {
        if case .ready(let digest) = self { return digest }
        return nil
    }
}

/// Share-sheet host for the signed template file when the direct system
/// open is refused: the documented recipient path (open/share the file,
/// then the system shows its own Add Shortcut step). Reports only whether
/// the handoff activity completed — never an install.
struct FloeShortcutShareActivity: UIViewControllerRepresentable {
    let items: [Any]
    let onFinished: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            MainActor.assumeIsolated { onFinished(completed) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
