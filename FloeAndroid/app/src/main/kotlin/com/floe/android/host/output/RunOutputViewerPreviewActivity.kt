// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.floe.android.FloeSystemBarAppearance
import com.floe.android.FloeThemeStore
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.conversation.RunOutputViewerKind
import com.floe.android.feature.conversation.RunOutputViewerSupport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * App-owned, non-exported full-screen viewer for ONE verified durable
 * run-output of a viewer-supported kind: plain text/Markdown source (a
 * read-only, selectable reading space — the snapshot is immutable and
 * run-output originals stay runtime-owned copy-only) and generated
 * image/audio/video (real decode/playback of the retained verified bytes).
 *
 * Trust model (mirrors the lane-17 PDF preview):
 *  - the Intent carries ONLY the opaque launch token; every byte fact comes
 *    from the live, owner-fenced launch record
 *    ([RunOutputViewerPreviewController.claimForViewer]) — an unknown/restored
 *    token (process death) or a retired owner shows the honest expired
 *    state; nothing is re-derived from Intent bytes and no path ever crosses
 *    into this screen;
 *  - the bytes were ALREADY proven at staging (sealed receipt re-derived by
 *    native, whole-stream SHA + exact length + clean EOF) over an immutable
 *    App-owned read-only snapshot; the kind is re-classified HERE from the
 *    live record's sealed facts, never from the card cache;
 *  - text renders as TEXT (monospace, scrollable, selectable) — no WebView,
 *    no remote images, no script, so untrusted Markdown source cannot reach
 *    network or script execution; a bounded read cap keeps memory honest;
 *  - media plays through the platform MediaPlayer against the App-owned
 *    snapshot file only; prepare/decode failure shows an explicit failure
 *    state (never a fake success), and the player is released on close.
 */
class RunOutputViewerPreviewActivity : ComponentActivity() {

    companion object {
        /** The ONLY extra this screen reads: the opaque live-launch token. */
        const val EXTRA_LAUNCH_TOKEN = "com.floe.android.runoutput.viewer.LAUNCH_TOKEN"

        /** Bounded raster decode: the sampled bitmap never exceeds this
         * pixel dimension on either axis (memory stays flat for 256 MiB
         * egress-capped sources). */
        private const val IMAGE_MAX_DIMENSION_PX = 4096
    }

    internal enum class Stage { VERIFYING, READY, FAILED }

    /** Path-free failure identity (mapped to strings). BINARY is the
     * content-probe refusal for an unknown/text-candidate snapshot whose
     * bytes are not UTF-8 text: the sealed bytes are never decoded with
     * replacement characters or presented as if they were text. */
    internal enum class Failure { EXPIRED, GONE, TOO_LARGE, INVALID, BINARY, RENDER }

    private var stage: Stage by mutableStateOf(Stage.VERIFYING)
    private var failure: Failure by mutableStateOf(Failure.GONE)
    private var kind: RunOutputViewerKind by mutableStateOf(RunOutputViewerKind.UNSUPPORTED)

    /** Token of the record THIS screen claimed (Live or StageFailed). */
    private var claimedToken: String? = null

    /** Non-null ONLY while this screen holds a viewer lease on a live
     * launch; every viewer-side settlement routes through it. */
    private var attachedToken: String? = null
    private var liveStaged: RunOutputViewerStaged? = null
    private val readerCompletions = Handler(Looper.getMainLooper())

    // ---- text content ----
    private var textPages by mutableStateOf<List<String>>(emptyList())
    private var textTruncated by mutableStateOf(false)

    // ---- image content ----
    private var imageBitmap by mutableStateOf<ImageBitmap?>(null)

    // ---- media transport (audio + video) ----
    private var player: MediaPlayer? = null
    private var mediaReady by mutableStateOf(false)
    private var mediaPlaying by mutableStateOf(false)
    private var mediaDurationMs by mutableLongStateOf(0L)
    private var mediaPositionMs by mutableLongStateOf(0L)
    private var videoSurface: Surface? = null
    internal var viewerVideoAspectRatio by mutableStateOf(16f / 9f)
        private set

