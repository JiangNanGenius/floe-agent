// SPDX-License-Identifier: MPL-2.0
//
// TEST-ONLY host for rendered Skills/MCP administration inspection. Declared
// in the instrumentation APK manifest as a non-exported Activity, it uses no
// sensitive permission, never touches real skills/MCP/backend/credential
// state and renders only the labelled synthetic controller below through the
// REAL entry point [FloeSkillsSettingsDestination]. The fixture owns the
// RAM holder exactly like a production settings host would; no App route,
// no production host binding, no network. Screenshots are synthetic UI
// evidence, never App/backend proof.

package com.floe.android.feature.integrations

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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.design.Floe
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeThemeMode
import java.util.Locale

class IntegrationsUiFixtureActivity : ComponentActivity() {

    internal val controller = IntegrationsFixtureController()

    internal val runLocale: String
        get() = localeArgument?.takeIf { it.isNotBlank() } ?: "system"

    internal val runTheme: String
        get() = themeArgument?.takeIf { it.isNotBlank() } ?: "auto"

    private val localeArgument: String?
        get() = runCatching {
            InstrumentationRegistry.getArguments().getString("integrationsUiLocale")
        }.getOrNull()

    private val themeArgument: String?
        get() = runCatching {
            InstrumentationRegistry.getArguments().getString("integrationsUiTheme")
        }.getOrNull()

    override fun attachBaseContext(newBase: Context) {
        val tag = runCatching {
            InstrumentationRegistry.getArguments().getString("integrationsUiLocale")
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
            "IntegrationsUiFixture",
            "Synthetic fixture only; locale=${localeArgument ?: "system"} theme=${themeArgument ?: "auto"}",
        )
        val theme = when (themeArgument?.lowercase(Locale.ROOT)) {
            "dark" -> FloeThemeMode.DARK
            "light" -> FloeThemeMode.LIGHT
            else -> FloeThemeMode.AUTO
        }
        setContent {
            FloeTheme(themeMode = theme) {
                IntegrationsFixtureRoot(controller)
            }
        }
    }
}

@Composable
private fun IntegrationsFixtureRoot(controller: IntegrationsFixtureController) {
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
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = 2.dp),
        ) {
            FloeSkillsSettingsDestination(
                state = controller.state.value,
                holder = controller.holder,
            )
        }
    }
}
