// FloeApp — concise bilingual copy for the Linux-only cache-cleanup entry.
// These strings describe what the app actually does; they never claim that a
// model or provider ran when the bundled script handled the task.

import Foundation
import FloeCore
import FloeExecution
import FloeModels

enum LinuxCacheCleanupText {
    static func t(_ zh: String, _ en: String) -> String {
        FloeL10n.isChinese ? zh : en
    }

    static var title: String { t("清理 Linux 缓存", "Clean Linux cache") }
    static var entryTitle: String { t("清理 Linux 环境缓存", "Clean Linux environment cache") }
    static var entryDetail: String {
        t("打开清理任务，保留文件与已安装软件。",
          "Open a cleanup task while keeping files and installed software.")
    }
    static var sectionFooter: String {
        t("没有可用模型时，自动使用内置清理方式。",
          "Uses built-in cleanup when no model is available.")
    }
    static var starting: String { t("正在创建清理任务…", "Creating cleanup task…") }
    static var prepareFailed: String {
        t("无法创建清理任务：", "Could not create the cleanup task: ")
    }

    static var fallbackStarted: String {
        t("未配置工具模型，正在使用内置方式清理 Linux 缓存。",
          "No tool-capable model is configured. Cleaning Linux caches with the built-in routine.")
    }

    static func fallbackCompleted(_ receipt: LinuxCacheCleanupReceipt) -> String {
        var lines: [String] = []
        lines.append(t("内置 Linux 清理脚本已完成（未使用模型）。",
                       "The bundled Linux cleanup script finished (no model was used)."))
        lines.append(spaceLine(receipt))
        lines.append(contentsOf: categoryLines(receipt))
        if receipt.partial {
            lines.append(t("部分类别未完成或被跳过；请查看上面的实际状态。",
                           "Some categories were partial or skipped; see the actual statuses above."))
        }
        if let note = receipt.repairGuidance ?? receipt.error, !note.isEmpty {
            lines.append(t("环境提示：", "Environment note: ") + note)
        }
        lines.append(outerSpaceNote)
        return lines.joined(separator: "\n")
    }

    static func fallbackFailed(_ receipt: LinuxCacheCleanupReceipt) -> String {
        var lines: [String] = []
        lines.append(t("内置 Linux 清理脚本未能完成。", "The bundled Linux cleanup script did not complete."))
        if let error = receipt.error, !error.isEmpty {
            lines.append(t("原因：", "Reason: ") + error)
        }
        if let repair = receipt.repairGuidance {
            lines.append(t("环境提示：", "Environment note: ") + repair)
        }
        lines.append(spaceLine(receipt))
        lines.append(contentsOf: categoryLines(receipt))
        lines.append(outerSpaceNote)
        return lines.joined(separator: "\n")
    }

    static func fallbackCancelled(_ receipt: LinuxCacheCleanupReceipt) -> String {
        var lines: [String] = []
        lines.append(t("已请求停止内置 Linux 清理脚本；实际状态如下。",
                       "Stop was requested for the bundled Linux cleanup script; its actual state is below."))
        if !receipt.state.isEmpty { lines.append(t("任务状态：", "Job state: ") + receipt.state) }
        lines.append(spaceLine(receipt))
        lines.append(contentsOf: categoryLines(receipt))
        lines.append(outerSpaceNote)
        return lines.joined(separator: "\n")
    }

    static func fallbackNeedsInspection(_ receipt: LinuxCacheCleanupReceipt) -> String {
        t("上一次 Linux 清理任务的结果未知或未完成。请先查看该任务的实际结果，确认后再决定是否重试；本次没有自动重放。",
          "The previous Linux cleanup job has an unknown or incomplete outcome. Inspect its actual result before deciding whether to retry; this call did not replay it.")
    }

    static func fallbackReusedElsewhere(_ receipt: LinuxCacheCleanupReceipt) -> String {
        t("另一个清理任务已经在同一个 Linux 环境中运行；本次没有重复启动。请等待该任务结束，或在原任务中停止它。",
          "Another cleanup task is already running in the same Linux environment; no duplicate was started. Wait for it to finish, or stop it in its owning task.")
    }

    static func failureMessage(_ error: Error) -> String {
        let reason = LinuxCacheCleanupEnvironmentRepair.guidance(for: error)
            ?? t("请打开 设置 → 执行环境，检查或修复共享 Linux 环境后重试。",
                 "Open Settings > Execution Environments, inspect or repair the shared Linux environment, then retry.")
        return t("清理任务未能启动。", "The cleanup task could not start.")
            + "\n" + reason
    }

    private static var outerSpaceNote: String {
        t("说明：上面是 Linux 客户机内的可用空间，不等于 iPad 物理空间；删除客户机文件可能不会让外层磁盘占用立即变小。",
          "Note: the numbers above are free space inside the Linux guest, not iPad physical storage. Deleting guest files may not shrink the outer disk immediately.")
    }

    private static func spaceLine(_ receipt: LinuxCacheCleanupReceipt) -> String {
        let before = receipt.dfAvailableBeforeBytes.map(bytes) ?? t("未知", "unknown")
        let after = receipt.dfAvailableAfterBytes.map(bytes) ?? t("未知", "unknown")
        return t("Linux 客户机可用空间：清理前 ", "Linux guest available space: ")
            + before
            + t("，清理后 ", " before, ")
            + after
            + "."
    }

    private static func categoryLines(_ receipt: LinuxCacheCleanupReceipt) -> [String] {
        guard !receipt.categoryResults.isEmpty else {
            return [t("没有返回类别明细。", "No per-category detail was returned.")]
        }
        return receipt.categoryResults.map { item in
            var text = "\(item.category): \(statusText(item.status))"
            if let before = item.bytesBefore, let after = item.bytesAfter {
                text += " · \(bytes(before)) → \(bytes(after))"
            }
            if let note = item.note, note != "none", !note.isEmpty {
                text += " · " + (note == "ownership_unverified"
                    ? t("归属未确认", "ownership unverified") : note)
            }
            return "• " + text
        }
    }

    private static func statusText(_ raw: String) -> String {
        switch raw {
        case "cleaned": return t("已清理", "cleaned")
        case "observed": return t("已检查", "inspected")
        case "retained": return t("已保留（归属未确认）", "retained (ownership unverified)")
        case "partial": return t("部分完成", "partial")
        case "failed": return t("失败", "failed")
        case "skipped-busy": return t("跳过（忙碌）", "skipped (busy)")
        case "skipped-missing": return t("跳过（不存在）", "skipped (missing)")
        case "skipped-symlink": return t("跳过（符号链接）", "skipped (symlink)")
        case "skipped-escaped": return t("跳过（路径越界）", "skipped (escaped root)")
        case "skipped-unresolved": return t("跳过（无法解析）", "skipped (unresolved)")
        case "skipped-unsearchable": return t("跳过（无法检查）", "skipped (unsearchable)")
        default: return raw
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}
