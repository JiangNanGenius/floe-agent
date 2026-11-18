import AppKit
import Combine
import SwiftUI
import FloeToolboxCore
import FloeToolboxUtilities

@MainActor
final class MacCalculatorModel: ObservableObject {
    @Published var expression = "" {
        didSet { if expression != oldValue { result = nil; failure = nil } }
    }
    @Published var angleMode: EverydayCalculator.AngleMode = .degrees {
        didSet { if angleMode != oldValue { result = nil; failure = nil } }
    }
    @Published private(set) var result: Double?
    @Published private(set) var failure: String?
    @Published private(set) var history: [EverydayCalculatorHistoryEntry] = []
    @Published private(set) var historyFailure: String?
    @Published private(set) var canRecoverHistory = false
    @Published private(set) var recoveringHistory = false
    @Published private(set) var historyBackupCreated = false
    var store: EverydayCalculatorHistoryStore { historyCoordinator.store }
    private let historyCoordinator: MacCalculatorHistoryCoordinator
    private var recoverySubscription: AnyCancellable?

    init(store: EverydayCalculatorHistoryStore) {
        self.historyCoordinator = MacCalculatorHistoryCoordinator(store: store)
        observeRecovery()
    }

    init(historyCoordinator: MacCalculatorHistoryCoordinator) {
        self.historyCoordinator = historyCoordinator
        observeRecovery()
    }

    private func observeRecovery() {
        recoverySubscription = historyCoordinator.$recoveryRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.loadHistory() }
        }
    }

    func loadHistory() async {
        guard historyCoordinator.ensureOwnership() else {
            historyFailure = "history ownership"
            return
        }
        let observedStore = store
        do {
            let entries = try await observedStore.load()
            guard observedStore === store else { return }
            history = entries
            if historyCoordinator.hasPendingRecovery {
                historyFailure = "history recovery"
                canRecoverHistory = true
                recoveringHistory = historyCoordinator.recoveryInProgress
            } else {
                historyFailure = nil
                canRecoverHistory = false
                recoveringHistory = false
            }
        } catch is CancellationError {
        } catch ToolboxError.corruptStore {
            guard observedStore === store else { return }
            historyFailure = "history corrupt"
            canRecoverHistory = true
            recoveringHistory = historyCoordinator.recoveryInProgress
        } catch ToolboxError.limit(_) {
            guard observedStore === store else { return }
            historyFailure = "history corrupt"
            canRecoverHistory = true
            recoveringHistory = historyCoordinator.recoveryInProgress
        } catch {
            guard observedStore === store else { return }
            historyFailure = "history load"
            recoveringHistory = historyCoordinator.recoveryInProgress
        }
    }

    func retryHistoryOwnership() async {
        historyCoordinator.retryOwnership()
        await loadHistory()
    }

    func append(_ token: String) {
        guard expression.utf8.count + token.utf8.count <= 512 else { return }
        expression += token
    }

    func deleteLast() {
        guard !expression.isEmpty else { return }
        expression.removeLast()
    }

    func clear() {
        expression = ""
        result = nil
        failure = nil
    }

    func useEntry(_ entry: EverydayCalculatorHistoryEntry) {
        expression = entry.expression
        evaluate()
    }

    func clearHistory() {
        guard !canRecoverHistory, !recoveringHistory else { return }
        let accepted = historyCoordinator.enqueue({ store in
                _ = try await store.load()
                try await store.removeAll()
                return []
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let entries):
                history = entries
                historyFailure = nil
            case .failure(let error):
                historyFailure = "history clear"
                noteRecoverableArchive(error)
            }
        }
        if !accepted { historyFailure = historyCoordinator.storageUnavailable ? "history ownership" : "history clear" }
    }

    private func noteRecoverableArchive(_ error: any Error) {
        guard let error = error as? ToolboxError else { return }
        switch error {
        case .corruptStore, .limit(_): canRecoverHistory = true
        default: break
        }
    }

    func recoverHistory() {
        guard canRecoverHistory, !recoveringHistory else { return }
        recoveringHistory = true
        let accepted = historyCoordinator.recoverCorruptHistory { [weak self] result in
            guard let self else { return }
            self.recoveringHistory = false
            switch result {
            case .success:
                self.canRecoverHistory = false
                self.historyFailure = nil
                self.historyBackupCreated = true
            case .failure:
                self.historyFailure = "history recovery"
            }
        }
        if !accepted {
            recoveringHistory = false
            historyFailure = "history recovery"
        }
    }

    func evaluate() {
        let frozen = expression
        guard !frozen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = nil
            failure = "empty expression"
            return
        }
        let canonical = EverydayNumberText.canonical(frozen)
        do {
            let value = try EverydayCalculator.evaluate(canonical, angleMode: angleMode)
            result = value
            failure = nil
            let text = EverydayNumberText.calculatorString(for: value)
            let entry = EverydayCalculatorHistoryEntry(expression: canonical, result: text)
            let accepted = historyCoordinator.enqueue({ store in
                try await store.add(entry)
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let entries):
                    self.history = entries
                    self.historyFailure = nil
                case .failure(let error):
                    self.historyFailure = "history save"
                    self.noteRecoverableArchive(error)
                }
            }
            if accepted {
                history.insert(entry, at: 0)
                if history.count > store.maximumCount { history = Array(history.prefix(store.maximumCount)) }
            } else {
                historyFailure = historyCoordinator.storageUnavailable ? "history ownership" : "history save"
            }
        } catch let error as ToolboxError {
            result = nil
            switch error {
            case .invalid(let message): failure = message
            case .limit(let message): failure = message
            default: failure = "calculator syntax"
            }
        } catch {
            result = nil
            failure = "calculator syntax"
        }
    }
}

