import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxUtilities
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The calculator evaluates only through the deterministic native parser in
// FloeToolboxUtilities; it registers no evaluation tool and runs no external
// code. History is a bounded local archive owned by this workbench.
@MainActor public final class EverydayCalculatorModel: ObservableObject {
    @Published public var expression = "" {
        didSet { if expression != oldValue { result = nil; failure = nil } }
    }
    @Published public private(set) var result: Double?
    @Published public private(set) var failure: String?
    @Published public var angleMode: EverydayCalculator.AngleMode = .degrees
    @Published public private(set) var history: [EverydayCalculatorHistoryEntry] = []
    /// Set when the local archive cannot be loaded, saved or cleared. The
    /// calculator keeps working from memory; the value is a stable identifier
    /// mapped to localized text by the view ("history load/save/clear/corrupt").
    @Published public private(set) var historyFailure: String?
    public let store: EverydayCalculatorHistoryStore

    public init(store: EverydayCalculatorHistoryStore = EverydayCalculatorModel.defaultStore) {
        self.store = store
    }

    public static let defaultStoreURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("FloeToolbox/Everyday/CalculatorHistory.json")
    }()
    /// All native windows serialize history mutations through the same actor.
    public static let defaultStore = EverydayCalculatorHistoryStore(url: defaultStoreURL)

    public func loadHistory() async {
        do {
            history = try await store.load()
            historyFailure = nil
        } catch is CancellationError {
        } catch ToolboxError.corruptStore {
            historyFailure = "history corrupt"
        } catch {
            historyFailure = "history load"
        }
    }

    public func append(_ token: String) {
        guard expression.utf8.count + token.utf8.count <= 512 else { return }
        expression += token
    }

    public func deleteLast() {
        guard !expression.isEmpty else { return }
        expression.removeLast()
    }

    public func clear() {
        expression = ""; result = nil; failure = nil
    }

    /// Reuse a history row: the expression is copied back verbatim and
    /// evaluated immediately with the current angle mode.
    public func useEntry(_ entry: EverydayCalculatorHistoryEntry) {
        expression = entry.expression
        evaluate()
    }

    public func clearHistory() {
        Task {
            do {
                try await store.removeAll()
                history = []
                historyFailure = nil
            } catch {
                historyFailure = "history clear"
            }
        }
    }

    public func evaluate() {
        let frozen = expression
        guard !frozen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = nil; failure = "empty expression"; return
        }
        let canonical = EverydayNumberText.canonical(frozen)
        do {
            let value = try EverydayCalculator.evaluate(canonical, angleMode: angleMode)
            result = value; failure = nil
            let text = EverydayNumberText.calculatorString(for: value)
            history.insert(EverydayCalculatorHistoryEntry(expression: canonical, result: text), at: 0)
            if history.count > store.maximumCount { history = Array(history.prefix(store.maximumCount)) }
            let entry = history[0]
            Task {
                do { try await self.store.add(entry); self.historyFailure = nil }
                catch { self.historyFailure = "history save" }
            }
        } catch let error as ToolboxError {
            result = nil
            switch error {
            case .invalid(let message): failure = message
            case .limit(let message): failure = message
            default: failure = "calculator syntax"
            }
        } catch {
            result = nil; failure = "calculator syntax"
        }
    }
}

private func everydayCopy(_ value: String) {
    #if os(iOS)
    UIPasteboard.general.string = value
    #elseif os(macOS)
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    #endif
}

private func calculatorFailureText(_ failure: String, _ locale: Locale) -> String {
    let zh = locale.language.languageCode?.identifier == "zh"
    switch failure {
    case "empty expression": return zh ? "请输入算式" : "Enter an expression"
    case "division by zero": return zh ? "不能除以 0" : "Cannot divide by zero"
    case "outside the function domain": return zh ? "超出函数定义域" : "Outside the function domain"
    case "number overflow": return zh ? "数值超出可显示范围" : "Number out of range"
    case "calculator history", "calculator history entry": return zh ? "历史记录无法保存" : "History could not be saved"
    case "calculator syntax": return zh ? "算式格式有误，请检查括号与符号" : "The expression has a syntax error"
    default: return zh ? "无法计算，请修改算式" : "Unable to compute. Edit the expression"
    }
}

