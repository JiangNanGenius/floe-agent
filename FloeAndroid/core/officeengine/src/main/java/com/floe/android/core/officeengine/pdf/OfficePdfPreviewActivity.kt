// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.floe.android.core.officeengine.OfficeHostSaveHandoffPolicy
import com.floe.android.core.officeengine.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import java.util.concurrent.Executors

/**
 * Read-only in-app PDF preview over ONE verified module-owned snapshot.
 *
 * Trust model (Main contract 2026-10-27):
 *  - launched only by this application's own viewer with an internal,
 *    non-exported explicit Intent; the request is NOT authority — the real
 *    bytes (containment, op-name binding, magic, exact length, whole-file
 *    SHA) are re-proved OFF the main thread before the renderer sees a
 *    single descriptor;
 *  - imported content stays untrusted: every page goes through the isolated
 *    FD-only renderer service; this process never parses PDF bytes itself;
 *  - page flips/zoom supersede through a monotonically increasing render
 *    generation: late bitmaps are dropped (never shown for the wrong page),
 *    and destruction releases the renderer host so no callback can touch a
 *    dead composition;
 *  - the screen NEVER claims saves/prints/closes: it is a viewer. Password
 *    and unparseable documents are honestly refused with path-free copy.
 */
class OfficePdfPreviewActivity : ComponentActivity() {

    internal sealed class PageUi {
        object Loading : PageUi()
        class Ready(val image: ImageBitmap, val widthPx: Int, val heightPx: Int) : PageUi()
        class Failed(val retryable: Boolean) : PageUi()
    }

    internal enum class Stage { VERIFYING, READY, FAILED }

    /** Doc-level failure identity (mapped to path-free strings). */
    internal enum class DocFailure { SNAPSHOT_GONE, PASSWORD, INVALID, TRANSPORT }

    private var stage: Stage by mutableStateOf(Stage.VERIFYING)
    private var docFailure: DocFailure by mutableStateOf(DocFailure.TRANSPORT)
    private var snapshot: VerifiedPdfSnapshot? = null
    private var pageCount by mutableIntStateOf(0)
    private var page by mutableIntStateOf(0)
    private var zoomIndex by mutableIntStateOf(FIT_INDEX) // 100% default
    private val pageUi = mutableStateMapOf<Int, PageUi>()
    private val renderFence = OfficePdfRenderFence()

    private var host: OfficePdfRenderHost? = null
    private val verifyIo = Executors.newSingleThreadExecutor { r ->
        Thread(r, "floe-pdf-verify").apply { isDaemon = true }
    }

    /** Shape-only validation of the parcelled request BEFORE any file touch. */
    private fun shapeOk(request: OfficePdfPreviewRequest?): Boolean =
        request != null &&
            OfficeHostSaveHandoffPolicy.validOpId(request.opId) &&
            request.generation >= 1L &&
            SHA256_REGEX.matches(request.sha256) &&
            request.lengthBytes in 1L..MAX_PDF_BYTES &&
            request.displayName.isNotBlank() && request.displayName.length <= 240 &&
            request.canonicalPdfPath.startsWith("/") &&
            !request.canonicalPdfPath.contains('\u0000')

    private fun failureKey(): String = when (docFailure) {
        DocFailure.SNAPSHOT_GONE -> "gone"
        DocFailure.PASSWORD -> "password"
        DocFailure.INVALID -> "invalid"
        DocFailure.TRANSPORT -> "transport"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val received = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(
                OfficePdfPreviewRequest.EXTRA_REQUEST,
                OfficePdfPreviewRequest::class.java,
            )
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<OfficePdfPreviewRequest>(OfficePdfPreviewRequest.EXTRA_REQUEST)
        }

