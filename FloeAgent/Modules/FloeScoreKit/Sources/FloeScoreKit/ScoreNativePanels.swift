// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeHeavyEditorSupport

// These are presentation values, never a second score store or audio session.
// The host controller owns commands, authorization, revisions and long work.
private extension EditorJSON {
    var scoreFlag: Bool { if case .bool(let value) = self { return value }; return false }
    func scoreText(_ fallback: String = "") -> String { string ?? fallback }
    func scoreNumber(_ fallback: Double = 0) -> Double { number ?? fallback }
}
private struct ScorePartRow: Identifiable {
    let value: EditorJSON
    var id: String { value["id"].scoreText() }
    var name: String { value["name"].scoreText() }
    var staves: Int { Int(value["staves"].scoreNumber(1)) }
    var measures: Int { Int(value["measureCount"].scoreNumber()) }
    var solo: Bool { value["mix"]["solo"].scoreFlag }
    var mute: Bool { value["mix"]["mute"].scoreFlag }
    var volume: Double { value["mix"]["volume"].scoreNumber(1) }
}
private struct ScoreMeasureRow: Identifiable {
    let value: EditorJSON
    var id: String { value["id"].scoreText() }
    var number: String { value["number"].scoreText() }
    var meter: String { "\(Int(value["beats"].scoreNumber(4)))/\(Int(value["beatType"].scoreNumber(4)))" }
    var count: Int { Int(value["notesCount"].scoreNumber()) }
}
private struct ScoreNoteRow: Identifiable {
    let value: EditorJSON
    var id: String { value["id"].scoreText() }
    var pitch: String { value["pitchName"].scoreText("C4") }
    var onset: String { value["onsetText"].scoreText("0") }
    var duration: String { value["durationText"].scoreText("1") }
    var type: String { value["type"].scoreText("quarter") }
    var dots: Int { Int(value["dots"].scoreNumber()) }
    var voice: Int { Int(Double(value["voice"].scoreText("1")) ?? 1) }
    var staff: Int { Int(value["staff"].scoreNumber(1)) }
    var rest: Bool { value["rest"].scoreFlag }
    var selected: Bool { value["selected"].scoreFlag }
    var actual: Double { value["actual"].scoreNumber(1) }
    var normal: Double { value["normal"].scoreNumber(1) }
    var preset: EditorJSON {
        .object(["pitch": .string(rest ? "C4" : pitch), "type": .string(type),
                 "dots": .number(Double(dots)), "voice": .number(Double(voice)),
                 "staff": .number(Double(staff)), "rest": .bool(rest),
                 "actual": .number(actual), "normal": .number(normal)])
    }
}
private struct ScoreMarkRow: Identifiable {
    let value: EditorJSON
    var id: String { value["id"].scoreText() }
    var label: String { value["label"].scoreText() }
}
private struct ScoreDiagnosticRow: Identifiable {
    let value: EditorJSON
    var id: Int { Int(value["index"].scoreNumber(1)) }
    var message: String { value["message"].scoreText() }
    var isError: Bool { value["severity"].string == "error" }
}
private struct ScorePanelSnapshot {
    let value: EditorJSON
    var parts: [ScorePartRow] { value["parts"].array.map { ScorePartRow(value: $0) } }
    var measures: [ScoreMeasureRow] { value["measures"].array.map { ScoreMeasureRow(value: $0) } }
    var notes: [ScoreNoteRow] { value["current"]["notes"].array.map { ScoreNoteRow(value: $0) } }
    var marks: [ScoreMarkRow] { value["current"]["marks"].array.map { ScoreMarkRow(value: $0) } }
    var diagnostics: [ScoreDiagnosticRow] { value["diagnostics"].array.map { ScoreDiagnosticRow(value: $0) } }
    var note: ScoreNoteRow? {
        let value = value["current"]["note"]
        return value["id"].string.map { _ in ScoreNoteRow(value: value) }
    }
    var partID: String { value["selection"]["part"].scoreText() }
    var measureID: String { value["selection"]["measure"].scoreText() }
    var selectedCount: Int { Int(value["selection"]["count"].scoreNumber()) }
    var currentPart: ScorePartRow? { parts.first { $0.id == partID } ?? parts.first }
    var currentIndex: Int { Int(value["current"]["index"].scoreNumber(1)) }
    var staves: Int { max(1, min(16, Int(value["current"]["staves"].scoreNumber(1)))) }
    var staffDetails: EditorJSON { value["current"]["staffDetails"] }
    var staffSign: String { staffDetails["clef"].scoreText("G") }
    var stringCount: Int { max(1, min(12, Int(staffDetails["lines"].scoreNumber(6)))) }
    var input: EditorJSON { value["input"] }
    var inputType: String { input["type"].scoreText("quarter") }
    var inputDots: Int { Int(input["dots"].scoreNumber()) }
    var inputVoice: Int { Int(input["voice"].scoreNumber(1)) }
    var inputStaff: Int { Int(input["staff"].scoreNumber(1)) }
    var inputOctave: Int { Int(input["octave"].scoreNumber(4)) }
    var entryMode: String { input["mode"].scoreText("replace") }
    var isRestInput: Bool { input["rest"].scoreFlag }
    var keyboardVisible: Bool { value["view"]["keyboardVisible"] != .bool(false) }
    var viewPart: String { value["view"]["part"].scoreText() }
    var concert: Bool { value["view"]["concert"].scoreFlag }
    var notation: String { value["view"]["notation"].scoreText("staff") }
    var numbered: EditorJSON { value["numberedInput"] }
    var numberAlter: Int { Int(input["numberAlter"].scoreNumber()) }
    var continuous: Bool { value["layout"]["continuous"].scoreFlag }
    var zoom: Double { value["layout"]["zoom"].scoreNumber(1) }
    var loop: Bool { value["playback"]["loop"].scoreFlag }
    var metronome: Bool { value["playback"]["metronome"].scoreFlag }
    var tempoScale: Double { value["playback"]["tempoScale"].scoreNumber(1) }
    var transportDuration: Double { max(0, value["transport"]["duration"].scoreNumber()) }
    func position(at date: Date) -> Double {
        let base = value["transport"]["position"].scoreNumber()
        guard value["transport"]["playing"].scoreFlag else { return base }
        let sample = value["transport"]["sampledAt"].scoreNumber(date.timeIntervalSince1970 * 1000) / 1000
        let position = base + max(0, date.timeIntervalSince1970 - sample)
        if loop, transportDuration > 0 { return position.truncatingRemainder(dividingBy: transportDuration) }
        return min(transportDuration, position)
    }
    func playing(at date: Date) -> Bool {
        value["transport"]["playing"].scoreFlag && (loop || position(at: date) < transportDuration)
    }
}

