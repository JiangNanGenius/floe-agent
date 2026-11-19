// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameTouch
import FloeGameWebKit

public struct GameTouchSettingsView: View {
    @Binding public var profile: GameTouchProfile
    @Binding public var editingLayout: Bool
    public let saving: Bool
    public let defaults: GameTouchProfile?
    public let onArrange: (@MainActor () -> Void)?
    public let onSave: @MainActor (GameTouchProfile) -> Void
    @Environment(\.locale) private var locale
    @State private var editingButton: ButtonPresentation?
    @State private var editingDirection: DirectionPresentation?
    @State private var issue: String?
    @State private var layoutPreview = false
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }

    public init(profile: Binding<GameTouchProfile>, editingLayout: Binding<Bool>, saving: Bool = false,
                defaults: GameTouchProfile? = nil, onArrange: (@MainActor () -> Void)? = nil,
                onSave: @escaping @MainActor (GameTouchProfile) -> Void) {
        _profile = profile; _editingLayout = editingLayout; self.saving = saving
        self.defaults = defaults; self.onArrange = onArrange; self.onSave = onSave
    }
    public var body: some View {
        Form {
            Section {
                Toggle(zh ? "显示触屏键位" : "Show touch keys", isOn: $profile.enabled)
                Picker(zh ? "方向控制" : "Movement", selection: $profile.stick) {
                    Text(zh ? "隐藏" : "Hidden").tag(GameTouchProfile.Stick.none)
                    Text(zh ? "摇杆" : "Joystick").tag(GameTouchProfile.Stick.joystick)
                    Text(zh ? "方向键" : "Direction pad").tag(GameTouchProfile.Stick.directionPad)
                }
                Picker(zh ? "移动键位" : "Movement keys", selection: Binding(get: { profile.movementKeys }, set: { chooseMovement($0) })) {
                    Text(zh ? "项目／引擎默认" : "Project / engine default").tag(GameTouchProfile.MovementKeys.engineDefault)
                    Text("↑ ↓ ← →").tag(GameTouchProfile.MovementKeys.arrows)
                    Text("W A S D").tag(GameTouchProfile.MovementKeys.wasd)
                    Text(zh ? "自定义" : "Custom").tag(GameTouchProfile.MovementKeys.custom)
                }
                ForEach([GameTouchAction.up, .down, .left, .right], id: \.self) { direction in
                    Button {
                        editingDirection = .init(value: direction)
                    } label: {
                        HStack {
                            Text(directionName(direction))
                            Spacer()
                            Text(profile.directionBinding(for: direction)?.keys.map(\.keyCap).joined(separator: " + ") ?? (zh ? "未绑定" : "Not bound"))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.foregroundStyle(.primary).frame(minHeight: 32)
                    }.accessibilityIdentifier("game.touch.direction." + direction.rawValue)
                }
            } header: { Text(zh ? "方向键位" : "Movement keys") }
            Section {
                if profile.buttons.isEmpty {
                    Text(zh ? "尚未添加按键" : "No keys added").foregroundStyle(.secondary)
                }
                ForEach(profile.buttons) { button in
                    HStack(spacing: 12) {
                        Button { editingButton = .init(id: button.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(button.label?.isEmpty == false ? button.label! : button.binding.keyCap)
                                    .font(.body.weight(.medium))
                                Text(button.binding.keyCap + " · " + modeName(button.mode))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).foregroundStyle(.primary)
                        }.buttonStyle(.plain).accessibilityIdentifier("game.touch.settings.edit." + button.id.rawValue)
                        Toggle(zh ? "显示" : "Visible", isOn: Binding(
                            get: { profile.button(id: button.id)?.visible ?? false },
                            set: { newValue in change(button.id) { $0.visible = newValue } }))
                            .labelsHidden().accessibilityLabel((zh ? "显示 " : "Show ") + button.binding.keyCap)
                    }
                    .contextMenu {
                        Button(zh ? "编辑按键" : "Edit key", systemImage: "pencil") { editingButton = .init(id: button.id) }
                        Button(zh ? "复制按键" : "Duplicate key", systemImage: "plus.square.on.square") { duplicate(button) }
                        Button(zh ? "向前移动" : "Move earlier", systemImage: "arrow.up") { move(button.id, offset: -1) }
                            .disabled(profile.buttons.first?.id == button.id)
                        Button(zh ? "向后移动" : "Move later", systemImage: "arrow.down") { move(button.id, offset: 1) }
                            .disabled(profile.buttons.last?.id == button.id)
                        Button(zh ? "删除按键" : "Delete key", systemImage: "trash", role: .destructive) { remove(button.id) }
                    }
                    .swipeActions {
                        Button(role: .destructive) { remove(button.id) } label: { Label(zh ? "删除" : "Delete", systemImage: "trash") }
                    }
                }
                Button(zh ? "添加按键" : "Add key", systemImage: "plus") { add() }
                    .disabled(profile.buttons.count >= 64)
                    .accessibilityIdentifier("game.touch.settings.add")
            } header: { Text(zh ? "键盘按键" : "Keyboard keys") }
              footer: { Text(zh ? "可绑定单键或组合键，名称和位置均可调整。" : "Bind a key or chord, and customize its label and position.") }
            Section {
                Toggle(zh ? "左手布局" : "Left-handed layout", isOn: $profile.leftHanded)
                slider(zh ? "整体大小" : "Overall size", value: .init(get: { profile.scale }, set: { value in attempt { try profile.adjust(scale: value) } }), range: 0.6...1.6)
                slider(zh ? "透明度" : "Opacity", value: .init(get: { profile.opacity }, set: { value in attempt { try profile.adjust(opacity: value) } }), range: 0.15...1)
                slider(zh ? "摇杆死区" : "Stick dead zone", value: .init(get: { profile.deadZone }, set: { value in attempt { try profile.adjust(deadZone: value) } }), range: 0.05...0.5)
                Button(zh ? "调整按键位置" : "Arrange keys", systemImage: "hand.draw") {
                    if let onArrange { editingLayout = true; onArrange() }
                    else { layoutPreview = true }
                }.accessibilityIdentifier("game.touch.settings.arrange")
            } header: { Text(zh ? "布局" : "Layout") }
            Section {
                Button(zh ? "恢复默认键位与布局" : "Restore default keys and layout") {
                    if let defaults, defaults.engine == profile.engine, defaults.keyboardTransport == profile.keyboardTransport {
                        profile = defaults
                    } else { profile = .standard(profile.engine, keyboardTransport: profile.keyboardTransport) }
                    editingLayout = false
                }
            }
        }.navigationTitle(zh ? "键位与布局" : "Keys and layout")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(zh ? "保存设置" : "Save controls") { onSave(profile) }.disabled(saving)
                        .accessibilityIdentifier("game.touch.settings.save")
                }
            }
            .sheet(item: $editingButton) { item in KeyboardButtonEditor(profile: $profile, id: item.id, isNew: item.isNew) }
            .sheet(item: $editingDirection) { item in
                KeyboardChordEditor(title: directionName(item.value),
                    keys: profile.directionBinding(for: item.value)?.keys ?? [], allowUnbound: true) { keys in
                    try profile.setDirectionBinding(keys.isEmpty ? nil : GameTouchChord(keys: keys), for: item.value)
                }
            }
            .sheet(isPresented: $layoutPreview) { KeyboardLayoutPreview(profile: $profile) }
            .alert(zh ? "无法更新键位" : "Could not update keys", isPresented: issueBinding) {
                Button(zh ? "好" : "OK") { issue = nil }
            } message: { Text(issue ?? "") }
    }
    private var issueBinding: Binding<Bool> { .init(get: { issue != nil }, set: { if !$0 { issue = nil } }) }
    private func attempt(_ body: () throws -> Void) { do { try body() } catch { issue = zh ? "请检查按键配置和尺寸后重试。" : "Check the key configuration and size, then try again." } }
    private func change(_ id: GameTouchButton.ID, _ body: (inout GameTouchButton) -> Void) {
        attempt { guard var value = profile.button(id: id) else { return }; body(&value); try profile.update(value) }
    }
    private func chooseMovement(_ preset: GameTouchProfile.MovementKeys) {
        attempt {
            if preset == .engineDefault {
                let original = defaults ?? .standard(profile.engine, keyboardTransport: profile.keyboardTransport)
                var value = profile
                for direction in [GameTouchAction.up, .down, .left, .right] {
                    try value.setDirectionBinding(original.directionBinding(for: direction), for: direction)
                }
                value.movementKeys = .engineDefault; profile = value
            } else { profile.movementKeys = preset }
        }
    }
    private func add() {
        attempt {
            let id = try GameTouchButton.ID("key." + UUID().uuidString.lowercased())
            editingButton = .init(id: id, isNew: true)
        }
    }
    private func duplicate(_ value: GameTouchButton) {
        attempt {
            let id = try GameTouchButton.ID("key." + UUID().uuidString.lowercased())
            var copy = GameTouchButton(id: id, binding: value.binding, anchor: nil, visible: value.visible)
            copy.label = value.label; copy.width = value.width; copy.height = value.height; copy.mode = value.mode
            try profile.add(copy); editingButton = .init(id: id)
        }
    }
    private func remove(_ id: GameTouchButton.ID) { attempt { try profile.remove(id: id) } }
    private func move(_ id: GameTouchButton.ID, offset: Int) {
        attempt {
            guard let index = profile.buttons.firstIndex(where: { $0.id == id }) else { return }
            try profile.move(id: id, to: index + offset)
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: value, in: range)
        }
    }
    private func directionName(_ direction: GameTouchAction) -> String {
        switch direction {
        case .up: zh ? "上" : "Up"
        case .down: zh ? "下" : "Down"
        case .left: zh ? "左" : "Left"
        case .right: zh ? "右" : "Right"
        default: direction.rawValue
        }
    }
    private func modeName(_ mode: GameTouchButton.Mode) -> String {
        switch mode { case .hold: zh ? "按住" : "Hold"; case .tap: zh ? "点按" : "Tap"; case .toggle: zh ? "切换" : "Toggle" }
    }
}

