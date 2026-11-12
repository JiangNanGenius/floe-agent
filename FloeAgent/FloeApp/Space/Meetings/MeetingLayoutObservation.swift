// SPDX-License-Identifier: MPL-2.0
#if DEBUG && canImport(UIKit)
import SwiftUI
import UIKit
import OSLog

/// Opt-in geometry evidence only. No AX element, text, identifiers, title or
/// polling; the bridge samples its own actual window and cannot pick a scene.
struct MeetingLayoutObservation: UIViewRepresentable {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--floe-meeting-layout-observation")
    var geometrySize: CGSize
    var geometryFrame: CGRect
    var geometryInsets: EdgeInsets
    var todoFocused: Bool
    var editingComposerCount: Int
    var compactInput: Bool
    var wideSplit: Bool
    var notesWidth: CGFloat
    var sideWidth: CGFloat?
    var showsPlayer: Bool
    var recording: Bool
    var savedRecordingCount: Int
    var transcriptBubbles: Int

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        var fields: [String: Any] = ["geometrySize": NSCoder.string(for: geometrySize),
            "geometryGlobalFrame": NSCoder.string(for: geometryFrame),
            "geometrySafeArea": "\(geometryInsets)", "todoFocused": todoFocused,
            "editingComposerCount": editingComposerCount, "compactInput": compactInput,
            "wideSplit": wideSplit, "notesWidth": "\(notesWidth)",
            "showsPlayer": showsPlayer, "recording": recording,
            "savedRecordingCount": savedRecordingCount, "transcriptBubbles": transcriptBubbles]
        if let sideWidth { fields["sideWidth"] = "\(sideWidth)" }
        view.fields = fields
        view.sample("update")
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    @MainActor final class Probe: UIView {
        private static let logger = Logger(subsystem: "org.floeagent.ios", category: "meeting.layout")
        var fields: [String: Any] = [:]
        private var lastSignature: Data?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            guard MeetingLayoutObservation.enabled else { return }
            for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                         UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                         UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { return nil }
        deinit { NotificationCenter.default.removeObserver(self) }
        func stop() { NotificationCenter.default.removeObserver(self) }
        override func didMoveToWindow() { super.didMoveToWindow(); sample("window") }
        override func layoutSubviews() { super.layoutSubviews(); sample("layout") }
        @objc private func keyboard(_ note: Notification) { sample(note.name.rawValue, note: note) }

        private func firstResponder(in root: UIView) -> UIView? {
            var pending = [root], remaining = 4096
            while let next = pending.popLast(), remaining > 0 {
                remaining -= 1
                if next.isFirstResponder { return next }
                pending.append(contentsOf: next.subviews)
            }
            return nil
        }
        func sample(_ event: String, note: Notification? = nil) {
            guard MeetingLayoutObservation.enabled else { return }
            var row = fields
            row["event"] = event
            if let window {
                row["windowBounds"] = NSCoder.string(for: window.bounds)
                row["windowSafeArea"] = NSCoder.string(for: window.safeAreaInsets)
                row["windowIsKey"] = window.isKeyWindow
                row["windowSceneActive"] = window.windowScene?.activationState == .foregroundActive
                // A zero guide is an observation, not proof of hidden keyboard.
                row["keyboardGuide"] = NSCoder.string(for: window.keyboardLayoutGuide.layoutFrame)
                row["firstResponderClass"] = firstResponder(in: window).map { NSStringFromClass(type(of: $0)) } ?? "noneObserved"
                var current: UIResponder? = self
                for _ in 0..<48 {
                    guard let item = current else { break }
                    if let host = item as? UIViewController {
                        row["probeHostClass"] = NSStringFromClass(type(of: host))
                        if let hostView = host.viewIfLoaded, hostView.window === window {
                            row["probeHostFrameInWindow"] = NSCoder.string(for: hostView.convert(hostView.bounds, to: window))
                            row["probeHostSafeArea"] = NSCoder.string(for: hostView.safeAreaInsets)
                        }
                        break
                    }
                    current = item.next
                }
            } else { row["windowAvailable"] = false }
            if let frame = (note?.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
                row["keyboardNotificationEndFrame"] = NSCoder.string(for: frame)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), data != lastSignature,
                  let text = String(data: data, encoding: .utf8) else { return }
            lastSignature = data
            Self.logger.info("C63Layout \(text, privacy: .public)")
        }
    }
}
#endif
