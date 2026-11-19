// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameTouch
#if os(iOS)
import UIKit
import FloeJoystickVendor
#endif

/// Overlay scoped to the game viewport. App/IDE navigation is outside its hit
/// area. iOS joystick touch tracking reuses the reviewed MIT JoyStickView.
public struct GameTouchControlsView: View {
    @ObservedObject public var service: GameTouchInputService
    public let editingLayout: Bool
    private let layoutProfile: GameTouchProfile?
    private var profile: GameTouchProfile { editingLayout ? layoutProfile ?? service.profile : service.profile }
    public let onMove: @MainActor (GameTouchButton.ID?, GameTouchAnchor) -> Void
    public let onFinishLayout: @MainActor () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    public init(service: GameTouchInputService, editingLayout: Bool = false, layoutProfile: GameTouchProfile? = nil,
                onMove: @escaping @MainActor (GameTouchButton.ID?, GameTouchAnchor) -> Void = { _, _ in },
                onFinishLayout: @escaping @MainActor () -> Void = {}) {
        self.layoutProfile = layoutProfile
        self.service = service; self.editingLayout = editingLayout; self.onMove = onMove; self.onFinishLayout = onFinishLayout
    }
    public var body: some View {
        let attachment = service.attachmentID
        GeometryReader { geometry in
            if service.profile.enabled || editingLayout {
                let size = geometry.size
                if editingLayout {
                    // The layout canvas owns blank space as well as controls.
                    Color.clear.contentShape(Rectangle()).accessibilityHidden(true)
                }
                let stickSize = CGFloat(profile.stick == .directionPad ? max(132, 132 * profile.scale) : 126 * profile.scale)
                if profile.stick != .none {
                    Group {
                        if profile.stick == .joystick { joystick }
                        else { directionPad }
                    }.frame(width: stickSize, height: stickSize)
                        .modifier(placement(nil, anchor: profile.stickAnchor, fallback: .init(x: 0.16, y: 0.76),
                                            size: size, extent: .init(width: stickSize, height: stickSize),
                                            label: locale.language.languageCode?.identifier == "zh" ? "方向控制" : "Movement"))
                }
                let visible = profile.buttons.filter { $0.visible || editingLayout }
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, button in
                    let extent = buttonExtent(button)
                    PressControl(label: button.label?.isEmpty == false ? button.label! : button.binding.keyCap,
                                 keyHint: button.label?.isEmpty == false ? button.binding.keyCap : nil,
                                 editing: editingLayout, selected: service.activeButtonIDs.contains(button.id)) {
                        service.button(button.id, pressed: $0, forAttachment: attachment)
                    }
                        .frame(width: extent.width, height: extent.height)
                        .modifier(placement(button.id, anchor: button.anchor, fallback: defaultPosition(index: index, count: visible.count, size: size),
                                            size: size, extent: extent, label: button.label ?? button.binding.keyCap))
                        .opacity(button.visible ? 1 : 0.4)
                        .accessibilityIdentifier("game.touch." + button.id.rawValue)
                }
                if editingLayout {
                    HStack {
                        Text(locale.language.languageCode?.identifier == "zh" ? "拖动键位调整位置" : "Drag keys to arrange")
                        Spacer()
                        Button(locale.language.languageCode?.identifier == "zh" ? "完成布局" : "Done") { onFinishLayout() }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("game.touch.layout.done")
                    }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(12).frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }.id(editingLayout ? nil : attachment)
            .coordinateSpace(name: "gameTouchLayout").opacity(editingLayout ? 1 : service.profile.opacity).allowsHitTesting(service.isAttached || editingLayout)
            .onDisappear { if let attachment { Task { await service.releaseAll(forAttachment: attachment) } } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active, let attachment { Task { await service.releaseAll(forAttachment: attachment) } }
            }
    }
    @ViewBuilder private var joystick: some View {
        let attachment = service.attachmentID
#if os(iOS)
        NativeJoystick { service.stick(x: $0, y: $1, forAttachment: attachment) }.allowsHitTesting(!editingLayout)
#else
        Circle().fill(.black.opacity(0.45)).overlay { Circle().stroke(.white.opacity(0.7), lineWidth: 2).padding(4) }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if !editingLayout { service.stick(x: Double(value.translation.width / 60), y: -Double(value.translation.height / 60), forAttachment: attachment) }
            }.onEnded { _ in service.stick(x: 0, y: 0, forAttachment: attachment) })
#endif
    }
    private var directionPad: some View {
        VStack(spacing: 0) {
            arrow(.up, symbol: "arrowtriangle.up.fill")
            HStack(spacing: 0) {
                arrow(.left, symbol: "arrowtriangle.left.fill")
                Color.clear.frame(width: 44, height: 44)
                arrow(.right, symbol: "arrowtriangle.right.fill")
            }
            arrow(.down, symbol: "arrowtriangle.down.fill")
        }.scaleEffect(max(1, profile.scale))
    }
    @ViewBuilder private func arrow(_ direction: GameTouchAction, symbol: String) -> some View {
        let attachment = service.attachmentID
        if profile.directionBinding(for: direction) != nil {
            PressControl(label: "", symbol: symbol, editing: editingLayout) { service.direction(direction, pressed: $0, forAttachment: attachment) }
                .frame(width: 44, height: 44).accessibilityLabel(direction.rawValue)
        } else { Color.clear.frame(width: 44, height: 44).allowsHitTesting(false) }
    }
    private func placement(_ id: GameTouchButton.ID?, anchor: GameTouchAnchor?, fallback: CGPoint,
                           size: CGSize, extent: CGSize, label: String) -> LayoutPlacement {
        let x = anchor?.x ?? fallback.x
        let center = CGPoint(x: (profile.leftHanded ? 1 - x : x) * size.width,
                             y: (anchor?.y ?? fallback.y) * size.height)
        return LayoutPlacement(editing: editingLayout, center: center, size: size, extent: extent, label: label,
                               identifier: "game.touch." + (id?.rawValue ?? "stick")) { point in
            guard size.width > 0, size.height > 0,
                  let anchor = try? GameTouchAnchor(x: profile.leftHanded ? 1 - point.x / size.width : point.x / size.width,
                                                   y: point.y / size.height) else { return }
            onMove(id, anchor)
        }
    }
    private func buttonExtent(_ button: GameTouchButton) -> CGSize {
        let title = button.label?.isEmpty == false ? button.label! : button.binding.keyCap
        let width = button.width ?? min(180, max(52, Double(title.count) * 9 + 24))
        return .init(width: max(44, width * profile.scale), height: max(44, (button.height ?? 52) * profile.scale))
    }
    private func defaultPosition(index: Int, count: Int, size: CGSize) -> CGPoint {
        let crowded = count > 8
        let width = Double(size.width) * (crowded ? 0.9 : 0.38)
        let height = Double(size.height) * (crowded ? 0.64 : 0.34)
        let estimatedColumns = Int(ceil(sqrt(Double(max(1, count)) * width / max(1, height))))
        let columns = max(1, min(max(1, count), estimatedColumns))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let left = crowded ? 0.05 : 0.59, top = crowded ? 0.12 : 0.58
        return .init(x: left + (Double(index % columns) + 0.5) / Double(columns) * (crowded ? 0.9 : 0.38),
                     y: top + (Double(index / columns) + 0.5) / Double(rows) * (crowded ? 0.64 : 0.34))
    }
}

