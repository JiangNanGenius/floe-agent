// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit

/// Readiness is based on the presenting window's ACTUAL input geometry. It
/// never supplies a destination height or changes keyboard safe-area rules.
nonisolated struct SpaceEditorInputReadiness {
    var activeWindow: Bool
    var searching: Bool
    var searchFirstResponder: Bool
    var keyboardTransition: Bool
    var windowBounds: CGRect
    var keyboardFrame: CGRect
    var bottomSafeArea: CGFloat
    var pixel: CGFloat
    var layoutCurrent: Bool
    var sourceFrame: CGRect
    var sourceSafeAreaBottom: CGFloat
    var nativeContentBottom: CGFloat
    var nativeHostBottom: CGFloat
    var nativeSafeAreaBottom: CGFloat
    var canPresent: Bool {
        guard activeWindow, !searching, !searchFirstResponder, !keyboardTransition,
              layoutCurrent, windowBounds.width > 0, windowBounds.height > 0,
              [windowBounds.minX, windowBounds.minY, windowBounds.maxX, windowBounds.maxY,
               sourceFrame.minX, sourceFrame.minY, sourceFrame.maxX, sourceFrame.maxY,
               sourceSafeAreaBottom, nativeContentBottom, nativeHostBottom, nativeSafeAreaBottom, pixel].allSatisfy(\.isFinite),
              pixel >= 0, nativeSafeAreaBottom >= 0,
              sourceFrame.width > 0, sourceFrame.height > 0,
              sourceFrame.minX >= windowBounds.minX - pixel, sourceFrame.maxX <= windowBounds.maxX + pixel,
              sourceFrame.minY >= windowBounds.minY - pixel,
              sourceFrame.maxY >= nativeContentBottom - pixel,
              sourceFrame.maxY <= nativeHostBottom + pixel,
              nativeHostBottom <= windowBounds.maxY + pixel,
              sourceSafeAreaBottom >= 0, sourceSafeAreaBottom <= nativeSafeAreaBottom + pixel else { return false }
        let overlap = keyboardFrame.intersection(windowBounds)
        return overlap.isNull || overlap.isEmpty || overlap.height <= max(0, bottomSafeArea) + max(0, pixel)
    }
}
nonisolated struct SpaceEditorInputClaim {
    private(set) var requestID: UUID?
    private var claimedID: UUID?
    mutating func setRequest(_ id: UUID?) {
        if requestID != id { requestID = id; claimedID = nil }
    }
    mutating func claim(_ input: SpaceEditorInputReadiness) -> UUID? {
        guard input.canPresent, let id = requestID, claimedID != id else { return nil }
        claimedID = id; return id
    }
    func owns(_ id: UUID) -> Bool { requestID == id && claimedID == id }
    mutating func retry(_ id: UUID) { if owns(id) { claimedID = nil } }
}

/// This view must be BELOW searchable: its environment ends the actual search
/// interaction, rather than only setting a FocusState in the parent. The
/// existing editor/print session is created only after the input handoff.
struct SpaceLibraryOpenBoundary<Content: View>: View {
    let requestID: UUID?
    let onReady: @MainActor (UUID) -> Void
    let content: Content
    @Environment(\.isSearching) private var searching
    @Environment(\.dismissSearch) private var dismissSearch
    init(requestID: UUID?, onReady: @escaping @MainActor (UUID) -> Void, @ViewBuilder content: () -> Content) {
        self.requestID = requestID; self.onReady = onReady; self.content = content()
    }
    var body: some View {
        GeometryReader { geometry in
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    SpaceLibraryInputProbe(requestID: requestID, searching: searching,
                        geometrySize: geometry.size, safeAreaBottom: geometry.safeAreaInsets.bottom, onReady: onReady)
                        .allowsHitTesting(false)
#if DEBUG
                        .accessibilityHidden(!SpaceNativeInputObservation.enabled)
#else
                        .accessibilityHidden(true)
#endif
                }
            }
            .onChange(of: requestID, initial: true) { _, id in
                if id != nil { dismissSearch() }
            }
    }
}