    // ---- exactly-once lease settlement ----
    /** True once destroy began: late IO completions still finish their
     * reader count (the registry may only settle after the blocking work
     * REALLY returned) but never publish content or touch the registry
     * twice. All mutations happen on the main thread (IO completions hop
     * back to Main before state publication). */
    private var settled = false
    private var pendingReaders = 0
    private var quiescedSent = false

    private fun beginReader() {
        pendingReaders++
    }

    private fun endReader() {
        if (pendingReaders > 0) pendingReaders--
        maybeQuiesce()
    }

    /** The exactly-once lease settlement: only after EVERY reader really
     * finished AND media is released AND the screen closed. Never blocks
     * the main thread joining a decoder — a still-running reader defers
     * this to its Main-posted completion. */
    private fun maybeQuiesce() {
        if (!settled || pendingReaders != 0 || quiescedSent) return
        quiescedSent = true
        val token = attachedToken
        attachedToken = null
        if (token != null) controller?.onViewerQuiesced(token)
    }

    /** SurfaceView bridge callback (video only): attach/detach independently
     * of the player handle so composition changes keep the player alive. */
    internal fun onViewerSurface(surface: Surface, width: Int, height: Int) {
        if (width < 1 || height < 1) return
        videoSurface = surface
        attachSurfaceIfPossible()
    }

    internal fun onViewerSurfaceDestroyed() {
        videoSurface = null
        runCatching { player?.setSurface(null) }
    }

    private val controller: RunOutputViewerPreviewController?
        get() = (application as? com.floe.android.FloeApplication)?.runOutputViewer

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val owner = controller
        val claim = owner?.claimForViewer(intent.getStringExtra(EXTRA_LAUNCH_TOKEN))
            ?: RunOutputViewerClaim.Expired
        when (claim) {
            is RunOutputViewerClaim.Live -> {
                claimedToken = claim.staged.launchToken
                if (owner?.attachViewer(claim.staged.launchToken) == true) {
                    attachedToken = claim.staged.launchToken
                    liveStaged = claim.staged
                    // Re-derive the kind from the LIVE record's sealed facts;
                    // a record that no longer classifies is refused honestly.
                    val stagedKind = RunOutputViewerSupport.classify(
                        claim.staged.mimeType, claim.staged.displayName)
                    if (stagedKind == RunOutputViewerKind.UNSUPPORTED) {
                        showFailure(Failure.INVALID)
                    } else {
                        kind = stagedKind
                        startContent(claim.staged, stagedKind)
                    }
                } else {
                    showFailure(Failure.EXPIRED)
                }
            }
            is RunOutputViewerClaim.StageFailed -> {
                claimedToken = intent.getStringExtra(EXTRA_LAUNCH_TOKEN)
                showFailure(mapStageFailure(claim.code))
            }
            RunOutputViewerClaim.Expired -> showFailure(Failure.EXPIRED)
        }