@MainActor private enum ScorePanelActions {
    static func input(_ controller: HeavyEditorController, _ key: String, _ value: EditorJSON) {
        controller.runCommand("score.ui.input", arguments: .object([key: value]))
    }
    static func layout(_ controller: HeavyEditorController, _ snapshot: ScorePanelSnapshot,
                       _ key: String, _ value: EditorJSON) {
        let layout = snapshot.value["layout"]
        var arguments: [String: EditorJSON] = [
            "scope": .string(snapshot.viewPart.isEmpty ? "score" : "part"),
            "part": .string(snapshot.viewPart.isEmpty ? snapshot.partID : snapshot.viewPart),
            "paper": .string(layout["paper"].scoreText("A4_P")),
            "continuous": .bool(snapshot.continuous), "zoom": .number(snapshot.zoom),
            "condenseRests": .bool(layout["condenseRests"].scoreFlag),
            "measuresPerSystem": .number(layout["measuresPerSystem"].scoreNumber(4)),
            "margin": .number(layout["margin"].scoreNumber(15)),
            "staffSpacing": .number(layout["staffSpacing"].scoreNumber(7))
        ]
        arguments[key] = value
        controller.runCommand("score.layout.settings", arguments: .object(arguments))
    }
    static func playback(_ controller: HeavyEditorController, _ snapshot: ScorePanelSnapshot,
                         _ key: String, _ value: EditorJSON) {
        let playback = snapshot.value["playback"]
        var arguments: [String: EditorJSON] = [
            "tempoScale": .number(snapshot.tempoScale), "loop": .bool(snapshot.loop),
            "loopFrom": .number(playback["loopFrom"].scoreNumber()),
            "loopTo": .number(playback["loopTo"].scoreNumber()),
            "metronome": .bool(snapshot.metronome)
        ]
        arguments[key] = value
        controller.runCommand("score.playback.settings", arguments: .object(arguments))
    }
    static func mix(_ controller: HeavyEditorController, _ part: ScorePartRow,
                    _ key: String, _ value: EditorJSON) {
        var arguments: [String: EditorJSON] = ["part": .string(part.id),
            "solo": .bool(part.solo), "mute": .bool(part.mute), "volume": .number(part.volume)]
        arguments[key] = value
        controller.runCommand("score.playback.mix", arguments: .object(arguments))
    }
    static func enter(_ controller: HeavyEditorController, _ snapshot: ScorePanelSnapshot, pitch: Int? = nil, spelledPitch: String? = nil, rest: Bool? = nil) {
        var arguments: [String: EditorJSON] = [
            "type": .string(snapshot.inputType), "dots": .number(Double(snapshot.inputDots)),
            "voice": .number(Double(snapshot.inputVoice)), "staff": .number(Double(snapshot.inputStaff)),
            "mode": .string(snapshot.entryMode), "rest": .bool(rest ?? snapshot.isRestInput)
        ]
        if !snapshot.partID.isEmpty { arguments["part"] = .string(snapshot.partID) }
        if !snapshot.measureID.isEmpty { arguments["measure"] = .string(snapshot.measureID) }
        if let spelledPitch { arguments["pitch"] = .string(spelledPitch) }
        else if let pitch { arguments["pitch"] = .string(pitchName(pitch)) }
        if snapshot.staffSign == "TAB", rest != true, !snapshot.isRestInput {
            controller.runCommand("score.edit.tabInsert", arguments: .object(arguments))
        } else if snapshot.staffSign == "percussion", rest != true, !snapshot.isRestInput {
            arguments["drum"] = .number(Double(pitch ?? 38))
            controller.runCommand("score.edit.percussionInsert", arguments: .object(arguments))
        } else { controller.runCommand("score.edit.insert", arguments: .object(arguments)) }
    }
    static func pitchName(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[(pitch % 12 + 12) % 12] + String(pitch / 12 - 1)
    }
    static func durationName(_ type: String) -> String {
        switch type {
        case "whole": EditorText.t("全音符", "Whole")
        case "half": EditorText.t("二分音符", "Half")
        case "quarter": EditorText.t("四分音符", "Quarter")
        case "eighth": EditorText.t("八分音符", "Eighth")
        case "16th": EditorText.t("十六分音符", "Sixteenth")
        case "32nd": EditorText.t("三十二分音符", "32nd")
        case "64th": EditorText.t("六十四分音符", "64th")
        case "128th": EditorText.t("一百二十八分音符", "128th")
        default: type
        }
    }
    static var durationTypes: [String] { ["whole", "half", "quarter", "eighth", "16th", "32nd", "64th", "128th"] }
}