/// Track the finger locally; commit one normalized position when it lifts.
private struct LayoutPlacement: ViewModifier {
    let editing: Bool
    let center: CGPoint
    let size: CGSize
    let extent: CGSize
    let label: String
    let identifier: String
    let commit: (CGPoint) -> Void
    @GestureState private var translation: CGSize = .zero

    private func clamp(_ value: CGFloat, in length: CGFloat, extent: CGFloat) -> CGFloat {
        let inset = min(length / 2, extent / 2 + 8)
        return min(max(inset, value), length - inset)
    }
    private func position(_ delta: CGSize) -> CGPoint {
        let x = clamp(center.x, in: size.width, extent: extent.width)
        let y = clamp(center.y, in: size.height, extent: extent.height)
        return CGPoint(x: clamp(x + delta.width, in: size.width, extent: extent.width),
                       y: clamp(y + delta.height, in: size.height, extent: extent.height))
    }
    @ViewBuilder func body(content: Content) -> some View {
        if editing {
            content.allowsHitTesting(false).accessibilityHidden(true)
                .overlay {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("gameTouchLayout"))
                            .updating($translation) { value, state, _ in state = value.translation }
                            .onEnded { value in commit(position(value.translation)) })
                        .accessibilityElement(children: .ignore).accessibilityLabel(label)
                        .accessibilityIdentifier(identifier)
                }
                .position(position(translation))
        } else {
            content.position(position(.zero))
        }
    }
}

private struct PressControl: View {
    let label: String
    var keyHint: String? = nil
    var symbol: String? = nil
    let editing: Bool
    var selected = false
    let onPress: @MainActor (Bool) -> Void
    @State private var pressed = false
    var body: some View {
#if os(iOS)
        NativePressControl(label: label, keyHint: keyHint, symbol: symbol, editing: editing, selected: selected, onPress: onPress)
#else
        Group { if let symbol { Image(systemName: symbol) } else { Text(label).font(.headline) } }
            .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed || selected ? .white.opacity(0.4) : .black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.8), lineWidth: 1.5) }
            .contentShape(RoundedRectangle(cornerRadius: 10)).gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                guard !editing, !pressed else { return }; pressed = true; onPress(true)
            }.onEnded { _ in pressed = false; onPress(false) })
            .onDisappear { if pressed { onPress(false) } }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPress(true); Task { try? await Task.sleep(for: .milliseconds(100)); onPress(false) } }
