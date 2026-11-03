// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeText
import com.floe.android.safgateway.SafPickerIntents
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * The user-reachable recovery review.
 *
 * Mounted once by the App shell beside the existing Office preview effect.
 * It renders ONLY the controller's measured projection: no path, URI or
 * exception text is shown. Every button maps to one explicit controller
 * action; opening the sheet performs no save, retry, restore or deletion.
 *
 * The CREATE_DOCUMENT picker is launched by THIS composition (foreground
 * only), exactly once per prepared request id, with the same system INTENT
 * the original Save-Copy flow uses. A late/foreign Activity result cannot
 * bind: the controller fences the exact request id.
 */
@Composable
internal fun OfficeRecoveryEffect(controller: OfficeRecoveryController) {
    val state by controller.state.collectAsState()
    val copy = androidx.compose.runtime.remember {
        RecoveryCopy(Locale.getDefault().language == "zh")
    }
    var issuedRequest by rememberSaveable { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        // Keep the issued id until the controller clears the matching launch:
        // a stale/foreign callback must never cause the CURRENT picker to be
        // relaunched a second time.
        val requestId = issuedRequest
        if (requestId != null) {
            controller.onPickerResult(
                requestId = requestId,
                resultCode = result.resultCode,
                uriString = result.data?.dataString,
                resultFlags = result.data?.flags ?: 0,
            )
        }
    }
    LaunchedEffect(state.launch?.requestId, issuedRequest) {
        val launch = state.launch ?: return@LaunchedEffect
        if (issuedRequest == launch.requestId) return@LaunchedEffect
        issuedRequest = launch.requestId
        val intent = SafPickerIntents.from(launch.spec)
        runCatching { picker.launch(intent) }.onFailure {
            controller.onPickerLaunchFailed(launch.requestId)
        }
    }

    val selected = state.selectedId?.let { id -> state.candidates.firstOrNull { it.id == id } }
    FloeActionSheet(
        visible = state.visible,
        onDismiss = controller::dismiss,
        maxCardWidth = 560.dp,
    ) {
        Column(
            Modifier
                .padding(20.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (selected != null) {
                RecoveryDetail(
                    view = selected,
                    state = state,
                    copy = copy,
                    onBack = controller::back,
                    onOpen = { controller.open(selected.id) },
                    onSaveCopy = { controller.saveCopy(selected.id) },
                    onCheckDestination = { controller.checkDestination(selected.id) },
                    onReauthorize = { controller.reauthorizeDestination(selected.id) },
                    onProbeOriginal = { controller.probeOriginal(selected.id) },
                    onDiscard = { controller.discard(selected.id) },
                )
            } else {
                RecoveryList(state = state, copy = copy, onSelect = controller::select)
            }
            state.message?.let { key ->
                copy.message(key)?.let { text ->
                    FloeText(text, color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
                }
            }
            if (state.busyId != null || state.launch != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeActivityIndicator()
                    Spacer(Modifier.width(10.dp))
                    FloeText(
                        if (state.launch != null) copy.waitingForTarget else copy.working,
                        color = Floe.colors.secondaryLabel,
                        style = Floe.typography.metadata,
                    )
                }
            }
            FloeCapsuleButton(
                label = if (selected != null) copy.done else copy.later,
                onClick = controller::dismiss,
            )
        }
    }
}

@Composable
private fun RecoveryList(
    state: OfficeRecoveryState,
    copy: RecoveryCopy,
    onSelect: (String) -> Unit,
) {
    FloeText(copy.title, style = Floe.typography.toolbarTitle)
    FloeText(copy.intro, color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
    if (state.loading) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeActivityIndicator()
            Spacer(Modifier.width(10.dp))
            FloeText(copy.loading, color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
        }
        return
    }
    if (state.candidates.isEmpty()) {
        FloeText(copy.empty, color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
        return
    }
    val ordered = state.candidates.sortedWith(
        compareByDescending<OfficeRecoveryView> { it.unresolved }.thenByDescending { it.updatedAtMillis },
    )
    ordered.forEach { view ->
        Column(
            Modifier
                .fillMaxWidth()
                .clickable { onSelect(view.id) }
                .padding(vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            FloeText(view.displayName, style = Floe.typography.body, maxLines = 1, overflow = TextOverflow.Ellipsis)
            FloeText(
                copy.phase(view),
                color = if (view.phase == OfficeRecoveryPhase.UNCERTAIN) {
                    Floe.colors.accent
                } else {
                    Floe.colors.secondaryLabel
                },
                style = Floe.typography.metadata,
            )
            FloeText(copy.updated(view.updatedAtMillis), color = Floe.colors.tertiaryLabel, style = Floe.typography.metadata)
            if (state.busyId == view.id || state.launch?.candidateId == view.id) {
                FloeText(copy.working, color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
            }
        }
        FloeDivider()
    }
}

@Composable
private fun RecoveryDetail(
    view: OfficeRecoveryView,
    state: OfficeRecoveryState,
    copy: RecoveryCopy,
    onBack: () -> Unit,
    onOpen: () -> Unit,
    onSaveCopy: () -> Unit,
    onCheckDestination: () -> Unit,
    onReauthorize: () -> Unit,
    onProbeOriginal: () -> Unit,
    onDiscard: () -> Unit,
) {
    FloeText(
        text = "‹ " + copy.back,
        color = Floe.colors.accent,
        style = Floe.typography.metadata,
        modifier = Modifier
            .clickable(onClick = onBack)
            .padding(vertical = 4.dp),
    )
    FloeText(view.displayName, style = Floe.typography.toolbarTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
    FloeText(copy.phase(view), color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
    FloeText(copy.updated(view.updatedAtMillis), color = Floe.colors.tertiaryLabel, style = Floe.typography.metadata)
    view.limitations.forEach { limitation ->
        FloeText(copy.limitation(limitation), color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
    }
    if (view.destinationVerified) {
        FloeText(copy.destinationVerified, color = Floe.colors.secondaryLabel, style = Floe.typography.metadata)
    }
    Spacer(Modifier.height(2.dp))
    FloeCapsuleButton(
        label = copy.open,
        onClick = onOpen,
        enabled = view.canOpen && state.busyId == null && state.launch == null,
        prominent = view.phase == OfficeRecoveryPhase.EDITING || view.phase == OfficeRecoveryPhase.CLOSED_UNSAVED,
    )
    FloeCapsuleButton(
        label = copy.saveCopy,
        onClick = onSaveCopy,
        enabled = view.canExport && state.busyId == null && state.launch == null,
        prominent = view.phase == OfficeRecoveryPhase.EXPORT_READY,
    )
    if (view.canCheckDestination) {
        FloeCapsuleButton(
            label = copy.checkDestination,
            onClick = onCheckDestination,
            enabled = state.busyId == null && state.launch == null,
        )
        FloeCapsuleButton(
            label = copy.reauthorize,
            onClick = onReauthorize,
            enabled = state.busyId == null && state.launch == null,
        )
    }
    if (view.canProbeOriginal) {
        FloeCapsuleButton(
            label = copy.checkOriginal,
            onClick = onProbeOriginal,
            enabled = state.busyId == null && state.launch == null,
        )
    }
    FloeCapsuleButton(
        label = copy.discard,
        onClick = onDiscard,
        enabled = view.canDiscard && state.busyId == null && state.launch == null,
    )
    FloeText(copy.discardHint, color = Floe.colors.tertiaryLabel, style = Floe.typography.metadata)
}

/**
 * Concise EN/ZH copy. Material limitations are stated plainly; internal
 * codes, paths, URIs and engine identifiers never appear here.
 */
private class RecoveryCopy(val zh: Boolean) {
    val title = if (zh) "恢复 Office 文档" else "Recover Office document"
    val intro = if (zh) {
        "这些副本没有确认保存完成。请选择要如何处理；应用不会自动覆盖、重试或删除你的文件。"
    } else {
        "These copies were not confirmed saved. Choose what to do; nothing is overwritten, retried or deleted automatically."
    }
    val loading = if (zh) "正在检查保留的副本…" else "Checking retained copies…"
    val empty = if (zh) "没有可恢复的文档。" else "No recoverable documents."
    val working = if (zh) "处理中…" else "Working…"
    val waitingForTarget = if (zh) "请选择保存位置…" else "Choose a save location…"
    val back = if (zh) "返回" else "Back"
    val done = if (zh) "完成" else "Done"
    val later = if (zh) "稍后" else "Later"
    val open = if (zh) "打开副本" else "Open copy"
    val saveCopy = if (zh) "另存副本" else "Save a copy"
    val checkDestination = if (zh) "检查目标文件" else "Check destination"
    val reauthorize = if (zh) "重新授权目标文件" else "Re-authorise destination"
    val checkOriginal = if (zh) "检查原文件" else "Check original"
    val discard = if (zh) "丢弃保留副本" else "Discard retained copy"
    val discardHint = if (zh) {
        "仅删除应用保留的工作副本和已校验副本，不会删除你选择的文件。"
    } else {
        "Deletes only the app's retained working copy and verified copy, never a file you chose."
    }
    val destinationVerified = if (zh) "目标文件已读取并校验。" else "The destination was read back and verified."

    fun updated(millis: Long): String {
        val formatted = runCatching {
            DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, Locale.getDefault())
                .format(Date(millis))
        }.getOrDefault("")
        return if (zh) "更新于 $formatted" else "Updated $formatted"
    }

    fun phase(view: OfficeRecoveryView): String = when (view.phase) {
        OfficeRecoveryPhase.EDITING -> if (zh) "尚未保存" else "Not saved yet"
        OfficeRecoveryPhase.EXPORT_READY -> if (zh) "已生成可保存的副本" else "A verified copy is ready to save"
        OfficeRecoveryPhase.TRANSFERRING -> if (zh) "保存可能已中断" else "A save may have been interrupted"
        OfficeRecoveryPhase.UNCERTAIN -> if (zh) "保存状态未知" else "Save status unknown"
        OfficeRecoveryPhase.SAVED -> if (zh) "已保存并校验" else "Saved and verified"
        OfficeRecoveryPhase.CLOSED_UNSAVED -> if (zh) "关闭时仍有未保存更改" else "Closed with unsaved changes"
        OfficeRecoveryPhase.CLOSED_CLEAN -> if (zh) "关闭时没有报告更改" else "Closed with no reported changes"
        OfficeRecoveryPhase.DISCARDED -> if (zh) "已丢弃" else "Discarded"
    }

    fun limitation(limitation: OfficeRecoveryLimitation): String = when (limitation) {
        OfficeRecoveryLimitation.ONLY_DISK_WRITTEN_BYTES -> if (zh) {
            "仅保留编辑器已写入磁盘的更改，副本可能早于最后一次屏幕状态。"
        } else {
            "Only changes the editor wrote to disk are kept; the copy may be older than the last screen."
        }
        OfficeRecoveryLimitation.WORKING_COPY_ONLY -> if (zh) {
            "只有工作副本，尚不等于完成的保存。"
        } else {
            "A working copy alone is not a completed save."
        }
        OfficeRecoveryLimitation.DESTINATION_UNCERTAIN -> if (zh) {
            "目标文件可能不完整。使用前请检查；应用不会自动重试。"
        } else {
            "The destination may be incomplete. Check it before use; it is not retried automatically."
        }
        OfficeRecoveryLimitation.NEVER_OVERWRITES_ORIGINAL -> if (zh) {
            "另存会创建新文件，绝不覆盖原文件。"
        } else {
            "Saving creates a new file and never overwrites the original."
        }
        OfficeRecoveryLimitation.ORIGINAL_CHANGED -> if (zh) {
            "打开副本后原文件已更改。另存会创建新文件。"
        } else {
            "The original changed after this copy was opened. Saving creates a new file."
        }
        OfficeRecoveryLimitation.ORIGINAL_UNAVAILABLE -> if (zh) {
            "无法检查原文件（访问已过期）。另存会创建新文件。"
        } else {
            "The original could not be checked (access expired). Saving creates a new file."
        }
        OfficeRecoveryLimitation.UNSAVED_AFTER_SAVE -> if (zh) {
            "此副本保存后又有未保存的更改。请打开保留副本并在 Office 中另存，以保留这些更改。"
        } else {
            "Changes were made after the verified copy. Open the retained copy and Save Copy to keep them."
        }
        OfficeRecoveryLimitation.MISSING_OR_CORRUPT -> if (zh) {
            "部分保留数据缺失或损坏，仅显示仍可用的部分。"
        } else {
            "Some retained data is missing or damaged; only available parts are shown."
        }
    }

    fun message(key: String): String? = when (key) {
        "saved" -> if (zh) "已保存并校验。" else "Saved and verified."
        "saveUncertain" -> if (zh) {
            "保存被中断，目标文件可能不完整，应用没有自动重试。"
        } else {
            "The save was interrupted. The destination may be incomplete; it was not retried."
        }
        "saveFailed" -> if (zh) "副本未保存，保留的副本未受影响。" else "The copy was not saved; the retained copy is unchanged."
        "cancelled" -> if (zh) "未选择保存位置。" else "No save location was chosen."
        "exportUnavailable" -> if (zh) {
            "没有可用的已校验副本。请打开保留副本后重新另存。"
        } else {
            "No verified copy is available. Open the retained copy and save again."
        }
        "openUnavailable" -> if (zh) "无法打开保留的副本。" else "The retained copy cannot be opened."
        "alreadyOpen" -> if (zh) "此副本已经在编辑器中打开。" else "This copy is already open in the editor."
        "discardBusy" -> if (zh) {
            "请先关闭正在编辑的文档或等待当前保存结束。"
        } else {
            "Close the open document or wait for the current save to finish."
        }
        "discardFailed" -> if (zh) "部分保留数据无法删除。" else "Some retained data could not be removed."
        "discarded" -> if (zh) "已丢弃保留副本。" else "Retained copy discarded."
        "checkSaved" -> if (zh) "目标文件已校验一致。" else "The destination matches this copy."
        "checkDiffers" -> if (zh) "目标文件与此副本不一致。" else "The destination does not match this copy."
        "checkGrant" -> if (zh) "目标文件的访问已过期，请另存新副本。" else "Access to the destination expired. Save a new copy."
        "checkUnavailable" -> if (zh) "现在无法检查目标文件。" else "The destination cannot be checked right now."
        "journalUnavailable" -> if (zh) "无法安全开始保存。" else "The save could not start safely."
        "stale" -> if (zh) "已忽略过期的保存结果。" else "An earlier save result was ignored."
        "originalUnchanged" -> if (zh) "原文件未更改。" else "The original is unchanged."
        "originalChanged" -> if (zh) "原文件已更改。" else "The original has changed."
        "originalUnavailable" -> if (zh) "无法检查原文件。" else "The original could not be checked."
        else -> null
    }
}
