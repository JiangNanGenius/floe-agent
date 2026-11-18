import Foundation

/// Mac toolbox copy is shared with the existing Floe product vocabulary.
/// Keep English and Simplified Chinese aligned; do not add implementation
/// details to ordinary labels.
public enum MacToolboxText {
    public static func t(_ zh: String, _ en: String, _ locale: Locale) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }

    public static func windowTitle(_ locale: Locale) -> String {
        t("工具箱", "Toolbox", locale)
    }

    public static func utilities(_ locale: Locale) -> String {
        t("实用工具", "Utilities", locale)
    }
}

public enum MacToolboxTool: String, CaseIterable, Identifiable, Sendable {
    case hash, json, encoding, qr, calculator, timer, magnifier, scanner

    public var id: String { rawValue }

    public func title(_ locale: Locale) -> String {
        switch self {
        case .hash: MacToolboxText.t("文件校验", "File checksum", locale)
        case .json: MacToolboxText.t("JSON 格式化", "JSON formatter", locale)
        case .encoding: MacToolboxText.t("文本编码", "Text encoding", locale)
        case .qr: MacToolboxText.t("二维码", "QR code", locale)
        case .calculator: MacToolboxText.t("计算器", "Calculator", locale)
        case .timer: MacToolboxText.t("秒表与倒计时", "Stopwatch and timers", locale)
        case .magnifier: MacToolboxText.t("放大镜", "Magnifier", locale)
        case .scanner: MacToolboxText.t("扫描与识别", "Scanner", locale)
        }
    }

    public func shortTitle(_ locale: Locale) -> String {
        switch self {
        case .hash: MacToolboxText.t("校验", "Checksum", locale)
        case .json: "JSON"
        case .encoding: MacToolboxText.t("编码", "Encoding", locale)
        case .qr: MacToolboxText.t("二维码", "QR", locale)
        case .calculator: MacToolboxText.t("计算器", "Calculator", locale)
        case .timer: MacToolboxText.t("计时", "Timers", locale)
        case .magnifier: MacToolboxText.t("放大镜", "Magnifier", locale)
        case .scanner: MacToolboxText.t("扫描", "Scanner", locale)
        }
    }

    public var symbol: String {
        switch self {
        case .hash: "checkmark.seal"
        case .json: "curlybraces"
        case .encoding: "textformat.abc"
        case .qr: "qrcode"
        case .calculator: "plus.forwardslash.minus"
        case .timer: "timer"
        case .magnifier: "magnifyingglass"
        case .scanner: "doc.viewfinder"
        }
    }

    /// Mirrors ToolCatalog's utilities group for the first Mac batch.
    public static let firstMacBatch: [MacToolboxTool] = [.hash, .json, .encoding, .qr, .calculator]
    public static let mediaBatch: [MacToolboxTool] = [.magnifier, .scanner]
}