        setContent {
            val theme = runCatching {
                FloeThemeMode.valueOf(intent.getStringExtra("com.floe.office.THEME_MODE").orEmpty())
            }.getOrDefault(FloeThemeMode.AUTO)
            FloeTheme(themeMode = theme) {
                OfficePdfPreviewScreen(
                    title = received?.displayName.orEmpty(),
                    stage = stage,
                    failureKey = failureKey(),
                    pageCount = pageCount,
                    page = page,
                    zoomPercent = ZOOM_PERCENTS[zoomIndex],
                    pageUi = pageUi,
                    onBack = ::finish,
                    onPrev = { if (page > 0) page-- },
                    onNext = { if (page < pageCount - 1) page++ },
                    onZoomIn = { applyZoom(zoomIndex + 1) },
                    onZoomOut = { applyZoom(zoomIndex - 1) },
                    onZoomFit = { applyZoom(FIT_INDEX) },
                    onRetryPage = { requestRender(page, force = true) },
                    onRetryDoc = { startVerification(received) },
                    onPageVisible = { requestRender(it, force = false) },
                )
            }
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = finish()
        })

        host = OfficePdfRenderHost(this)
        if (shapeOk(received)) {
            startVerification(received)
        } else {
            docFailure = DocFailure.SNAPSHOT_GONE
            stage = Stage.FAILED
        }
    }

    /**
     * Re-prove bytes OFF main, then ask the renderer for the REAL page
     * count. Every stage failure is honest and path-free.
     */
    private fun startVerification(request: OfficePdfPreviewRequest?) {
        if (request == null || !shapeOk(request)) {
            docFailure = DocFailure.SNAPSHOT_GONE
            stage = Stage.FAILED
            return
        }
        val currentHost = host ?: return
        stage = Stage.VERIFYING
        docFailure = DocFailure.TRANSPORT
        pageCount = 0
        page = 0
        pageUi.clear()
        val generation = renderFence.bump()
        verifyIo.execute {
            val opened: Pair<VerifiedPdfSnapshot?, DocFailure?> = try {
                val (file, _) = OfficePdfReceiptPolicy.resolveOwnedOutput(
                    applicationContext.noBackupFilesDir,
                    request.generation,
                    request.opId,
                    request.canonicalPdfPath,
                )
                if (file == null) {
                    null to DocFailure.SNAPSHOT_GONE
                } else {
                    val proveErr = OfficePdfReceiptPolicy.proveBytes(file, request.sha256, request.lengthBytes)
                    if (proveErr != null) {
                        null to DocFailure.SNAPSHOT_GONE
                    } else {
                        VerifiedPdfSnapshot(
                            file = file,
                            sha256 = request.sha256,
                            lengthBytes = request.lengthBytes,
                            opId = request.opId,
                            generation = request.generation,
                        ) to null
                    }
                }
            } catch (t: Throwable) {
                null to DocFailure.TRANSPORT
            }
            runOnUiThread {
                if (!renderFence.isCurrent(generation) || isDestroyed || isFinishing) return@runOnUiThread
                val (verified, failure) = opened
                if (verified == null) {
                    docFailure = failure ?: DocFailure.SNAPSHOT_GONE
                    stage = Stage.FAILED
                    return@runOnUiThread
                }
                snapshot = verified
                currentHost.documentInfo(verified) { result ->
                    if (!renderFence.isCurrent(generation) || isDestroyed || isFinishing) return@documentInfo
                    when (result) {
                        is PdfDocResult.Ready -> {
                            pageCount = result.pageCount
                            page = 0
                            stage = Stage.READY
                            requestRender(0, force = true)
                        }
                        is PdfDocResult.Failed -> {
                            docFailure = when (result.failure) {
                                PdfFailure.PasswordProtected -> DocFailure.PASSWORD
                                PdfFailure.InvalidPdf -> DocFailure.INVALID
                                else -> DocFailure.TRANSPORT
                            }
                            stage = Stage.FAILED
                        }
                    }
                }
            }
        }
    }

    private fun requestRender(index: Int, force: Boolean) {
        if (stage != Stage.READY) return
        val currentSnapshot = snapshot ?: return
        val currentHost = host ?: return
        if (index !in 0 until pageCount) return
        val existing = pageUi[index]
        if (!force && (existing is PageUi.Ready || existing is PageUi.Loading)) return
        pageUi[index] = PageUi.Loading
        val zoom = ZOOM_PERCENTS[zoomIndex]
        val generation = renderFence.current()
        currentHost.renderPage(currentSnapshot, index, zoom) { result ->
            // Fence: only the CURRENT verification generation may update the
            // map; superseded bitmaps are recycled, never shown for a wrong
            // page/zoom (late-render fencing).
            if (!renderFence.isCurrent(generation) || isDestroyed || isFinishing) {
                if (result is PdfPageResult.Rendered && !result.bitmap.isRecycled) {
                    runCatching { result.bitmap.recycle() }
                }
                return@renderPage
            }
            when (result) {
                is PdfPageResult.Rendered ->
                    pageUi[index] = PageUi.Ready(result.bitmap.asImageBitmap(), result.widthPx, result.heightPx)
                is PdfPageResult.Failed ->
                    pageUi[index] = PageUi.Failed(retryable = true)
            }
        }
    }

    /**
     * Zoom mutation lives here so the raster invalidation can never be
     * skipped: every rendered page was baked at the old density.
     */
    private fun applyZoom(next: Int) {
        if (next == zoomIndex || next !in ZOOM_PERCENTS.indices) return
        zoomIndex = next
        renderFence.bump()
        pageUi.clear()
        requestRender(page, force = true)
    }

    override fun onDestroy() {
        renderFence.bump()
        host?.release()
        host = null
        verifyIo.shutdownNow()
        pageUi.clear()
        super.onDestroy()
    }

    companion object {
        private val SHA256_REGEX = Regex("^[0-9a-f]{64}$")
        private const val MAX_PDF_BYTES = 256L shl 20
        private val ZOOM_PERCENTS = intArrayOf(50, 75, 100, 150, 200, 300)
        private const val FIT_INDEX = 2 // 100% = the bounded fit density
    }
}

