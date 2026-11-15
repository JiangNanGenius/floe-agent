// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore

/// User-visible problem with the original file left untouched. The editor
/// never substitutes a blank image or a detached save when decoding fails.
public struct SpriteEditorIssue: Error, Hashable, Sendable {
    public let title: GameEditCopy
    public let diagnostics: [GameEditDiagnostic]

    public init(title: GameEditCopy, diagnostics: [GameEditDiagnostic]) {
        self.title = title
        self.diagnostics = diagnostics
    }

    public func message(_ locale: GameEditLocale) -> String {
        diagnostics.map { $0.message.text(locale) }.joined(separator: "\n")
    }

    public static func make(_ error: Error, path: GameRelativePath? = nil) -> SpriteEditorIssue {
        if let issue = error as? SpriteEditorIssue { return issue }
        if let issue = error as? GameEditIssue {
            return SpriteEditorIssue(
                title: GameEditCopy("Could not complete the edit", "无法完成编辑"),
                diagnostics: issue.diagnostics)
        }
        if let error = error as? SpritePNGError {
            return SpriteEditorIssue(
                title: GameEditCopy("PNG unavailable", "PNG 无法使用"),
                diagnostics: [diagnostic(pngCopy(error), path: path)])
        }
        if let error = error as? SpriteSheetError {
            return SpriteEditorIssue(
                title: GameEditCopy("Frame grid not available", "帧网格不可用"),
                diagnostics: [diagnostic(error.copy, path: path)])
        }
        if let error = error as? SpriteAnimationError {
            let copy: GameEditCopy
            switch error {
            case .emptySequence:
                copy = GameEditCopy("There are no frames to animate.",
                                    "没有可播放的帧。")
            case .invalidFrameRate(let rate):
                let formatted = String(format: "%.1f", rate)
                copy = GameEditCopy("Animation speed \(formatted) fps is outside 1–30 fps.",
                                    "动画速度 \(formatted) fps 超出 1–30 fps 范围。")
            }
            return SpriteEditorIssue(
                title: GameEditCopy("Animation unavailable", "动画无法播放"),
                diagnostics: [diagnostic(copy, path: path)])
        }
        if let error = error as? SpritePixelError {
            return SpriteEditorIssue(
                title: GameEditCopy("Pixels could not be edited", "像素编辑失败"),
                diagnostics: [diagnostic(pixelCopy(error), path: path)])
        }
        return SpriteEditorIssue(
            title: GameEditCopy("Could not open this image", "无法打开此图片"),
            diagnostics: [diagnostic(GameEditCopy(
                "The original file is kept. Open it in the IDE or ask AI to inspect it.",
                "原文件已保留。可在 IDE 中打开，或让 AI 检查。"), path: path)])
    }

    private static func diagnostic(_ copy: GameEditCopy, path: GameRelativePath?) -> GameEditDiagnostic {
        GameEditDiagnostic(severity: .error, message: copy, path: path)
    }

    private static func pngCopy(_ error: SpritePNGError) -> GameEditCopy {
        switch error {
        case .emptyData:
            return GameEditCopy("The PNG file is empty.", "此 PNG 文件为空。")
        case .encodedBytesExceeded(let bytes):
            return GameEditCopy("The PNG is \(bytes) bytes, larger than the editing limit.",
                                "此 PNG 为 \(bytes) 字节，超过编辑上限。")
        case .dimensionsExceeded(let width, let height):
            return GameEditCopy("The image is \(width) × \(height), outside the safe editing limit.",
                                "图片尺寸为 \(width) × \(height)，超出安全编辑上限。")
        case .invalidPNG:
            return GameEditCopy("The file is not a readable PNG. The original file is kept.",
                                "此文件不是可读取的 PNG，原文件已保留。")
        case .unsupportedBitDepth(let bits):
            return GameEditCopy("This PNG uses \(bits)-bit components. Only 8-bit PNG editing is supported; the original file is kept.",
                                "此 PNG 使用 \(bits) 位分量。仅支持 8 位 PNG 编辑，原文件已保留。")
        case .truncated:
            return GameEditCopy("The PNG is incomplete or truncated. The original file is kept.",
                                "此 PNG 不完整或被截断，原文件已保留。")
        case .encodeFailed:
            return GameEditCopy("The edited pixels could not be encoded as PNG. The original file is kept.",
                                "编辑后的像素无法编码为 PNG，原文件已保留。")
        case .roundtripMismatch:
            return GameEditCopy("The PNG did not preserve every pixel exactly, so the edit was discarded.",
                                "PNG 未能逐像素完整保留，因此已放弃本次修改。")
        }
    }

    private static func pixelCopy(_ error: SpritePixelError) -> GameEditCopy {
        switch error {
        case .invalidDimensions(let width, let height):
            return GameEditCopy("The image size \(width) × \(height) is not valid.",
                                "图片尺寸 \(width) × \(height) 无效。")
        case .dimensionLimitExceeded:
            return GameEditCopy("The image is too large for bounded in-memory editing.",
                                "图片过大，超出内存编辑上限。")
        case .pixelCountMismatch(let expected, let actual):
            return GameEditCopy("The pixel buffer has \(actual) bytes instead of \(expected).",
                                "像素缓冲区为 \(actual) 字节，应为 \(expected) 字节。")
        case .invalidCrop:
            return GameEditCopy("The selected frame is outside the image.",
                                "所选帧超出图片范围。")
        }
    }
}