struct SpaceLibraryInputProbe: UIViewRepresentable {
    let requestID: UUID?
    let searching: Bool
    let geometrySize: CGSize
    let safeAreaBottom: CGFloat
    let onReady: @MainActor (UUID) -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.update(requestID, searching: searching, geometrySize: geometrySize, safeAreaBottom: safeAreaBottom, onReady: onReady) }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    @MainActor final class Probe: UIView {
        private var claim = SpaceEditorInputClaim()
        private var searching = false
        private var transition = false
        private var transitionEndFrame: CGRect?
        private var ownedInput = false
        private var scheduled = false
        private var ready: (@MainActor (UUID) -> Void)?
        private var geometrySize = CGSize.zero
        private var geometryBottom = CGFloat.nan
        private weak var measuredWindow: UIWindow?
        private weak var measuredHost: UIViewController?
        private var measuredWindowBounds = CGRect.null
        private var measuredFrame = CGRect.null
        private var measuredHostFrame = CGRect.null
        private var measuredHostInsets = UIEdgeInsets.zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
#if DEBUG
            isAccessibilityElement = SpaceNativeInputObservation.enabled
            accessibilityIdentifier = "debug.space.nativeInputObservation"
            accessibilityLabel = "Native input handoff observation"
#endif
            let center = NotificationCenter.default
            for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
                center.addObserver(self, selector: #selector(willChange(_:)), name: name, object: nil)
            }
            for name in [UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidHideNotification] {
                center.addObserver(self, selector: #selector(didChange(_:)), name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { return nil }
        deinit { NotificationCenter.default.removeObserver(self) }
        func stop() { claim.setRequest(nil); ready = nil; NotificationCenter.default.removeObserver(self) }
        func update(_ id: UUID?, searching: Bool, geometrySize: CGSize, safeAreaBottom: CGFloat, onReady: @escaping @MainActor (UUID) -> Void) {
            claim.setRequest(id); self.searching = searching; ready = onReady
            self.geometrySize = geometrySize; geometryBottom = safeAreaBottom
            measuredWindow = nil; setNeedsLayout()
            if searching { ownedInput = true }
            observeInput("space.update")
            schedule()
        }
        override func didMoveToWindow() { super.didMoveToWindow(); measuredWindow = nil; setNeedsLayout(); observeInput("space.window"); schedule() }
        override func layoutSubviews() { super.layoutSubviews(); captureLayout(); observeInput("space.layout"); schedule() }
        private func sourceHost() -> UIViewController? {
            var responder: UIResponder? = next
            for _ in 0..<48 {
                guard let current = responder else { return nil }
                if let host = current as? UIViewController { return host }
                responder = current.next
            }
            return nil
        }
        private func captureLayout() {
            guard let window, let host = sourceHost(), let hostView = host.viewIfLoaded, hostView.window === window,
                  geometrySize.width.isFinite, geometrySize.height.isFinite,
                  geometrySize.width > 0, geometrySize.height > 0,
                  abs(bounds.width - geometrySize.width) <= 1 / max(1, traitCollection.displayScale),
                  abs(bounds.height - geometrySize.height) <= 1 / max(1, traitCollection.displayScale) else { measuredWindow = nil; return }
            measuredWindow = window; measuredHost = host
            measuredWindowBounds = window.bounds; measuredFrame = convert(bounds, to: window)
            measuredHostFrame = hostView.convert(hostView.bounds, to: window); measuredHostInsets = hostView.safeAreaInsets
        }
        private func observeInput(_ event: String, note: Notification? = nil) {
#if DEBUG
            SpaceNativeInputObservation.rememberLibrary(self, searching: searching)
            var fields: [String: Any] = ["isSearching": searching, "probeTransition": transition, "probeOwnedInput": ownedInput, "probePending": claim.requestID != nil, "geometrySize": NSCoder.string(for: geometrySize), "geometryBottom": geometryBottom.isFinite ? String(describing: geometryBottom) : "unknown"]
            if let state = input() { fields["layoutCurrent"] = state.layoutCurrent; fields["sourceFrame"] = NSCoder.string(for: state.sourceFrame); fields["nativeContentBottom"] = state.nativeContentBottom; fields["nativeHostBottom"] = state.nativeHostBottom; fields["nativeSafeAreaBottom"] = state.nativeSafeAreaBottom; fields["canPresent"] = state.canPresent }
            SpaceNativeInputObservation.record(event, from: self, fields: fields, note: note)
#endif
        }
        private func hasSearchResponder(_ view: UIView) -> Bool {
            if view.isFirstResponder, view is UISearchTextField || view is UISearchBar { return true }
            return view.subviews.contains { self.hasSearchResponder($0) }
        }
        func input() -> SpaceEditorInputReadiness? {
            guard let window, let host = sourceHost(), let hostView = host.viewIfLoaded, hostView.window === window else { return nil }
            let frame = convert(bounds, to: window)
            let hostFrame = hostView.convert(hostView.bounds, to: window)
            return .init(activeWindow: window.windowScene?.activationState == .foregroundActive,
                searching: searching, searchFirstResponder: hasSearchResponder(window), keyboardTransition: transition,
                windowBounds: window.bounds, keyboardFrame: window.keyboardLayoutGuide.layoutFrame,
                bottomSafeArea: window.safeAreaInsets.bottom, pixel: 1 / max(1, window.traitCollection.displayScale),
                layoutCurrent: measuredWindow === window && measuredHost === host && measuredWindowBounds == window.bounds && measuredFrame == frame && measuredHostFrame == hostFrame && measuredHostInsets == hostView.safeAreaInsets,
                sourceFrame: frame, sourceSafeAreaBottom: geometryBottom,
                nativeContentBottom: hostFrame.maxY - hostView.safeAreaInsets.bottom, nativeHostBottom: hostFrame.maxY,
                nativeSafeAreaBottom: hostView.safeAreaInsets.bottom)
        }
        @objc private func willChange(_ note: Notification) {
            observeInput("space." + note.name.rawValue, note: note)
            guard let input = input() else { return }
            let overlap = input.keyboardFrame.intersection(input.windowBounds)
            let occupied = !overlap.isNull && overlap.height > input.bottomSafeArea + input.pixel
            // An unrelated window's keyboard must not stall this window's
            // request. Do not resign arbitrary inputs or enumerate app scenes.
            guard ownedInput || searching || input.searchFirstResponder || (claim.requestID != nil && occupied) else { return }
            transition = true
            transitionEndFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        }
        @objc private func didChange(_ note: Notification) {
            observeInput("space." + note.name.rawValue, note: note)
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            if transition, let expected = transitionEndFrame, let end, end != expected { return }
            transition = false; transitionEndFrame = nil
            if note.name == UIResponder.keyboardDidHideNotification { ownedInput = false }
            guard claim.requestID != nil else { return }
            // A keyboard notification does not commit SwiftUI's proposal.
            // Wait for the source's next actual layout instead of forcing the
            // owning window to lay out reentrantly from this callback.
            measuredWindow = nil; setNeedsLayout(); schedule()
        }
        private func schedule() {
            guard claim.requestID != nil, !scheduled else { return }
            scheduled = true
            Task { @MainActor [weak self] in
                // Separate presentation from the focus/search update and the
                // native keyboard/layout callback; no fixed animation delay.
                await Task.yield()
                guard let self else { return }
                self.scheduled = false
                guard let input = self.input(), let id = self.claim.claim(input) else { return }
                // Claim immediately before delivery; an old request never
                // opens a different record or survives source navigation.
                guard self.claim.owns(id) else { return }
                self.ready?(id)
            }
        }
#if DEBUG
        override var accessibilityValue: String? {
            get { observeInput("space.axRead"); return SpaceNativeInputObservation.json }
            set { }
        }
#endif
    }
}

#if DEBUG
/// Temporary read-only diagnostics, enabled only by the Print UI test flag.
/// No text, identifiers, selection ranges, input modes, or view descriptions.
@MainActor enum SpaceNativeInputObservation {
    static let launchFlag = "--floe-native-input-observation"
    static let enabled = ProcessInfo.processInfo.arguments.contains(launchFlag)
    private static weak var libraryWindow: UIWindow?
    private static weak var originalSearchField: UISearchTextField?
    private static weak var originalSearchController: UISearchController?
    private static var libraryWindowWasObserved = false
    private static var originalSearchWasObserved = false
    private static var flags: [String: Bool] = [:]
    private static var lines: [String] = []
    private static var byteCount = 0
    private static var sequence = 0
    private static var lastSignature: Data?
    private static func nullable<T>(_ value: T?) -> Any { if let value { return value }; return NSNull() }

    static func setLibraryFlags(_ value: [String: Bool]) {
        guard enabled else { return }; flags = value
        record("space.flags", from: libraryWindow)
    }
    private static func firstResponder(_ view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let found = firstResponder(child) { return found } }
        return nil
    }
    private static func ownerController(_ responder: UIResponder?) -> UIViewController? {
        var current = responder
        for _ in 0..<48 {
            guard let item = current else { return nil }
            if let controller = item as? UIViewController { return controller }
            current = item.next
        }
        return nil
    }
    private static func isWithin(_ controller: UIViewController, host: UIViewController) -> Bool {
        var current: UIViewController? = controller
        for _ in 0..<48 {
            guard let item = current else { return false }
            if item === host { return true }; current = item.parent
        }
        return false
    }
    private static func controllers(_ root: UIViewController?) -> [UIViewController] {
        var pending = root.map { [$0] } ?? [], result: [UIViewController] = []
        var seen = Set<ObjectIdentifier>()
        while let next = pending.popLast(), result.count < 48 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next); pending.append(contentsOf: next.children)
            if let presented = next.presentedViewController { pending.append(presented) }
        }
        return result
    }
    static func rememberLibrary(_ view: UIView, searching: Bool) {
        guard enabled, let window = view.window else { return }
        if !libraryWindowWasObserved { libraryWindow = window; libraryWindowWasObserved = true }
        // Source isSearching plus the actual first responder identifies the
        // source field. Failure to observe it remains unknown, never false-safe.
        if searching, !originalSearchWasObserved, let field = firstResponder(window) as? UISearchTextField {
            originalSearchField = field; originalSearchWasObserved = true
            let active = controllers(window.rootViewController).compactMap { $0.navigationItem.searchController }.filter(\.isActive)
            if active.count == 1 { originalSearchController = active[0] }
        }
    }
    static func record(_ event: String, from view: UIView?, fields: [String: Any] = [:], note: Notification? = nil) {
        guard enabled else { return }
        var row: [String: Any] = ["event": event, "space": flags, "state": fields]
        if let window = view?.window ?? (view as? UIWindow) {
            let owners = controllers(window.rootViewController)
            let responder: UIResponder?
            if let input = firstResponder(window) { responder = input }
            else { responder = owners.first(where: \.isFirstResponder) }
            row["windowBounds"] = NSCoder.string(for: window.bounds)
            row["windowFrame"] = NSCoder.string(for: window.frame)
            row["windowSafeArea"] = NSCoder.string(for: window.safeAreaInsets)
            row["windowIsKey"] = window.isKeyWindow
            row["windowSceneActive"] = window.windowScene?.activationState == .foregroundActive
            row["windowMatchesLibrary"] = nullable(libraryWindow.map { $0 === window })
            row["originalLibraryWindowAlive"] = libraryWindow != nil
            row["keyboardGuide"] = NSCoder.string(for: window.keyboardLayoutGuide.layoutFrame)
            row["guideFollowsUndocked"] = window.keyboardLayoutGuide.followsUndockedKeyboard
            row["firstResponderClassInOwnViewOrControllerTree"] = responder.map { NSStringFromClass(type(of: $0)) } ?? "noneObserved"
            let inputOwner = ownerController(responder), probeHost = ownerController(view)
            row["firstResponderOwnerControllerClass"] = nullable(inputOwner.map { NSStringFromClass(type(of: $0)) })
            row["probeHostControllerClass"] = nullable(probeHost.map { NSStringFromClass(type(of: $0)) })
            row["firstResponderWithinProbeHost"] = nullable(inputOwner.flatMap { input in probeHost.map { isWithin(input, host: $0) } })
            if let host = probeHost, let hostView = host.viewIfLoaded, hostView.window === window {
                row["probeHostFrameInWindow"] = NSCoder.string(for: hostView.convert(hostView.bounds, to: window))
                row["probeHostSafeArea"] = NSCoder.string(for: hostView.safeAreaInsets)
                row["probeHostAdditionalSafeArea"] = NSCoder.string(for: host.additionalSafeAreaInsets)
            }
            if let input = responder as? UIView, input.window === window {
                row["firstResponderFrameInWindow"] = NSCoder.string(for: input.convert(input.bounds, to: window))
            }
            row["firstResponderIsOriginalSpaceSearch"] = nullable(originalSearchField.map { field in responder.map { $0 === field } ?? false })
            row["originalSpaceSearchAlive"] = originalSearchField != nil
            row["originalSpaceSearchWasObserved"] = originalSearchWasObserved
            row["originalSpaceSearchFirstResponder"] = nullable(originalSearchField.map(\.isFirstResponder))
            row["originalSpaceSearchSameWindow"] = nullable(originalSearchField.map { $0.window === window })
            row["originalSearchControllerActive"] = nullable(originalSearchController.map(\.isActive))
            row["nativeSearchControllers"] = owners.compactMap { owner -> [String: Any]? in
                guard let search = owner.navigationItem.searchController else { return nil }
                return ["ownerClass": NSStringFromClass(type(of: owner)), "active": search.isActive, "viewLoaded": search.isViewLoaded, "isOriginal": nullable(originalSearchController.map { $0 === search })]
            }
            if let view {
                row["probeBounds"] = NSCoder.string(for: view.bounds)
                row["probeFrameInWindow"] = NSCoder.string(for: view.convert(view.bounds, to: window))
                row["probeSafeArea"] = NSCoder.string(for: view.safeAreaInsets)
            }
        } else { row["windowAvailable"] = false }
        if let note {
            row["notificationEndFrameInScreenCoordinates"] = nullable((note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue).map { NSCoder.string(for: $0.cgRectValue) })
            row["notificationIsLocal"] = nullable((note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? NSNumber)?.boolValue)
        }
        guard let signature = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), signature != lastSignature else { return }
        lastSignature = signature; sequence += 1
        row["sequence"] = sequence; row["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line); byteCount += data.count
        while lines.count > 96 || byteCount > 60 * 1024 { byteCount -= lines.removeFirst().utf8.count }
    }
    static var json: String { "[" + lines.joined(separator: ",") + "]" }
}