        val themeMode = FloeThemeStore(applicationContext).mode
        setContent {
            FloeTheme(themeMode = themeMode) {
                FloeSystemBarAppearance(themeMode)
                RunOutputViewerScreen(
                    title = liveStaged?.displayName
                        ?: stringResource(R.string.run_viewer_failed_title),
                    stage = stage,
                    kind = kind,
                    failure = failure,
                    textPages = textPages,
                    textTruncated = textTruncated,
                    image = imageBitmap,
                    mediaReady = mediaReady,
                    mediaPlaying = mediaPlaying,
                    mediaDurationMs = mediaDurationMs,
                    mediaPositionMs = mediaPositionMs,
                    onBack = { closeAndFinish() },
                    onTogglePlay = { togglePlay() },
                )
            }
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = closeAndFinish()
        })
    }

    private fun showFailure(value: Failure) {
        failure = value
        stage = Stage.FAILED
    }

    /** Explicit close: hand the launch to the owner accounting (the record
     * may still be settling — that keeps the file until the last real owner
     * quiesces). Back returns to the originating conversation task. */
    private fun closeAndFinish() {
        claimedToken?.let { controller?.onUserClose(it) }
        finish()
    }

    /** Staging failures are FINAL for this launch (recovery is refreshing /
     * re-opening from the conversation, which re-proves bytes from the
     * durable receipt) — none maps to a retry state, so no screen shows a
     * retry button that could retry nothing. */
    private fun mapStageFailure(code: String): Failure = when (code) {
        "ownerChanged" -> Failure.EXPIRED
        "contentTooLarge" -> Failure.TOO_LARGE
        "format" -> Failure.INVALID
        else -> Failure.GONE
    }

    /** Start the real consumer for the staged, already-proven bytes. Every
     * path resolves to READY or an explicit FAILED — never a silent hang. */
    private fun startContent(staged: RunOutputViewerStaged, stagedKind: RunOutputViewerKind) {
        when (stagedKind) {
            RunOutputViewerKind.TEXT -> loadText(staged)
            RunOutputViewerKind.IMAGE -> loadImage(staged)
            RunOutputViewerKind.AUDIO -> prepareMedia(staged, video = false)
            RunOutputViewerKind.VIDEO -> prepareMedia(staged, video = true)
            RunOutputViewerKind.UNSUPPORTED -> showFailure(Failure.INVALID)
        }
    }

    /** Bounded UTF-8 read of the immutable snapshot. The reader walks real
     * 64 KiB pages to EOF and reports the actual file byte count, so a page
     * window is never mistaken for whole-file truncation. NUL or invalid
     * UTF-8 is a typed BINARY refusal — never replacement characters. Only
     * the reader's own 4 MiB display cap is disclosed as truncation. */
    private fun loadText(staged: RunOutputViewerStaged) {
        beginReader()
        val reader = lifecycleScope.launch(Dispatchers.IO) {
            val read = RunOutputTextViewReader.read(staged.file)
            val pages = (read as? RunOutputTextViewReader.Result.Success)?.let {
                RunOutputTextViewReader.displayPages(it.page.text)
            }
            withContext(Dispatchers.Main) {
                // A late completion after close owns no launch: it settles
                // the reader count but never publishes content.
                if (isDestroyed || isFinishing || settled) return@withContext
                when (read) {
                    is RunOutputTextViewReader.Result.Success -> {
                        textPages = pages.orEmpty()
                        textTruncated = read.page.truncated
                        stage = Stage.READY
                    }
                    RunOutputTextViewReader.Result.NotUTF8Text ->
                        showFailure(Failure.BINARY)
                    is RunOutputTextViewReader.Result.ReadFailure ->
                        showFailure(Failure.RENDER)
                }
            }
        }
        reader.invokeOnCompletion { readerCompletions.post { endReader() } }
    }

    /** Memory-bounded raster decode of the snapshot (power-of-two sample
     * against the capped pixel dimension, decided by the pure
     * [runOutputImageSampleSize]); an undecodable receipt is an explicit
     * failure, never a placeholder image. */
    private fun loadImage(staged: RunOutputViewerStaged) {
        beginReader()
        val reader = lifecycleScope.launch(Dispatchers.IO) {
            val decoded = runCatching {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(staged.file.absolutePath, bounds)
                if (bounds.outWidth < 1 || bounds.outHeight < 1) return@runCatching null
                BitmapFactory.decodeFile(
                    staged.file.absolutePath,
                    BitmapFactory.Options().apply {
                        inSampleSize = runOutputImageSampleSize(
                            bounds.outWidth, bounds.outHeight, IMAGE_MAX_DIMENSION_PX)
                    },
                )?.asImageBitmap()
            }.getOrNull()
            withContext(Dispatchers.Main) {
                // A late completion after close owns no launch: it settles
                // the reader count but never publishes content.
                if (isDestroyed || isFinishing || settled) return@withContext
                if (decoded == null) {
                    showFailure(Failure.RENDER)
                } else {
                    imageBitmap = decoded
                    stage = Stage.READY
                }
            }
        }
        reader.invokeOnCompletion { readerCompletions.post { endReader() } }
    }

    /** Platform MediaPlayer against the App-owned snapshot file only:
     * prepare is never reported as playback; a prepare/playback error is an
     * explicit failure state; completion returns to the transport start. */
    private fun prepareMedia(staged: RunOutputViewerStaged, video: Boolean) {
        val mediaPlayer = MediaPlayer()
        player = mediaPlayer
        mediaPlayer.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(
                    if (video) AudioAttributes.CONTENT_TYPE_MOVIE
                    else AudioAttributes.CONTENT_TYPE_MUSIC,
                )
                .build(),
        )
        mediaPlayer.setOnPreparedListener {
            if (settled || isDestroyed || isFinishing) return@setOnPreparedListener
            mediaDurationMs = it.duration.coerceAtLeast(0).toLong()
            if (it.videoWidth > 0 && it.videoHeight > 0) {
                viewerVideoAspectRatio = it.videoWidth.toFloat() / it.videoHeight
            }
            mediaReady = true
            stage = Stage.READY
            attachSurfaceIfPossible()
        }
        mediaPlayer.setOnVideoSizeChangedListener { _, width, height ->
            if (width > 0 && height > 0 && !settled) {
                viewerVideoAspectRatio = width.toFloat() / height
            }
        }
        mediaPlayer.setOnCompletionListener {
            if (settled || isDestroyed || isFinishing) return@setOnCompletionListener
            mediaPlaying = false
            mediaPositionMs = 0L
        }
        mediaPlayer.setOnErrorListener { _, _, _ ->
            releaseMedia()
            if (!settled && !isDestroyed && !isFinishing) showFailure(Failure.RENDER)
            true
        }
        runCatching {
            mediaPlayer.setDataSource(staged.file.absolutePath)
            mediaPlayer.prepareAsync()
        }.onFailure {
            releaseMedia()
            if (!settled && !isDestroyed && !isFinishing) showFailure(Failure.RENDER)
        }
    }

    private fun attachSurfaceIfPossible() {
        val mediaPlayer = player ?: return
        val surface = videoSurface ?: return
        if (kind != RunOutputViewerKind.VIDEO) return
        runCatching { mediaPlayer.setSurface(surface) }
    }

    /** Live position refresh for the transport label (poll only). */
    internal fun onPlaybackTick() {
        val mediaPlayer = player ?: return
        if (settled || !mediaPlaying) return
        runCatching { mediaPositionMs = mediaPlayer.currentPosition.coerceAtLeast(0).toLong() }
    }

    private fun togglePlay() {
        val mediaPlayer = player
        if (settled || !mediaReady || mediaPlayer == null) return
        runCatching {
            if (mediaPlayer.isPlaying) {
                mediaPlayer.pause()
                mediaPlaying = false
            } else {
                mediaPlayer.start()
                mediaPlaying = true
            }
        }.onFailure {
            releaseMedia()
            showFailure(Failure.RENDER)
        }
    }

    private fun releaseMedia() {
        val mediaPlayer = player
        player = null
        mediaReady = false
        mediaPlaying = false
        if (mediaPlayer != null) {
            runCatching { mediaPlayer.stop() }
            runCatching { mediaPlayer.reset() }
            runCatching { mediaPlayer.release() }
        }
        videoSurface = null
    }

    /** Home/lock/Surface loss must never leave media playing invisibly:
     * pause preserves the real position and player state; playback resumes
     * only from the explicit transport. No background service, no PiP. */
    override fun onStop() {
        super.onStop()
        val mediaPlayer = player
        if (mediaPlayer != null && mediaPlaying) {
            runCatching { mediaPlayer.pause() }
            mediaPlaying = false
        }
    }

    override fun onDestroy() {
        // A system-initiated finish (task swipe with a live process, an
        // external finish()) closes the launch exactly like Back: the slot
        // must not leak. isFinishing is FALSE across a configuration
        // destroy, so rotation (configChanges) never reaches this and can
        // never unwind a live viewer. onUserClose is idempotent for the
        // back-button path.
        if (isFinishing) claimedToken?.let { controller?.onUserClose(it) }
        // From here a late IO completion owns nothing: it still finishes
        // its reader count (the registry settles only after the blocking
        // decode REALLY returned) but never publishes content. Media
        // release is synchronous on the main thread, so with no reader in
        // flight the lease settles right here; a running reader defers the
        // quiesce to its Main-posted completion. Never joins a decoder.
        settled = true
        releaseMedia()
        liveStaged = null
        textPages = emptyList()
        imageBitmap = null
        maybeQuiesce()
        super.onDestroy()
    }
}