private enum MacCalculatorPanel: String, CaseIterable, Identifiable {
    case calculator, converter
    var id: String { rawValue }
}

struct MacCalculatorToolView: View {
    @Environment(\.locale) private var locale
    @StateObject private var model: MacCalculatorModel
    @State private var panel: MacCalculatorPanel = .calculator
    @State private var copiedResult = false

    init(store: EverydayCalculatorHistoryStore) {
        _model = StateObject(wrappedValue: MacCalculatorModel(store: store))
    }

    init(historyCoordinator: MacCalculatorHistoryCoordinator) {
        _model = StateObject(wrappedValue: MacCalculatorModel(historyCoordinator: historyCoordinator))
    }

    private func t(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, locale)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(t("面板", "Panel"), selection: $panel) {
                Text(t("计算器", "Calculator")).tag(MacCalculatorPanel.calculator)
                Text(t("单位换算", "Unit converter")).tag(MacCalculatorPanel.converter)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.vertical, 10)
            .accessibilityIdentifier("mac.toolbox.calculator.panel")
            if panel == .calculator {
                calculatorLayout
            } else {
                MacUnitConverterPanel()
            }
        }
        .task { await model.loadHistory() }
    }

    private var calculatorLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            calculatorPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            historyPane
                .frame(width: 300)
        }
    }

    private var calculatorPane: some View {
        ScrollView {
            VStack(spacing: 14) {
                display
                Picker(t("角度单位", "Angle unit"), selection: $model.angleMode) {
                    Text("DEG").tag(EverydayCalculator.AngleMode.degrees)
                    Text("RAD").tag(EverydayCalculator.AngleMode.radians)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .accessibilityIdentifier("mac.toolbox.calculator.angle")
                pad
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    private var display: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(t("输入算式", "Enter an expression"), text: $model.expression, axis: .vertical)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.title3, design: .monospaced))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit { model.evaluate() }
                    .accessibilityIdentifier("mac.toolbox.calculator.expression")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                if let failure = model.failure {
                    Label(failureText(failure), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if let result = model.result {
                    Text(EverydayNumberText.calculatorString(for: result, locale: locale))
                        .font(.system(.largeTitle, design: .monospaced))
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .minimumScaleFactor(0.4)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("mac.toolbox.calculator.result")
                } else {
                    Text("0")
                        .font(.system(.largeTitle, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    if let result = model.result {
                        copy(EverydayNumberText.calculatorString(for: result, locale: locale))
                        copiedResult = true
                    }
                } label: {
                    Image(systemName: copiedResult ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(model.result == nil)
                .accessibilityLabel(t("复制结果", "Copy result"))
                .accessibilityIdentifier("mac.toolbox.calculator.copy")
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: model.result) { _, _ in copiedResult = false }
    }

    private var pad: some View {
        let rows: [[MacPadKey]] = [
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
                Label(t("计算", "Calculate"), systemImage: "equal")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("mac.toolbox.calculator.evaluate")
        }
    }

    private func padButton(_ key: MacPadKey) -> some View {
        Button {
            switch key {
            case .clear: model.clear()
            case .delete: model.deleteLast()
            case .toggleSign: toggleSignOfLastNumber()
            case .digit(let text), .symbol(let text), .constant(let text, _), .suffix(let text, _):
                model.append(text)
            case .function(let text, _): model.append(text)
            }
        } label: {
            Text(key.label)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(key.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .foregroundStyle(key.tint)
        .accessibilityLabel(key.accessibilityLabel(locale))
        .accessibilityIdentifier("mac.toolbox.calculator.key.\(key.identifier)")
    }

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

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(t("历史记录", "History"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if !model.history.isEmpty {
                    Button(t("清空", "Clear"), systemImage: "trash") {
                        model.clearHistory()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(t("清空历史记录", "Clear history"))
                    .accessibilityIdentifier("mac.toolbox.calculator.history.clear")
                    .disabled(model.canRecoverHistory || model.recoveringHistory)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if let failure = model.historyFailure {
                Label(historyFailureText(failure), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("mac.toolbox.calculator.history.error")
            }
            if model.canRecoverHistory {
                Button(t("备份并恢复历史", "Back up and restore history")) {
                    model.recoverHistory()
                }
                .disabled(model.recoveringHistory)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("mac.toolbox.calculator.history.recover")
            } else if model.historyFailure == "history ownership" {
                Button(t("重试", "Try again")) {
                    Task { await model.retryHistoryOwnership() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("mac.toolbox.calculator.history.retry")
            } else if model.historyBackupCreated {
                Text(t("损坏的历史记录已备份。", "The damaged history has been backed up."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if model.history.isEmpty {
                ContentUnavailableView(t("暂无历史记录", "No history yet"),
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text(t("计算结果会保存在这里，点按可重新使用。",
                                                           "Results appear here. Select one to reuse it.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(t("历史记录不保存角度单位；选择后会按当前 DEG/RAD 重新计算。",
                       "History doesn't save the angle mode; selecting an entry recalculates it using the current DEG/RAD setting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                List(model.history) { entry in
                    Button {
                        model.useEntry(entry)
                    } label: {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(entry.expression)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Spacer(minLength: 4)
                                Text("= " + entry.result)
                                    .font(.body.monospaced())
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.left")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(t("复制", "Copy")) {
                            copy(entry.expression + " = " + entry.result)
                        }
                    }
                    .accessibilityIdentifier("mac.toolbox.calculator.history.row")
                }
                .listStyle(.plain)
                .accessibilityIdentifier("mac.toolbox.calculator.history.list")
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func failureText(_ failure: String) -> String {
        switch failure {
        case "empty expression": t("请输入算式", "Enter an expression")
        case "division by zero": t("不能除以 0", "Cannot divide by zero")
        case "outside the function domain": t("超出函数定义域", "Outside the function domain")
        case "number overflow": t("数值超出可显示范围", "Number out of range")
        case "calculator history", "calculator history entry": t("历史记录无法保存", "History could not be saved")
        case "calculator syntax": t("算式格式有误，请检查括号与符号", "The expression has a syntax error")
        default: t("无法计算，请修改算式", "Unable to compute. Edit the expression")
        }
    }

    private func historyFailureText(_ failure: String) -> String {
        switch failure {
        case "history corrupt":
            t("历史文件无法读取。请先备份并恢复历史。",
              "History could not be read. Back it up and restore history to continue.")
        case "history load":
            t("历史记录读取失败，本次计算仍可正常使用。",
              "History could not be loaded. The calculator still works for this session.")
        case "history save":
            t("历史记录保存失败，该结果仅保留在本次界面中。",
              "History could not be saved. This result is kept in this session only.")
        case "history clear":
            t("历史记录清除失败，请重试。", "History could not be cleared. Try again.")
        case "history recovery":
            t("历史记录恢复失败，请检查存储位置并重试。", "History could not be restored. Check storage and try again.")
        case "history ownership":
            t("历史记录正在其他 Floe 窗口中使用，或无法读取恢复位置。", "History is in use by another Floe window, or its recovery location cannot be read.")
        default:
            t("历史记录暂不可用", "History is temporarily unavailable")
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum MacPadKey: Hashable {
    case digit(String), symbol(String), clear, delete, toggleSign
    case function(String, String), constant(String, String), suffix(String, String)

    var label: String {
        switch self {
        case .digit(let text), .symbol(let text): text
        case .clear: "C"
        case .delete: "\u{232B}"
        case .toggleSign: "\u{00B1}"
        case .function(_, let label), .constant(_, let label), .suffix(_, let label): label
        }
    }

    var identifier: String {
        switch self {
        case .digit(let text), .symbol(let text): text
        case .clear: "clear"
        case .delete: "delete"
        case .toggleSign: "sign"
        case .function(let text, _), .constant(let text, _), .suffix(let text, _): text
        }
    }

    var tint: Color {
        switch self {
        case .digit, .constant: .primary
        case .symbol, .function, .suffix, .toggleSign: .blue
        case .clear, .delete: .red
        }
    }

    func accessibilityLabel(_ locale: Locale) -> String {
        switch self {
        case .clear: MacToolboxText.t("清除", "Clear", locale)
        case .delete: MacToolboxText.t("删除一位", "Delete last digit", locale)
        case .toggleSign: MacToolboxText.t("正负号切换", "Toggle sign", locale)
        case .symbol(let text): text
        case .function(_, let label), .constant(_, let label), .suffix(_, let label): label
        case .digit(let text): text
        }
    }
}

private struct MacUnitConverterPanel: View {
    @Environment(\.locale) private var locale
    @State private var category: EverydayUnitCategory = .length
    @State private var source = EverydayUnitConverter.units(for: .length)[0]
    @State private var target = EverydayUnitConverter.units(for: .length)[1]
    @State private var input = "1"
    @State private var precision = 2
    @State private var copied = false

    private func t(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, locale)
    }

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
        ScrollView {
            VStack(spacing: 18) {
                Picker(t("类别", "Category"), selection: categorySelection) {
                    ForEach(EverydayUnitCategory.allCases) { value in
                        Text(categoryName(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("mac.toolbox.converter.category")

                HStack(alignment: .center, spacing: 12) {
                    unitPicker(t("从", "From"), selection: $source, identifier: "mac.toolbox.converter.from")
                    Button {
                        swap(&source, &target)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(t("交换单位", "Swap units"))
                    .accessibilityIdentifier("mac.toolbox.converter.swap")
                    unitPicker(t("到", "To"), selection: $target, identifier: "mac.toolbox.converter.to")
                }
                .frame(maxWidth: 620)

                HStack(spacing: 16) {
                    LabeledContent(t("数值", "Value")) {
                        TextField(t("数值", "Value"), text: $input)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .accessibilityIdentifier("mac.toolbox.converter.input")
                    }
                    Stepper(value: $precision, in: 0...6) {
                        Text(t("小数位 \(precision)", "\(precision) decimals"))
                    }
                    .accessibilityIdentifier("mac.toolbox.converter.precision")
                    Spacer()
                }
                .frame(maxWidth: 620)

                conversionResult
                    .frame(maxWidth: 620)
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private func unitPicker(_ title: String, selection: Binding<EverydayUnit>, identifier: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(units) { unit in
                Text("\(unitName(unit)) (\(unit.symbol))").tag(unit)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var conversionResult: some View {
        switch result() {
        case .success(let value):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatted(value))
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mac.toolbox.converter.result")
                    Text(target.symbol)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copy(formatted(value))
                        copied = true
                    } label: {
                        Label(copied ? t("已复制", "Copied") : t("复制结果", "Copy result"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("mac.toolbox.converter.copy")
                }
                Text("\(formatted(numericInput() ?? 0)) \(source.symbol) = \(formatted(value)) \(target.symbol)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .onChange(of: value) { _, _ in copied = false }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        case .failure(let error):
            Label(conversionFailureText(error), systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("mac.toolbox.converter.error")
        }
    }

    private func conversionFailureText(_ error: ToolboxError) -> String {
        switch error {
        case .invalid(let message) where message == "below absolute zero":
            t("温度低于绝对零度", "Temperature is below absolute zero")
        case .invalid(let message) where message == "incompatible units":
            t("单位类别不一致", "Units belong to different categories")
        default:
            t("请输入有效数值", "Enter a valid number")
        }
    }

    private func numericInput() -> Double? {
        let canonical = EverydayNumberText.canonical(
            input.trimmingCharacters(in: .whitespacesAndNewlines),
            locale: locale
        )
        return Double(canonical)
    }

    private func result() -> Result<Double, ToolboxError> {
        guard let value = numericInput() else { return .failure(.invalid("unit value")) }
        do {
            return .success(try EverydayUnitConverter.convert(value, from: source, to: target))
        } catch let error as ToolboxError {
            return .failure(error)
        } catch {
            return .failure(.invalid("unit conversion"))
        }
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = precision
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value))
            ?? EverydayNumberText.calculatorString(for: value, locale: locale)
    }

    private func categoryName(_ category: EverydayUnitCategory) -> String {
        switch category {
        case .length: t("长度", "Length")
        case .area: t("面积", "Area")
        case .volume: t("体积", "Volume")
        case .temperature: t("温度", "Temperature")
        case .pressure: t("压力", "Pressure")
        case .mass: t("质量", "Mass")
        case .speed: t("速度", "Speed")
        }
    }

    private func unitName(_ unit: EverydayUnit) -> String {
        let names: [String: (String, String)] = [
            "mm": ("毫米", "Millimetres"), "cm": ("厘米", "Centimetres"), "m": ("米", "Metres"), "km": ("千米", "Kilometres"),
            "in": ("英寸", "Inches"), "ft": ("英尺", "Feet"), "yd": ("码", "Yards"), "mi": ("英里", "Miles"),
            "mm2": ("平方毫米", "Square millimetres"), "cm2": ("平方厘米", "Square centimetres"),
            "m2": ("平方米", "Square metres"), "km2": ("平方千米", "Square kilometres"),
            "ha": ("公顷", "Hectares"), "ft2": ("平方英尺", "Square feet"), "ac": ("英亩", "Acres"),
            "ml": ("毫升", "Millilitres"), "l": ("升", "Litres"), "cm3": ("立方厘米", "Cubic centimetres"),
            "m3": ("立方米", "Cubic metres"), "ft3": ("立方英尺", "Cubic feet"), "gal": ("加仑（美）", "Gallons (US)"),
            "c": ("摄氏度", "Celsius"), "f": ("华氏度", "Fahrenheit"), "k": ("开尔文", "Kelvin"),
            "pa": ("帕斯卡", "Pascals"), "kpa": ("千帕", "Kilopascals"), "bar": ("巴", "Bar"),
            "atm": ("标准大气压", "Atmospheres"), "psi": ("磅/平方英寸", "Pounds per square inch"),
            "mmhg": ("毫米汞柱", "Millimetres of mercury"),
            "mg": ("毫克", "Milligrams"), "g": ("克", "Grams"), "kg": ("千克", "Kilograms"), "t": ("吨", "Tonnes"),
            "oz": ("盎司", "Ounces"), "lb": ("磅", "Pounds"),
            "ms": ("米/秒", "Metres per second"), "kmh": ("千米/时", "Kilometres per hour"),
            "mph": ("英里/时", "Miles per hour"), "kn": ("节", "Knots"), "fts": ("英尺/秒", "Feet per second"),
        ]
        guard let pair = names[unit.id] else { return unit.symbol }
        return t(pair.0, pair.1)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
