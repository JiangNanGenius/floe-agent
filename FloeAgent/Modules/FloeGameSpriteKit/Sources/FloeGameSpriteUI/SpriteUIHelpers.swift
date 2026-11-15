// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import CoreGraphics
import FloeGameEditingCore
import FloeGameSpriteCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum SpriteUICopy {
    static let editorTitle = GameEditCopy("Sprite editor", "精灵编辑器")
    static let frames = GameEditCopy("Frames", "帧")
    static let tools = GameEditCopy("Tools", "工具")
    static let color = GameEditCopy("Color", "颜色")
    static let opacity = GameEditCopy("Opacity", "不透明度")
    static let brushSize = GameEditCopy("Brush size", "画笔大小")
    static let fingerDrawing = GameEditCopy("Finger drawing", "手指绘制")
    static let fingerDrawingHelp = GameEditCopy(
        "Off: finger moves the canvas and Apple Pencil draws. On: a finger also draws.",
        "关闭时：手指移动画布，Apple Pencil 绘制。开启后：手指也可绘制。")
    static let grid = GameEditCopy("Frame grid", "帧网格")
    static let preset = GameEditCopy("Preset", "预设")
    static let scope = GameEditCopy("Sheet layout", "图集布局")
    static let columns = GameEditCopy("Columns", "列数")
    static let rows = GameEditCopy("Rows", "行数")
    static let applyGrid = GameEditCopy("Apply grid", "应用网格")
    static let detectGrid = GameEditCopy("Detect common grid", "识别常见网格")
    static let frameSize = GameEditCopy("Frame size", "帧尺寸")
    static let imageSize = GameEditCopy("Image size", "图片尺寸")
    static let animation = GameEditCopy("Animation", "动画")
    static let speed = GameEditCopy("Speed", "速度")
    static let play = GameEditCopy("Play", "播放")
    static let stop = GameEditCopy("Stop", "停止")
    static let transform = GameEditCopy("Whole image", "整张图片")
    static let flipH = GameEditCopy("Flip horizontally", "水平翻转")
    static let flipV = GameEditCopy("Flip vertically", "垂直翻转")
    static let rotateLeft = GameEditCopy("Rotate counterclockwise", "逆时针旋转")
    static let rotateRight = GameEditCopy("Rotate clockwise", "顺时针旋转")
    static let fit = GameEditCopy("Fit", "适应")
    static let zoomIn = GameEditCopy("Zoom in", "放大")
    static let zoomOut = GameEditCopy("Zoom out", "缩小")
    static let edited = GameEditCopy("Edited", "已修改")
    static let loading = GameEditCopy("Opening PNG…", "正在打开 PNG…")
    static let noFrame = GameEditCopy("No frame selected", "未选择帧")
    static let oneFrame = GameEditCopy("This row has one frame.", "此帧行只有一帧。")
    static let rotateWarning = GameEditCopy(
        "Rotating turns the whole sheet. A preset grid becomes a custom grid when its dimensions no longer match.",
        "旋转会转动整张图集。若预设尺寸不再匹配，将改为自定义网格。")
    static let unsupported = GameEditCopy("PNG unavailable", "PNG 无法使用")
    static let customGridHelp = GameEditCopy(
        "The image must divide exactly. Pixels are never resized.",
        "图片必须能被整除，像素不会被缩放。")
    static let zoom = GameEditCopy("Zoom", "缩放")
    static let frame = GameEditCopy("Frame", "帧")
    static let character = GameEditCopy("Character", "角色")
    static let animationPreview = GameEditCopy("Frame preview", "帧预览")
    static let apply = GameEditCopy("Apply", "应用")
    static let cancel = GameEditCopy("Cancel", "取消")
    static let retry = GameEditCopy("Retry", "重试")
    static let current = GameEditCopy("Current", "当前")
    static let editHelp = GameEditCopy(
        "Save, undo and redo use the shared project toolbar. Every stroke is one project edit.",
        "保存、撤销和重做使用共享的项目工具栏。每次笔画都是一次项目编辑。")
}

enum SpriteColorBridge {
    static func color(_ rgba: SpriteRGBA) -> Color {
        Color(.sRGB,
              red: Double(rgba.red) / 255.0,
              green: Double(rgba.green) / 255.0,
              blue: Double(rgba.blue) / 255.0,
              opacity: Double(rgba.alpha) / 255.0)
    }

    static func rgba(_ color: Color) -> SpriteRGBA {
        #if canImport(UIKit)
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return SpriteRGBA(red: byte(red), green: byte(green),
                              blue: byte(blue), alpha: byte(alpha))
        }
        #elseif canImport(AppKit)
        if let resolved = NSColor(color).usingColorSpace(.sRGB) {
            return SpriteRGBA(red: byte(resolved.redComponent),
                              green: byte(resolved.greenComponent),
                              blue: byte(resolved.blueComponent),
                              alpha: byte(resolved.alphaComponent))
        }
        #endif
        return .black
    }

    private static func byte(_ value: CGFloat) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255.0).rounded())
    }
}

/// 12-point checkerboard used behind transparent frame previews.
struct SpriteCheckerboard: View {
    var square: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(.sRGB, white: 0.42, opacity: 1)))
            var path = Path()
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + column).isMultiple(of: 2) {
                        path.addRect(CGRect(x: x, y: y, width: square, height: square))
                    }
                    column += 1
                    x += square
                }
                row += 1
                y += square
            }
            context.fill(path, with: .color(Color(.sRGB, white: 0.62, opacity: 1)))
        }
        .accessibilityHidden(true)
    }
}

struct SpriteFrameThumbnail: View {
    let image: CGImage?
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            SpriteCheckerboard(square: 8)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary, lineWidth: 1))
    }
}
