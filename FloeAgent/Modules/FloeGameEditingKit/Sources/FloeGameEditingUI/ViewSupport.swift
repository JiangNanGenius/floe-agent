// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

#if canImport(UIKit)
import UIKit
public typealias EditPlatformImage = UIImage
#else
import AppKit
public typealias EditPlatformImage = NSImage
#endif

public enum EditImageDecoder {
    public static func image(_ bytes: Data) -> EditPlatformImage? {
        #if canImport(UIKit)
        UIImage(data: bytes)
        #else
        NSImage(data: bytes)
        #endif
    }
}

private struct GameEditLocaleKey: EnvironmentKey {
    static let defaultValue: GameEditLocale = GameEditLocale.host
}

extension EnvironmentValues {
    public var gameEditLocale: GameEditLocale {
        get { self[GameEditLocaleKey.self] }
        set { self[GameEditLocaleKey.self] = newValue }
    }
}

/// Changes the structure from the actual editor width, including iPad windows.
/// Accessibility text sizes keep one clear reading column.
public struct GameEditorAdaptive<Expanded: View, Compact: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private let expanded: (CGFloat) -> Expanded
    private let compact: () -> Compact

    public init(@ViewBuilder expanded: @escaping (CGFloat) -> Expanded,
                @ViewBuilder compact: @escaping () -> Compact) {
        self.expanded = expanded; self.compact = compact
    }

    public var body: some View {
        GeometryReader { geometry in
            if expands(at: geometry.size.width) { expanded(geometry.size.width) }
            else { compact() }
        }
    }

    private func expands(at width: CGFloat) -> Bool {
        #if os(iOS)
        guard sizeClass != .compact else { return false }
        #endif
        return width >= 800 && !typeSize.isAccessibilitySize
    }
}

public enum GameEditorSurfaces {
    public static var sidebar: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

/// Bilingual text resolved from the environment locale.
public struct EditText: View {
    let copy: GameEditCopy
    @Environment(\.gameEditLocale) private var locale
    public init(_ copy: GameEditCopy) { self.copy = copy }
    public var body: some View { Text(copy.text(locale)) }
}

/// A tappable control meeting the 44pt minimum target.
public struct EditButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action; self.label = label()
    }
    public var body: some View {
        Button(action: action) { label }
            .frame(minWidth: 44, minHeight: 44)
    }
}

public struct ByteImage: View {
    public let bytes: Data
    public var body: some View {
        Group {
            if let image = EditImageDecoder.image(bytes) {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().interpolation(.none)
                #else
                Image(nsImage: image).resizable().interpolation(.none)
                #endif
            } else {
                Image(systemName: "doc")
            }
        }
    }
}

extension GameEditCopy {
    public static let save = GameEditCopy("Save", "保存")
    public static let undo = GameEditCopy("Undo", "撤销")
    public static let redo = GameEditCopy("Redo", "重做")
    public static let close = GameEditCopy("Close", "关闭")
    public static let cancel = GameEditCopy("Cancel", "取消")
    public static let recover = GameEditCopy("Recover", "恢复")
    public static let discard = GameEditCopy("Discard", "丢弃")
    public static let deleted = GameEditCopy("Delete", "删除")
    public static let rename = GameEditCopy("Rename", "重命名")
    public static let importAction = GameEditCopy("Import", "导入")
    public static let replace = GameEditCopy("Replace", "替换")
    public static let references = GameEditCopy("References", "引用")
    public static let addAsset = GameEditCopy("Add Asset", "添加素材")
    public static let importProject = GameEditCopy("Import Project…", "导入项目…")
    public static let unsavedDraftTitle = GameEditCopy("Unsaved draft", "未保存草稿")
    public static let editingIssueTitle = GameEditCopy("Editing issue", "编辑问题")
}
