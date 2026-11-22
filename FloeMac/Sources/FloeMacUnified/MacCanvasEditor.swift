// SPDX-License-Identifier: MPL-2.0
import FloeCore
import Foundation

/// One reversible board edit. The inverse closure receives the owning
/// library, captures only value snapshots (node, index, connections) and
/// applies the opposite mutation WITHOUT recording another undo entry, so an
/// undo never becomes redoable work. Entries are discarded when the selected
/// canvas changes; they are session-local exactly like the iPad kit's undo.
struct MacCanvasUndoEntry {
    let projectID: UUID
    let documentID: UUID
    let inverse: @MainActor (MacCreativeLibrary) throws -> Void
}

/// Bounded undo stack for the simple board. The bound keeps long editing
/// sessions from growing without limit; dropping the oldest entry is safe
/// because every entry is independently reversible.
struct MacCanvasUndoStack {
    private(set) var entries: [MacCanvasUndoEntry] = []
    let limit: Int

    init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !entries.isEmpty }

    mutating func push(_ entry: MacCanvasUndoEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    mutating func pop() -> MacCanvasUndoEntry? {
        entries.popLast()
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// Two-tap connector gesture state. The source node may be any node on the
/// page — endpoints do not modify node content, so read-only preserved nodes
/// can participate in a connection.
struct MacCanvasConnectSession {
    private(set) var sourceID: UUID?

    var isActive: Bool { sourceID != nil }

    mutating func begin(from id: UUID) {
        sourceID = id
    }

    mutating func cancel() {
        sourceID = nil
    }

    /// Returns the pending source when `targetID` is a valid partner
    /// (different node), and clears the session either way.
    mutating func complete(to targetID: UUID) -> UUID? {
        guard let source = sourceID, source != targetID else {
            sourceID = nil
            return nil
        }
        sourceID = nil
        return source
    }
}

/// English/Simplified-Chinese inline copy for the canvas board and the
/// generated-media routing buttons. Keys that already exist in the Mac string
/// tables stay at their call sites; everything new resolves here, following
/// the `MacVideoStrings` convention that ships copy with the file.
enum MacCanvasText {
    static var undo: String { t(en: "Undo", zh: "撤销") }
    static var connectFrom: String { t(en: "Connect From This Node", zh: "从此节点连接") }
    static var connectBanner: String { t(en: "Tap the node to connect to, or tap the source again to cancel.", zh: "点按要连接到的节点；再次点按起点可取消。") }
    static var connectCancel: String { t(en: "Cancel", zh: "取消") }
    static var removeConnection: String { t(en: "Remove Connection", zh: "移除连接") }
    static var readonlyLocked: String { t(en: "Locked · preserved for iPad", zh: "已锁定 · 为 iPad 保留") }
    static var readonlyGrouped: String { t(en: "In a group · preserved for iPad", zh: "成组成员 · 为 iPad 保留") }
    static var readonlyKind: String { t(en: "iPad content · read-only on Mac", zh: "iPad 内容 · Mac 上只读") }
    static var preservedPencil: String { t(en: "Includes an Apple Pencil drawing · preserved read-only", zh: "包含 Apple Pencil 手绘 · 已只读保留") }
    static func preservedStrokes(_ count: Int) -> String {
        t(en: "\(count) ink stroke\(count == 1 ? "" : "s") preserved read-only",
           zh: "\(count) 条手绘笔迹已只读保留")
    }
    static var readonlyEditDenied: String {
        t(en: "This content is read-only on Mac. Open it on iPad to edit.",
           zh: "该内容在 Mac 上为只读，请在 iPad 上编辑。")
    }
    /// Coordinator-provided route that publishes the generated file through
    /// the existing pinned file import and returns to that task.
    static var saveToTask: String { t(en: "Save to Task Files", zh: "保存到任务文件") }
    static var addToCanvas: String { t(en: "Add to Canvas", zh: "添加到画布") }
    static var routeFailed: String { t(en: "Couldn't route the file.", zh: "无法转发该文件。") }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