private struct ButtonPresentation: Identifiable { let id: GameTouchButton.ID; var isNew = false }
private struct DirectionPresentation: Identifiable { let value: GameTouchAction; var id: String { value.rawValue } }
private struct KeySlot: Identifiable { let id: Int }

private struct KeyboardButtonEditor: View {
    @Binding var profile: GameTouchProfile
    let id: GameTouchButton.ID
    let isNew: Bool
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var keys: [GameKeyboardKey]
    @State private var mode: GameTouchButton.Mode
    @State private var automaticSize: Bool
    @State private var width: Double
    @State private var height: Double
    @State private var choosingKey: KeySlot?
    @State private var issue: String?
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }
    init(profile: Binding<GameTouchProfile>, id: GameTouchButton.ID, isNew: Bool = false) {
        _profile = profile; self.id = id; self.isNew = isNew
        let value = profile.wrappedValue.button(id: id)
        _label = State(initialValue: value?.label ?? "")
        _keys = State(initialValue: value?.binding.keyboardKeys ?? [.space])
        _mode = State(initialValue: value?.mode ?? .hold)
        _automaticSize = State(initialValue: value?.width == nil && value?.height == nil)
        _width = State(initialValue: value?.width ?? 84); _height = State(initialValue: value?.height ?? 52)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(zh ? "名称（留空显示键位）" : "Label (leave empty to show keys)", text: $label)
                        .accessibilityIdentifier("game.touch.button.label")
                    Picker(zh ? "触发方式" : "Behavior", selection: $mode) {
                        Text(zh ? "按住" : "Hold").tag(GameTouchButton.Mode.hold)
                        Text(zh ? "点按" : "Tap").tag(GameTouchButton.Mode.tap)
                        Text(zh ? "切换" : "Toggle").tag(GameTouchButton.Mode.toggle)
                    }
                }
                KeyboardKeysSection(keys: $keys, choosing: $choosingKey)
                Section {
                    Toggle(zh ? "自动大小" : "Automatic size", isOn: $automaticSize)
                    if !automaticSize {
                        VStack(alignment: .leading) {
                            Text((zh ? "宽度 " : "Width ") + String(Int(width)))
                            Slider(value: $width, in: 44...320, step: 1)
                        }
                        VStack(alignment: .leading) {
                            Text((zh ? "高度 " : "Height ") + String(Int(height)))
                            Slider(value: $height, in: 44...320, step: 1)
                        }
                    }
                } header: { Text(zh ? "大小" : "Size") }
            }.navigationTitle(zh ? (isNew ? "添加按键" : "编辑按键") : (isNew ? "Add key" : "Edit key"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(zh ? "取消" : "Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(zh ? "完成" : "Done") { save() }.disabled(keys.isEmpty)
                            .accessibilityIdentifier("game.touch.button.done")
                    }
                }
        }.sheet(item: $choosingKey) { slot in
            KeyboardKeyChooser { key in
                if keys.indices.contains(slot.id) { keys[slot.id] = key }
                else if slot.id == keys.count, keys.count < 8 { keys.append(key) }
                choosingKey = nil
            }
        }
        .alert(zh ? "无法更新按键" : "Could not update key", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button(zh ? "好" : "OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func save() {
        do {
            guard profile.button(id: id) != nil || isNew else { dismiss(); return }
            var value = profile.button(id: id) ?? GameTouchButton(id: id, binding: .key(.space))
            let chord = try GameTouchChord(keys: keys)
            value.binding = chord.keys.count == 1 ? .key(chord.keys[0]) : .chord(chord)
            let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
            value.label = text.isEmpty ? nil : text
            value.mode = mode; value.width = automaticSize ? nil : width; value.height = automaticSize ? nil : height
            if isNew { try profile.add(value) } else { try profile.update(value) }
            dismiss()
        } catch { issue = zh ? "请选择不重复的键位，并检查名称和尺寸。" : "Choose distinct keys and check the label and size." }
    }
}