@MainActor private struct ScoreNativeSelectionRow<Content: View>: View {
    let title: String
    let identifier: String
    let action: () -> Void
    let content: Content
    init(_ title: String, identifier: String, action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.title = title; self.identifier = identifier; self.action = action; self.content = label()
    }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                content.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor struct ScoreNativeOutline: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    var body: some View {
        List {
            Section {
                Picker(EditorText.t("显示", "Display"), selection: Binding(get: { snapshot.viewPart }, set: { value in
                    controller.runCommand("score.ui.view", arguments: .object(["part": .string(value)]))
                })) {
                    Text(EditorText.t("完整总谱", "Full score")).tag("")
                    ForEach(snapshot.parts) { part in Text(part.name).tag(part.id) }
                }.pickerStyle(.menu)
                Toggle(EditorText.t("实音显示", "Concert pitch"), isOn: Binding(get: { snapshot.concert }, set: { value in
                    controller.runCommand("score.ui.view", arguments: .object(["concert": .bool(value)]))
                }))
            }
            Section {
                ForEach(snapshot.parts) { part in
                    ScoreNativeSelectionRow(part.name, identifier: "score.part." + part.id) {
                        controller.runCommand("score.ui.select", arguments: .object(["part": .string(part.id)]))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "music.note.list").foregroundStyle(part.id == snapshot.partID ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(part.name).foregroundStyle(.primary)
                                Text(EditorText.t("\(part.staves) 个谱表 · \(part.measures) 小节", "\(part.staves) staves · \(part.measures) measures"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if part.solo { Image(systemName: "headphones").foregroundStyle(Color.accentColor) }
                            if part.mute { Image(systemName: "speaker.slash").foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                    .listRowBackground(part.id == snapshot.partID ? Color.accentColor.opacity(0.1) : Color.clear)
                    .contextMenu {
                        Button(EditorText.t("乐器与移调", "Instrument & transposition")) {
                            controller.showCommand("score.parts.update", preset: .object(["part": .string(part.id), "name": .string(part.name)]))
                        }
                        Button(EditorText.t("谱表", "Staves")) { controller.showCommand("score.parts.staff", preset: .object(["part": .string(part.id)])) }
                        Button(EditorText.t("独奏与音量", "Solo & volume")) { controller.showCommand("score.playback.mix", preset: .object(["part": .string(part.id)])) }
                        Button(EditorText.t("排序", "Reorder")) { controller.showCommand("score.parts.reorder", preset: .object(["part": .string(part.id)])) }
                    }
                    if part.staves > 1 {
                        DisclosureGroup(EditorText.t("谱表", "Staves")) {
                            ForEach(1...part.staves, id: \.self) { staff in
                                ScoreNativeSelectionRow(EditorText.t("\(part.name) · 谱表 \(staff)", "\(part.name) · Staff \(staff)"), identifier: "score.staff.\(part.id).\(staff)") {
                                    controller.runCommand("score.ui.select", arguments: .object(["part": .string(part.id), "staff": .number(Double(staff))]))
                                } label: {
                                    HStack {
                                        Text(EditorText.t("谱表 \(staff)", "Staff \(staff)"))
                                        Spacer()
                                        if part.id == snapshot.partID, staff == snapshot.inputStaff { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(EditorText.t("乐器与谱表", "Instruments & staves"))
                    Spacer()
                    Button { controller.showCommand("score.parts.add") } label: { Image(systemName: "plus") }
                        .accessibilityLabel(EditorText.t("添加乐器", "Add instrument"))
                }
            }
            Section {
                ForEach(snapshot.measures) { measure in
                    ScoreNativeSelectionRow(EditorText.t("第 \(measure.number) 小节", "Measure \(measure.number)"), identifier: "score.measure." + measure.id) {
                        controller.runCommand("score.ui.select", arguments: .object(["part": .string(snapshot.partID), "measure": .string(measure.id)]))
                    } label: {
                        HStack {
                            Text(EditorText.t("第 \(measure.number) 小节", "Measure \(measure.number)"))
                            Spacer()
                            Text(measure.meter).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    .listRowBackground(measure.id == snapshot.measureID ? Color.accentColor.opacity(0.1) : Color.clear)
                    .contextMenu {
                        Button(EditorText.t("谱号、调号与拍号", "Clef, key & meter")) {
                            controller.showCommand("score.edit.attributes", preset: .object(["part": .string(snapshot.partID), "measure": .string(measure.id)]))
                        }
                        Button(EditorText.t("换行或换页", "System or page break")) {
                            controller.showCommand("score.layout.break", preset: .object(["part": .string(snapshot.partID), "measure": .string(measure.id)]))
                        }
                    }
                }
            } header: {
                HStack {
                    Text(EditorText.t("小节", "Measures")); Spacer()
                    Button { controller.showCommand("score.edit.measure") } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                        .accessibilityLabel(EditorText.t("增删或移动小节", "Edit measures"))
                }
            }
            Section {
                Button(EditorText.t("新建模板", "New from template"), systemImage: "doc.badge.plus") { controller.showCommand("score.project.template") }
                Button(EditorText.t("标题与作者", "Title & credits"), systemImage: "textformat") { controller.showCommand("score.project.metadata") }
                Button(EditorText.t("导出乐谱", "Export score"), systemImage: "square.and.arrow.up") { controller.showCommand("score.export") }
                Button(EditorText.t("导出全部分谱", "Export linked parts"), systemImage: "doc.on.doc") { controller.showCommand("score.parts.export", preset: .object(["format": .string("pdf")])) }
            }
        }.listStyle(.sidebar)
        .accessibilityIdentifier("score.native.outline")
    }
}

@MainActor struct ScoreNativeInputToolbar: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                    Picker(EditorText.t("记谱", "Notation"), selection: Binding(get: { snapshot.notation }, set: { value in
                        controller.runCommand("score.view.notation", arguments: .object(["notation": .string(value)]))
                    })) {
                        Text(EditorText.t("五线谱", "Staff")).tag("staff")
                        Text(EditorText.t("简谱", "Numbered")).tag("jianpu")
                    }.pickerStyle(.segmented).frame(width: 178)
                        .accessibilityIdentifier("score.native.notation")
                    if snapshot.notation == "jianpu", !snapshot.value["notationWarnings"].array.isEmpty {
                        Label(EditorText.t("完整记号请查看五线谱", "View the staff score for all marks"), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("score.native.numberedWarning")
                    }

                Picker(EditorText.t("时值", "Duration"), selection: Binding(get: { snapshot.inputType }, set: { ScorePanelActions.input(controller, "type", .string($0)) })) {
                    ForEach(ScorePanelActions.durationTypes, id: \.self) { type in Text(ScorePanelActions.durationName(type)).tag(type) }
                }.pickerStyle(.menu).fixedSize()
                Picker(EditorText.t("附点", "Dots"), selection: Binding(get: { snapshot.inputDots }, set: { ScorePanelActions.input(controller, "dots", .number(Double($0))) })) {
                    ForEach(0...3, id: \.self) { dots in Text(dots == 0 ? EditorText.t("无附点", "No dot") : String(repeating: "·", count: dots)).tag(dots) }
                }.pickerStyle(.menu).fixedSize()
                Picker(EditorText.t("声部", "Voice"), selection: Binding(get: { snapshot.inputVoice }, set: { ScorePanelActions.input(controller, "voice", .number(Double($0))) })) {
                    ForEach(1...64, id: \.self) { voice in Text(EditorText.t("声部 \(voice)", "Voice \(voice)")).tag(voice) }
                }.pickerStyle(.menu).fixedSize()
                Picker(EditorText.t("谱表", "Staff"), selection: Binding(get: { snapshot.inputStaff }, set: { ScorePanelActions.input(controller, "staff", .number(Double($0))) })) {
                    ForEach(1...snapshot.staves, id: \.self) { staff in Text(EditorText.t("谱表 \(staff)", "Staff \(staff)")).tag(staff) }
                }.pickerStyle(.menu).fixedSize()
                Picker(EditorText.t("输入方式", "Entry mode"), selection: Binding(get: { snapshot.entryMode }, set: { ScorePanelActions.input(controller, "mode", .string($0)) })) {
                    Text(EditorText.t("替换", "Replace")).tag("replace")
                    Text(EditorText.t("续写", "Append")).tag("append")
                    Text(EditorText.t("插入", "Insert")).tag("insert")
                }.pickerStyle(.menu).fixedSize()
                Toggle(EditorText.t("休止符", "Rest"), isOn: Binding(get: { snapshot.isRestInput }, set: { ScorePanelActions.input(controller, "rest", .bool($0)) }))
                    .toggleStyle(.button)
                Button { ScorePanelActions.enter(controller, snapshot, rest: true) } label: { Label(EditorText.t("输入休止符", "Enter rest"), systemImage: "pause") }
                ScoreNativeNotationMenu(controller: controller)
                Menu {
                    Button(EditorText.t("分页", "Pages")) { ScorePanelActions.layout(controller, snapshot, "continuous", .bool(false)) }
                    Button(EditorText.t("连续", "Continuous")) { ScorePanelActions.layout(controller, snapshot, "continuous", .bool(true)) }
                    Divider()
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { zoom in
                        Button("\(Int(zoom * 100))%") { ScorePanelActions.layout(controller, snapshot, "zoom", .number(zoom)) }
                    }
                    Divider()
                    Button(EditorText.t("页面与间距", "Page & spacing")) { controller.showCommand("score.layout.settings") }
                    Button(EditorText.t("换行与换页", "System & page breaks")) { controller.showCommand("score.layout.break") }
                } label: {
                    Label("\(snapshot.continuous ? EditorText.t("连续", "Continuous") : EditorText.t("分页", "Pages")) · \(Int(snapshot.zoom * 100))%", systemImage: "rectangle.split.1x2")
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.scrollIndicators(.hidden)
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityIdentifier("score.native.input")
    }
}

@MainActor private struct ScoreNativeNotationMenu: View {
    let controller: HeavyEditorController
    var body: some View {
        Menu {
            Button(EditorText.t("和弦音", "Chord tones")) { controller.showCommand("score.edit.chord") }
            Button(EditorText.t("连音组", "Tuplet group")) { controller.showCommand("score.edit.tuplet") }
            Button(EditorText.t("延音线与圆滑线", "Ties & slurs")) { controller.showCommand("score.edit.spanner") }
            Button(EditorText.t("连桁", "Beaming")) { controller.showCommand("score.edit.beam") }
            Button(EditorText.t("奏法与装饰音", "Articulations & ornaments")) { controller.showCommand("score.edit.articulation") }
            Divider()
            Button(EditorText.t("歌词", "Lyrics")) { controller.showCommand("score.edit.lyrics") }
            Button(EditorText.t("力度、文字与导航", "Dynamics, text & navigation")) { controller.showCommand("score.edit.direction") }
            Button(EditorText.t("和弦标记", "Chord symbol")) { controller.showCommand("score.edit.harmony") }
            Button(EditorText.t("渐快或渐慢", "Tempo ramp")) { controller.showCommand("score.edit.tempoRamp") }
            Divider()
            Button(EditorText.t("指法与六线谱", "Fingering & TAB")) { controller.showCommand("score.edit.technical") }
            Button(EditorText.t("鼓组记谱", "Drum notation")) { controller.showCommand("score.edit.percussion") }
            Button(EditorText.t("反复与房子", "Repeats & endings")) { controller.showCommand("score.edit.barline") }
        } label: { Label(EditorText.t("记号", "Notation"), systemImage: "music.note") }
    }
}

@MainActor struct ScoreNativeInspector: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    var body: some View {
        Form {
            Section(EditorText.t("当前小节", "Current measure")) {
                LabeledContent(EditorText.t("乐器", "Instrument"), value: snapshot.currentPart?.name ?? "—")
                LabeledContent(EditorText.t("小节", "Measure"), value: String(snapshot.currentIndex))
                LabeledContent(EditorText.t("拍号", "Meter"), value: "\(Int(snapshot.value["current"]["beats"].scoreNumber(4)))/\(Int(snapshot.value["current"]["beatType"].scoreNumber(4)))")
                Button(EditorText.t("谱号、调号与拍号", "Clef, key & meter")) { controller.showCommand("score.edit.attributes") }
            }
            Section(EditorText.t("选区", "Selection")) {
                Text(EditorText.t("选中 \(snapshot.selectedCount) 个音符", "\(snapshot.selectedCount) notes selected")).foregroundStyle(.secondary)
                HStack {
                    Button { controller.runCommand("score.edit.transpose", arguments: .object(["semitones": .number(-1)])) } label: { Label(EditorText.t("降半音", "Down semitone"), systemImage: "arrow.down") }
                    Button { controller.runCommand("score.edit.transpose", arguments: .object(["semitones": .number(1)])) } label: { Label(EditorText.t("升半音", "Up semitone"), systemImage: "arrow.up") }
                }.disabled(snapshot.selectedCount == 0)
                Menu(EditorText.t("选区操作", "Selection actions")) {
                    Button(EditorText.t("选择范围", "Select range")) { controller.showCommand("score.edit.select") }
                    Button(EditorText.t("复制", "Copy")) { controller.runCommand("score.edit.copy", arguments: .object([:])) }
                    Button(EditorText.t("剪切", "Cut")) { controller.runCommand("score.edit.cut", arguments: .object([:])) }
                    Button(EditorText.t("粘贴", "Paste")) { controller.showCommand("score.edit.paste") }
                    Button(EditorText.t("移调", "Transpose")) { controller.showCommand("score.edit.transpose") }
                    Button(EditorText.t("等音拼写", "Enharmonic spelling")) { controller.showCommand("score.edit.enharmonic") }
                    Button(EditorText.t("移动", "Move")) { controller.showCommand("score.edit.move") }
                    Button(EditorText.t("缩放时值", "Scale durations")) { controller.showCommand("score.edit.duration") }
                    Button(EditorText.t("删除", "Delete"), role: .destructive) { controller.runCommand("score.edit.delete", arguments: .object([:])) }
                }
                if let note = snapshot.note {
                    ScoreNativeNoteProperties(controller: controller, note: note, snapshot: snapshot)
                }
            }
            if let part = snapshot.currentPart {
                Section(EditorText.t("乐器播放", "Instrument playback")) { ScoreNativePartMix(controller: controller, part: part) }
            }
            Section(EditorText.t("本小节音符", "Notes in measure")) {
                if snapshot.notes.isEmpty { Text(EditorText.t("从键盘输入音符。", "Enter a note with the keyboard.")).foregroundStyle(.secondary) }
                ForEach(snapshot.notes) { note in
                    Button {
                        controller.runCommand("score.ui.select", arguments: .object(["note": .string(note.id)]))
                    } label: {
                        HStack {
                            Text(note.pitch).fontWeight(note.selected ? .semibold : .regular)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(EditorText.t("位置 \(note.onset) · 时值 \(note.duration)", "At \(note.onset) · length \(note.duration)"))
                                Text(EditorText.t("谱表 \(note.staff) · 声部 \(note.voice)", "Staff \(note.staff) · voice \(note.voice)"))
                            }.font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(note.selected ? Color.accentColor : Color.primary).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
            }
            Section(EditorText.t("记号", "Marks")) {
                ScoreNativeNotationMenu(controller: controller)
                ForEach(snapshot.marks) { mark in
                    HStack {
                        Text(mark.label)
                        Spacer()
                        Button {
                            controller.runCommand("score.edit.removeMark", arguments: .object(["id": .string(mark.id)]))
                        } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel(EditorText.t("移除记号", "Remove mark"))
                    }
                }
            }
            Section(EditorText.t("检查与修复", "Checks & repair")) {
                Button(EditorText.t("节奏与音域检查", "Check rhythm & range")) { controller.runCommand("score.analyze.diagnostics", arguments: .object([:])) }
                Button(EditorText.t("音程、和弦与调性", "Intervals, chords & key")) { controller.runCommand("score.analyze.harmony", arguments: .object([:]), showResult: true) }
                Button(EditorText.t("补齐休止符", "Fill rests")) { controller.showCommand("score.edit.fill") }
                Button(EditorText.t("按拍号重排", "Rebar to meter")) { controller.showCommand("score.edit.rebar") }
                ForEach(snapshot.diagnostics) { issue in
                    Button {
                        controller.runCommand("score.analyze.navigate", arguments: .object(["index": .number(Double(issue.id))]))
                    } label: {
                        Label(issue.message, systemImage: issue.isError ? "exclamationmark.circle" : "info.circle")
                            .font(.caption).multilineTextAlignment(.leading)
                    }
                }
            }
        }.formStyle(.grouped)
        .accessibilityIdentifier("score.native.inspector")
    }
}

@MainActor private struct ScoreNativeNoteProperties: View {
    let controller: HeavyEditorController
    let note: ScoreNoteRow
    let snapshot: ScorePanelSnapshot
    @State private var pitchDraft = ""
    @FocusState private var pitchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.selectedCount == 1, !note.rest {
                HStack {
                    TextField(EditorText.t("音高", "Pitch"), text: $pitchDraft)
                        .focused($pitchFocused).onSubmit(applyPitch)
                    Button(EditorText.t("应用", "Apply"), action: applyPitch)
                }
            }
            Picker(EditorText.t("时值", "Duration"), selection: Binding(get: { note.type }, set: { updateDuration(type: $0, dots: note.dots) })) {
                ForEach(ScorePanelActions.durationTypes, id: \.self) { type in Text(ScorePanelActions.durationName(type)).tag(type) }
            }
            Picker(EditorText.t("附点", "Dots"), selection: Binding(get: { note.dots }, set: { updateDuration(type: note.type, dots: $0) })) {
                ForEach(0...3, id: \.self) { Text(String($0)).tag($0) }
            }
            Picker(EditorText.t("声部", "Voice"), selection: Binding(get: { note.voice }, set: { value in
                controller.runCommand("score.edit.update", arguments: .object(["voice": .number(Double(value))]))
            })) {
                ForEach(1...64, id: \.self) { Text(String($0)).tag($0) }
            }
            Picker(EditorText.t("谱表", "Staff"), selection: Binding(get: { note.staff }, set: { value in
                controller.runCommand("score.edit.update", arguments: .object(["staff": .number(Double(value))]))
            })) {
                ForEach(1...snapshot.staves, id: \.self) { Text(String($0)).tag($0) }
            }
            Button(EditorText.t("更多音符属性", "More note properties")) { controller.showCommand("score.edit.update", preset: note.preset) }
        }
        .onAppear { pitchDraft = note.rest ? "C4" : note.pitch }
        .onChange(of: note.id) { _, _ in pitchDraft = note.rest ? "C4" : note.pitch }
        .onChange(of: note.pitch) { _, value in if !pitchFocused { pitchDraft = value } }
    }
    private func applyPitch() {
        controller.runCommand("score.edit.update", arguments: .object(["pitch": .string(pitchDraft)]))
    }
    private func updateDuration(type: String, dots: Int) {
        controller.runCommand("score.edit.update", arguments: .object(["type": .string(type), "dots": .number(Double(dots)),
            "actual": .number(note.actual), "normal": .number(note.normal)]))
    }
}

@MainActor private struct ScoreNativePartMix: View {
    let controller: HeavyEditorController
    let part: ScorePartRow
    @State private var adjustingVolume = false
    @State private var volumeDraft = 1.0
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Toggle(EditorText.t("独奏", "Solo"), isOn: Binding(get: { part.solo }, set: { ScorePanelActions.mix(controller, part, "solo", .bool($0)) }))
                Toggle(EditorText.t("静音", "Mute"), isOn: Binding(get: { part.mute }, set: { ScorePanelActions.mix(controller, part, "mute", .bool($0)) }))
            }.toggleStyle(.button)
            HStack {
                Image(systemName: "speaker.wave.1")
                Slider(value: Binding(get: { adjustingVolume ? volumeDraft : part.volume }, set: { volumeDraft = $0 }), in: 0...1) { editing in
                    if editing { volumeDraft = part.volume; adjustingVolume = true }
                    else { adjustingVolume = false; ScorePanelActions.mix(controller, part, "volume", .number(volumeDraft)) }
                }.accessibilityLabel(EditorText.t("音量", "Volume"))
                Text("\(Int((adjustingVolume ? volumeDraft : part.volume) * 100))%").font(.caption).monospacedDigit()
            }
        }
    }
}

@MainActor struct ScoreNativeBottomBar: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    var body: some View {
        VStack(spacing: 0) {
            ScoreNativeTransport(controller: controller)
            if snapshot.keyboardVisible {
                Divider()
                if snapshot.staffSign == "percussion" { ScoreNativeDrumEntry(controller: controller) }
                else if snapshot.notation == "jianpu", snapshot.numbered["supported"].scoreFlag { ScoreNativeNumberedEntry(controller: controller) }
                else if snapshot.staffSign == "TAB" { ScoreNativeTabEntry(controller: controller) }
                else { ScoreNativePiano(controller: controller) }
            }
        }.accessibilityIdentifier("score.native.playback")
    }
}

@MainActor private struct ScoreNativeTabEntry: View {
    let controller: HeavyEditorController
    @State private var string = 1
    @State private var fret = 0
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Picker(EditorText.t("弦", "String"), selection: $string) { ForEach(1...snapshot.stringCount, id: \.self) { Text("\($0)").tag($0) } }
                    .accessibilityIdentifier("score.native.tab.string")
                Stepper(EditorText.t("品位", "Fret") + " · \(fret)", value: $fret, in: 0...36).frame(minWidth: 150, minHeight: 44)
                    .accessibilityIdentifier("score.native.tab.fret")
                Button(EditorText.t("输入音符", "Enter note"), systemImage: "plus") {
                    var arguments: [String: EditorJSON] = ["part":.string(snapshot.partID),"measure":.string(snapshot.measureID),"staff":.number(Double(snapshot.inputStaff)),"voice":.number(Double(snapshot.inputVoice)),"type":.string(snapshot.inputType),"dots":.number(Double(snapshot.inputDots)),"mode":.string(snapshot.entryMode),"string":.number(Double(string)),"fret":.number(Double(fret))]
                    arguments["rest"] = .bool(false)
                    controller.runCommand("score.edit.tabInsert", arguments: .object(arguments))
                }.frame(minHeight: 44).accessibilityIdentifier("score.native.tab.enter")
                Button(EditorText.t("调弦与变调夹", "Tuning & capo")) {
                    let pitches = snapshot.staffDetails["tuning"].array.compactMap { $0.number }.map { ScorePanelActions.pitchName(Int($0)) }.joined(separator: " ")
                    controller.showCommand("score.parts.tuning", preset: .object(["part":.string(snapshot.partID),"measure":.string(snapshot.measureID),"staff":.number(Double(snapshot.inputStaff)),"tuning":.string(pitches),"capo":snapshot.staffDetails["capo"]]))
                }.frame(minHeight: 44)
            }.padding(.horizontal, 10)
        }.accessibilityIdentifier("score.native.tab.entry")
            .onChange(of: snapshot.stringCount) { _, count in string = min(string, count) }
    }
}
@MainActor private struct ScoreNativeDrumEntry: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    private var drums: [(Int,String)] { [(36,EditorText.t("底鼓","Kick")),(38,EditorText.t("军鼓","Snare")),(42,EditorText.t("闭镲","Closed hat")),(46,EditorText.t("开镲","Open hat")),(45,EditorText.t("低嗵","Low tom")),(48,EditorText.t("高嗵","High tom")),(49,EditorText.t("吊镲","Crash")),(51,EditorText.t("叮叮镲","Ride"))] }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(drums, id: \.0) { pitch, title in
                    Button(title) { controller.runCommand("score.edit.percussionInsert", arguments: .object(["part":.string(snapshot.partID),"measure":.string(snapshot.measureID),"staff":.number(Double(snapshot.inputStaff)),"voice":.number(Double(snapshot.inputVoice)),"type":.string(snapshot.inputType),"dots":.number(Double(snapshot.inputDots)),"mode":.string(snapshot.entryMode),"drum":.number(Double(pitch))])) }
                        .buttonStyle(.bordered).frame(minWidth: 56, minHeight: 44).accessibilityIdentifier("score.native.drum.\(pitch)")
                }
            }.padding(.horizontal, 10)
        }.accessibilityIdentifier("score.native.drum.entry")
    }
}

