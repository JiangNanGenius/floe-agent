// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/**
 * iOS-style page sheet: rounded slide-up surface covering the window with a
 * dim scrim, system-back dismissal and iOS-motion easing. Content owns its
 * own toolbar (title + Done), matching SettingsRootView's sheet behavior.
 */
@Composable
fun FloePageSheet(
    visible: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    topInset: Dp = 0.dp,
    content: @Composable BoxScope.() -> Unit,
) {
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(220, easing = LinearOutSlowInEasing)) +
            slideInVertically(tween(320, easing = LinearOutSlowInEasing)) { it / 6 },
        exit = fadeOut(tween(160)) +
            slideOutVertically(tween(280, easing = LinearOutSlowInEasing)) { it / 6 },
        modifier = modifier,
    ) {
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            BackHandler(onBack = onDismiss)
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.28f)),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = topInset)
                        .clip(RoundedCornerShape(topStart = FloeLayout.SettingsSheetCorner, topEnd = FloeLayout.SettingsSheetCorner))
                        .background(Floe.colors.readingSurface),
                    content = content,
                )
            }
        }
    }
}
