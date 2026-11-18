// Floe Mac M00 — owner of the nested Mac Catalyst UI app.
//
// SPDX-License-Identifier: MPL-2.0
//
// The Catalyst app is an internal component, not a second installable product.
// It is launched through NSWorkspace exactly as the host would launch any
// nested UI, and M00 records its activation policy so a second Dock entry is
// a visible failure rather than an assumption.

import AppKit
import Combine
import Foundation

struct CatalystProbeReport {
    var appPath: String
    var markerPath: String
    var launched: Bool
    var pid: Int32?
    var activationPolicy: Int
    var activationPolicyName: String
    var marker: [String: Any]?
    var terminated: Bool
    var error: String?
}

@MainActor
final class AgentUIComponentController: ObservableObject {
    enum State: Equatable {
        case idle
        case launching
        case running(pid: Int32)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var runningApplication: NSRunningApplication?
    private var terminationObserver: NSObjectProtocol?
    private var observerGeneration: UInt64 = 0
    private let appOverride: URL?
    // All fields are main-actor isolated. NSWorkspace's async completion can
    // arrive after the user presses Close, so retain the intent until the
    // owned launch settles instead of treating a nil process as idle.
    private var opening = false
    private var closing = false
    private var probing = false
    private var closeRequested = false
    private var openOutcomeUnknown = false
    // Held through a successful host termination decision. A launch that was
    // already in flight must settle before the host can safely exit.
    private var hostTerminationFence = false
    /// User intent, independent of the current process state: an owned app
    /// may still be running while an explicit Close is already in flight.
    private(set) var userWantsAgentOpen = false
    /// A successful terminate request can complete after the caller cancels.
    /// Keep that exact owned handle and a separately cancellable reopen intent.
    private var terminationRequestedFor: NSRunningApplication?
    private var restorationGeneration = UUID()
    private var restorationTask: Task<Void, Never>?
    #if FLOE_AGENT_UI_EXIT_TESTING
    func setOpeningForTesting(_ value: Bool) { opening = value }
    func setUnknownForTesting(_ value: Bool) { openOutcomeUnknown = value }
    func setCloseRequestedForTesting(_ value: Bool) { closeRequested = value }
    var hostTerminationFenceForTesting: Bool { hostTerminationFence }
    var closeRequestedForTesting: Bool { closeRequested }
    #endif

    init(appOverride: URL? = nil) {
        self.appOverride = appOverride
    }

