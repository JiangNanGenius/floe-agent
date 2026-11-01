// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Channel-provided settings category. The PLAY flavor always supplies an
 * EMPTY list, so this common type carries no phone/ADB/Root identifier.
 */
class FloeSettingsExternalSection(
    val key: String,
    val titleRes: Int,
    val icon: ImageVector,
    val content: @Composable () -> Unit,
)