struct PrintNativeInputObservation: UIViewRepresentable {
    var geometrySize: CGSize
    var geometryFrame: CGRect
    var geometryInsets: EdgeInsets
    var stage: String
    var busy: Bool
    var editing: Bool
    var completed: Bool
    var revision: UInt64
    var rootInputFocused: Bool
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.fields = ["geometrySize": NSCoder.string(for: geometrySize), "geometryGlobalFrame": NSCoder.string(for: geometryFrame), "geometrySafeArea": "\(geometryInsets)", "stage": stage, "busy": busy, "editing": editing, "completed": completed, "revision": String(revision), "rootInputFocused": rootInputFocused]
        view.sample("print.update")
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }
    @MainActor final class Probe: UIView {
        var fields: [String: Any] = [:]
        override init(frame: CGRect) {
            super.init(frame: frame); isUserInteractionEnabled = false
            guard SpaceNativeInputObservation.enabled else { return }
            isAccessibilityElement = true
            accessibilityIdentifier = "debug.print.nativeInputObservation"
            accessibilityLabel = "Native input observation"
            for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification, UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { return nil }
        deinit { NotificationCenter.default.removeObserver(self) }
        func stop() { NotificationCenter.default.removeObserver(self) }
        override func didMoveToWindow() { super.didMoveToWindow(); sample("print.window") }
        override func layoutSubviews() { super.layoutSubviews(); sample("print.layout") }
        @objc private func keyboard(_ note: Notification) { SpaceNativeInputObservation.record("print." + note.name.rawValue, from: self, fields: fields, note: note) }
        func sample(_ event: String) { SpaceNativeInputObservation.record(event, from: self, fields: fields) }
        override var accessibilityValue: String? {
            get { sample("print.axRead"); return SpaceNativeInputObservation.json }
            set { }
        }
    }
}
#endif
#endif