    func locateApp() -> URL? {
        if let appOverride {
            return FileManager.default.fileExists(atPath: appOverride.path) ? appOverride : nil
        }
        if let text = ProcessInfo.processInfo.environment["FLOE_MAC_AGENT_UI_PATH"], !text.isEmpty {
            let url = URL(fileURLWithPath: text, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("Contents/Helpers/FloeMacAgentUI.app", isDirectory: true),
            bundle.deletingLastPathComponent().appendingPathComponent("FloeMacAgentUI.app", isDirectory: true)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func launch() async {
        // Do not create a second NSWorkspace instance while an earlier launch,
        // stop or smoke probe is suspended.
        guard !hostTerminationFence else { return }
        userWantsAgentOpen = true
        closeRequested = false
        if closing, let current = runningApplication, !current.isTerminated,
           terminationRequestedFor === current {
            scheduleRestoreAfterExit(of: current)
            return
        }
        guard !opening, !closing, !probing else { return }
        guard !openOutcomeUnknown else {
            state = .failed("The previous Catalyst UI launch could not be confirmed.")
            return
        }
        if let current = runningApplication, !current.isTerminated {
            _ = current.activate()
            if terminationRequestedFor === current { scheduleRestoreAfterExit(of: current) }
            return
        }
        invalidateRestoration()
        runningApplication = nil
        removeObserver()
        guard let appURL = locateApp() else {
            state = .failed("Nested Catalyst UI app is missing from the app bundle.")
            return
        }
        opening = true
        closeRequested = false
        state = .launching
        defer { opening = false }
        do {
            let application = try await open(
                appURL,
                arguments: [],
                environment: nil,
                activates: true
            )
            runningApplication = application
            observeTermination(of: application)
            if closeRequested || hostTerminationFence {
                await stopOwnedApplication(application)
                return
            }
            guard !application.isTerminated else {
                runningApplication = nil
                removeObserver()
                state = .failed("The Catalyst UI exited during launch.")
                return
            }
            state = .running(pid: application.processIdentifier)
        } catch {
            // An async launch error does not prove that no process was
            // created. Do not silently retry or claim the process is gone.
            openOutcomeUnknown = true
            state = .failed("Could not confirm the Catalyst UI launch: \(error.localizedDescription)")
        }
    }

    func terminateOwned() async {
        invalidateRestoration()
        userWantsAgentOpen = false
        closeRequested = true
        // The launch/probe owns its result and will honor this intent as soon
        // as NSWorkspace returns. A second stop does not race the first.
        guard !opening, !probing, !closing else { return }
        guard let application = runningApplication else {
            if openOutcomeUnknown {
                state = .failed("The previous Catalyst UI launch could not be confirmed.")
            } else {
                state = .idle
            }
            return
        }
        await stopOwnedApplication(application)
    }

    /// Quiesce the owned M00 UI before its host exits. A successful return
    /// leaves launch admission closed until the host exits or cancels the
    /// termination. This waits for already-issued NSWorkspace operations and
    /// never signals an application for which this controller has no handle.
    func prepareForHostTermination(timeout: Duration = .seconds(5)) async -> Bool {
        guard !hostTerminationFence else { return false }
        invalidateRestoration()
        hostTerminationFence = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while opening || probing || closing {
            guard !Task.isCancelled, clock.now < deadline else {
                cancelHostTermination()
                return false
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { cancelHostTermination(); return false }
        }
        guard !openOutcomeUnknown else {
            cancelHostTermination()
            return false
        }
        if let application = runningApplication {
            await stopOwnedApplication(application)
        }
        guard !Task.isCancelled, !opening, !probing, !closing,
              !openOutcomeUnknown,
              runningApplication == nil || runningApplication?.isTerminated == true else {
            cancelHostTermination()
            return false
        }
        return true
    }

    /// Resume admissions only if host termination was refused or cancelled.
    func cancelHostTermination() {
        hostTerminationFence = false
    }

    /// A cancelled host quit cannot revoke an already-sent terminate request.
    /// If it is still pending, retain this exact owned process and reopen only
    /// after that process really exits. A later explicit close or quit fences
    /// the intent, so a stale callback cannot resurrect a window.
    func restoreAfterCancelledHostTermination() async {
        guard userWantsAgentOpen, !hostTerminationFence, !openOutcomeUnknown else { return }
        if let current = runningApplication, !current.isTerminated,
           terminationRequestedFor === current {
            _ = current.activate()
            scheduleRestoreAfterExit(of: current)
            return
        }
        await launch()
    }

    private func invalidateRestoration() {
        restorationGeneration = UUID()
        restorationTask?.cancel()
        restorationTask = nil
    }

    private func scheduleRestoreAfterExit(of application: NSRunningApplication) {
        invalidateRestoration()
        let ticket = restorationGeneration
        restorationTask = Task { @MainActor [weak self, application] in
            while true {
                guard let self, !Task.isCancelled, self.restorationGeneration == ticket,
                      self.userWantsAgentOpen, !self.hostTerminationFence,
                      !self.closeRequested, !self.openOutcomeUnknown else { return }
                if application.isTerminated && !self.closing && !self.opening && !self.probing { break }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
            guard let self, !Task.isCancelled, self.restorationGeneration == ticket,
                  self.userWantsAgentOpen, !self.hostTerminationFence,
                  !self.closeRequested, !self.openOutcomeUnknown,
                  self.runningApplication == nil || self.runningApplication === application else { return }
            if self.runningApplication === application {
                self.runningApplication = nil
                self.removeObserver()
            }
            self.terminationRequestedFor = nil
            self.state = .idle
            self.restorationTask = nil
            self.restorationGeneration = UUID()
            await self.launch()
        }
    }

    func terminateOwnedNow() {
        invalidateRestoration()
        userWantsAgentOpen = false
        closeRequested = true
        guard let application = runningApplication else {
            // An in-flight launch has no process handle yet. This method is
            // not proof that the UI or its future work has stopped.
            if opening || probing { state = .failed("Catalyst UI launch has not settled.") }
            return
        }
        if !application.isTerminated { _ = application.terminate() }
        if application.isTerminated {
            runningApplication = nil
            state = .idle
            removeObserver()
        } else {
            // Retain the owned handle; never report a successful stop merely
            // because terminate() was requested.
            state = .failed("Catalyst UI termination is not confirmed.")
        }
    }

    private func stopOwnedApplication(_ application: NSRunningApplication) async {
        guard !closing else { return }
        closing = true
        defer { closing = false }
        if !application.isTerminated {
            terminationRequestedFor = application
            _ = application.terminate()
            let deadline = Date().addingTimeInterval(3)
            while !application.isTerminated && Date() < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { break }
            }
        }
        guard runningApplication === application else { return }
        guard application.isTerminated else {
            state = .failed("Catalyst UI termination is not confirmed.")
            return
        }
        if terminationRequestedFor === application { terminationRequestedFor = nil }
        runningApplication = nil
        state = .idle
        removeObserver()
    }

    /// Launch with a bounded smoke marker. Only the instance this probe
    /// launched is terminated; an unrelated user instance is never touched.
    func probe(
        markerURL: URL,
        environment: [String: String],
        timeout: TimeInterval = 30
    ) async -> CatalystProbeReport {
        guard !hostTerminationFence, !opening, !closing, !probing, !openOutcomeUnknown,
              runningApplication == nil || runningApplication?.isTerminated == true else {
            return CatalystProbeReport(
                appPath: "busy", markerPath: markerURL.path, launched: false,
                pid: nil, activationPolicy: -1, activationPolicyName: "busy",
                marker: nil, terminated: false, error: "Catalyst UI is already launching or running."
            )
        }
        guard let appURL = locateApp() else {
            return CatalystProbeReport(
                appPath: "missing", markerPath: markerURL.path, launched: false,
                pid: nil, activationPolicy: -1, activationPolicyName: "missing",
                marker: nil, terminated: false, error: "Nested Catalyst UI app is missing."
            )
        }
        probing = true
        closeRequested = false
        state = .launching
        defer { probing = false }
        try? FileManager.default.removeItem(at: markerURL)
        do {
            let application = try await open(
                appURL,
                arguments: [
                    "--smoke-marker", markerURL.path,
                    "--smoke-exit-after", "1.0"
                ],
                environment: environment,
                activates: false
            )
            runningApplication = application
            observeTermination(of: application)
            state = .running(pid: application.processIdentifier)
            let deadline = Date().addingTimeInterval(timeout)
            var markerData: Data?
            while !closeRequested && !hostTerminationFence && Date() < deadline {
                if let data = try? Data(contentsOf: markerURL), !data.isEmpty {
                    markerData = data
                    break
                }
                if application.isTerminated { break }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { break }
            }
            let policy = application.activationPolicy.rawValue
            let policyName = Self.policyName(application.activationPolicy)
            var markerObject: [String: Any]?
            if let markerData {
                markerObject = (try? JSONSerialization.jsonObject(with: markerData)) as? [String: Any]
            }
            // Wait for the Catalyst app's own smoke exit first.
            let exitDeadline = Date().addingTimeInterval(10)
            while !closeRequested && !hostTerminationFence && !application.isTerminated && Date() < exitDeadline {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { break }
            }
            var terminated = application.isTerminated
            if !terminated {
                application.terminate()
                let forcedDeadline = Date().addingTimeInterval(3)
                while !application.isTerminated && Date() < forcedDeadline {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { break }
                }
                terminated = application.isTerminated
            }
            if terminated {
                if runningApplication === application { runningApplication = nil }
                removeObserver()
                state = .idle
            } else {
                state = .failed("Catalyst UI termination is not confirmed.")
            }
            return CatalystProbeReport(
                appPath: appURL.path,
                markerPath: markerURL.path,
                launched: markerObject != nil,
                pid: application.processIdentifier,
                activationPolicy: policy,
                activationPolicyName: policyName,
                marker: markerObject,
                terminated: terminated,
                error: !terminated ? "Catalyst UI termination is not confirmed." : (markerObject == nil ? "Catalyst smoke marker was not written." : nil)
            )
        } catch {
            runningApplication = nil
            openOutcomeUnknown = true
            state = .failed("Could not confirm the Catalyst UI launch: \(error.localizedDescription)")
            return CatalystProbeReport(
                appPath: appURL.path,
                markerPath: markerURL.path,
                launched: false,
                pid: nil,
                activationPolicy: -1,
                activationPolicyName: "unknown",
                marker: nil,
                terminated: false,
                error: error.localizedDescription
            )
        }
    }

    private func open(
        _ appURL: URL,
        arguments: [String],
        environment: [String: String]?,
        activates: Bool
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        if let environment { configuration.environment = environment }
        configuration.activates = activates
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.executableLoad))
                }
            }
        }
    }

    private func observeTermination(of application: NSRunningApplication) {
        removeObserver()
        let generation = observerGeneration
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self, pid = application.processIdentifier] notification in
            guard let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  terminated.processIdentifier == pid else { return }
            Task { @MainActor [weak self] in
                guard let self, self.observerGeneration == generation,
                      self.runningApplication?.processIdentifier == pid else { return }
                self.runningApplication = nil
                self.state = .idle
                self.removeObserver()
            }
        }
    }

    private func removeObserver() {
        observerGeneration &+= 1
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    private static func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
    }
}