@MainActor private struct ScoreNativeTransport: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    @State private var seeking = false
    @State private var seekDraft = 0.0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let position = snapshot.position(at: timeline.date)
            let playing = snapshot.playing(at: timeline.date)
            HStack(spacing: 12) {
                Button {
                    controller.runCommand("score.playback.control", arguments: .object(["action": .string(playing ? "pause" : "start")]))
                } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .accessibilityLabel(playing ? EditorText.t("暂停", "Pause") : EditorText.t("播放", "Play"))
                Button {
                    controller.runCommand("score.playback.control", arguments: .object(["action": .string("stop")]))
                } label: { Image(systemName: "stop.fill") }.accessibilityLabel(EditorText.t("停止", "Stop"))
                Text(Self.time(seeking ? seekDraft : position)).font(.caption).monospacedDigit()
                Slider(value: Binding(get: { seeking ? seekDraft : position }, set: { seekDraft = $0 }), in: 0...max(0.001, snapshot.transportDuration)) { editing in
                    if editing { seekDraft = position; seeking = true }
                    else { seeking = false; controller.runCommand("score.playback.control", arguments: .object(["action": .string("seek"), "position": .number(seekDraft)])) }
                }.disabled(snapshot.transportDuration <= 0).accessibilityLabel(EditorText.t("播放位置", "Playback position"))
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { scale in
                        Button("\(scale.formatted(.number.precision(.fractionLength(0...2))))×") { ScorePanelActions.playback(controller, snapshot, "tempoScale", .number(scale)) }
                    }
                    Divider()
                    Toggle(EditorText.t("循环", "Loop"), isOn: Binding(get: { snapshot.loop }, set: { ScorePanelActions.playback(controller, snapshot, "loop", .bool($0)) }))
                    Toggle(EditorText.t("节拍器", "Metronome"), isOn: Binding(get: { snapshot.metronome }, set: { ScorePanelActions.playback(controller, snapshot, "metronome", .bool($0)) }))
                    Button(EditorText.t("速度与循环范围", "Tempo & loop range")) { controller.showCommand("score.playback.settings") }
                } label: {
                    Label("\(snapshot.tempoScale.formatted(.number.precision(.fractionLength(0...2))))×", systemImage: snapshot.loop ? "repeat" : "metronome")
                }
                Button {
                    controller.runCommand("score.ui.view", arguments: .object(["keyboardVisible": .bool(!snapshot.keyboardVisible)]))
                } label: { Image(systemName: "pianokeys") }
                .accessibilityLabel(snapshot.keyboardVisible ? EditorText.t("隐藏键盘", "Hide keyboard") : EditorText.t("显示键盘", "Show keyboard"))
            }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
    private static func time(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

@MainActor private struct ScoreNativeNumberedEntry: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(snapshot.numbered["key"].scoreText()).font(.subheadline.weight(.semibold))
                Picker(EditorText.t("主音八度", "Tonic octave"), selection: Binding(get: { snapshot.inputOctave }, set: {
                    ScorePanelActions.input(controller, "octave", .number(Double($0)))
                })) {
                    ForEach(0...8, id: \.self) { Text(String($0)).tag($0) }
                }.frame(width: 105)
                Picker(EditorText.t("升降", "Accidental"), selection: Binding(get: { snapshot.numberAlter }, set: {
                    ScorePanelActions.input(controller, "numberAlter", .number(Double($0)))
                })) {
                    Text("♭").tag(-1); Text(EditorText.t("本调", "Key")).tag(0); Text("♯").tag(1)
                }.pickerStyle(.segmented).frame(width: 132)
                Button { ScorePanelActions.enter(controller, snapshot, rest: true) } label: {
                    Text("0").font(.title3.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.bordered).accessibilityLabel(EditorText.t("输入休止符", "Enter rest"))
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach(Array(snapshot.numbered["keys"].array.enumerated()), id: \.offset) { _, key in
                    let degree = Int(key["degree"].scoreNumber())
                    Button { ScorePanelActions.enter(controller, snapshot, spelledPitch: key["pitch"].scoreText(), rest: false) } label: {
                        VStack(spacing: 1) {
                            Text(String(degree)).font(.title3.weight(.semibold))
                            Text(key["pitch"].scoreText()).font(.caption2).foregroundStyle(.secondary)
                        }.frame(minWidth: 44, maxWidth: .infinity, minHeight: 48)
                    }.accessibilityLabel(EditorText.t("输入 \(degree)，\(key["pitch"].scoreText())", "Enter \(degree), \(key["pitch"].scoreText())"))
                        .accessibilityIdentifier("score.native.number." + String(degree))
                }
            }.buttonStyle(.bordered)
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .accessibilityIdentifier("score.native.numberedInput")
    }
}

