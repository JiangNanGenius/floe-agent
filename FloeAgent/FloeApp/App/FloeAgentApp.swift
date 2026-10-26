// FloeApp — SwiftUI app entry point (iOS/iPadOS only).
//
// SPDX-License-Identifier: MPL-2.0
//
// iPhone shows exactly five locked tabs (Workbench, Files, Browser, Hosts, More) in
// a TabView; iPad shows a three-column NavigationSplitView with a functional
// sidebar, a content column, and a detail column. Both idioms are driven by
// one AppRouter so navigation state and scene-phase background-policy
// wiring are shared.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import AVFoundation
import FloeCore
import FloeModels
import FloePersistence
import FloeLocalModelCatalog
import FloeCAD
#if canImport(AppIntents)
import AppIntents
#endif

final class FloeApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        RuntimeDiagnostics.shared.start()
        Task {
            await WhisperModelStore.shared.restoreInstallation()
            await LocalSpeechModelStore.shared.restoreInstallation()
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        RuntimeDiagnostics.shared.normalTermination()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // All callbacks join the one process-owned graph. Registering the
        // bootstrap atomically with each completion accounts for cold launch
        // before UIKit can release this background execution opportunity.
        let bootstrap: @Sendable () async -> Void = {
            // TTS shares the speech downloader but keeps its own persisted
            // request/retirement policy and installation owner.
            await LocalSpeechModelStore.shared.restoreInstallation()
            await FloeAgentApp.liveEnvironment.backgroundRunCoordinator.runDownloadWakeBootstrap()
        }
        if identifier == WhisperDownloadCoordinator.identifier {
            WhisperDownloadCoordinator.shared.registerBackgroundCompletion(completionHandler, bootstrap: bootstrap)
        } else if identifier == MediaArtifactDownloadCoordinator.sessionIdentifier {
            MediaArtifactBackgroundEvents.shared.register(completionHandler, bootstrap: bootstrap)
        } else if identifier == JobDownloadCoordinator.sessionIdentifier {
            JobDownloadBackgroundEvents.shared.register(completionHandler, bootstrap: bootstrap)
        } else {
            LocalModelBackgroundEvents.shared.register(
                identifier: identifier,
                completion: completionHandler,
                bootstrap: bootstrap
            )
        }
    }
}

@main
struct FloeAgentApp: App {
    // App reconstruction must not open another database/service graph while
    // SwiftUI retains the original StateObject and system action dependency.
    @MainActor fileprivate static let liveEnvironment = AppEnvironment.live()
    @UIApplicationDelegateAdaptor(FloeApplicationDelegate.self) private var applicationDelegate
    @StateObject private var environment: AppEnvironment
    @StateObject private var router: AppRouter

    init() {
        // Apply the saved in-app language before any catalog lookup.
        FloeL10n.bootstrap()
        // Route Floe-owned CAD workbench chrome to the same catalog. A missing
        // key falls back to the panel's English text.
        FloeCADStrings.localizer = { key in
            let value = FloeL10n.localized(key: key)
            return value == key ? nil : value
        }
        // Most UI runs disable animations to avoid continuous spinners
        // delaying XCUITest's idle checks. Gesture/rendering qualification
        // must explicitly preserve the normal UIKit animation behavior.
        let uiTestArguments = ProcessInfo.processInfo.arguments
        if uiTestArguments.contains("-ui-testing"),
           !uiTestArguments.contains("--ui-test-preserve-animations") {
            UIView.setAnimationsEnabled(false)
        }
        let environment = Self.liveEnvironment
        #if canImport(AppIntents)
        // System actions join the same app-owned service graph, including
        // headless invocations. They never create a second environment.
        AppDependencyManager.shared.add(dependency: environment)
        FloeShortcutsRuntime.shared.install(environment: environment)
        #endif
        #if DEBUG
        AppEnvironment.qualificationLaunchEnvironment = environment
        #endif
        let router = AppRouter()
        _environment = StateObject(wrappedValue: environment)
        _router = StateObject(wrappedValue: router)
        // A notification tap can be delivered while UIKit connects the first
        // scene, before RootView's bootstrap task runs. Install the existing
        // notification delegate now; its readiness gate defers navigation
        // until persistence and the foreground route subscribers are ready.
        // Leaving this coordinator lazy drops cold-launch response actions.
        _ = environment.backgroundRunCoordinator
        router.registerBackgroundTasksAtAppLaunch()
        // Creative routing / canvas handoff navigation seam: foreground-only
        // delivery through the real router (late or replayed routes never
        // steal focus — the router service gates on the active run).
        CreativeDestinationRouter.navigator = { conversationID in
            router.presentRoutedDestination(conversationID)
        }
        // Foreground truth for routing: the initiating run must be the
        // SELECTED conversation's active run, OR the user must be looking at
        // the very canvas that owns the run (root canvas cover). Background
        // runs and switched conversations answer false — navigation is
        // honestly suppressed (no focus stealing from late/background runs).
        let centerRef = environment.conversationCenter
        let contextStore = CanvasRunContextStore(database: environment.database)
        CreativeDestinationRouter.foregroundRunProbe = { runID in
            guard let record = centerRef.activeRuns.values.first(where: { $0.id == runID })
            else { return false }
            if router.workbenchSelection == .conversation(record.conversationID) {
                return true
            }
            // Canvas-cover foreground: the run's durable canvas binding is
            // the canvas currently presented through the root cover.
            guard router.presentsCanvas,
                  let context = try? await contextStore.context(runID: runID)
            else { return false }
            return context.canvasID == router.presentedCanvasID
        }
        CreativeDestinationRouter.canvasNavigator = { canvasID in
            router.presentRoutedCanvas(canvasID)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-long-reasoning"),
                   ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                    LongReasoningTestHarness()
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-workbench-fixture"),
                          ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                    // Synthetic media workbench fixture for primary CUA
                    // acceptance on iPad and iPhone.
                    WorkbenchUITestHarness()
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-cad-fixture"),
                          ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                    // Deterministic native CAD fixture: the REAL workbench on a
                    // 100×60×10 plate with a Ø10 through-hole. No workspace,
                    // grant or credential setup required.
                    CADWorkbenchFixtureHarness()
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-canvas-cad-fixture"),
                          ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                    // Deterministic canvas fixture: an ordinary canvas with
                    // one canvas-owned native CAD node, for the node preview +
                    // explicit "Open CAD workbench" entry acceptance.
                    CanvasCADEntryFixtureHarness()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .environmentObject(environment)
                .environmentObject(router)
                .environmentObject(environment.voiceInput)
                .environmentObject(environment.speechService)
                .environmentObject(environment.ttsSettingsService)
                .environmentObject(environment.designEntryState)
                .environmentObject(environment.skillAuthoring)
                .modifier(SkillAuthoringPresentationHost(coordinator: environment.skillAuthoring, router: router))
                .task {
                    #if DEBUG
                    // Hosted actual-entry acceptance parks the entire scene
                    // startup here, before bootstrap or any scene follow-up.
                    // The test releases it after driving the real App Intents.
                    await FloeEntryQualification.awaitSceneBootstrapBarrierIfRequested()
                    #endif
                    await environment.bootstrap()
                    #if DEBUG
                    FloeEntryQualification.noteSceneBootstrapReturned()
                    // Temporary-chat GUI acceptance: optionally preset a
                    // separate session with synthetic in-RAM messages and
                    // navigate to it (DEBUG/simulator/launch-arg gated).
                    await TemporaryChatUITestFixture.presetSessionIfRequested(
                        router: router,
                        center: environment.conversationCenter
                    )
                    #endif
                }
        }
        .commands {
            FloeAgentCommands(router: router)
        }
    }
}