#endif
    }
}

#if os(iOS)
/// UIKit's control tracking keeps simultaneous press/release and touch
/// cancellation independent from SwiftUI's optional layout drag gesture.
private struct NativePressControl: UIViewRepresentable {
    let label: String
    let keyHint: String?
    let symbol: String?
    let editing: Bool
    let selected: Bool
    let onPress: @MainActor (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }
    func makeUIView(context: Context) -> HoldButton {
        let button = HoldButton(type: .custom)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.numberOfLines = 2; button.titleLabel?.textAlignment = .center
        button.titleLabel?.adjustsFontSizeToFitWidth = true; button.titleLabel?.minimumScaleFactor = 0.6
        button.setTitleColor(.white, for: .normal); button.tintColor = .white
        button.layer.borderWidth = 1.5; button.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        button.addTarget(context.coordinator, action: #selector(Coordinator.down), for: [.touchDown, .touchDragEnter])
        button.addTarget(context.coordinator, action: #selector(Coordinator.up), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        updateUIView(button, context: context)
        return button
    }
    func updateUIView(_ button: HoldButton, context: Context) {
        context.coordinator.onPress = onPress
        if editing { context.coordinator.up() }
        button.isEnabled = !editing
        if symbol == nil {
            let title = NSMutableAttributedString(string: label, attributes: [.font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: UIColor.white])
            if let keyHint, keyHint != label { title.append(.init(string: "\n" + keyHint, attributes: [.font: UIFont.preferredFont(forTextStyle: .caption2), .foregroundColor: UIColor.white.withAlphaComponent(0.8)])) }
            button.setAttributedTitle(title, for: .normal)
        } else { button.setAttributedTitle(nil, for: .normal) }
        button.isSelected = selected
        button.setImage(symbol.flatMap { UIImage(systemName: $0) }, for: .normal)
        button.accessibilityLabel = label.isEmpty ? symbol : label
        button.refreshAppearance()
    }
    static func dismantleUIView(_ button: HoldButton, coordinator: Coordinator) { coordinator.up() }
    @MainActor final class Coordinator: NSObject {
        var onPress: (Bool) -> Void
        private var held = false
        init(onPress: @escaping (Bool) -> Void) { self.onPress = onPress }
        @objc func down() { guard !held else { return }; held = true; onPress(true) }
        @objc func up() { guard held else { return }; held = false; onPress(false) }
    }
    final class HoldButton: UIButton {
        override var isHighlighted: Bool { didSet { refreshAppearance() } }
        override var isSelected: Bool { didSet { refreshAppearance() } }
        override func layoutSubviews() { super.layoutSubviews(); layer.cornerRadius = min(12, bounds.height / 4) }
        func refreshAppearance() { backgroundColor = isHighlighted || isSelected ? UIColor.white.withAlphaComponent(0.4) : UIColor.black.withAlphaComponent(0.55) }
        override func accessibilityActivate() -> Bool {
            sendActions(for: .touchDown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.sendActions(for: .touchUpInside) }
            return true
        }
    }
}

private struct NativeJoystick: UIViewRepresentable {
    let change: @MainActor (Double, Double) -> Void
    func makeUIView(context: Context) -> JoyStickView {
        let view = JoyStickView(frame: .zero)
        view.baseImage = image(size: 126, fill: UIColor.black.withAlphaComponent(0.55), stroke: UIColor.white.withAlphaComponent(0.8))
        view.handleImage = image(size: 68, fill: UIColor.white.withAlphaComponent(0.75), stroke: .white)
        view.handleSizeRatio = 0.5; view.movable = false
        view.monitor = .polar { value in let xy = value.rectangular; change(Double(xy.x), Double(xy.y)) }
        view.accessibilityLabel = "Joystick"; view.isAccessibilityElement = true
        view.accessibilityIdentifier = "game.touch.stick"
        return view
    }
    func updateUIView(_ view: JoyStickView, context: Context) { view.monitor = .polar { value in let xy = value.rectangular; change(Double(xy.x), Double(xy.y)) } }
    static func dismantleUIView(_ view: JoyStickView, coordinator: ()) { view.monitor = .none }
    private func image(size: CGFloat, fill: UIColor, stroke: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            fill.setFill(); stroke.setStroke(); let path = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: size - 4, height: size - 4)); path.lineWidth = 2; path.fill(); path.stroke()
        }
    }
}
#endif
