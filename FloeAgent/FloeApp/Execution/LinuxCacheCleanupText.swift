// FloeApp — concise bilingual copy for the Linux-only cache-cleanup entry.
// These strings describe what the app actually does; they never claim that a
// model or provider ran when the bundled script handled the task.

import Foundation
import FloeCore
import FloeExecution
import FloeModels

enum LinuxCacheCleanupText {
    static func t(_ zh: String, _ en: String) -> String {
        FloeL10n.bilingual(chinese: zh, english: en)
    }

    static var title: String { FloeL10n.l("app.linux_cache_cleanup_text.clean_linux_cache") }
    static var entryTitle: String { FloeL10n.l("app.linux_cache_cleanup_text.clean_linux_environment_cache") }
    static var entryDetail: String {
        FloeL10n.l("app.linux_cache_cleanup_text.check_caches_used_by_linux")
    }
    static var sectionFooter: String {
        FloeL10n.l("app.linux_cache_cleanup_text.when_no_model_is_available")
    }
    static var starting: String { FloeL10n.l("app.linux_cache_cleanup_text.creating_cleanup_task") }
    static var prepareFailed: String {
        FloeL10n.l("app.linux_cache_cleanup_text.could_not_create_the_cleanup")
    }

    static var fallbackStarted: String {
        FloeL10n.l("app.linux_cache_cleanup_text.no_tool_capable_model_is")
    }

    static func fallbackCompleted(_ receipt: LinuxCacheCleanupReceipt) -> String {
        var lines: [String] = []
        if receipt.mode == "clean" {
            lines.append(FloeL10n.l("app.linux_cache_cleanup_text.the_built_in_cleanup_finished"))
        } else {
            lines.append(FloeL10n.l("app.linux_cache_cleanup_text.only_the_cache_inspection_completed"))
        }
        lines.append(spaceLine(receipt))
        lines.append(contentsOf: categoryLines(receipt))
        if receipt.partial {
            lines.append(FloeL10n.l("app.linux_cache_cleanup_text.some_categories_were_partial_or"))
        }
        if let note = receipt.repairGuidance ?? receipt.error, !note.isEmpty {
            lines.append(FloeL10n.l("app.linux_cache_cleanup_text.environment_note") + note)
        }
        lines.append(outerSpaceNote)
        return lines.joined(separator: "\n")
    }

    static func fallbackFailed(_ receipt: LinuxCacheCleanupReceipt) -> String {
        var lines: [String] = []
        lines.append(FloeL10n.l("app.linux_cache_cleanup_text.the_bundled_linux_cleanup_script"))
        if let error = receipt.error, !error.isEmpty {
            lines.append(FloeL10n.l("app.linux_cache_cleanup_text.reason") + error)
        }
        if let repair = receipt.repairGuidance {
            lines.append(FloeL10n.l("app.linux_cache_cleanup_text.environment_note") + repair)
        }
        lines.append(spaceLine(receipt))
        lines.append(contentsOf: categoryLines(receipt))
        lines.append(outerSpaceNote)
        return lines.joined(separator: "\n")
    }

    static func fallbackCancelled(_ receipt: LinuxCacheCleanupReceipt) -> String {
        var lines: [String] = []
        lines.append(FloeL10n.l("app.linux_cache_cleanup_text.stop_was_requested_for_the"))
        if !receipt.state.isEmpty { lines.append(FloeL10n.l("app.linux_cache_cleanup_text.job_state") + receipt.state) }
        lines.append(spaceLine(receipt))
        lines.append(contentsOf: categoryLines(receipt))
        lines.append(outerSpaceNote)
        return lines.joined(separator: "\n")
    }

    static func fallbackNeedsInspection(_ receipt: LinuxCacheCleanupReceipt) -> String {
        FloeL10n.l("app.linux_cache_cleanup_text.the_previous_linux_cleanup_job")
    }

    static func fallbackReusedElsewhere(_ receipt: LinuxCacheCleanupReceipt) -> String {
        FloeL10n.l("app.linux_cache_cleanup_text.another_cleanup_task_is_already")
    }

    static func failureMessage(_ error: Error) -> String {
        let reason = LinuxCacheCleanupEnvironmentRepair.guidance(for: error)
            ?? FloeL10n.l("app.linux_cache_cleanup_text.open_settings_execution_environments_inspect")
        return FloeL10n.l("app.linux_cache_cleanup_text.the_cleanup_task_could_not")
            + "\n" + reason
    }

    private static var outerSpaceNote: String {
        FloeL10n.l("app.linux_cache_cleanup_text.for_device_storage_open_data")
    }

    private static func spaceLine(_ receipt: LinuxCacheCleanupReceipt) -> String {
        let before = receipt.dfAvailableBeforeBytes.map(bytes) ?? FloeL10n.l("app.linux_cache_cleanup_text.unknown")
        let after = receipt.dfAvailableAfterBytes.map(bytes) ?? FloeL10n.l("app.linux_cache_cleanup_text.unknown")
        let sharedMount = receipt.dfPath == "/floe/env" || receipt.dfPath == "/workspace"
        let label = sharedMount
            ? FloeL10n.l("app.linux_cache_cleanup_text.shared_folder_volume")
            : FloeL10n.l("app.linux_cache_cleanup_text.linux_system_disk")
        if receipt.mode == "inspect" {
            return label + FloeL10n.l("app.linux_cache_cleanup_text.free_space") + before
        }
        return label + FloeL10n.l("app.linux_cache_cleanup_text.free_space_before_cleanup")
            + before
            + FloeL10n.l("app.linux_cache_cleanup_text.after_cleanup")
            + after
    }

    private static func categoryLines(_ receipt: LinuxCacheCleanupReceipt) -> [String] {
        guard !receipt.categoryResults.isEmpty else {
            return [FloeL10n.l("app.linux_cache_cleanup_text.no_per_category_detail_was")]
        }
        return receipt.categoryResults.map { item in
            var text = "\(item.category): \(statusText(item.status))"
            if let before = item.bytesBefore, let after = item.bytesAfter {
                text += " · \(bytes(before)) → \(bytes(after))"
            }
            if let note = item.note, note != "none", !note.isEmpty {
                text += " · " + (note == "ownership_unverified"
                    ? FloeL10n.l("app.linux_cache_cleanup_text.ownership_unverified") : note)
            }
            return "• " + text
        }
    }

    private static func statusText(_ raw: String) -> String {
        switch raw {
        case "cleaned": return FloeL10n.l("app.linux_cache_cleanup_text.cleaned")
        case "observed": return FloeL10n.l("app.linux_cache_cleanup_text.inspected")
        case "retained": return FloeL10n.l("app.linux_cache_cleanup_text.retained_ownership_unverified")
        case "partial": return FloeL10n.l("app.linux_cache_cleanup_text.partial")
        case "failed": return FloeL10n.l("app.linux_cache_cleanup_text.failed")
        case "skipped-busy": return FloeL10n.l("app.linux_cache_cleanup_text.skipped_busy")
        case "skipped-missing": return FloeL10n.l("app.linux_cache_cleanup_text.skipped_missing")
        case "skipped-symlink": return FloeL10n.l("app.linux_cache_cleanup_text.skipped_symlink")
        case "skipped-escaped": return FloeL10n.l("app.linux_cache_cleanup_text.skipped_escaped_root")
        case "skipped-unresolved": return FloeL10n.l("app.linux_cache_cleanup_text.skipped_unresolved")
        case "skipped-unsearchable": return FloeL10n.l("app.linux_cache_cleanup_text.skipped_unsearchable")
        default: return raw
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}