/**
 * Preview chrome: the existing Floe toolbar (Back left, document label
 * center), the page viewport with honest per-page render state, and one
 * compact bottom bar (page navigation + bounded zoom) built from the SAME
 * pinned design tokens — no new large command surface.
 */
@Composable
private fun OfficePdfPreviewScreen(
    title: String,
    stage: OfficePdfPreviewActivity.Stage,
    failureKey: String,
    pageCount: Int,
    page: Int,
    zoomPercent: Int,
    pageUi: SnapshotStateMap<Int, OfficePdfPreviewActivity.PageUi>,
    onBack: () -> Unit,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onZoomIn: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomFit: () -> Unit,
    onRetryPage: () -> Unit,
    onRetryDoc: () -> Unit,
    onPageVisible: (Int) -> Unit,
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
                    contentDescription = stringResource(R.string.office_viewer_back_cd),
                    onClick = onBack,
                )
            },
            showHairline = true,
        )
        when (stage) {
            OfficePdfPreviewActivity.Stage.VERIFYING -> Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 36.dp)
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator(modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = stringResource(R.string.office_pdf_opening),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }

            OfficePdfPreviewActivity.Stage.FAILED -> FloeUnavailableView(
                icon = FloeIcons.WarningTriangle,
                title = stringResource(R.string.office_pdf_failed_title),
                description = when (failureKey) {
                    "password" -> stringResource(R.string.office_pdf_password_info)
                    "invalid" -> stringResource(R.string.office_pdf_invalid_info)
                    "transport" -> stringResource(R.string.office_pdf_transport_info)
                    else -> stringResource(R.string.office_pdf_gone_info)
                },
                // Transport faults are retryable (the renderer host may just
                // have been slow to bind); document refusals are final for
                // this snapshot and offer only Back.
                action = if (failureKey == "transport") {
                    { FloeCapsuleButton(stringResource(R.string.office_pdf_retry), onClick = onRetryDoc) }
                } else {
                    null
                },
            )

            OfficePdfPreviewActivity.Stage.READY -> {
                // The page the user is actually looking at drives rendering:
                // first visit AND any zoom/page change request it (bounded,
                // serialized by the host; already-ready pages are untouched).
                LaunchedEffect(page, zoomPercent) { onPageVisible(page) }
                PageViewport(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    ui = pageUi[page],
                    page = page,
                    zoomPercent = zoomPercent,
                    onRetryPage = onRetryPage,
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 48.dp)
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    FloeCircleButton(
                        icon = FloeIcons.ChevronBack,
                        contentDescription = stringResource(R.string.office_pdf_prev_cd),
                        onClick = onPrev,
                        enabled = page > 0,
                        visualSize = 36.dp,
                        iconSize = 18.dp,
                    )
                    FloeText(
                        text = stringResource(R.string.office_pdf_page_indicator, page + 1, pageCount),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.weight(1f),
                    )
                    FloeCircleButton(
                        icon = FloeIcons.ChevronForward,
                        contentDescription = stringResource(R.string.office_pdf_next_cd),
                        onClick = onNext,
                        enabled = page < pageCount - 1,
                        visualSize = 36.dp,
                        iconSize = 18.dp,
                    )
                    Spacer(Modifier.width(10.dp))
                    ZoomChip(label = stringResource(R.string.office_pdf_zoom_out), onClick = onZoomOut)
                    ZoomChip(label = stringResource(R.string.office_pdf_zoom_in), onClick = onZoomIn)
                    ZoomChip(label = stringResource(R.string.office_pdf_fit), onClick = onZoomFit)
                }
            }
        }
    }
}

