import Foundation
import AppKit
import FloeMacMediaCore
import FloeToolboxUtilities

/// Bilingual copy for the candidate surfaces. English and Simplified Chinese
/// stay aligned; diagnostics never become user-visible copy.
func macToolboxText(_ zh: String, _ en: String, _ locale: Locale) -> String {
    locale.language.languageCode?.identifier == "zh" ? zh : en
}

enum MacPrivacyPane: String {
    case microphone = "Privacy_Microphone"
    case camera = "Privacy_Camera"
}

@MainActor
func macOpenPrivacySettings(_ pane: MacPrivacyPane) {
    let raw = "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
    guard let url = URL(string: raw) else { return }
    NSWorkspace.shared.open(url)
}

func macMediaFailureText(_ failure: MacMediaFailure, _ locale: Locale) -> String {
    switch failure {
    case .notAuthorized:
        macToolboxText("需要授权。允许访问后重新开始。", "Access is not allowed. Allow access, then start again.", locale)
    case .noDevice:
        macToolboxText("未找到可用设备。连接设备后重试。", "No device is available. Connect one and retry.", locale)
    case .deviceBusy:
        macToolboxText("设备正被其他窗口或应用使用。", "The device is in use by another window or app.", locale)
    case .invalidFormat:
        macToolboxText("设备格式不可用，请更换输入设备后重试。", "The device format is unavailable. Try a different input device.", locale)
    case .mediaServicesReset:
        macToolboxText("音频设备已更改或被断开，测量已停止。", "The audio device changed or disconnected, so measurement stopped.", locale)
    case .engine:
        macToolboxText("设备启动失败。检查连接后重试。", "The device could not start. Check the connection and retry.", locale)
    case .captureFailed:
        macToolboxText("采集失败，请重试。", "Capture failed. Try again.", locale)
    case .pageLimit:
        macToolboxText("最多保留 24 页。请先移除页面或导出。", "Up to 24 pages are kept. Remove a page or export first.", locale)
    case .fileTooLarge:
        macToolboxText("图片超过可读取大小或像素上限。", "The image exceeds the readable size or pixel limit.", locale)
    case .fileNotRegular:
        macToolboxText("请选择普通图片文件。", "Choose a regular image file.", locale)
    case .fileIsSymbolicLink:
        macToolboxText("不支持符号链接，请选择实际图片文件。", "Symbolic links are not supported. Choose the real image file.", locale)
    case .unreadable:
        macToolboxText("无法读取该图片。", "The image could not be read.", locale)
    case .emptyExport:
        macToolboxText("没有可导出的内容。", "There is nothing to export yet.", locale)
    case .exportTooLarge:
        macToolboxText("导出内容超过大小上限。", "The export exceeds the size limit.", locale)
    case .writeFailed(let reason) where reason == "destination-exists":
        macToolboxText("该文件已存在，请选择新的文件名。", "That file already exists. Choose a new filename.", locale)
    case .writeFailed:
        macToolboxText("无法写入所选位置，请选择其他位置。", "The chosen location could not be written. Choose another location.", locale)
    }
}

func macScanNoticeText(_ notice: MacScanNotice, _ locale: Locale) -> String {
    switch notice {
    case .recognized(let count):
        macToolboxText("已识别 \(count) 条内容。", "Recognized \(count) items.", locale)
    case .noResults:
        macToolboxText("未识别到条码、二维码或文字。", "No barcode, QR code, or text was recognized.", locale)
    case .resultsTruncated:
        macToolboxText("结果已达 64 条上限，仅保留较新的结果。", "The 64-result limit was reached; newer results are kept.", locale)
    case .pageAdded(let count):
        macToolboxText("已加入第 \(count) 页。", "Page \(count) added.", locale)
    case .pagesTruncated(let dropped):
        macToolboxText("有 \(dropped) 页超出上限，导出的文档不含这些页。", "\(dropped) pages exceeded the limit and are not part of the export.", locale)
    case .pagesComplete(let count):
        macToolboxText("已完成 \(count) 页的文字识别。", "Text recognition finished for \(count) pages.", locale)
    case .pageRemoved:
        macToolboxText("已移除该页；如需文字导出请重新识别。", "Page removed. Run recognition again for a text export.", locale)
    case .cleared:
        macToolboxText("已清空本次扫描。", "This scan was cleared.", locale)
    }
}

func macResultKindText(_ kind: OpticsScanItem.Kind, _ locale: Locale) -> String {
    switch kind {
    case .qrCode: macToolboxText("二维码", "QR code", locale)
    case .barcode: macToolboxText("条码", "Barcode", locale)
    case .text: macToolboxText("文字", "Text", locale)
    }
}
