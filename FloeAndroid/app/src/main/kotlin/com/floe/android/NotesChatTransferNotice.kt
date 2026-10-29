// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeText
import com.floe.android.host.noteschattransfer.NotesChatTransferController
import com.floe.android.host.noteschattransfer.NotesChatTransferState
import kotlinx.coroutines.delay

/** App-owned save receipts stay visible after the originating chat is left. */
@Composable
internal fun NotesChatTransferNotice(controller: NotesChatTransferController, modifier: Modifier = Modifier) {
    val state by controller.latest.collectAsState()
    val transferID = when (val current = state) {
        is NotesChatTransferState.Saving -> current.transferID
        is NotesChatTransferState.Saved -> current.transferID
        is NotesChatTransferState.Failed -> current.transferID
        NotesChatTransferState.Idle -> return
    }
    LaunchedEffect(state) {
        if (state is NotesChatTransferState.Saved) {
            delay(4_000)
            controller.dismiss(transferID)
        }
    }
    Row(modifier.clip(RoundedCornerShape(16.dp)).background(Floe.colors.readingSurface).padding(16.dp)) {
        FloeText(
            text = stringResource(when (val current = state) {
                is NotesChatTransferState.Saving -> R.string.notes_copy_saving
                is NotesChatTransferState.Saved -> R.string.notes_copy_saved
                is NotesChatTransferState.Failed -> if (current.keptRecovery) R.string.notes_copy_failed else R.string.notes_copy_failed_unkept
                else -> R.string.notes_copy_saving
            }),
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
        )
        val failed = state as? NotesChatTransferState.Failed
        if (failed?.retryable == true) {
            Spacer(Modifier.width(12.dp))
            FloeText(stringResource(R.string.retry), style = Floe.typography.bodyEmphasized,
                color = Floe.colors.accent,
                modifier = Modifier.clickable(role = Role.Button) { controller.retry(transferID) })
        }
        if (state !is NotesChatTransferState.Saving) {
            Spacer(Modifier.width(12.dp))
            FloeText(stringResource(R.string.notes_copy_dismiss), style = Floe.typography.bodyEmphasized,
                color = Floe.colors.accent,
                modifier = Modifier.clickable(role = Role.Button) { controller.dismiss(transferID) })
        }
    }
}