/* ------------------------------- screen ------------------------------- */

@Composable
private fun RunOutputViewerScreen(
    title: String,
    stage: RunOutputViewerPreviewActivity.Stage,
    kind: RunOutputViewerKind,
    failure: RunOutputViewerPreviewActivity.Failure,
    textPages: List<String>,
    textTruncated: Boolean,
    image: ImageBitmap?,
    mediaReady: Boolean,
    mediaPlaying: Boolean,
    mediaDurationMs: Long,
    mediaPositionMs: Long,
    onBack: () -> Unit,
    onTogglePlay: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface)
            .safeDrawingPadding(),
    ) {
        FloeToolbar(
            title = title,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.run_viewer_back_cd),
                    onClick = onBack,
                )
            },
            showHairline = true,
        )
        when (stage) {
            RunOutputViewerPreviewActivity.Stage.VERIFYING -> Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 36.dp)
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator(modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = stringResource(R.string.run_viewer_opening),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }

            RunOutputViewerPreviewActivity.Stage.FAILED -> FloeUnavailableView(
                icon = FloeIcons.WarningTriangle,
                title = stringResource(R.string.run_viewer_failed_title),
                description = when (failure) {
                    RunOutputViewerPreviewActivity.Failure.EXPIRED ->
                        stringResource(R.string.run_viewer_expired_info)
                    RunOutputViewerPreviewActivity.Failure.TOO_LARGE ->
                        stringResource(R.string.run_viewer_toolarge_info)
                    RunOutputViewerPreviewActivity.Failure.INVALID ->
                        stringResource(R.string.run_viewer_invalid_info)
                    RunOutputViewerPreviewActivity.Failure.BINARY ->
                        stringResource(R.string.run_viewer_binary_info)
                    RunOutputViewerPreviewActivity.Failure.RENDER ->
                        stringResource(R.string.run_viewer_render_info)
                    RunOutputViewerPreviewActivity.Failure.GONE ->
                        stringResource(R.string.run_viewer_gone_info)
                },
            )

            RunOutputViewerPreviewActivity.Stage.READY -> when (kind) {
                RunOutputViewerKind.TEXT -> TextViewport(
                    pages = textPages,
                    truncated = textTruncated,
                )
                RunOutputViewerKind.IMAGE -> ImageViewport(image = image)
                RunOutputViewerKind.AUDIO -> MediaViewport(
                    video = false,
                    ready = mediaReady,
                    playing = mediaPlaying,
                    positionMs = mediaPositionMs,
                    durationMs = mediaDurationMs,
                    onTogglePlay = onTogglePlay,
                )
                RunOutputViewerKind.VIDEO -> MediaViewport(
                    video = true,
                    ready = mediaReady,
                    playing = mediaPlaying,
                    positionMs = mediaPositionMs,
                    durationMs = mediaDurationMs,
                    onTogglePlay = onTogglePlay,
                )
                RunOutputViewerKind.UNSUPPORTED -> Unit
            }
        }
    }
}