private func historyFailureText(_ failure: String, _ locale: Locale) -> String {
    let zh = locale.language.languageCode?.identifier == "zh"
    switch failure {
    case "history corrupt":
        return zh ? "历史文件已损坏，原有数据未改动；可清空后重新开始。" : "The history file is corrupted. Existing data was left untouched; clear it to start over."
    case "history load":
        return zh ? "历史记录读取失败，本次计算仍可正常使用。" : "History could not be loaded. The calculator still works for this session."
    case "history save":
        return zh ? "历史记录保存失败，该结果仅保留在本次界面中。" : "History could not be saved. This result is kept in this session only."
    case "history clear":
        return zh ? "历史记录清除失败，请重试。" : "History could not be cleared. Try again."
    default:
        return zh ? "历史记录暂不可用" : "History is temporarily unavailable"
    }
}

public struct ToolboxCalculatorView: View {
    @StateObject private var model = EverydayCalculatorModel()
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var panel: Panel = .calculator
    @State private var copiedResult = false

    public init() {}

    private enum Panel: String, CaseIterable, Identifiable {
        case calculator, converter
        var id: String { rawValue }
    }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !dynamicTypeSize.isAccessibilitySize
            VStack(spacing: 0) {
                Picker(workbenchText("面板", "Panel", locale), selection: $panel) {
                    Text(workbenchText("计算器", "Calculator", locale)).tag(Panel.calculator)
                    Text(workbenchText("单位换算", "Unit converter", locale)).tag(Panel.converter)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                if panel == .calculator {
                    calculatorLayout(wide: wide)
                } else {
                    EverydayUnitConverterPanel().padding(16)
                }
            }
        }
        .navigationTitle(workbenchText("计算器", "Calculator", locale))
        .task { await model.loadHistory() }
    }

    @ViewBuilder private func calculatorLayout(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 0) {
                calculatorPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                historyPanel.frame(width: 300)
            }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    calculatorPanel
                    historyPanel
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    private var calculatorPanel: some View {
        VStack(spacing: 12) {
            display
            Picker(workbenchText("角度单位", "Angle unit", locale), selection: $model.angleMode) {
                Text("DEG").tag(EverydayCalculator.AngleMode.degrees)
                Text("RAD").tag(EverydayCalculator.AngleMode.radians)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            pad
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var display: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer(minLength: 8)
                TextField(workbenchText("输入算式", "Enter an expression", locale), text: $model.expression, axis: .vertical)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("toolbox.calculator.expression")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                if let failure = model.failure {
                    Label(calculatorFailureText(failure, locale), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                } else if let result = model.result {
                    Text(EverydayNumberText.calculatorString(for: result, locale: locale))
                        .font(.system(.largeTitle, design: .monospaced)).fontWeight(.medium)
                        .lineLimit(2).minimumScaleFactor(0.4).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("toolbox.calculator.result")
                } else {
                    Text("0").font(.system(.largeTitle, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Button {
                    if let result = model.result {
                        everydayCopy(EverydayNumberText.calculatorString(for: result, locale: locale)); copiedResult = true
                    }
                } label: { Image(systemName: copiedResult ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44) }
                .buttonStyle(.plain)
                .disabled(model.result == nil)
                .accessibilityLabel(workbenchText("复制结果", "Copy result", locale))
                .accessibilityIdentifier("toolbox.calculator.copy")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: model.result) { _, _ in copiedResult = false }
    }

    private var pad: some View {
        let rows: [[EverydayPadKey]] = [
            [.clear, .delete, .symbol("("), .symbol(")"), .symbol("^")],
            [.function("sin(", "sin"), .function("cos(", "cos"), .function("tan(", "tan"), .function("sqrt(", "√"), .constant("pi", "π")],
            [.function("ln(", "ln"), .function("log(", "log"), .suffix("^2", "x²"), .constant("e", "e"), .toggleSign],
            [.digit("7"), .digit("8"), .digit("9"), .symbol("\u{00F7}"), .symbol("\u{00D7}")],
            [.digit("4"), .digit("5"), .digit("6"), .symbol("+"), .symbol("\u{2212}")],
            [.digit("1"), .digit("2"), .digit("3"), .digit("0"), .symbol(".")],
        ]
        return VStack(spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in padButton(key) }
                }
            }
            Button {
                model.evaluate()
            } label: {
                Label(workbenchText("计算", "Calculate", locale), systemImage: "equal")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("toolbox.calculator.evaluate")
        }
    }

    private func padButton(_ key: EverydayPadKey) -> some View {
        Button {
            switch key {
            case .clear: model.clear()
            case .delete: model.deleteLast()
            case .toggleSign: toggleSignOfLastNumber()
            case .digit(let text), .symbol(let text), .constant(let text, _), .suffix(let text, _): model.append(text)
            case .function(let text, _): model.append(text)
            }
        } label: {
            Text(key.label)
                .font(.title3).frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(key.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(key.tint)
        .accessibilityLabel(key.accessibilityLabel(locale))
        .accessibilityIdentifier("toolbox.calculator.key.\(key.identifier)")
    }

    /// Flips the sign of the trailing number token; leaves exponents intact.
    private func toggleSignOfLastNumber() {
        let text = model.expression
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            let character = text[previous]
            if character.isNumber || character == "." { end = previous } else { break }
        }
        guard end < text.endIndex else { return }
        if end > text.startIndex, text[text.index(before: end)] == "-" {
            let minusIndex = text.index(before: end)
            let isExponentMinus = minusIndex > text.startIndex
                && (text[text.index(before: minusIndex)] == "e" || text[text.index(before: minusIndex)] == "E")
            if !isExponentMinus {
                model.expression.remove(at: minusIndex)
                return
            }
        }
        model.expression.insert("-", at: end)
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(workbenchText("历史记录", "History", locale), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if !model.history.isEmpty {
                    Button(workbenchText("清空", "Clear", locale), systemImage: "trash") { model.clearHistory() }
                        .font(.callout).labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("toolbox.calculator.history.clear")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if let failure = model.historyFailure {
                Label(historyFailureText(failure, locale), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .accessibilityIdentifier("toolbox.calculator.history.error")
            }
            if model.history.isEmpty {
                ContentUnavailableView(workbenchText("暂无历史记录", "No history yet", locale),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(workbenchText("计算结果会保存在这里，点按可重新使用。", "Results appear here. Tap one to reuse it.", locale)))
            } else {
                List(model.history) { entry in
                    Button { model.useEntry(entry) } label: {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(entry.expression).font(.callout.monospaced()).lineLimit(1)
                            HStack(spacing: 6) {
                                Spacer(minLength: 4)
                                Text("= " + entry.result).font(.body.monospaced()).fontWeight(.medium).lineLimit(1)
                                Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("toolbox.calculator.history.row")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(workbenchText("复制", "Copy", locale), systemImage: "doc.on.doc") {
                            everydayCopy(entry.expression + " = " + entry.result)
                        }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("toolbox.calculator.history.list")
            }
        }
        .background(Color.secondary.opacity(0.05))
    }
}

private enum EverydayPadKey: Hashable {
    case digit(String), symbol(String), clear, delete, toggleSign
    case function(String, String), constant(String, String), suffix(String, String)

    var label: String {
        switch self {
        case .digit(let text), .symbol(let text): return text
        case .clear: return "C"
        case .delete: return "\u{232B}"
        case .toggleSign: return "\u{00B1}"
        case .function(_, let label), .constant(_, let label), .suffix(_, let label): return label
        }
    }
    var identifier: String {
        switch self {
        case .digit(let text), .symbol(let text): return text
        case .clear: return "clear"
        case .delete: return "delete"
        case .toggleSign: return "sign"
        case .function(let text, _), .constant(let text, _), .suffix(let text, _): return text
        }
    }
    var tint: Color {
        switch self {
        case .digit, .constant: return .primary
        case .symbol, .function, .suffix, .toggleSign: return .blue
        case .clear, .delete: return .red
        }
    }
    func accessibilityLabel(_ locale: Locale) -> String {
        let zh = locale.language.languageCode?.identifier == "zh"
        switch self {
        case .clear: return zh ? "清除" : "Clear"
        case .delete: return zh ? "删除一位" : "Delete last digit"
        case .toggleSign: return zh ? "正负号切换" : "Toggle sign"
        case .symbol(let text): return text
        case .function(_, let label): return label
        case .constant(_, let label), .suffix(_, let label): return label
        case .digit(let text): return text
        }
    }
}

// MARK: - Unit conversion panel

private struct EverydayUnitConverterPanel: View {
    @Environment(\.locale) private var locale
    @State private var category: EverydayUnitCategory = .length
    @State private var source = EverydayUnitConverter.units(for: .length)[0]
    @State private var target = EverydayUnitConverter.units(for: .length)[1]
    @State private var input = "1"
    @State private var precision = 2
    @State private var copied = false

    private var units: [EverydayUnit] { EverydayUnitConverter.units(for: category) }

    private var categorySelection: Binding<EverydayUnitCategory> {
        Binding(get: { category }, set: { value in
            let choices = EverydayUnitConverter.units(for: value)
            source = choices[0]
            target = choices[min(1, choices.count - 1)]
            category = value
            copied = false
        })
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker(workbenchText("类别", "Category", locale), selection: categorySelection) {
                ForEach(EverydayUnitCategory.allCases) { value in
                    Text(categoryName(value, locale)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("toolbox.converter.category")

            HStack(alignment: .center, spacing: 12) {
                unitPicker(workbenchText("从", "From", locale), selection: $source, identifier: "toolbox.converter.from")
                Button {
                    swap(&source, &target)
                } label: {
                    Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(workbenchText("交换单位", "Swap units", locale))
                .accessibilityIdentifier("toolbox.converter.swap")
                unitPicker(workbenchText("到", "To", locale), selection: $target, identifier: "toolbox.converter.to")
            }

            HStack(spacing: 12) {
                LabeledContent(workbenchText("数值", "Value", locale)) {
                    TextField(workbenchText("数值", "Value", locale), text: $input)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityIdentifier("toolbox.converter.input")
                }
                Stepper(value: $precision, in: 0...6) {
                    Text(workbenchText("小数位 \(precision)", "\(precision) decimals", locale))
                }
                .accessibilityIdentifier("toolbox.converter.precision")
            }

            switch conversionResult() {
            case .success(let value):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(formatted(value)).font(.system(.title2, design: .monospaced)).fontWeight(.semibold)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("toolbox.converter.result")
                        Text(target.symbol).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            everydayCopy(formatted(value)); copied = true
                        } label: {
                            Label(copied ? workbenchText("已复制", "Copied", locale) : workbenchText("复制结果", "Copy result", locale),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("toolbox.converter.copy")
                    }
                    Text("\(formatted(numericInput() ?? 0)) \(source.symbol) = \(formatted(value)) \(target.symbol)")
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .onChange(of: value) { _, _ in copied = false }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            case .failure(let error):
                Label(conversionFailureText(error, locale), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("toolbox.converter.error")
            }
        }
    }

    private func unitPicker(_ title: String, selection: Binding<EverydayUnit>, identifier: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(units) { unit in
                Text("\(unitName(unit, locale)) (\(unit.symbol))").tag(unit)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(identifier)
    }

    private func numericInput() -> Double? {
        let canonical = EverydayNumberText.canonical(input.trimmingCharacters(in: .whitespacesAndNewlines), locale: locale)
        return Double(canonical)
    }

    private func conversionResult() -> Result<Double, ToolboxError> {
        guard let value = numericInput() else { return .failure(.invalid("unit value")) }
        do { return .success(try EverydayUnitConverter.convert(value, from: source, to: target)) }
        catch let error as ToolboxError { return .failure(error) }
        catch { return .failure(.invalid("unit conversion")) }
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = precision
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? EverydayNumberText.calculatorString(for: value, locale: locale)
    }

    private func conversionFailureText(_ error: ToolboxError, _ locale: Locale) -> String {
        let zh = locale.language.languageCode?.identifier == "zh"
        switch error {
        case .invalid(let message) where message == "below absolute zero":
            return zh ? "温度低于绝对零度" : "Temperature is below absolute zero"
        case .invalid(let message) where message == "incompatible units":
            return zh ? "单位类别不一致" : "Units belong to different categories"
        default:
            return zh ? "请输入有效数值" : "Enter a valid number"
        }
    }

    private func categoryName(_ category: EverydayUnitCategory, _ locale: Locale) -> String {
        let zh = locale.language.languageCode?.identifier == "zh"
        switch category {
        case .length: return zh ? "长度" : "Length"
        case .area: return zh ? "面积" : "Area"
        case .volume: return zh ? "体积" : "Volume"
        case .temperature: return zh ? "温度" : "Temperature"
        case .pressure: return zh ? "压力" : "Pressure"
        case .mass: return zh ? "质量" : "Mass"
        case .speed: return zh ? "速度" : "Speed"
        }
    }

    private func unitName(_ unit: EverydayUnit, _ locale: Locale) -> String {
        let zh = locale.language.languageCode?.identifier == "zh"
        let names: [String: (String, String)] = [
            "mm": ("毫米", "Millimetres"), "cm": ("厘米", "Centimetres"), "m": ("米", "Metres"), "km": ("千米", "Kilometres"),
            "in": ("英寸", "Inches"), "ft": ("英尺", "Feet"), "yd": ("码", "Yards"), "mi": ("英里", "Miles"),
            "mm2": ("平方毫米", "Square millimetres"), "cm2": ("平方厘米", "Square centimetres"), "m2": ("平方米", "Square metres"),
            "km2": ("平方千米", "Square kilometres"), "ha": ("公顷", "Hectares"), "ft2": ("平方英尺", "Square feet"), "ac": ("英亩", "Acres"),
            "ml": ("毫升", "Millilitres"), "l": ("升", "Litres"), "cm3": ("立方厘米", "Cubic centimetres"),
            "m3": ("立方米", "Cubic metres"), "ft3": ("立方英尺", "Cubic feet"), "gal": ("加仑（美）", "Gallons (US)"),
            "c": ("摄氏度", "Celsius"), "f": ("华氏度", "Fahrenheit"), "k": ("开尔文", "Kelvin"),
            "pa": ("帕斯卡", "Pascals"), "kpa": ("千帕", "Kilopascals"), "bar": ("巴", "Bar"), "atm": ("标准大气压", "Atmospheres"),
            "psi": ("磅/平方英寸", "Pounds per square inch"), "mmhg": ("毫米汞柱", "Millimetres of mercury"),
            "mg": ("毫克", "Milligrams"), "g": ("克", "Grams"), "kg": ("千克", "Kilograms"), "t": ("吨", "Tonnes"),
            "oz": ("盎司", "Ounces"), "lb": ("磅", "Pounds"),
            "ms": ("米/秒", "Metres per second"), "kmh": ("千米/时", "Kilometres per hour"), "mph": ("英里/时", "Miles per hour"),
            "kn": ("节", "Knots"), "fts": ("英尺/秒", "Feet per second"),
        ]
        guard let pair = names[unit.id] else { return unit.symbol }
        return zh ? pair.0 : pair.1
    }
}
