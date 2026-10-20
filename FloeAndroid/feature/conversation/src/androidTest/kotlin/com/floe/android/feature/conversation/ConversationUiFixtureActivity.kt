// SPDX-License-Identifier: MPL-2.0
//
// TEST-ONLY host for rendered conversation-component inspection. Declared in
// the INSTRUMENTATION APK manifest as a non-exported Activity; it uses no
// permission, never touches real provider/backend/credential state, and
// renders only the labelled synthetic controller below against the real
// presentation composables. This is not production navigation and not App
// acceptance: screenshots are synthetic UI evidence for Main's review.

package com.floe.android.feature.conversation

import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.design.Floe
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeThemeMode
import java.util.Locale

class ConversationUiFixtureActivity : ComponentActivity() {

    internal val controller: ConversationFixtureController by lazy {
        ConversationFixtureController(Handler(mainLooper), MarkdownParseService())
    }

    internal val runLocale: String
        get() = localeArgument?.takeIf { it.isNotBlank() } ?: "system"

    internal val runTheme: String
        get() = themeArgument?.takeIf { it.isNotBlank() } ?: "auto"

    private val localeArgument: String?
        get() = runCatching {
            InstrumentationRegistry.getArguments().getString("conversationUiLocale")
        }.getOrNull()

    private val themeArgument: String?
        get() = runCatching {
            InstrumentationRegistry.getArguments().getString("conversationUiTheme")
        }.getOrNull()

    override fun attachBaseContext(newBase: Context) {
        val tag = runCatching {
            InstrumentationRegistry.getArguments().getString("conversationUiLocale")
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
            "ConversationUiFixture",
            "Synthetic component fixture only; locale=${localeArgument ?: "system"} theme=${themeArgument ?: "auto"}; " +
                "no backend, no network, no credentials",
        )
        val theme = when (themeArgument?.lowercase(Locale.ROOT)) {
            "dark" -> FloeThemeMode.DARK
            "light" -> FloeThemeMode.LIGHT
            else -> FloeThemeMode.AUTO
        }
        setContent {
            FloeTheme(themeMode = theme) {
                ConversationFixtureRoot(controller)
            }
        }
    }

    override fun onDestroy() {
        controller.shutdown()
        super.onDestroy()
    }
}

/** Test-only tag for the sized pane host used by geometry regressions. */
internal object ConversationPaneGeometryFixtureTags {
    const val ROOT = "conversation.pane.geometry.root"
}