/// Hardware-keyboard command surface shared by iPad and Mac Catalyst-style
/// keyboard navigation. Canvas editing shortcuts intentionally use Option for
/// node-level operations so normal text editing keeps Command-C/V/Z semantics.
private struct FloeAgentCommands: Commands {
    let router: AppRouter
    @FocusedValue(\.canvasKeyboardActions) private var canvas

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("workbench.new_task") { router.startNewTask() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu(FloeL10n.l("app.floe_agent_app.navigation")) {
            Button("tab.workbench") { router.navigate(to: .home) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("notes.notes_root_view.notes") { router.openMore(.notes) }
            Button("app.floe_agent_app.creative") { router.openMore(.creative) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("app.floe_agent_app.task_center") { router.openMore(.runs) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("app.floe_agent_app.files") { router.navigate(to: .files) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("app.floe_agent_app.settings") { router.presentedSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu(FloeL10n.l("settings.settings_root_view.canvas")) {
            Button("app.floe_agent_app.undo_canvas") { canvas?.undo() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(canvas?.canUndo != true)
            Button("app.floe_agent_app.redo_canvas") { canvas?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(canvas?.canRedo != true)
            Divider()
            Button("app.floe_agent_app.select_and_move") { canvas?.chooseTool(0) }
                .keyboardShortcut("1", modifiers: .option)
            Button("Apple Pencil") { canvas?.chooseTool(1) }
                .keyboardShortcut("2", modifiers: .option)
            Button("workspace.workspace_canvas_view.eraser") { canvas?.chooseTool(2) }
                .keyboardShortcut("3", modifiers: .option)
            Button("workspace.workspace_canvas_view.connector") { canvas?.chooseTool(3) }
                .keyboardShortcut("4", modifiers: .option)
            Button("canvas.node.card") { canvas?.createCard() }
                .keyboardShortcut("5", modifiers: .option)
            Button("canvas.node.text") { canvas?.createText() }
                .keyboardShortcut("6", modifiers: .option)
            Button("canvas.node.shape") { canvas?.createShape() }
                .keyboardShortcut("7", modifiers: .option)
            Divider()
            Button("app.floe_agent_app.duplicate_selected_nodes") { canvas?.copy() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(canvas?.hasNodeSelection != true)
            Button("app.floe_agent_app.paste_canvas_nodes") { canvas?.paste() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(canvas == nil)
            Button("app.floe_agent_app.duplicate") { canvas?.duplicate() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(canvas?.hasNodeSelection != true)
            Button("app.floe_agent_app.select_all_canvas_content") { canvas?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(canvas == nil)
            Button("app.floe_agent_app.delete_selected_canvas_content") { canvas?.delete() }
                .keyboardShortcut(.delete, modifiers: .option)
                .disabled(canvas?.hasNodeSelection != true && canvas?.hasInkSelection != true)
            Button("app.floe_agent_app.group") { canvas?.group() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(canvas?.canGroup != true)
            Button("app.floe_agent_app.ungroup") { canvas?.ungroup() }
                .keyboardShortcut("g", modifiers: [.command, .option, .shift])
                .disabled(canvas?.canUngroup != true)
            Button("app.floe_agent_app.understand_and_organize_handwriting") { canvas?.interpretInk() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(canvas?.hasInkSelection != true)
            Divider()
            Button("app.floe_agent_app.nudge_left") { canvas?.nudge(-4, 0) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(canvas?.hasNodeSelection != true)
            Button("app.floe_agent_app.nudge_right") { canvas?.nudge(4, 0) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(canvas?.hasNodeSelection != true)
            Button("app.floe_agent_app.nudge_up") { canvas?.nudge(0, -4) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(canvas?.hasNodeSelection != true)
            Button("app.floe_agent_app.nudge_down") { canvas?.nudge(0, 4) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(canvas?.hasNodeSelection != true)
            Divider()
            Button("app.floe_agent_app.zoom_in") { canvas?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(canvas == nil)
            Button("app.floe_agent_app.zoom_out") { canvas?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(canvas == nil)
            Button("app.floe_agent_app.fit_canvas") { canvas?.resetView() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(canvas == nil)
        }
    }
}

/// Idiom-adaptive root: a task-first sidebar workbench on both iPhone and
/// iPad. Scene-phase transitions are forwarded to
/// the router, which owns the background policy.
struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("floe.settings.appearance") private var appearanceValue = "system"
    /// SceneStorage belongs to one WindowGroup content instance even though
    /// navigation and the environment remain app-wide shared objects.
    @SceneStorage("floe.windowSceneIdentity") private var sceneID = UUID().uuidString
    @State private var expandedWorkspaceIDs: Set<UUID> = []
    /// Long-press conversation selection in the sidebar: circles appear in
    /// this list, bulk archive/delete run through the existing task bulk
    /// engine, and navigation / temporary-session ownership is untouched.
    @StateObject private var inlineSelection = InlineConversationSelectionModel()
    @State private var renamingConversation: ConversationRecord?
    @State private var deletingConversation: ConversationRecord?
    @State private var deletingWorkspace: WorkspaceRecord?
    @State private var presentedCanvasWorkspace: WorkspaceRecord?
    @State private var canvasPresenceRevision = 0
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var isPhoneSidebarOpen = false
    @GestureState private var phoneDrawerTranslation: CGFloat = 0
    /// Foreground notification banner (terminal/approval events that would
    /// otherwise duplicate a system alert).
    @ObservedObject private var taskBannerCenter = TaskBannerCenter.shared
    /// Persisted list typography and iPad sidebar width (Build265).
    @ObservedObject private var layoutPreferences = LayoutPreferences.shared
    /// Scene-bound foldable display capability. Proven hinge hardware keeps
    /// the stable NavigationSplitView shell across open/close (system
    /// collapse handles compact), so fold/unfold never remounts the editor
    /// session identities below. Never persisted across hardware.
    @StateObject private var foldableSupport = FoldableDisplayState()
    @State private var sidebarWidthObservation: CGFloat = 0
    /// Linux session/service deep link destination, optionally focused on the
    /// environment the notification came from.
    @State private var presentedExecutionEnvironment = false
    @State private var focusedLinuxEnvironmentID: String?
    private struct QueuedEntry: Identifiable {
        let id = UUID()
        let route: FloeAppEntryRoute
    }
    @State private var pendingEntry: QueuedEntry?
    @State private var entryNavigationReady = false
    @State private var entryNotice: String?
    @State private var continuousVoiceActive = false
    /// Compact 导入手记 / 导入任务 / 导入画布 chooser for ambiguous inbound
    /// entries. Presentation never navigates; only an explicit action may.
    @State private var presentedDestination: ImportDestinationRequest?
    @State private var lastPresentedDestination: ImportDestinationRequest?
    @State private var destinationNoticeTask: Task<Void, Never>?

    /// UITest runs pin a deterministic layout: `-ui-testing` forces the
    /// compact (iPhone-style) tab layout; `-ui-testing-ipad` additionally
    /// forces the regular split layout for the iPad suite, regardless of
    /// the size class the test host reports.
    private var forceCompactForUITest: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return false }
        return !arguments.contains("-ui-testing-ipad")
    }

    private var forceRegularForUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-ipad")
    }

    /// One tappable in-app banner for foreground terminal/approval events.
    /// The tap performs the exact same deep link a system notification would,
    /// so routing behavior does not depend on how the event was presented.
    @ViewBuilder
    private var foregroundBanner: some View {
        if let banner = taskBannerCenter.banner {
            Button {
                BackgroundRunCoordinator.route(deepLink: banner.deepLink)
                taskBannerCenter.dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.title).font(.subheadline.weight(.semibold))
                    Text(banner.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.secondary.opacity(0.25))
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("task.banner")
        }
    }

    var body: some View {
        Group {
            if FoldableMountGate.showsBootChrome(
                persistenceReady: environment.persistenceReady,
                mountResolved: foldableSupport.snapshot.isMountResolved) {
                // Existing boot chrome (no new spinner). The foldable mount
                // decision is bounded: the attach-time initial hinge update
                // answers immediately on 27.1 hardware and a deadline
                // guarantees ordinary mounting everywhere else, so this gate
                // cannot stall — it only ensures the ONE shell/container
                // choice freezes before any editor mounts or route delivers.
                persistenceState
            } else if FoldableLayoutEngine.selectRootShell(
                snapshot: foldableSupport.snapshot,
                isPadIdiom: UIDevice.current.userInterfaceIdiom == .pad,
                mountResolved: foldableSupport.snapshot.isMountResolved,
                forceRegularForUITest: forceRegularForUITest,
                forceCompactForUITest: forceCompactForUITest) == .splitView {
                // Outermost shell is chosen from the FROZEN decision + idiom
                // only — never live width/size-class — so rotation, stage
                // resizing and late foldable evidence cannot replace the
                // mounted tree. Size-adaptive layout stays inside each shell.
                iPadRoot
            } else {
                iPhoneRoot
            }
        }
        // Foldable detection is scene/window-bound. The probe observes the
        // real iOS 27.1 hinge context (initial state arrives on attach) and
        // system division regions; the outermost shell then follows the
        // frozen mount choice (idiom selects only the ordinary navigation
        // shell — size adaptation lives inside the shells). The snapshot is
        // a plain environment value so isolated hosts and pre-27.1 systems
        // need no provider.
        .environment(\.foldableDisplay, foldableSupport.snapshot)
        .modifier(FoldableCapabilityProbeModifier(state: foldableSupport))
        .background(alignment: .bottomTrailing) {
            BackgroundPiPSceneSource(videoService: environment.backgroundVideoService)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                DocumentIntakeBanner(center: environment.documentIntakeCenter, sceneID: sceneID)
                if let entryNotice {
                    HStack {
                        Text(entryNotice).font(.subheadline)
                        Spacer(minLength: 8)
                        Button("action.done") { self.entryNotice = nil }
                            .frame(minHeight: 44)
                    }
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
                foregroundBanner
            }
        }
        .onOpenURL { handleEntryURL($0) }
        .task(id: "\(entryNavigationReady)-\(pendingEntry?.id.uuidString ?? "none")") {
            await deliverPendingEntry()
        }
        .onReceive(environment.importDestinationCenter.$destinationRequest) { request in
            if request != nil { takeDestinationRequestIfNeeded() }
        }
        .onChange(of: continuousVoiceActive) { _, active in
            // A live continuous-voice session keeps its own modal surface;
            // the chooser waits instead of interrupting it, then resumes.
            if !active { takeDestinationRequestIfNeeded() }
        }
        .onChange(of: destinationPresentationBlocked) { _, blocked in
            if !blocked { takeDestinationRequestIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { takeDestinationRequestIfNeeded() }
        }
        .onReceive(router.objectWillChange.receive(on: DispatchQueue.main)) { _ in
            // Settings / setup / design page / canvas and other router
            // presentations flip through here; after a dismissal hop the
            // chooser retries itself if a request is still waiting. The
            // peek/confirm design means a blocked attempt consumes nothing.
            takeDestinationRequestIfNeeded()
        }
        .sheet(item: $presentedDestination, onDismiss: {
            // Swipe-to-dismiss is an explicit "not now": it behaves exactly
            // like Cancel (durable source untouched, banner/card path
            // remains). A completed choice already settled the origin, so
            // this never cancels what the destination now owns.
            if let request = lastPresentedDestination {
                environment.importDestinationCenter.cancelPresentation(request)
            }
            lastPresentedDestination = nil
        }) { request in
            ImportDestinationSheet(
                request: request,
                center: environment.importDestinationCenter,
                onNotes: {
                    Task { await resolveDestination(.notes, request) }
                },
                onTask: { target in
                    Task { await resolveDestination(.task, request, taskTarget: target) }
                },
                onCanvas: { target in
                    Task { await resolveDestination(.canvas, request, canvasTarget: target) }
                },
                onCancel: {
                    environment.importDestinationCenter.cancelPresentation(request)
                    presentedDestination = nil
                },
                onPresented: {
                    // Consumption is confirmed only once the chooser truly
                    // appeared; blocked presentations stay re-armable.
                    environment.importDestinationCenter.confirmPresentation(request)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .onReceive(environment.documentIntakeCenter.$presentation) { _ in
            presentPendingDocument()
        }
        .onChange(of: entryNavigationReady) { _, ready in
            if ready { presentPendingDocument() }
        }
        .onAppear {
            configureDocumentRouting()
            foldableSupport.startMountResolutionDeadline()
            DocumentIntakeRoutingRegistry.shared.setActive(scenePhase == .active, sceneID: sceneID)
            GitHubActionsJobCenter.shared.scenePhaseChanged(active: scenePhase == .active, sceneID: sceneID)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            DocumentIntakeRoutingRegistry.shared.setActive(newPhase == .active, sceneID: sceneID)
            router.handleScenePhase(
                newPhase,
                sceneID: sceneID,
                environment: environment
            )
            // IDE GitHub Actions runs live on GitHub, not in this process.
            // Launch/foreground re-reads every durable record and resumes
            // bounded polling; background stops the local poll only, never the
            // remote run.
            GitHubActionsJobCenter.shared.scenePhaseChanged(active: newPhase == .active, sceneID: sceneID)
            if newPhase == .active, environment.persistenceReady {
                // First active rendered launch, after setup readiness: ask for
                // When-In-Use location access exactly once. Denied/restricted
                // never re-prompts, and the app never requests Always. The
                // shared service suppresses this inside an App-hosted unit
                // test process.
                LocationServicesCenter.shared.requestInitialAuthorizationIfNeeded()
                Task {
                    try? await environment.configurationSync.synchronize()
                    await environment.conversationCenter.reload()
                    // Guest git writes through 9p cannot post a host
                    // notification; re-reading here makes those changes (and
                    // anything else that landed while suspended) visible in
                    // an open source-control pane.
                    await environment.sourceControlCenter.refreshOnForeground()
                }
            }
            if newPhase == .active || newPhase == .background {
                // App state avoids retiring a shared model when another window
                // still owns the foreground. Active playback retires on completion.
                let foreground = UIApplication.shared.applicationState != .background
                Task { await environment.speechService.setLocalSpeechForeground(foreground) }
                #if canImport(UIKit) && canImport(WhisperKit)
                // The warm enhanced recognition model follows the same
                // residency policy: idle foreground keeps it, background
                // releases it, and a session that still owns it retires when
                // it ends — never underneath live decoding.
                Task { await SpeechRecognitionRuntime.live.setForeground(foreground) }
                #endif
            }
            if newPhase != .active {
                environment.voiceInput.handleInterruption(reason: .interrupted)
                // Persist the diagnostics ring buffer before suspension so a
                // crash or relaunch never loses the most recent evidence.
                FloeLogger.buffer.flush()
            }
        }
        .onDisappear {
            DocumentIntakeRoutingRegistry.shared.setActive(false, sceneID: sceneID)
            // A full-screen editor can cover this view while its scene is
            // still active. View disappearance alone must not pause cloud jobs.
            if scenePhase != .active {
                GitHubActionsJobCenter.shared.sceneDidDisappear(sceneID: sceneID)
            }
            router.removeScene(sceneID: sceneID, environment: environment)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) {
            environment.voiceInput.handleAudioInterruption($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) {
            environment.voiceInput.handleAudioRouteChange($0)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
        )) { _ in
            Self.importCanvasSyncPreferenceFromCloud()
        }
        .task(id: environment.persistenceReady) {
            entryNavigationReady = false
            guard environment.persistenceReady else { return }
            if scenePhase == .active {
                // Covers a launch where persistence readiness landed after the
                // scene-phase report (and is an idempotent no-op otherwise).
                LocationServicesCenter.shared.requestInitialAuthorizationIfNeeded()
            }
            Self.importCanvasSyncPreferenceFromCloud()
            NSUbiquitousKeyValueStore.default.synchronize()
            // Repair only rows left by a previous process before settings or
            // UI reloads can yield to a newly-created run.
            await environment.conversationCenter.reconcileInterruptedRunsOnLaunch()
            // Publish local task history before optional provider probes.
            // Launch-critical settings already came from bootstrap; network
            // diagnostics must not leave an otherwise ready sidebar empty.
            await environment.workspaceCenter.reload()
            router.reconcileOnLaunch(environment: environment)
            await environment.conversationCenter.reload()
            // Publish the first widget snapshot only after launch recovery
            // and history reload; the center observes real changes after this.
            environment.widgetSnapshotCenter.start(
                observing: environment.conversationCenter
            )
            // Entry/deeplink routes stay queued (existing pendingEntry
            // machinery) until the one frozen foldable mount decision lands,
            // so delivery always happens inside the final root shell — never
            // through a shell that a late decision would replace.
            entryNavigationReady = FoldableMountGate.entryRoutesReady(
                persistenceReady: environment.persistenceReady,
                mountResolved: foldableSupport.snapshot.isMountResolved)
            await environment.settingsCenter.load()
            await environment.conversationCenter.resumeSafeRunsAfterForeground()
            await environment.backgroundRunCoordinator.reconcileSchedulesAfterLaunch()
            await presentOnboardingIfNeeded()
        }
        .onChange(of: foldableSupport.snapshot.isMountResolved) { _, resolved in
            if resolved && environment.persistenceReady {
                entryNavigationReady = true
            }
        }
        .environment(\.continuousVoiceWindowID, sceneID)
        .onReceive(environment.continuousVoicePresentation.$request) { request in
            continuousVoiceActive = request != nil
        }
        .modifier(ContinuousVoiceRootModifier(
            presentation: environment.continuousVoicePresentation,
            environment: environment, windowID: sceneID
        ))
        .onReceive(environment.conversationCenter.$conversations) { conversations in
            // The durable list is SQLite-only by design; the ACTIVE temporary
            // session is additionally available, so a reload during a
            // temporary thread cannot classify its selected id as deleted
            // and bounce to New Task. The temporary id is never added to the
            // saved history list itself.
            var available = Set(conversations.map(\.id))
            if let session = environment.conversationCenter.temporarySession {
                available.insert(session.conversation.id)
            }
            router.reconcileConversations(available)
        }
        .onChange(of: router.inspectorRoute) { _, _ in
            reconcileTemporaryInspectorRoute()
        }
        .onChange(of: environment.conversationCenter.temporarySession?.incarnation) { _, _ in
            reconcileTemporaryInspectorRoute()
        }
        .onChange(of: environment.browserCenter.presentationRequest) { _, request in
            guard let request, request.conversationID == router.selectedConversationID else { return }
            if request.show {
                _ = environment.browserCenter.consumePendingPanelRequest(for: request.conversationID)
                router.showInspector(.browser)
            }
            else if router.inspectorRoute?.content == .browser,
                    router.inspectorRoute?.conversationID == request.conversationID { router.hideInspector() }
        }
        .onChange(of: router.workbenchSelection) { _, selection in
            environment.previewCenter.select(router.selectedConversationID)
            if let voice = environment.continuousVoicePresentation.request,
               voice.windowID == sceneID {
                if case .conversation(let selectedID) = selection,
                   selectedID == environment.continuousVoicePresentation.activeConversationID {
                    // Home's first utterance may create and select its own
                    // conversation without closing the stable voice surface.
                } else {
                    environment.continuousVoicePresentation.dismiss(voice.id)
                }
            }
            guard case .conversation(let id) = selection,
                  let request = environment.browserCenter.consumePendingPanelRequest(for: id),
                  request.show else { return }
            router.showInspector(.browser)
        }
        .onChange(of: router.selection) { _, destination in
            guard destination != .home,
                  let voice = environment.continuousVoicePresentation.request,
                  voice.windowID == sceneID else { return }
            environment.continuousVoicePresentation.dismiss(voice.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeOpenConversation)) { notification in
            if let id = notification.userInfo?["conversationID"] as? UUID {
                router.openConversation(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeOpenExecutionEnvironment)) { notification in
            // A Linux session/service notification routes to the execution
            // surface, focused on its own environment when the payload names
            // one. It never opens a conversation the id did not identify.
            focusedLinuxEnvironmentID = notification.userInfo?["environmentID"] as? String
            presentedExecutionEnvironment = true
        }
        .sheet(isPresented: $presentedExecutionEnvironment, onDismiss: {
            focusedLinuxEnvironmentID = nil
        }) {
            NavigationStack {
                ExecutionEnvironmentView(
                    center: environment.settingsCenter,
                    initialEnvironmentID: focusedLinuxEnvironmentID
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("action.done") { presentedExecutionEnvironment = false }
                    }
                }
            }
            .environmentObject(environment)
        }
        .sheet(item: $router.presentedSetup, onDismiss: markDismissedSetupSkipped) { _ in
            OnboardingView(center: environment.conversationCenter)
                .presentationSizing(.page)
        }
        .sheet(isPresented: $router.presentedSettings) {
            // Settings owns its regular-width split navigation. Wrapping that
            // split in another stack makes detail toolbar buttons and
            // NavigationLinks appear enabled while their taps are dropped.
            SettingsRootView(environment: environment)
                .environmentObject(router)
                .environment(\.continuousVoiceActive, continuousVoiceActive)
                .presentationSizing(.page)
        }
        .fullScreenCover(item: $router.presentedDesignPage) { request in
            // The preview-first design workbench for ONE bound task,
            // presented from the STABLE app root: a presenter inside a live
            // thread re-renders on every run event and iPad popovers
            // anchored there dismiss spontaneously. Same conversation, same
            // run context, no second chat. A full-screen cover (not a
            // page-sized form sheet) gives the preview the whole available
            // window — no dimmed margins around an in-sheet "fullscreen".
            DesignConversationPageView(
                target: request.target,
                conversationID: request.conversationID,
                environment: environment)
                .environmentObject(router)
        }
        .modifier(CanvasDestinationCover(environment: environment))
        .sheet(item: $renamingConversation) { conversation in
            TaskRenameSheet(conversation: conversation) { title in
                try await environment.conversationCenter.renameConversation(
                    id: conversation.id,
                    title: title
                )
            }
        }
        .fullScreenCover(item: $presentedCanvasWorkspace) { workspace in
            WorkspaceCanvasView(canvasID: workspace.id, name: workspace.name, workspace: workspace)
                .environmentObject(environment)
        }

        .alert("app.floe_agent_app.the_local_model_needs_the_linux",
            isPresented: Binding(
                get: { environment.heavyRuntimeConflictCenter.pending != nil },
                set: { presented in
                    // Any dismissal that is not one of the two buttons defers:
                    // the arbiter only stops guests after an explicit confirm.
                    if !presented { environment.heavyRuntimeConflictCenter.resolve(.deferLocalModel) }
                }
            )
        ) {
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) {
                environment.heavyRuntimeConflictCenter.resolve(.deferLocalModel)
            }
            Button("app.floe_agent_app.stop_and_continue", role: .destructive) {
                environment.heavyRuntimeConflictCenter.resolve(.stopGuestsAndProceed)
            }
        } message: {
            Text(Self.heavyRuntimeConflictMessage(environment.heavyRuntimeConflictCenter.pending))
        }
        .alert("app.floe_agent_app.delete_task", isPresented: Binding(
            get: { deletingConversation != nil },
            set: { if !$0 { deletingConversation = nil } }
        )) {
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { deletingConversation = nil }
            Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                guard let target = deletingConversation else { return }
                deletingConversation = nil
                Task { try? await environment.conversationCenter.deleteConversation(id: target.id) }
            }
        } message: {
            Text("app.floe_agent_app.the_task_private_workspace_and_temporary")
        }
        .confirmationDialog("settings.files_settings_view.remove_workspace_2",
            isPresented: Binding(
                get: { deletingWorkspace != nil },
                set: { if !$0 { deletingWorkspace = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("localmodels.remove", role: .destructive) {
                guard let target = deletingWorkspace else { return }
                deletingWorkspace = nil
                Task { try? await environment.workspaceCenter.deleteWorkspace(id: target.id) }
            }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { deletingWorkspace = nil }
        } message: {
            Text("app.floe_agent_app.only_the_project_entry_in_floe")
        }
        .preferredColorScheme(resolvedColorScheme)
        .environment(\.locale, resolvedLocale)
        // Terminal schedule-cleanup popup, attached exactly once at the app
        // root (Home lane owner; this lane only wires the call). It gates on
        // persistenceReady + scene active internally and never re-wraps the
        // navigation shell or changes editor identity.
        .floeScheduleCleanupPopup(environment: environment)
    }

    private func configureDocumentRouting() {
        // AppRouter is shared across scenes; the registry checks the exact
        // originating scene and its separate Notes document identity.
        environment.documentIntakeCenter.setRoutingEligibility { [weak router] presentation in
            guard let router else { return false }
            return DocumentIntakeRoutingRegistry.shared.canPresent(
                presentation, currentRoute: DocumentIntakeRouteSnapshot(router: router))
        }
    }

    private func handleEntryURL(_ url: URL) {
        do {
            let route = try FloeAppEntryRoute.parse(url)
            if case .externalFile(let file) = route {
                // Acquire the provider scope in this callback, not after boot.
                configureDocumentRouting()
                DocumentIntakeRoutingRegistry.shared.setActive(scenePhase == .active, sceneID: sceneID)
                // Common file formats opened from outside are ambiguous
                // about their destination; own-format restores (.floenote /
                // .floecanvas) keep their existing unambiguous destination.
                let ambiguous = ImportDestinationCenter.isAmbiguousExternalOpen(file)
                // The requirement is written into the staged entry
                // atomically before publish (fail-closed), so no side
                // journal can silently default an interrupted arrival.
                if let eventID = environment.documentIntakeCenter.submit(
                    file,
                    sceneID: sceneID,
                    destinationChoiceRequired: ambiguous
                ) {
                    DocumentIntakeRoutingRegistry.shared.capture(
                        DocumentIntakeRouteSnapshot(router: router), sceneID: sceneID, eventID: eventID)
                }
            } else {
                pendingEntry = QueuedEntry(route: route)
                entryNotice = nil
            }
        } catch {
            entryNotice = FloeL10n.l("app.entry.invalid_link")
        }
    }

    private func deliverPendingEntry() async {
        guard entryNavigationReady, environment.persistenceReady,
              let entry = pendingEntry else { return }
        let selection = router.workbenchSelection
        do {
            switch entry.route {
            case .newTask:
                router.startNewTask()
            case .task(let id):
                let record = try await environment.conversationStore.conversation(id: id)
                try Task.checkCancellation()
                guard pendingEntry?.id == entry.id else { return }
                guard router.workbenchSelection == selection else {
                    pendingEntry = nil
                    return
                }
                guard let record, record.archivedAt == nil, record.purpose == .ordinary, record.visibility == .normal else {
                    entryNotice = FloeL10n.l("app.entry.task_unavailable")
                    break
                }
                router.openConversation(id)
            case .shareInbox(let id):
                await environment.shareIntakeCenter.refresh()
                try Task.checkCancellation()
                guard pendingEntry?.id == entry.id else { return }
                if let id, !environment.shareIntakeCenter.pending.contains(where: { $0.id == id }) {
                    entryNotice = FloeL10n.l("app.entry.share_unavailable")
                } else {
                    // Ambiguous arrival: never navigate on arrival alone
                    // (a live Temporary Chat stays exactly where it is).
                    // The durable envelope is already staged; this only
                    // queues/presents the explicit destination choice over
                    // the current context. Navigation happens only after
                    // the user taps 导入任务.
                    await environment.importDestinationCenter.observeShareArrival(focusedEnvelopeID: id)
                    takeDestinationRequestIfNeeded()
                }
            case .externalFile:
                break
            }
        } catch is CancellationError {
            if pendingEntry?.id == entry.id, router.workbenchSelection != selection {
                pendingEntry = nil
            }
            return
        } catch {
            if pendingEntry?.id == entry.id, router.workbenchSelection == selection {
                entryNotice = FloeL10n.l("app.entry.open_failed")
            }
        }
        if pendingEntry?.id == entry.id { pendingEntry = nil }
    }

    // MARK: Inbound destination choice

    /// While another modal surface (voice, Settings, setup, design page,
    /// Canvas, batch/rename/delete sheets, execution environment) is
    /// presented, SwiftUI cannot reliably present the chooser here. The
    /// request is only PEEKED, never consumed, until the chooser actually
    /// appears; these surfaces retry through the signals above. Nothing is
    /// navigated away or discarded to force it onscreen.
    private var destinationPresentationBlocked: Bool {
        continuousVoiceActive
            || router.presentedSettings
            || router.presentedSetup != nil
            || router.presentedDesignPage != nil
            || presentedCanvasWorkspace != nil
            || renamingConversation != nil
            || deletingConversation != nil
            || deletingWorkspace != nil
            || presentedExecutionEnvironment
    }

    /// Shows the chooser over the CURRENT surface only, and only when no
    /// other modal owns the presentation slot.
    private func takeDestinationRequestIfNeeded() {
        guard presentedDestination == nil, !destinationPresentationBlocked else { return }
        let center = environment.importDestinationCenter
        guard let request = center.peekDestinationRequest() else { return }
        center.beginPresentation()
        lastPresentedDestination = request
        presentedDestination = request
    }

    /// Only an explicit choice lands here, and only then may this scene
    /// navigate. The durable ledger has already recorded the destination by
    /// the time the action returns.
    private func resolveDestination(
        _ destination: ImportDestination,
        _ request: ImportDestinationRequest,
        canvasTarget: CanvasDestinationTarget? = nil,
        taskTarget: TaskDestinationTarget? = nil
    ) async {
        let center = environment.importDestinationCenter
        let result = await center.perform(
            destination,
            for: request,
            canvasTarget: canvasTarget,
            taskTarget: taskTarget
        )
        switch result {
        case .taskReady(let target):
            presentedDestination = nil
            switch target {
            case .newTask:
                // Task destination = the existing Home draft / normal composer
                // through the reviewed share card. This attaches nothing and
                // starts nothing by itself.
                router.startNewTask()
            case .existing:
                // The confirmed task's durable draft slot already holds the
                // merge (receipt-verified). No navigation, no send.
                showDestinationNotice(FloeL10n.l("import.destination.task_imported"))
            }
        case .notesQueued:
            // Re-arm the routing fence at SELECTION time (not arrival), so
            // the existing staged import completes without stealing
            // navigation if the user moved on meanwhile.
            if case .documentEvent(let eventID) = request.origin {
                DocumentIntakeRoutingRegistry.shared.capture(
                    DocumentIntakeRouteSnapshot(router: router),
                    sceneID: sceneID,
                    eventID: eventID
                )
            }
            presentedDestination = nil
        case .notesImported(let documentCount):
            presentedDestination = nil
            showDestinationNotice(FloeL10n.plural(
                "share.intake.notes_imported",
                count: documentCount
            ))
        case .canvasReady(let itemCount):
            // No navigation: insertion into a canvas stays a user action in
            // the Canvas surface. The files are durable material now.
            presentedDestination = nil
            showDestinationNotice(FloeL10n.plural(
                "import.destination.canvas_imported",
                count: itemCount
            ))
        case .deferred, .failed:
            // Keep the sheet open with its concise reason line; the source
            // stays exactly as it was (no task, no note, no canvas, no
            // removal).
            break
        }
        takeDestinationRequestIfNeeded()
    }

    private func showDestinationNotice(_ message: String) {
        destinationNoticeTask?.cancel()
        entryNotice = message
        destinationNoticeTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if entryNotice == message { entryNotice = nil }
        }
    }

    private func presentPendingDocument() {
        guard entryNavigationReady,
              let presentation = environment.documentIntakeCenter.takePresentation(sceneID: sceneID)
        else { return }
        if presentation.kind == .floeCanvas {
            guard let canvasID = presentation.canvasID else { return }
            guard presentedCanvasWorkspace == nil,
                  !router.presentsCanvas || router.presentedCanvasID == canvasID else {
                environment.documentIntakeCenter.deferPresentation(presentation)
                return
            }
            router.presentRoutedCanvas(canvasID)
        } else {
            environment.documentIntakeCenter.presentNotes(presentation)
            router.openMore(.notes)
        }
    }

    private static func importCanvasSyncPreferenceFromCloud() {
        let cloud = NSUbiquitousKeyValueStore.default
        let key = "creative.canvas.sync.enabled"
        guard cloud.object(forKey: key) != nil else { return }
        UserDefaults.standard.set(cloud.bool(forKey: key), forKey: key)
    }

    /// Maps the appearance preference to a concrete color scheme (nil = follow
    /// the system).
    private var resolvedColorScheme: ColorScheme? {
        switch AppearancePreference(rawValue: appearanceValue) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Concrete locale rooted on FloeL10n. Reading `languageOverride`
    /// keeps this view subscribed to in-session language changes so the
    /// environment locale (and every keyed view under it) refreshes.
    private var resolvedLocale: Locale {
        _ = environment.settingsCenter.languageOverride
        return FloeL10n.swiftUILocale
    }

    @ViewBuilder
    private var persistenceState: some View {
        if let error = environment.bootstrapError {
            ContentUnavailableView {
                Label("storage.unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(error)
            }
            .background(FloeTheme.readingSurface)
        } else {
            ProgressView("storage.preparing")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FloeTheme.readingSurface)
        }
    }

    /// Presents first-run onboarding until a provider+model is configured.
    private func presentOnboardingIfNeeded() async {
        #if DEBUG
        // UI tests that exercise an unrelated settings flow must not race the
        // launch-time CloudKit grace period and have the first-run sheet appear
        // over the control they are testing. This flag is DEBUG-only and does
        // not alter production onboarding behavior.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-skip-onboarding") {
            ConversationCenter.persistOnboardingSkippedMarker(true)
            router.presentedSetup = nil
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-force-onboarding") {
            router.presentedSetup = .firstLaunch
            return
        }
        #endif
        await environment.conversationCenter.reconcileOnboardingForLaunch()
        if environment.conversationCenter.modelPreferences.onboardingStatus == .unseen,
           UserDefaults.standard.bool(forKey: ConversationCenter.onboardingSkippedDefaultsKey) {
            var preferences = environment.conversationCenter.modelPreferences
            preferences.onboardingStatus = .skipped
            try? await environment.conversationCenter.saveModelPreferences(preferences)
            return
        }
        if environment.conversationCenter.modelPreferences.onboardingStatus == .unseen {
            // Give an existing private-CloudKit configuration a brief chance
            // to arrive, without making launch dependent on network health.
            try? await Task.sleep(for: .seconds(2))
            await environment.conversationCenter.reconcileOnboardingForLaunch()
        }
        if environment.conversationCenter.modelPreferences.onboardingStatus == .unseen {
            router.presentedSetup = .firstLaunch
        }
    }

    /// Bounded, redacted conflict description: counts only. The environment
    /// IDs themselves are internal identifiers and are not shown in the alert.
    private static func heavyRuntimeConflictMessage(
        _ pending: HeavyRuntimeConflictCenter.PendingConflict?
    ) -> String {
        guard let pending else { return "" }
        var parts: [String] = []
        if pending.guestCount > 0 {
            parts.append(FloeL10n.l("app.floe_agent_app.linux_environments_count", pending.guestCount))
        }
        if pending.serviceCount > 0 {
            parts.append(FloeL10n.l("app.floe_agent_app.local_services_count", pending.serviceCount))
        }
        let running = parts.isEmpty
            ? FloeL10n.l("exec.linux.env_title")
            : parts.joined(separator: FloeL10n.l("app.floe_agent_app.list_separator"))
        return FloeL10n.l("app.floe_agent_app.local_models_and_linux_environments_cannot",
                          running)
    }

    private func markDismissedSetupSkipped() {
        let center = environment.conversationCenter
        guard center.modelPreferences.onboardingStatus == .unseen else { return }
        // Interactive sheet dismissal is synchronous. Persist this tiny local
        // marker immediately so a force-quit cannot resurrect onboarding while
        // the durable DB/CloudKit preference save is still being scheduled.
        ConversationCenter.persistOnboardingSkippedMarker(true)
        Task {
            var preferences = center.modelPreferences
            preferences.onboardingStatus = .skipped
            try? await center.saveModelPreferences(preferences)
        }
    }

    // MARK: - iPhone: task workbench with a native sidebar drawer

    private var iPhoneRoot: some View {
        GeometryReader { proxy in
            let drawerWidth = min(390, max(300, proxy.size.width - 44))
            let baseOffset = isPhoneSidebarOpen ? CGFloat.zero : -drawerWidth
            let interactiveOffset = min(0, max(-drawerWidth, baseOffset + phoneDrawerTranslation))
            let drawerProgress = 1 - abs(interactiveOffset / drawerWidth)
            ZStack(alignment: .leading) {
                contentColumn
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(1 - drawerProgress * 0.025, anchor: .trailing)
                    .offset(x: drawerProgress * 18)
                    .clipShape(.rect(cornerRadius: drawerProgress * 22))
                    .overlay(alignment: .topLeading) {
                        if drawerProgress == 0 {
                            Button { withAnimation(.snappy) { isPhoneSidebarOpen = true } } label: {
                                Image(systemName: "sidebar.left")
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .padding(.leading, 8)
                            .padding(.top, 4)
                            .accessibilityLabel("app.floe_agent_app.open_task_list")
                            .accessibilityIdentifier("phone.sidebar.open")
                        }
                    }

                if drawerProgress > 0 {
                    Color.black.opacity(0.22 * drawerProgress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy) { isPhoneSidebarOpen = false } }
                        .accessibilityLabel("app.floe_agent_app.collapse_task_list")
                }

                sidebarColumn
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .background(FloeTheme.groupedSurface.ignoresSafeArea())
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .offset(x: interactiveOffset)
                    .shadow(color: .black.opacity(0.18 * drawerProgress), radius: 24, x: 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("phone.sidebar.drawer")

                if let route = presentableInspectorRoute {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { router.hideInspector() }
                    NavigationStack { InspectorColumnView(route: route).id(route.id) }
                        .frame(width: drawerWidth, height: proxy.size.height)
                        .background(FloeTheme.readingSurface)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing))
                        .shadow(radius: 12)
                        .accessibilityIdentifier("phone.inspector.drawer")
                }
            }
            // Respect the top safe area so the navigation bar (and the
            // drawer's "Floe Agent" title) never collides with the system
            // status-bar clock. Overlay scrims and drawer backgrounds still
            // extend behind the status bar via their own .ignoresSafeArea().
            .animation(.snappy, value: isPhoneSidebarOpen)
            .animation(.snappy, value: router.inspectorRoute)
            .contentShape(Rectangle())
            .simultaneousGesture(phoneDrawerGesture(drawerWidth: drawerWidth))
        }
        .onChange(of: router.workbenchSelection) { _, _ in
            withAnimation(.snappy) { isPhoneSidebarOpen = false }
        }
        .onChange(of: router.sidebarSelection) { _, _ in
            // Creative mode and plugins change the sidebar route without
            // changing the selected task. Close the phone drawer for them too.
            withAnimation(.snappy) { isPhoneSidebarOpen = false }
        }
    }

    private func phoneDrawerGesture(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($phoneDrawerTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if isPhoneSidebarOpen {
                    state = min(0, value.translation.width)
                } else if value.startLocation.x < 28, router.inspectorRoute == nil {
                    state = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                guard abs(horizontal) > abs(value.translation.height) else { return }
                if !isPhoneSidebarOpen,
                   value.startLocation.x < 28,
                   router.inspectorRoute == nil,
                   max(horizontal, predicted) > drawerWidth * 0.22 {
                    withAnimation(.snappy) { isPhoneSidebarOpen = true }
                } else if isPhoneSidebarOpen {
                    // A deliberate horizontal swipe anywhere in the drawer
                    // closes it. Supporting the user's right-swipe habit as
                    // well as the conventional left swipe avoids requiring a
                    // separate hand/pan mode just to dismiss navigation.
                    let closesLeft = min(horizontal, predicted) < -drawerWidth * 0.22
                    let closesRight = max(horizontal, predicted) > drawerWidth * 0.22
                    if closesLeft || closesRight {
                        withAnimation(.snappy) { isPhoneSidebarOpen = false }
                    }
                } else if horizontal > 0, router.inspectorRoute != nil {
                    router.hideInspector()
                }
            }
    }

    // MARK: - iPad: task surface with an on-demand inspector

    @ViewBuilder
    private var iPadRoot: some View {
        // Keep one stable two-column split. Replacing a two-column
        // NavigationSplitView with a three-column instance while a WKWebView
        // is first responder can leave the old UIKit hit-test surface above
        // the newly-created sidebar and toolbar. The inspector is an explicit
        // trailing pane inside the stable detail column instead.
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            sidebarColumn
                .collapseSidebarOnRightSwipe {
                    withAnimation(.snappy) {
                        router.columnVisibility = .detailOnly
                    }
                }
        } detail: {
            HStack(spacing: 0) {
                contentColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let inspectorRoute = presentableInspectorRoute {
                    Divider()
                    NavigationStack {
                        // The inspector must be re-created per conversation:
                        // its `.task` re-mounts the task workspace, but the
                        // previous conversation's file tree/editor state must
                        // never linger as a stale right-hand workspace.
                        InspectorColumnView(route: inspectorRoute).id(inspectorRoute.id)
                    }
                    .frame(minWidth: 360, idealWidth: 430, maxWidth: 520)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityIdentifier("ipad.inspector.column")
                }
            }
        }
        .animation(.snappy, value: router.inspectorRoute)
    }

    /// Shared information architecture. NavigationSplitView projects this
    /// as a first column on iPad and a native drawer on iPhone.
    private var sidebarColumn: some View {
        SidebarObservationHost(center: environment.conversationCenter, workspaces: environment.workspaceCenter) {
            GeometryReader { proxy in
                sidebarContent
                    .onChange(of: proxy.size.width) { _, width in
                        // Persist the user's chosen width (bounded) so the next
                        // presentation restores it; ignore tiny layout noise.
                        layoutPreferences.setSidebarWidth(Double(width))
                    }
            }
            .navigationSplitViewColumnWidth(
                min: LayoutSettings.sidebarMinimumWidth,
                ideal: layoutPreferences.settings.sidebarWidth,
                max: LayoutSettings.sidebarMaximumWidth)
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            List(selection: $router.sidebarSelection) {
                Section {
                    Label("workbench.new_task", systemImage: "square.and.pencil")
                        .tag(SidebarSelection.workbench(.newTask(workspaceID: nil)))
                        .accessibilityIdentifier("sidebar.workbench.new_task")
                    Label("app.floe_agent_app.task_center", systemImage: "checklist")
                        .tag(SidebarSelection.workbench(.overview))
                        .accessibilityIdentifier("sidebar.task_center")
                    Label("notes.notes_root_view.notes", systemImage: "book.pages")
                        .tag(SidebarSelection.more(.notes))
                        .accessibilityIdentifier("sidebar.notes")
                    Label("app.floe_agent_app.creative", systemImage: "rectangle.and.pencil.and.ellipsis")
                        .tag(SidebarSelection.more(.creative))
                        .accessibilityIdentifier("sidebar.creative")
                    Label("plugins.title", systemImage: "puzzlepiece.extension")
                        .tag(SidebarSelection.more(.skills))
                        .accessibilityIdentifier("sidebar.skills")
                }
                if !environment.workspaceCenter.projectWorkspaces.isEmpty {
                    Section("workspace.title") {
                        ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedWorkspaceIDs.contains(workspace.id) },
                                    set: { expanded in
                                        if expanded { expandedWorkspaceIDs.insert(workspace.id) }
                                        else { expandedWorkspaceIDs.remove(workspace.id) }
                                    }
                                )
                            ) {
                                if WorkspaceCanvasRegistry.exists(workspaceID: workspace.id) {
                                    Button {
                                        presentedCanvasWorkspace = workspace
                                    } label: {
                                        Label("settings.settings_root_view.canvas", systemImage: "rectangle.and.pencil.and.ellipsis")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("sidebar.workspace.canvas.\(workspace.id.uuidString)")
                                }
                                ForEach(conversations(in: workspace.id)) { conversation in
                                    conversationSidebarRow(conversation)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Button {
                                        router.selectWorkspace(workspace.id)
                                        Task {
                                            try? await environment.workspaceCenter.openWorkspace(id: workspace.id)
                                        }
                                    } label: {
                                        Label(workspace.name, systemImage: "folder")
                                    }
                                    .buttonStyle(.plain)
                                    Spacer(minLength: 4)
                                    workspaceAddControl(workspace)
                                }
                            }
                            .accessibilityIdentifier("sidebar.workspace.\(workspace.id.uuidString)")
                            .contextMenu {
                                Button(role: .destructive) {
                                    deletingWorkspace = workspace
                                } label: {
                                    Label("settings.files_settings_view.remove_workspace", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                if !chatConversations.isEmpty {
                    Section("settings.all_workspaces_files_view.chat") {
                        ForEach(chatConversations) { conversation in
                            conversationSidebarRow(conversation)
                        }
                    }
                }
            }
            .accessibilityIdentifier("sidebar.list")
            .disabled(inlineSelection.busy)
            if inlineSelection.isActive {
                InlineConversationSelectionBar(
                    model: inlineSelection,
                    center: environment.conversationCenter,
                    visibleIDs: { inlineSidebarVisibleIDs },
                    selectedItems: { inlineSidebarSelectedItems }
                )
                Divider()
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    router.presentedSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("more.settings")
                .accessibilityIdentifier("sidebar.settings")
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("app.name")
        .task {
            await environment.workspaceCenter.reload()
            await environment.conversationCenter.reload()
        }
        .onChange(of: router.sidebarSelection) { oldValue, newValue in
            applySidebarSelection(newValue)
            preferredCompactColumn = .detail
            discardTemporarySessionOnContentLeave(old: oldValue, new: newValue)
        }
        .inlineConversationSelectionChrome(
            model: inlineSelection,
            center: environment.conversationCenter,
            afterRun: {
                // Real reload only: the center republishes, the existing
                // router reconciliation updates selection/navigation, and an
                // open conversation that was archived/deleted follows the
                // established route — nothing is fabricated.
                await environment.conversationCenter.reload()
            }
        )
        .onChange(of: environment.conversationCenter.conversations.map(\.id)) { _, _ in
            inlineSelection.pruneInvisible(inlineSidebarVisibleIDs)
        }
        .onChange(of: expandedWorkspaceIDs) { _, _ in
            // Collapsing a project hides its rows: invisible selections
            // must not stay pending.
            inlineSelection.pruneInvisible(inlineSidebarVisibleIDs)
        }
    }

    /// Leaving the visible conversation surface — another chat, New Task, a
    /// workspace, overview, or a primary/more destination — explicitly ends
    /// an active temporary chat exactly once: the session is discarded and
    /// its owned run cancelled, EVEN mid-generation or mid-Keep. An
    /// in-flight Keep is settled atomically first: a committed promotion is
    /// ordinary truth and survives with normal history/lifecycle; no
    /// resumable temporary state remains after the leave. Rotation,
    /// fullscreen editing and content-view rebuilds never change the
    /// sidebar selection, so they cannot discard; background/foreground
    /// transitions are NOT navigation leaves and never destroy the session.
    /// An inspector inherited from an ordinary thread can be retargeted by
    /// AppRouter when the selected conversation changes. Temporary chats have
    /// no workspace/browser/terminal/child bindings: never mount such a pane
    /// for that identity, even for a frame before the route is reconciled.
    /// An inspector still owned by another ordinary task keeps its own scope.
    private var presentableInspectorRoute: AppRouter.InspectorRoute? {
        guard let route = router.inspectorRoute else { return nil }
        if environment.conversationCenter.isTemporaryConversation(route.conversationID),
           route.content != .progress {
            return nil
        }
        return route
    }

    private func reconcileTemporaryInspectorRoute() {
        if router.inspectorRoute != nil, presentableInspectorRoute == nil {
            router.hideInspector()
        }
    }

    private func discardTemporarySessionOnContentLeave(
        old oldSelection: SidebarSelection?,
        new newSelection: SidebarSelection?
    ) {
        guard oldSelection != newSelection,
              case .workbench(.conversation(let visibleID)) = oldSelection
        else { return }
        // A toggle-on attempt whose eligibility transaction is still
        // suspended must not publish a temporary session after the user left
        // this conversation: cancel it first (the attempt's own continuation
        // restores anything a committed removal deleted). This runs for
        // every leave, with or without an already-published session.
        environment.conversationCenter.cancelPendingTemporaryToggle(for: visibleID)
        guard let session = environment.conversationCenter.temporarySession,
              session.conversation.id == visibleID
        else { return }
        // The expected identity is captured HERE (synchronously, with the
        // guard) and bound into the destroy: a late task from an old view
        // can never act on a replacement session — not even one that reuses
        // the same conversation UUID (the incarnation distinguishes epochs).
        let incarnation = session.incarnation
        Task {
            await environment.conversationCenter.endTemporaryChat(
                expectedConversationID: visibleID,
                expectedIncarnation: incarnation)
        }
    }

    private func conversations(in workspaceID: UUID) -> [ConversationRecord] {
        environment.conversationCenter.conversations.filter {
            environment.workspaceCenter.workspaceID(for: $0.id) == workspaceID
        }
    }

    private var chatConversations: [ConversationRecord] {
        let privateIDs = Set(environment.workspaceCenter.workspaces
            .filter { $0.kind == .privateTask }.map(\.id))
        return environment.conversationCenter.conversations.filter {
            environment.workspaceCenter.workspaceID(for: $0.id).map(privateIDs.contains) == true
        }
    }

    /// One sidebar conversation row. Long press ALWAYS enters the inline
    /// selection (leading circles appear here; no management sheet and no
    /// navigation — the row is `selectionDisabled` while selected so the
    /// release cannot commit a list selection, and the recognized gesture
    /// consumes the touch). Outside selection the normal swipe actions and
    /// the per-row action menu stay; while selection is open they are the
    /// conflicting controls and are hidden, and a tap toggles the circle
    /// instead of navigating. `router.sidebarSelection` is never touched by
    /// selection itself, so the open conversation and temporary-session
    /// ownership are unaffected.
    @ViewBuilder
    private func conversationSidebarRow(_ conversation: ConversationRecord) -> some View {
        let base = HStack(spacing: 8) {
            if inlineSelection.isActive {
                InlineSelectionCircle(
                    conversationID: conversation.id,
                    isSelected: inlineSelection.selectedIDs.contains(conversation.id)
                )
            }
            Label(conversation.title.isEmpty ? String(localized: "chat.untitled") : conversation.title, systemImage: "bubble.left")
            Spacer(minLength: 0)
            ConversationActivityBadge(conversationID: conversation.id, center: environment.conversationCenter)
            if !inlineSelection.isActive {
                sidebarRowActionsMenu(conversation)
            }
        }
        .lineLimit(1)
        .tag(SidebarSelection.workbench(.conversation(conversation.id)))
        .accessibilityIdentifier("sidebar.conversation.\(conversation.id.uuidString)")
        .inlineSelectionRowTraits(model: inlineSelection, conversationID: conversation.id)
        .contentShape(Rectangle())
        .inlineSelectionLongPress(conversationID: conversation.id, model: inlineSelection)

        if inlineSelection.isActive {
            base
                .selectionDisabled(true)
                .onTapGesture {
                    inlineSelection.toggle(conversation.id)
                }
        } else {
            base
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        Task { try? await environment.conversationCenter.archiveConversation(id: conversation.id) }
                    } label: { Label("app.floe_agent_app.archive", systemImage: "archivebox") }
                    .tint(.orange)
                    Button(role: .destructive) { deletingConversation = conversation } label: {
                        Label("workspace.workspace_canvas_view.delete", systemImage: "trash")
                    }
                }
        }
    }

    /// The single-task actions that previously lived in the long-press
    /// menu. Long press now opens the inline selection, so they stay
    /// reachable through this explicit per-row control (hidden while a
    /// selection is active, together with the swipe actions).
    private func sidebarRowActionsMenu(_ conversation: ConversationRecord) -> some View {
        Menu {
            Button {
                renamingConversation = conversation
            } label: {
                Label("workspace.file_tree_view.rename", systemImage: "pencil")
            }
            Menu("app.floe_agent_app.move_to_project") {
                ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                    Button(workspace.name) {
                        Task {
                            try? await environment.conversationCenter.moveConversation(
                                id: conversation.id,
                                to: workspace.id
                            )
                        }
                    }
                }
            }
            Button {
                Task { try? await environment.conversationCenter.archiveConversation(id: conversation.id) }
            } label: {
                Label("app.floe_agent_app.archive_task", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                deletingConversation = conversation
            } label: {
                Label("app.floe_agent_app.delete_task_2", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                // The glyph stays compact; the hit target keeps the app's
                // standard minimum (same 44pt used across controls).
                .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(ChatBilingualCatalog.localized(
            key: "sidebar.row_actions",
            en: "Task actions",
            zh: "任务操作"
        ))
        .accessibilityIdentifier("sidebar.rowActions.\(conversation.id.uuidString)")
    }

    /// Sidebar conversation rows the user can currently see: expanded
    /// project workspaces plus the Chat section. Collapsed rows are NOT
    /// visible and are pruned from any pending selection.
    private var inlineSidebarVisibleRecords: [ConversationRecord] {
        var records: [ConversationRecord] = []
        for workspace in environment.workspaceCenter.projectWorkspaces
        where expandedWorkspaceIDs.contains(workspace.id) {
            records.append(contentsOf: conversations(in: workspace.id))
        }
        records.append(contentsOf: chatConversations)
        return records
    }

    private var inlineSidebarVisibleIDs: Set<UUID> {
        Set(inlineSidebarVisibleRecords.map(\.id))
    }

    private var inlineSidebarSelectedItems: [TaskBulkItem] {
        inlineSidebarVisibleRecords
            .filter { inlineSelection.selectedIDs.contains($0.id) }
            .map { TaskBulkItem(id: $0.id, title: InlineSelectionCopy.untitled($0.title)) }
    }

    @ViewBuilder
    private func workspaceAddControl(_ workspace: WorkspaceRecord) -> some View {
        // Reading this state makes explicit creation immediately re-project
        // the optional CanvasProject child without a database refresh.
        let _ = canvasPresenceRevision
        if WorkspaceCanvasRegistry.exists(workspaceID: workspace.id) {
            Button {
                router.startNewTask(workspaceID: workspace.id)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(FloeL10n.l("app.floe_agent_app.new_task_in", workspace.name))
        } else {
            Menu {
                Button {
                    router.startNewTask(workspaceID: workspace.id)
                } label: {
                    Label("app.floe_agent_app.new_regular_chat", systemImage: "square.and.pencil")
                }
                Button {
                    do {
                        try WorkspaceCanvasRegistry.createIfNeeded(workspace: workspace)
                        canvasPresenceRevision += 1
                        expandedWorkspaceIDs.insert(workspace.id)
                        presentedCanvasWorkspace = workspace
                    } catch {
                        FloeLogger(category: .app).error(
                            "canvasCreateFailed workspace=\(workspace.id.uuidString)"
                        )
                    }
                } label: {
                    Label("workspace.workspace_canvas_view.new_canvas", systemImage: "rectangle.and.pencil.and.ellipsis")
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(FloeL10n.l("app.floe_agent_app.new_in", workspace.name))
        }
    }

    /// Column 2 renders the canonical workbench selection or the selected
    /// primary/More destination.
    @ViewBuilder
    private var contentColumn: some View {
        switch router.sidebarSelection ?? .workbench(router.workbenchSelection) {
        case .workbench(let selection):
            switch selection {
            case .overview:
                HomeOverviewView(center: environment.conversationCenter)
            case .newTask(let workspaceID):
                NavigationStack {
                    HomeLaunchpadView(
                        center: environment.conversationCenter,
                        workspaceID: workspaceID
                    )
                }
            case .workspace(let workspaceID):
                NavigationStack {
                    HomeLaunchpadView(
                        center: environment.conversationCenter,
                        workspaceID: workspaceID
                    )
                }
            case .conversation(let conversationID):
                NavigationStack {
                    ThreadDetailView(
                        conversationID: conversationID,
                        center: environment.conversationCenter
                    )
                }
                .id(conversationID)
            }
        case .primary(let destination):
            if destination == .home || destination == .chat {
                HomeOverviewView(center: environment.conversationCenter)
            } else {
                PrimaryDestinationView(destination, environment: environment)
            }
        case .more(let sub):
            MoreListView(selection: sub)
        }
    }

    private func applySidebarSelection(_ selection: SidebarSelection?) {
        guard let selection else { return }
        switch selection {
        case .workbench(.overview):
            router.showOverview()
        case .workbench(.newTask(let workspaceID)):
            router.startNewTask(workspaceID: workspaceID)
        case .workbench(.workspace(let workspaceID)):
            router.selectWorkspace(workspaceID)
            Task { try? await environment.workspaceCenter.openWorkspace(id: workspaceID) }
        case .workbench(.conversation(let conversationID)):
            router.workbenchSelection = .conversation(conversationID)
            router.workbenchPath = [conversationID]
            router.selection = .home
        case .primary(let destination):
            router.navigate(to: destination)
        case .more(let destination):
            router.openMore(destination)
        }
    }
}

/// The on-demand inspector column (iPad third column / iPhone sheet).
/// T05: renders the real workspace file inspector through WorkspaceCenter.
private struct InspectorColumnView: View {
    let route: AppRouter.InspectorRoute
    @EnvironmentObject private var environment: AppEnvironment
    @State private var workspaceMountState: WorkspaceMountState = .idle
    @State private var workspaceMountAttempt = 0
    @State private var terminalOwner: LocalTerminalOwner?
    @State private var showsRemoteTerminal = false

    private enum WorkspaceMountState: Equatable {
        case idle
        case loading
        case mounted
        case failed(String)
    }

    var body: some View {
        Group {
            switch route.content {
            case .changes, .workspaceFiles:
                workspaceBackedContent
            case .browser:
                BrowserView(center: environment.browserCenter)
            case .terminal:
                VStack(spacing: 0) {
                    Picker(IDELanguageRunText.t("终端", "Terminal"), selection: $showsRemoteTerminal) {
                        Text(IDELanguageRunText.t("本地工作区", "Local workspace")).tag(false)
                        Text(IDELanguageRunText.t("远程 SSH", "Remote SSH")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    .accessibilityIdentifier("terminal.destination")
                    if showsRemoteTerminal {
                        HostListView(center: environment.remoteSessionCenter)
                    } else {
                        workspaceBackedContent
                    }
                }
            case .progress:
                TaskProgressInspectorView(conversationID: route.conversationID)
            case .childAgents:
                ChildAgentsInspectorView(conversationID: route.conversationID)
            case .permissions:
                TaskPermissionsInspectorView(conversationID: route.conversationID)
            }
        }
        .task(id: "\(route.id).\(workspaceMountAttempt)") {
            let conversationID = route.conversationID
            switch route.content {
            case .changes, .workspaceFiles, .terminal:
                workspaceMountState = .loading
                terminalOwner = nil
                do {
                    try await environment.workspaceCenter.openTaskWorkspace(
                        conversationID: conversationID
                    )
                    guard !Task.isCancelled else { return }
                    if route.content == .terminal,
                       let workspace = environment.workspaceCenter.currentWorkspace,
                       let root = environment.workspaceCenter.currentRootURL {
                        terminalOwner = environment.localTerminals.owner(workspaceID: workspace.id, root: root)
                    }
                    workspaceMountState = .mounted
                } catch is CancellationError {
                    return
                } catch {
                    workspaceMountState = .failed(error.localizedDescription)
                }
            case .browser:
                environment.browserCenter.bind(to: conversationID)
            case .progress, .childAgents, .permissions:
                break
            }
        }
    }

    @ViewBuilder
    private var workspaceBackedContent: some View {
        switch workspaceMountState {
        case .mounted:
            if route.content == .terminal {
                if let terminalOwner {
                    LocalTerminalView(owner: terminalOwner, embedded: true)
                        .accessibilityIdentifier("terminal.local.workspace")
                } else {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("本地终端不可用", "Local terminal unavailable"), systemImage: "terminal")
                    } actions: {
                        Button(IDELanguageRunText.t("重试", "Retry")) { workspaceMountAttempt += 1 }
                    }
                }
            } else if route.content == .changes {
                TaskChangesInspectorView(conversationID: route.conversationID)
            } else {
                FileInspectorView(center: environment.workspaceCenter)
                    .background(FloeTheme.readingSurface)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("app.floe_agent_app.the_workspace_could_not_be_mounted", systemImage: "folder.badge.questionmark")
            } description: {
                Text(message)
            } actions: {
                Button("settings.document_recovery_list_view.retry") { workspaceMountAttempt += 1 }
                    .buttonStyle(.borderedProminent)
            }
        case .idle, .loading:
            ProgressView("app.floe_agent_app.mounting_task_workspace")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FloeTheme.readingSurface)
        }
    }
}

/// Routes a primary destination to its root screen. Every root is a real
/// navigation-titled screen with a localized empty state — never a promise
/// of a future milestone.
private struct PrimaryDestinationView: View {
    let destination: AppDestination
    let environment: AppEnvironment

    init(_ destination: AppDestination, environment: AppEnvironment) {
        self.destination = destination
        self.environment = environment
    }

    var body: some View {
        switch destination {
        case .home:
            HomeLaunchpadView(center: environment.conversationCenter)
        case .chat:
            ConversationListView(center: environment.conversationCenter)
        case .files:
            FilesView(center: environment.filesCenter)
        case .browser:
            BrowserView(center: environment.browserCenter)
        case .hosts:
            HostListView(center: environment.remoteSessionCenter)
        case .more:
            MoreView(center: environment.conversationCenter)
        }
    }
}

/// Creative-routing canvas destination cover. Extracted so the app body
/// stays type-checkable; the design workbench sheet stays inline above.
private struct CanvasDestinationCover: ViewModifier {
    @EnvironmentObject private var router: AppRouter
    let environment: AppEnvironment

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $router.presentsCanvas) {
                if let canvasID = router.presentedCanvasID {
                    CanvasDestinationOpener(canvasID: canvasID, environment: environment)
                        .environmentObject(environment)
                }
            }
    }
}

/// iPad Chat detail with nothing selected: quiet empty state plus a real
/// "new conversation" entry. Never the Home launchpad.
private struct ChatDetailEmptyView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ContentUnavailableView {
            Label("tab.chat", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("chat.select_or_new")
        } actions: {
            Button("chat.new") {
                Task {
                    if let conversation = try? await environment.conversationCenter
                        .createConversation(title: nil) {
                        router.openConversation(conversation.id)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("chat.detail.new")
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("tab.chat")
    }
}

/// The More list: Runs, Providers, Settings, and Diagnostics. As the iPhone
/// More tab root it pushes sub-screens; as the
/// iPad content column it renders the sidebar-selected section directly.
private struct MoreListView: View {
    /// When set (iPad content column), that section's screen is embedded
    /// here; when nil (iPhone More tab), the full list pushes sub-screens.
    let selection: MoreDestination?

    var body: some View {
        if let selection {
            MoreDestinationView(selection)
        } else {
            List {
                ForEach(MoreDestination.visibleCases) { sub in
                    NavigationLink(value: sub) {
                        Label(sub.title, systemImage: sub.systemImage)
                    }
                }
            }
            .navigationTitle("tab.more")
            .navigationDestination(for: MoreDestination.self) { sub in
                MoreDestinationView(sub)
            }
        }
    }
}

/// Routes a More sub-destination to its real screen.
private struct MoreDestinationView: View {
    let sub: MoreDestination

    @EnvironmentObject private var environment: AppEnvironment

    init(_ sub: MoreDestination) {
        self.sub = sub
    }

    var body: some View {
        switch sub {
        case .notes:
            NotesRootView()
        case .creative:
            CreativeModeHubView()
        case .runs:
            RunsHistoryView(viewModel: MoreViewModel(center: environment.conversationCenter))
        case .setupGuide:
            SetupGuideLauncherView()
        case .providers:
            ProviderListView(center: environment.conversationCenter)
        case .auxiliaryModels:
            AuxiliaryModelsView(center: environment.conversationCenter)
        case .skills:
            SkillsView(center: environment.skillsCenter)
        case .memory:
            NavigationStack {
                MemoryView(center: environment.memoryCenter)
            }
        case .settings:
            SettingsRootView(environment: environment)
        case .diagnostics:
            DiagnosticsAboutView(center: environment.settingsCenter)
        }
    }
}

/// A structural empty state used when the split view has no selected detail.
private struct ShellPlaceholderView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let messageKey: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(messageKey)
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle(title)
    }
}

private struct TaskRenameSheet: View {
    let conversation: ConversationRecord
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(conversation: ConversationRecord, save: @escaping (String) async throws -> Void) {
        self.conversation = conversation
        self.save = save
        _title = State(initialValue: conversation.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("app.floe_agent_app.task_name", text: $title)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(FloeTheme.destructive)
                }
            }
            .navigationTitle("app.floe_agent_app.rename_task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            do { try await save(title); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Observe nested stores at the sidebar boundary, not the whole chat tree.
/// Reading them through AppEnvironment alone does not subscribe to updates.
private struct SidebarObservationHost<Content: View>: View {
    @ObservedObject var center: ConversationCenter
    @ObservedObject var workspaces: WorkspaceCenter
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

#endif