/** Read-only text/Markdown space: monospace evidence type, scrollable and
 * selectable, bounded padding. Raw source only — no WebView, no remote
 * images, no script — so untrusted Markdown cannot reach network or script
 * execution. */
@Composable
private fun TextViewport(pages: List<String>, truncated: Boolean) {
    var selectedPage by rememberSaveable { mutableIntStateOf(0) }
    val lastPage = (pages.size - 1).coerceAtLeast(0)
    val page = selectedPage.coerceIn(0, lastPage)
    Column(modifier = Modifier.fillMaxSize()) {
        if (pages.size > 1) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TransportChip(stringResource(R.string.run_viewer_text_first), page > 0) {
                    selectedPage = 0
                }
                TransportChip(stringResource(R.string.run_viewer_text_previous), page > 0) {
                    selectedPage = page - 1
                }
                FloeText(
                    text = stringResource(R.string.run_viewer_text_page, page + 1, pages.size),
                    style = Floe.typography.evidence,
                    color = Floe.colors.secondaryLabel,
                )
                TransportChip(stringResource(R.string.run_viewer_text_next), page < lastPage) {
                    selectedPage = page + 1
                }
                TransportChip(stringResource(R.string.run_viewer_text_last), page < lastPage) {
                    selectedPage = lastPage
                }
            }
        }
        // A new page starts at the top; only this bounded page is laid out.
        key(page) {
            Column(
                modifier = Modifier.weight(1f).fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                SelectionContainer {
                    FloeText(
                        text = pages.getOrElse(page) { "" },
                        style = Floe.typography.evidence,
                        color = Floe.colors.label,
                    )
                }
                if (truncated && page == lastPage) {
                    Spacer(Modifier.size(12.dp))
                    FloeText(
                        text = stringResource(R.string.run_viewer_text_truncated),
                        style = Floe.typography.evidence,
                        color = Floe.colors.tertiaryLabel,
                    )
                }
            }
        }
    }
}