@Composable
private fun PageViewport(
    modifier: Modifier,
    ui: OfficePdfPreviewActivity.PageUi?,
    page: Int,
    zoomPercent: Int,
    onRetryPage: () -> Unit,
) {
    // The rendered raster is capped by the bounded geometry; display scales
    // it by the requested zoom against the screen width, and the viewport
    // scrolls in both directions when the page grows past the screen.
    val screenWidthDp = LocalConfiguration.current.screenWidthDp.toFloat()
    val displayWidth: Dp = (screenWidthDp * zoomPercent / 100f).dp
    val vertical = rememberScrollState()
    val horizontal = rememberScrollState()
    // Reset scroll when the page changes (fresh framing per page).
    LaunchedEffect(page) {
        vertical.scrollTo(0)
        horizontal.scrollTo(0)
    }
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
        when (ui) {
            null, is OfficePdfPreviewActivity.PageUi.Loading -> Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                FloeActivityIndicator(modifier = Modifier.size(24.dp))
            }

            is OfficePdfPreviewActivity.PageUi.Ready -> {
                val height = displayWidth * (ui.heightPx.toFloat() / ui.widthPx.toFloat())
                androidx.compose.foundation.Image(
                    bitmap = ui.image,
                    contentDescription = null,
                    modifier = Modifier
                        .verticalScroll(vertical)
                        .horizontalScroll(horizontal)
                        .width(displayWidth)
                        .height(height),
                )
            }

            is OfficePdfPreviewActivity.PageUi.Failed -> Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.padding(24.dp),
                ) {
                    FloeText(
                        text = stringResource(R.string.office_pdf_render_failed),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloeCapsuleButton(stringResource(R.string.office_pdf_retry), onClick = onRetryPage)
                }
            }
        }
    }
}

/** Small text chip for the bounded zoom row (no new glyph invented). */
@Composable
private fun ZoomChip(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .heightIn(min = 36.dp)
            .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(18.dp))
            .background(Floe.colors.chromeSurface, RoundedCornerShape(18.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(text = label, style = Floe.typography.metadata, color = Floe.colors.label)
    }
}
