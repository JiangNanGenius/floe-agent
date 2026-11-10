// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

/// The active personal editor passes only its own input-ownership bit to
/// nested native canvas layouts. No shared responder or editor state is used.
private struct EditorCanvasOwnsTextInputKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var editorCanvasOwnsTextInput: Bool {
        get { self[EditorCanvasOwnsTextInputKey.self] }
        set { self[EditorCanvasOwnsTextInputKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func editorLayoutObservation(_ stage: String) -> some View {
        #if DEBUG
        modifier(EditorLayoutObservation(stage: stage))
        #else
        self
        #endif
    }
}

#if DEBUG
/// Opt-in geometry of the actual SwiftUI proposal, separate from UIKit's
/// window/host bounds. Records no document content or user identifiers.
private struct EditorLayoutObservation: ViewModifier {
    let stage: String
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--floe-editor-input-ownership-observation")
    private static let logger = Logger(subsystem: "org.floeagent.ios", category: "editor.layout.geometry")
    private struct Snapshot: Equatable {
        let size: String
        let globalFrame: String
        let safeArea: String
    }
    @ViewBuilder func body(content: Content) -> some View {
        if Self.enabled {
            content.onGeometryChange(for: Snapshot.self) { geometry in
                Snapshot(size: NSCoder.string(for: geometry.size),
                    globalFrame: NSCoder.string(for: geometry.frame(in: .global)),
                    safeArea: NSCoder.string(for: UIEdgeInsets(top: geometry.safeAreaInsets.top,
                        left: geometry.safeAreaInsets.leading, bottom: geometry.safeAreaInsets.bottom,
                        right: geometry.safeAreaInsets.trailing)))
            } action: { snapshot in
                Self.logger.info("EditorLayoutGeometry \(stage, privacy: .public) size=\(snapshot.size, privacy: .public) frame=\(snapshot.globalFrame, privacy: .public) insets=\(snapshot.safeArea, privacy: .public)")
            }
        } else { content }
    }
}
#endif

/// Observes the exact native host containing this background probe. It never
/// resigns input, changes layout, chooses an application window, or borrows a
/// source page's search/focus state. Mount inside the actual editor branch.
struct EditorInputOwnership:UIViewRepresentable {
    let ownerID:UUID
    let onChange:@MainActor (Bool)->Void
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeUIView(context:Context)->Probe {
        let view=Probe()
        context.coordinator.mount(view,ownerID:ownerID,onChange:onChange)
        return view
    }
    func updateUIView(_ view:Probe,context:Context) {context.coordinator.update(ownerID:ownerID,onChange:onChange)}
    static func dismantleUIView(_ view:Probe,coordinator:Coordinator) {coordinator.stop()}

    @MainActor final class Probe:UIView {
        weak var observer:Coordinator?
        override init(frame:CGRect) {
            super.init(frame:frame)
            isUserInteractionEnabled=false;isAccessibilityElement=false;accessibilityElementsHidden=true
            backgroundColor = .clear
        }
        required init?(coder:NSCoder) {nil}
        override func didMoveToWindow() {super.didMoveToWindow();observer?.schedule(.window)}
        override func didMoveToSuperview() {super.didMoveToSuperview();observer?.schedule(.hierarchy)}
        override func layoutSubviews() {super.layoutSubviews();observer?.schedule(.layout)}
        override func safeAreaInsetsDidChange() {super.safeAreaInsetsDidChange();observer?.schedule(.layout)}
    }

    enum Event:String {case initial,update,window,hierarchy,layout,input,keyboard}
    @MainActor final class Coordinator:NSObject {
        private weak var probe:Probe?
        private var ownerID:UUID?
        private var callback:(@MainActor (Bool)->Void)?
        private var active=false
        private var generation=UUID()
        private var pending:UUID?
        private var lastValue:Bool?
        #if DEBUG
        private var lastGeometry:Data?
        private var geometryReports=0
        #endif
        deinit {NotificationCenter.default.removeObserver(self)}

        func mount(_ view:Probe,ownerID:UUID,onChange:@escaping @MainActor (Bool)->Void) {
            guard !active else {return}
            active=true;probe=view;view.observer=self;self.ownerID=ownerID;callback=onChange
            let center=NotificationCenter.default
            for name in [UITextField.textDidBeginEditingNotification,UITextField.textDidEndEditingNotification,
                         UITextView.textDidBeginEditingNotification,UITextView.textDidEndEditingNotification] {
                center.addObserver(self,selector:#selector(inputChanged(_:)),name:name,object:nil)
            }
            // Recheck the real controls on keyboard transitions too. A
            // canvas/shortcut or read-only text responder is not text editing.
            for name in [UIResponder.keyboardWillChangeFrameNotification,UIResponder.keyboardDidChangeFrameNotification,
                         UIResponder.keyboardDidHideNotification] {
                center.addObserver(self,selector:#selector(keyboardChanged(_:)),name:name,object:nil)
            }
            schedule(.initial)
        }
        func update(ownerID:UUID,onChange:@escaping @MainActor (Bool)->Void) {
            guard active else {return}
            callback=onChange
            if self.ownerID != ownerID {
                self.ownerID=ownerID;generation=UUID();pending=nil;lastValue=nil
                #if DEBUG
                lastGeometry=nil;geometryReports=0
                #endif
            }
            schedule(.update)
        }
        func stop() {
            guard active else {return}
            active=false;generation=UUID();pending=nil;callback=nil;lastValue=nil
            NotificationCenter.default.removeObserver(self)
            if probe?.observer===self {probe?.observer=nil};probe=nil
        }
        // Notifications carry no value into a later callback: always read
        // the current root. A queued event from another window cannot supply
        // a first-responder flag or revive an unmounted observer.
        @objc nonisolated private func inputChanged(_ note:Notification) {Task { @MainActor [weak self] in self?.schedule(.input)}}
        @objc nonisolated private func keyboardChanged(_ note:Notification) {Task { @MainActor [weak self] in self?.schedule(.keyboard)}}
        func schedule(_ event:Event) {
            guard active,pending==nil else {return}
            let ticket=UUID(),epoch=generation;pending=ticket
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,self.active,self.generation==epoch,self.pending==ticket else {return}
                self.pending=nil;self.reconcile(event)
            }
        }
        private func reconcile(_ event:Event) {
            guard active,let probe else {return}
            let root=Self.hostRoot(containing:probe)
            let scan=root.map(Self.firstTextInput)
            #if DEBUG
            observeGeometry(event,probe:probe,root:root)
            #endif
            // Exhausting a bounded scan is unknown, not evidence that an
            // active field disappeared. Keep the last proven value.
            guard scan?.limited != true else {return}
            let value=scan?.view != nil
            guard lastValue != value else {return};lastValue=value
            callback?(value)
        }
        static func hostRoot(containing probe:UIView)->UIView? {
            guard let window=probe.window else {return nil}
            var next:UIResponder?=probe.next
            for _ in 0..<48 {
                guard let current=next else {return nil}
                if let controller=current as? UIViewController {
                    // Never broaden a failed nearest-host match to a parent
                    // navigation controller or the entire application window.
                    guard let root=controller.viewIfLoaded,root !== window,root.window===window,
                          probe===root || probe.isDescendant(of:root) else {return nil}
                    return root
                }
                next=current.next
            }
            return nil
        }
        struct InputScan {var view:UIView?;var limited:Bool}
        static func firstTextInput(in root:UIView)->InputScan {
            var remaining=4096,pending=[root]
            while let view=pending.popLast() {
                guard remaining>0 else {return .init(view:nil,limited:true)};remaining-=1
                guard !view.isHidden,view.alpha>0.01 else {continue}
                if view.isFirstResponder {
                    if let field=view as? UITextField,field.isEnabled {return .init(view:field,limited:false)}
                    if let text=view as? UITextView,text.isEditable {return .init(view:text,limited:false)}
                }
                pending.append(contentsOf:view.subviews)
            }
            return .init(view:nil,limited:false)
        }
        #if DEBUG
        private static let logger=Logger(subsystem:"org.floeagent.ios",category:"editor.input.geometry")
        private static let geometryEnabled=ProcessInfo.processInfo.arguments.contains("--floe-editor-input-ownership-observation")
        private func observeGeometry(_ event:Event,probe:Probe,root:UIView?) {
            guard Self.geometryEnabled,geometryReports<64 else {return}
            let row=Self.geometrySnapshot(probe:probe,root:root)
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            guard let data=try? encoder.encode(row),data != lastGeometry,
                  let text=String(data:data,encoding:.utf8) else {return}
            lastGeometry=data;geometryReports+=1
            Self.logger.info("EditorInputGeometry \(event.rawValue,privacy:.public) \(text,privacy:.public)")
        }
        /// Explicit read-only geometry: no text, paths, identifiers, selection
        /// ranges, view descriptions, source record IDs or scene enumeration.
        struct GeometrySnapshot:Encodable {
            var probeClass:String
            var probeFrame:String
            var hostClass:String?
            var hostFrame:String?
            var hostInsets:String?
            var windowClass:String?
            var windowBounds:String?
            var windowInsets:String?
            var keyboardGuide:String?
            var firstTextInputClass:String?
            var firstTextInputFrame:String?
            var firstTextInputInsideHost:Bool?
        }
        static func geometrySnapshot(probe:Probe,root:UIView?)->GeometrySnapshot {
            func name(_ view:UIView)->String {String(NSStringFromClass(type(of:view)).prefix(256))}
            var row=GeometrySnapshot(probeClass:name(probe),probeFrame:NSCoder.string(for:probe.frame))
            guard let window=probe.window else {return row}
            row.windowClass=name(window);row.windowBounds=NSCoder.string(for:window.bounds);row.windowInsets=NSCoder.string(for:window.safeAreaInsets)
            row.keyboardGuide=NSCoder.string(for:window.keyboardLayoutGuide.layoutFrame)
            row.probeFrame=NSCoder.string(for:probe.convert(probe.bounds,to:window))
            if let root {
                row.hostClass=name(root);row.hostFrame=NSCoder.string(for:root.convert(root.bounds,to:window));row.hostInsets=NSCoder.string(for:root.safeAreaInsets)
            }
            // Diagnostics inspect only the probe's already-attached window.
            // Production ownership above inspects only the actual host root.
            if let input=firstTextInput(in:window).view {
                row.firstTextInputClass=name(input);row.firstTextInputFrame=NSCoder.string(for:input.convert(input.bounds,to:window))
                row.firstTextInputInsideHost=root.map {input===$0 || input.isDescendant(of:$0)}
            }
            return row
        }
        #endif
    }
}
#endif