@Composable
private fun ImageViewport(image: ImageBitmap?) {
    Box(
        modifier = Modifier.fillMaxSize().background(Floe.colors.readingSurface),
        contentAlignment = Alignment.Center,
    ) {
        if (image == null) {
            FloeActivityIndicator(modifier = Modifier.size(24.dp))
        } else {
            Image(
                bitmap = image,
                contentDescription = stringResource(R.string.run_viewer_image_cd),
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/**
 * Real media surface + transport over the staged snapshot. Video renders
 * through a platform SurfaceView whose lifecycle is independent of
 * composition (surfaceCreated/Changed attach, surfaceDestroyed clears);
 * audio shows an explicit play transport. Position/duration labels are real
 * player facts only.
 */
@Composable
private fun MediaViewport(
    video: Boolean,
    ready: Boolean,
    playing: Boolean,
    positionMs: Long,
    durationMs: Long,
    onTogglePlay: () -> Unit,
) {
    val activity = androidx.compose.ui.platform.LocalContext.current as?
        RunOutputViewerPreviewActivity
    // Position polling only while really playing; the label is a live
    // player fact, never a timer pretending to be playback.
    LaunchedEffect(playing) {
        while (playing) {
            delay(500)
            activity?.onPlaybackTick()
        }
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            contentAlignment = Alignment.Center,
        ) {
            if (video) {
                AndroidSurface(
                    aspectRatio = activity?.viewerVideoAspectRatio ?: (16f / 9f),
                    onSurface = { surface, width, height ->
                        activity?.onViewerSurface(surface, width, height)
                    },
                    onSurfaceDestroyed = { activity?.onViewerSurfaceDestroyed() },
                )
            } else {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    FloeText(
                        text = stringResource(R.string.run_viewer_audio_cd),
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                    )
                }
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            TransportChip(
                label = stringResource(
                    if (playing) R.string.run_viewer_pause else R.string.run_viewer_play,
                ),
                enabled = ready,
                onClick = onTogglePlay,
            )
            FloeText(
                text = stringResource(
                    R.string.run_viewer_time_indicator,
                    formatClock(positionMs),
                    formatClock(durationMs),
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

/** Platform SurfaceView bridge (mirrors the reviewed workbench video
 * surface discipline): the surface attaches/detaches independently of the
 * player handle, so configuration changes keep the player alive. */
@Composable
private fun AndroidSurface(
    aspectRatio: Float,
    onSurface: (Surface, Int, Int) -> Unit,
    onSurfaceDestroyed: () -> Unit,
) {
    androidx.compose.ui.viewinterop.AndroidView(
        factory = { context ->
            SurfaceView(context).apply {
                holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) {
                        val frame = holder.surfaceFrame
                        onSurface(holder.surface, frame.width(), frame.height())
                    }

                    override fun surfaceChanged(
                        holder: SurfaceHolder,
                        format: Int,
                        width: Int,
                        height: Int,
                    ) {
                        onSurface(holder.surface, width, height)
                    }

                    override fun surfaceDestroyed(holder: SurfaceHolder) {
                        onSurfaceDestroyed()
                    }
                })
            }
        },
        modifier = Modifier.fillMaxWidth().aspectRatio(aspectRatio),
    )
}

@Composable
private fun TransportChip(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .heightIn(min = 36.dp)
            .clip(RoundedCornerShape(18.dp))
            .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(18.dp))
            .background(
                if (enabled) Floe.colors.chromeSurface else Floe.colors.fillTertiary,
                RoundedCornerShape(18.dp),
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            text = label,
            style = Floe.typography.metadata,
            color = if (enabled) Floe.colors.label else Floe.colors.tertiaryLabel,
        )
    }
}

private fun formatClock(ms: Long): String {
    val totalSeconds = (ms.coerceAtLeast(0) / 1000L)
    val minutes = totalSeconds / 60L
    val seconds = totalSeconds % 60L
    return "%d:%02d".format(minutes, seconds)
}