@MainActor private struct ScoreNativePiano: View {
    let controller: HeavyEditorController
    private var snapshot: ScorePanelSnapshot { ScorePanelSnapshot(value: controller.presentation) }
    private let keyWidth: CGFloat = 42
    private let blackWidth: CGFloat = 28
    private func black(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }
    var body: some View {
        let first = max(0, min(92, snapshot.inputOctave * 12))
        let pitches = Array(first...min(127, first + 35))
        let whites = pitches.filter { !black($0) }
        HStack(spacing: 10) {
            Picker(EditorText.t("八度", "Octave"), selection: Binding(get: { snapshot.inputOctave }, set: { ScorePanelActions.input(controller, "octave", .number(Double($0))) })) {
                ForEach(1...7, id: \.self) { octave in Text("C\(octave)").tag(octave) }
            }.pickerStyle(.menu).fixedSize()
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 1) {
                        ForEach(whites, id: \.self) { pitch in
                            Button { ScorePanelActions.enter(controller, snapshot, pitch: pitch) } label: {
                                VStack { Spacer(); Text(ScorePanelActions.pitchName(pitch)).font(.caption2).padding(.bottom, 6) }
                                    .frame(width: keyWidth, height: 86).background(Color.white).foregroundStyle(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.6)))
                            }.buttonStyle(.plain).accessibilityLabel(ScorePanelActions.pitchName(pitch))
                        }
                    }
                    ForEach(pitches.filter { black($0) }, id: \.self) { pitch in
                        let before = whites.filter { $0 < pitch }.count
                        Button { ScorePanelActions.enter(controller, snapshot, pitch: pitch) } label: {
                            VStack { Spacer(); Text(ScorePanelActions.pitchName(pitch)).font(.system(size: 9)).padding(.bottom, 5) }
                                .frame(width: blackWidth, height: 54).background(Color.black).foregroundStyle(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).accessibilityLabel(ScorePanelActions.pitchName(pitch))
                        .offset(x: CGFloat(before) * (keyWidth + 1) - blackWidth / 2 - 0.5)
                    }
                }.frame(width: CGFloat(whites.count) * (keyWidth + 1) - 1, height: 88)
            }.scrollIndicators(.hidden)
        }.padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityIdentifier("score.native.piano")
    }
}