private struct KeyboardChordEditor: View {
    let title: String
    let onSave: ([GameKeyboardKey]) throws -> Void
    let allowUnbound: Bool
    @State private var keys: [GameKeyboardKey]
    @State private var choosing: KeySlot?
    @State private var issue: String?
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }
    init(title: String, keys: [GameKeyboardKey], allowUnbound: Bool = false, onSave: @escaping ([GameKeyboardKey]) throws -> Void) {
        self.title = title; _keys = State(initialValue: keys); self.allowUnbound = allowUnbound; self.onSave = onSave
    }
    var body: some View {
        NavigationStack {
            Form {
                KeyboardKeysSection(keys: $keys, choosing: $choosing)
                if allowUnbound { Button(zh ? "不绑定按键" : "Leave unbound") { keys = [] } }
            }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(zh ? "取消" : "Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(zh ? "完成" : "Done") { do { try onSave(keys); dismiss() } catch { issue = zh ? "组合键不能包含重复键位。" : "A chord cannot contain duplicate keys." } }
                            .disabled(keys.isEmpty && !allowUnbound)
                    }
                }
        }.sheet(item: $choosing) { slot in
            KeyboardKeyChooser { key in
                if keys.indices.contains(slot.id) { keys[slot.id] = key }
                else if slot.id == keys.count, keys.count < 8 { keys.append(key) }
                choosing = nil
            }
        }
        .alert(zh ? "无法更新键位" : "Could not update keys", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button(zh ? "好" : "OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
}

private struct KeyboardKeysSection: View {
    @Binding var keys: [GameKeyboardKey]
    @Binding var choosing: KeySlot?
    @Environment(\.locale) private var locale
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }
    var body: some View {
        Section {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                Button { choosing = .init(id: index) } label: {
                    HStack { Text(key.keyCap).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        .frame(minHeight: 32)
                }.accessibilityIdentifier("game.touch.binding.key." + String(index))
            }.onDelete { keys.remove(atOffsets: $0) }
            if keys.count < 8 {
                Button(zh ? "添加组合键" : "Add key to chord", systemImage: "plus") {
                    choosing = .init(id: keys.count)
                }.accessibilityIdentifier("game.touch.binding.add")
            }
        } header: { Text(zh ? "键盘映射" : "Keyboard binding") }
          footer: { Text(zh ? "组合键会同时按下，松开时一并释放。" : "Keys in a chord press together and release together.") }
    }
}