/** Owns the synthetic holders; the tests drive scenarios through it. */
internal class ConversationFixtureController(
    private val main: Handler,
    private val parseService: MarkdownParseService,
) {
    val host = ConversationFixtureHost(main, parseService)

    /** Observable so the fixture banner recomposes with every scenario. */
    var scenario by mutableStateOf(ConversationUiScenario.EMPTY)
        private set
    var compact by mutableStateOf(false)
        private set

    /**
     * TEST-ONLY opt-in for the real measured-pane host. Null keeps the legacy
     * full-window destination used by every pre-existing component test; a
     * size hosts [FloeConversationPaneHost] in exactly that many dp, so the
     * actual-constraint geometry path is exercised without altering the
     * production App route (which is still unbound).
     */
    var paneSize by mutableStateOf<DpSize?>(null)
        private set
    var paneFontScale by mutableStateOf(1f)
        private set

    fun setPaneGeometry(size: DpSize?, fontScale: Float = 1f) {
        paneSize = size
        paneFontScale = fontScale.coerceAtLeast(0.5f)
    }

    /** The surface currently hosted. */
    val surface = mutableStateOf(Surface.THREAD)
    var threadHolder: ConversationFlowHolder? by mutableStateOf(null)
    var historyHolder: ConversationHistoryHolder? by mutableStateOf(null)
    var historyMode: HistoryDestinationMode = HistoryDestinationMode.LIST
        private set

    enum class Surface { THREAD, HISTORY }

    fun applyScenario(next: ConversationUiScenario) {
        scenario = next
        compact = next == ConversationUiScenario.COMPACT_COMPOSER || next == ConversationUiScenario.FULL_EDITOR
        host.launchEcho = when (next) {
            ConversationUiScenario.FULL_EDITOR -> LaunchEcho.PREPARE
            else -> LaunchEcho.NONE
        }
        host.keepsRequested = 0
        when (next) {
            ConversationUiScenario.HISTORY_SEARCH,
            ConversationUiScenario.HISTORY_MANAGE,
            ConversationUiScenario.HISTORY_ARCHIVE,
            -> {
                surface.value = Surface.HISTORY
                historyMode = when (next) {
                    ConversationUiScenario.HISTORY_MANAGE -> HistoryDestinationMode.MANAGE
                    ConversationUiScenario.HISTORY_ARCHIVE -> HistoryDestinationMode.ARCHIVE
                    else -> HistoryDestinationMode.LIST
                }
                val holder = ConversationHistoryHolder(host).also { h ->
                    historyHolder = h
                    h.applyHostState(UiFixtures.historyState(next))
                }
                host.historyHolder = holder
                // MANAGE starts in the multi-select surface; SEARCH shows the
                // query field of the list surface.
                if (next == ConversationUiScenario.HISTORY_MANAGE) {
                    holder.setEditMode(true)
                }
            }

            else -> {
                surface.value = Surface.THREAD
                host.historyHolder = null
                val seed = when (next) {
                    ConversationUiScenario.COMPACT_COMPOSER -> ComposerDraftSeedUi(
                        "typed synthetic draft",
                        listOf(UiFixtures.staged("att-1"), UiFixtures.staged("att-2", AttachmentImportUi.InProgress(0.4f))),
                        7,
                        0,
                    )

                    ConversationUiScenario.TEMP_DISCARD -> ComposerDraftSeedUi(
                        "temp discard synthetic draft",
                        listOf(UiFixtures.staged("att-1")),
                        null,
                        null,
                    )

                    else -> null
                }
                val holder = ConversationFlowHolder(host, "conv-1", seed).also { h ->
                    threadHolder = h
                    host.threadHolder = h
                    h.applyHostSnapshot(UiFixtures.threadState(h.session, next))
                }
                // Re-seed staged rows through the handoff at generation 0.
                if (seed != null) {
                    holder.applySendHandoff(null, seed.attachments)
                }
            }
        }
    }

    fun shutdown() {
        parseService.close()
    }
}

@Composable
internal fun ConversationFixtureRoot(controller: ConversationFixtureController) {
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
    val content: @Composable () -> Unit = { FixtureSurface(controller) }
    if (controller.compact) {
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
            LocalWindowInfo provides FixtureWindowInfo(compactWindowSize),
            content = content,
        )
    } else {
        content()
    }
}

private class FixtureWindowInfo(private val size: IntSize) : WindowInfo {
    override val isWindowFocused: Boolean = true
    override val containerSize: IntSize = size
}

@Composable
private fun FixtureSurface(controller: ConversationFixtureController) {
    val stamp = controller.scenario
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
        FloeText(
            text = "SCENARIO=$stamp",
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 2.dp),
        )
        Box(modifier = Modifier.fillMaxSize()) {
            when (controller.surface.value) {
                ConversationFixtureController.Surface.THREAD -> {
                    controller.threadHolder?.let { holder ->
                        val paneSize = controller.paneSize
                        if (paneSize != null) {
                            val density = LocalDensity.current
                            CompositionLocalProvider(
                                LocalDensity provides Density(
                                    density.density,
                                    controller.paneFontScale,
                                ),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(paneSize)
                                        .testTag(ConversationPaneGeometryFixtureTags.ROOT),
                                ) {
                                    FloeConversationPaneHost(
                                        holder = holder,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                }
                            }
                        } else {
                            FloeConversationDestination(holder = holder)
                        }
                    }
                }

                ConversationFixtureController.Surface.HISTORY -> {
                    controller.historyHolder?.let { holder ->
                        FloeConversationHistoryDestination(
                            holder = holder,
                            mode = controller.historyMode,
                        )
                    }
                }
            }
        }
    }
}
