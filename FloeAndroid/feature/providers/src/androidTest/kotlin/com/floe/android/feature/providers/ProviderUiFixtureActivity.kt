// SPDX-License-Identifier: MPL-2.0
//
// TEST-ONLY host for rendered provider-UI inspection. It is declared in the
// instrumentation APK manifest as a non-exported Activity, uses no sensitive
// permission, never touches real provider/backend/credential state and renders
// only the labelled synthetic controller below. Main runs the instrumentation
// APK and reads screenshots via run-as; this is not production navigation.

package com.floe.android.feature.providers

import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.design.Floe
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeThemeMode
import java.util.Locale

class ProviderUiFixtureActivity : ComponentActivity() {

    internal val controller = ProviderFixtureController()

    internal val runLocale: String
        get() = localeArgument?.takeIf { it.isNotBlank() } ?: "system"

    internal val runTheme: String
        get() = themeArgument?.takeIf { it.isNotBlank() } ?: "auto"

    private val localeArgument: String?
        get() = runCatching {
            InstrumentationRegistry.getArguments().getString("providerUiLocale")
        }.getOrNull()

    private val themeArgument: String?
        get() = runCatching {
            InstrumentationRegistry.getArguments().getString("providerUiTheme")
        }.getOrNull()

    override fun attachBaseContext(newBase: Context) {
        val tag = runCatching {
            InstrumentationRegistry.getArguments().getString("providerUiLocale")
        }.getOrNull()
        if (tag.isNullOrBlank() || tag == "system") {
            super.attachBaseContext(newBase)
            return
        }
        val locale = Locale.forLanguageTag(tag)
        val configuration = Configuration(newBase.resources.configuration).apply {
            setLocale(locale)
            setLayoutDirection(locale)
        }
        super.attachBaseContext(newBase.createConfigurationContext(configuration))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(
            "ProviderUiFixture",
            "Synthetic fixture only; locale=${localeArgument ?: "system"} theme=${themeArgument ?: "auto"}",
        )
        val theme = when (themeArgument?.lowercase(Locale.ROOT)) {
            "dark" -> FloeThemeMode.DARK
            "light" -> FloeThemeMode.LIGHT
            else -> FloeThemeMode.AUTO
        }
        setContent {
            FloeTheme(themeMode = theme) {
                ProviderFixtureRoot(controller)
            }
        }
    }
}

@Composable
internal fun ProviderFixtureRoot(controller: ProviderFixtureController) {
    if (controller.scenario == ProviderFixtureScenario.PURPOSE_WIDE_HOST ||
        controller.scenario == ProviderFixtureScenario.PURPOSE_WIDE_HOST_COLLAPSED ||
        controller.scenario == ProviderFixtureScenario.PURPOSE_WIDE_HOST_LARGE_FONT
    ) {
        ProviderHostFixtureSurface(controller)
        return
    }
    val compact = controller.compact
    val baseContext = LocalContext.current
    val currentConfiguration = LocalConfiguration.current
    val compactContext = remember(baseContext, currentConfiguration) {
        baseContext.createConfigurationContext(
            Configuration(currentConfiguration).apply {
                screenWidthDp = 420
                screenHeightDp = 900
                smallestScreenWidthDp = 420
            },
        )
    }
    if (compact) {
        val density = LocalDensity.current
        val compactWindowSize = remember(density) {
            IntSize(
                with(density) { 420.dp.roundToPx() },
                with(density) { 900.dp.roundToPx() },
            )
        }
        CompositionLocalProvider(
            LocalContext provides compactContext,
            LocalConfiguration provides compactContext.resources.configuration,
            // The destination uses the actual window container width for its
            // wide/compact decision. A tablet launch cannot otherwise exercise
            // the compact path; provide a deterministic compact window for the
            // fixture only (true phone rendering remains Main-owned).
            LocalWindowInfo provides FixtureWindowInfo(compactWindowSize),
        ) {
            FixtureSurface(controller)
        }
    } else {
        FixtureSurface(controller)
    }
}

private class FixtureWindowInfo(private val size: IntSize) : WindowInfo {
    override val isWindowFocused: Boolean = true
    override val containerSize: IntSize = size
}

@Composable
private fun FixtureSurface(controller: ProviderFixtureController) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        FloeText(
            text = stringResource(R.string.preview_synthetic_notice),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.pending.copy(alpha = 0.12f))
                .padding(horizontal = 12.dp, vertical = 4.dp),
        )
        Box(Modifier.fillMaxSize().padding(top = 2.dp)) {
            FloeProviderSettingsDestination(
                state = controller.state.value,
                holder = controller.holder,
            )
        }
    }
}