private struct KeyboardKeyChooser: View {
    let onSelect: (GameKeyboardKey) -> Void
    @State private var search = ""
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }
    var body: some View {
        NavigationStack {
            List {
                ForEach(GameKeyboardKey.allCases.filter { search.isEmpty || $0.keyCap.localizedCaseInsensitiveContains(search) || $0.rawValue.localizedCaseInsensitiveContains(search) || $0.descriptor.code.localizedCaseInsensitiveContains(search) }, id: \.self) { key in
                    Button { onSelect(key) } label: {
                        HStack { Text(key.keyCap).foregroundStyle(.primary); Spacer(); Text(category(key)).font(.caption).foregroundStyle(.secondary) }
                            .frame(minHeight: 32)
                    }.accessibilityIdentifier("game.touch.key.choose." + key.rawValue)
                }
            }.searchable(text: $search, prompt: zh ? "搜索键位" : "Search keys")
                .navigationTitle(zh ? "键盘按键" : "Keyboard key")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(zh ? "取消" : "Cancel") { dismiss() } } }
        }
    }
    private func category(_ key: GameKeyboardKey) -> String {
        if key.isModifier { return zh ? "修饰键" : "Modifier" }
        let code = key.descriptor.code
        if code.hasPrefix("Numpad") { return zh ? "数字小键盘" : "Number pad" }
        if code.hasPrefix("Key") { return zh ? "字母" : "Letter" }
        if code.hasPrefix("Digit") { return zh ? "数字" : "Number" }
        if code.hasPrefix("Arrow") { return zh ? "方向键" : "Arrow key" }
        return zh ? "功能键" : "Function key"
    }
}

private struct KeyboardLayoutPreview: View {
    @Binding var profile: GameTouchProfile
    @StateObject private var service: GameTouchInputService
    @State private var original: GameTouchProfile
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }
    init(profile: Binding<GameTouchProfile>) {
        _profile = profile; _original = State(initialValue: profile.wrappedValue)
        _service = StateObject(wrappedValue: GameTouchInputService(profile: profile.wrappedValue))
    }
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.12)
                GameTouchControlsView(service: service, editingLayout: true, layoutProfile: profile, onMove: { id, anchor in
                    do {
                        if let id, var value = profile.button(id: id) { value.anchor = anchor; try profile.update(value) }
                        else { profile.stickAnchor = anchor }
                    } catch {}
                }, onFinishLayout: { dismiss() })
            }.navigationTitle(zh ? "按键布局" : "Key layout")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(zh ? "取消" : "Cancel") { profile = original; dismiss() } } }
        }.interactiveDismissDisabled()
    }
}
