// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Image
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.core.officeengine.pdf.OfficePdfPrintFlow
import com.floe.android.core.officeengine.pdf.OfficePdfRenderFence
import com.floe.android.core.officeengine.pdf.OfficePdfRenderHost
import com.floe.android.core.officeengine.pdf.PdfDocResult
import com.floe.android.core.officeengine.pdf.PdfFailure
import com.floe.android.core.officeengine.pdf.PdfPageResult
import com.floe.android.core.officeengine.pdf.PrintStartOutcome
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.FloeThemeStore
import com.floe.android.FloeSystemBarAppearance
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView

/**
 * Lane 17: the App-owned, non-exported preview screen for ONE verified
 * durable run-output PDF, rendering through the SAME isolated renderer and
 * printing through the SAME accepted system-print seam as the Office module's
 * PDF surfaces — one renderer family, one honesty contract, no second
 * parser, no external-app fallback.
 *
 * Trust model (Main contract 2026-10-27):
 *  - the Intent carries ONLY the opaque launch token; every byte fact comes
 *    from the live, owner-fenced launch record
 *    ([RunOutputPdfPreviewController.claimForViewer]) — an unknown/restored
 *    token (process death) or a retired owner shows the honest expired state
 *    pointing back to the conversation; nothing is re-derived from Intent
 *    bytes and no path ever crosses into this screen;
 *  - the bytes were ALREADY proven at staging (sealed receipt re-derived by
 *    native, whole-stream SHA + exact length + clean EOF + `%PDF-` magic +
 *    MIME agreement) over an immutable App-owned read-only snapshot;
 *  - parsing runs ONLY in the isolated FD-only renderer process; page
 *    flips/zoom supersede through the existing [OfficePdfRenderFence];
 *    destruction releases the host through its quiescent lease-join so the
 *    snapshot's owner accounting learns when descriptors really settled;
 *  - Print uses the REAL renderer page count (never guessed) and the exact-
 *    once [PrintFinish] owner settlement: "dialog opened" is reported as
 *    exactly that — a physical print is NEVER claimed, and closing this
 *    screen neither cancels nor settles an admitted job.
 */
class RunOutputPdfPreviewActivity : ComponentActivity() {

    companion object {
        /** The ONLY extra this screen reads: the opaque live-launch token. */
        const val EXTRA_LAUNCH_TOKEN = "com.floe.android.runoutput.pdf.LAUNCH_TOKEN"

        private val ZOOM_PERCENTS = intArrayOf(50, 75, 100, 150, 200, 300)
        private const val FIT_INDEX = 2 // 100% = the bounded fit density
    }

    internal sealed class PageUi {
        object Loading : PageUi()
        class Ready(val image: ImageBitmap, val widthPx: Int, val heightPx: Int) : PageUi()
        class Failed(val retryable: Boolean) : PageUi()
    }

    internal enum class Stage { VERIFYING, READY, FAILED }

    /** Doc-level failure identity (mapped to path-free strings). */
    internal enum class DocFailure { EXPIRED, GONE, TOO_LARGE, INVALID, PASSWORD, TRANSPORT }

    private var stage: Stage by mutableStateOf(Stage.VERIFYING)
    private var docFailure: DocFailure by mutableStateOf(DocFailure.TRANSPORT)
    private var pageCount by mutableIntStateOf(0)
    private var page by mutableIntStateOf(0)
    private var zoomIndex by mutableIntStateOf(FIT_INDEX)
    private val pageUi = mutableStateMapOf<Int, PageUi>()
    private val renderFence = OfficePdfRenderFence()

    /** Token of the record THIS screen claimed from the slot (Live or
     * StageFailed): the close path must free the slot even when no renderer
     * was ever attached (failure screen, task-swipe finish without back). */
    private var claimedToken: String? = null

    /** Non-null ONLY while this screen instance holds an attached renderer
     * lease on a live launch; every renderer-side call routes through it. */
    private var attachedToken: String? = null
    private var liveStaged: RunOutputPdfStaged? = null
    private var host: OfficePdfRenderHost? = null
    private var printPending by mutableStateOf(false)
    private var noticeKey: String? by mutableStateOf(null)

    private val controller: RunOutputPdfPreviewController?
        get() = (application as? FloeApplication)?.runOutputPdf

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val owner = controller
        val claim = owner?.claimForViewer(intent.getStringExtra(EXTRA_LAUNCH_TOKEN))
            ?: RunOutputPdfClaim.Expired
        when (claim) {
            is RunOutputPdfClaim.Live -> {
                // Attach the renderer owner lease BEFORE any host exists; a
                // refused attach means the launch retired concurrently.
                claimedToken = claim.staged.launchToken
                if (owner?.attachRenderer(claim.staged.launchToken) == true) {
                    attachedToken = claim.staged.launchToken
                    liveStaged = claim.staged
                    host = OfficePdfRenderHost(this)
                    startVerification(claim.staged)
                } else {
                    showExpired()
                }
            }
            is RunOutputPdfClaim.StageFailed -> {
                // The slot holds this failure record until an explicit close.
                claimedToken = intent.getStringExtra(EXTRA_LAUNCH_TOKEN)
                docFailure = mapStageFailure(claim.code)
                stage = Stage.FAILED
            }
            RunOutputPdfClaim.Expired -> showExpired()
        }

        val themeMode = FloeThemeStore(applicationContext).mode
        setContent {
            FloeTheme(themeMode = themeMode) {
                FloeSystemBarAppearance(themeMode)
                RunOutputPdfScreen(
                    // A non-live screen shows the failure title, NEVER the
                    // raw token (an opaque identity is not a document name).
                    title = liveStaged?.displayName
                        ?: stringResource(R.string.run_pdf_failed_title),
                    stage = stage,
                    failureKey = failureKey(),
                    pageCount = pageCount,
                    page = page,
                    zoomPercent = ZOOM_PERCENTS[zoomIndex],
                    pageUi = pageUi,
                    noticeKey = noticeKey,
                    printEnabled = stage == Stage.READY && pageCount > 0 && !printPending,
                    printBusy = printPending,
                    onBack = { closeAndFinish() },
                    onPrev = { if (page > 0) page-- },
                    onNext = { if (page < pageCount - 1) page++ },
                    onZoomIn = { applyZoom(zoomIndex + 1) },
                    onZoomOut = { applyZoom(zoomIndex - 1) },
                    onZoomFit = { applyZoom(FIT_INDEX) },
                    onRetryPage = { requestRender(page, force = true) },
                    onRetryDoc = { liveStaged?.let { startVerification(it) } },
                    onPrint = { requestPrint() },
                    onPageVisible = { requestRender(it, force = false) },
                )
            }
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = closeAndFinish()
        })
    }

    private fun showExpired() {
        docFailure = DocFailure.EXPIRED
        stage = Stage.FAILED
    }

    /** Explicit close: hand the launch to the owner accounting (the record
     * may still be draining/printing — that keeps the file until the last
     * real owner settles; NEVER a print cancel). */
    private fun closeAndFinish() {
        claimedToken?.let { controller?.onUserClose(it) }
        finish()
    }

    /** Staging failures are FINAL for this launch (the recovery flow is
     * refreshing/re-opening from the conversation, which re-proves bytes from
     * the durable receipt) — so none maps to the retryable TRANSPORT state,
     * and no screen ever shows a retry button that could retry nothing.
     * "source" covers every lane-refusal family (typed negatives including
     * the -702/-704 closed-mid-I/O fences, truncation/drift/digest or EOF
     * disagreement, storage denial): an unavailable stream is NEVER worded
     * as a document defect (lane 16 doctrine); only the closed PDF identity
     * refusals ("format": host-MIME/extension disagreement or non-%PDF-
     * magic) say the file isn't a readable PDF. */
    private fun mapStageFailure(code: String): DocFailure = when (code) {
        "ownerChanged" -> DocFailure.EXPIRED
        "contentTooLarge" -> DocFailure.TOO_LARGE
        "format" -> DocFailure.INVALID
        else -> DocFailure.GONE
    }

    private fun failureKey(): String = when (docFailure) {
        DocFailure.EXPIRED -> "expired"
        DocFailure.GONE -> "gone"
        DocFailure.TOO_LARGE -> "tooLarge"
        DocFailure.INVALID -> "invalid"
        DocFailure.PASSWORD -> "password"
        DocFailure.TRANSPORT -> "transport"
    }

    /**
     * Ask the isolated renderer for the REAL page count of the staged
     * snapshot (bytes were already proven at staging; a transport fault is
     * retryable here, document refusals are final for this snapshot).
     */
    private fun startVerification(staged: RunOutputPdfStaged) {
        val currentHost = host ?: return
        stage = Stage.VERIFYING
        noticeKey = null
        pageCount = 0
        page = 0
        pageUi.clear()
        val generation = renderFence.bump()
        currentHost.documentInfo(RunOutputPdfVerifiedSource(staged)) { result ->
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

    private fun requestRender(index: Int, force: Boolean) {
        if (stage != Stage.READY) return
        val staged = liveStaged ?: return
        val currentHost = host ?: return
        if (index !in 0 until pageCount) return
        val existing = pageUi[index]
        if (!force && (existing is PageUi.Ready || existing is PageUi.Loading)) return
        pageUi[index] = PageUi.Loading
        val zoom = ZOOM_PERCENTS[zoomIndex]
        val generation = renderFence.current()
        currentHost.renderPage(RunOutputPdfVerifiedSource(staged), index, zoom) { result ->
            // Fence: only the CURRENT verification generation may update the
            // map; superseded bitmaps are recycled, never shown for a wrong
            // page/zoom (the host additionally fences release-after-post now).
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

    /** Zoom mutation lives here so the raster invalidation can never be
     * skipped: every rendered page was baked at the old density. */
    private fun applyZoom(next: Int) {
        if (next == zoomIndex || next !in ZOOM_PERCENTS.indices) return
        zoomIndex = next
        renderFence.bump()
        pageUi.clear()
        requestRender(page, force = true)
    }

    /**
     * ONE print over the SAME verified source through the accepted
     * [OfficePdfPrintFlow]: the REAL renderer page count first (never a
     * guessed one), the exact-owned coordinator lease from admission until
     * the exactly-once [PrintFinish], and copy that only claims the SYSTEM
     * DIALOG was opened. Rotation or close of this screen never reaches the
     * framework job: the job belongs to the print framework until its own
     * finish settles the lease.
     */
    private fun requestPrint() {
        val staged = liveStaged ?: return
        val owner = controller ?: return
        val count = pageCount
        if (stage != Stage.READY || count < 1 || printPending) return
        if (!owner.beginPrintAttempt(staged.launchToken)) {
            noticeKey = "unavailable"
            return
        }
        printPending = true
        OfficePdfPrintFlow.requestPrint(
            this,
            RunOutputPdfVerifiedSource(staged),
            count,
            staged.displayName,
            onFinished = { _ ->
                // Exactly once per attempt — the ONLY print-side settlement.
                if (!isDestroyed && !isFinishing) printPending = false
                owner.onPrintSettled(staged.launchToken)
            },
        ) { outcome ->
            if (isDestroyed || isFinishing) return@requestPrint
            noticeKey = when (outcome) {
                PrintStartOutcome.DialogOpened -> "submitted"
                PrintStartOutcome.NoPrintService -> "unavailable"
                PrintStartOutcome.ActivityRetired -> "unavailable"
                PrintStartOutcome.SourceUnavailable -> "gone"
            }
        }
    }

    override fun onDestroy() {
        renderFence.bump()
        // A system-initiated finish (task swipe with a live process, an
        // external finish()) closes the launch exactly like Back: the slot
        // must not leak. isFinishing is FALSE across a configuration
        // destroy, so rotation never reaches this and can never unwind an
        // admitted print. onUserClose is idempotent for the back-button path.
        if (isFinishing) claimedToken?.let { controller?.onUserClose(it) }
        val token = attachedToken
        val currentHost = host
        attachedToken = null
        liveStaged = null
        host = null
        if (currentHost != null && token != null) {
            // Quiescent lease-join: the registry learns the descriptor truth
            // only after the owned worker drained every transaction.
            currentHost.release(onQuiescent = { controller?.onRendererQuiesced(token) })
        } else {
            currentHost?.release()
        }
        pageUi.clear()
        super.onDestroy()
    }
}

/**
 * Preview chrome: the existing Floe toolbar (Back left, document label
 * center, ONE bounded Print capsule action right), the page viewport with
 * honest per-page render state, one compact print-result notice line (which
 * only ever says the dialog was opened/unavailable), and the same bottom
 * page/zoom row as the module's PDF surface — pinned Floe tokens only, no
 * new large command surface.
 */
@Composable
private fun RunOutputPdfScreen(
    title: String,
    stage: RunOutputPdfPreviewActivity.Stage,
    failureKey: String,
    pageCount: Int,
    page: Int,
    zoomPercent: Int,
    pageUi: SnapshotStateMap<Int, RunOutputPdfPreviewActivity.PageUi>,
    noticeKey: String?,
    printEnabled: Boolean,
    printBusy: Boolean,
    onBack: () -> Unit,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onZoomIn: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomFit: () -> Unit,
    onRetryPage: () -> Unit,
    onRetryDoc: () -> Unit,
    onPrint: () -> Unit,
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
                    contentDescription = stringResource(R.string.run_pdf_back_cd),
                    onClick = onBack,
                )
            },
            actions = {
                if (stage == RunOutputPdfPreviewActivity.Stage.READY) {
                    FloeCapsuleButton(
                        label = stringResource(
                            if (printBusy) R.string.run_pdf_print_busy else R.string.run_pdf_print,
                        ),
                        enabled = printEnabled,
                        onClick = onPrint,
                    )
                    Spacer(Modifier.width(8.dp))
                }
            },
            showHairline = true,
        )
        when (stage) {
            RunOutputPdfPreviewActivity.Stage.VERIFYING -> Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 36.dp)
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator(modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = stringResource(R.string.run_pdf_opening),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }

            RunOutputPdfPreviewActivity.Stage.FAILED -> FloeUnavailableView(
                icon = FloeIcons.WarningTriangle,
                title = stringResource(R.string.run_pdf_failed_title),
                description = when (failureKey) {
                    "expired" -> stringResource(R.string.run_pdf_expired_info)
                    "password" -> stringResource(R.string.run_pdf_password_info)
                    "invalid" -> stringResource(R.string.run_pdf_invalid_info)
                    "tooLarge" -> stringResource(R.string.run_pdf_toolarge_info)
                    "transport" -> stringResource(R.string.run_pdf_transport_info)
                    else -> stringResource(R.string.run_pdf_gone_info)
                },
                // Transport faults are retryable (the renderer host may just
                // have been slow to bind); expired/absent/document refusals
                // are final for THIS launch and offer only Back — recovery is
                // re-opening from the conversation, which re-proves bytes from
                // the durable receipt.
                action = if (failureKey == "transport") {
                    { FloeCapsuleButton(stringResource(R.string.run_pdf_retry), onClick = onRetryDoc) }
                } else {
                    null
                },
            )

            RunOutputPdfPreviewActivity.Stage.READY -> {
                noticeKey?.let { key ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 24.dp)
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeText(
                            text = when (key) {
                                "submitted" -> stringResource(R.string.run_pdf_print_opened)
                                "gone" -> stringResource(R.string.run_pdf_print_gone)
                                "unavailable" -> stringResource(R.string.run_pdf_print_unavailable)
                                else -> stringResource(R.string.run_pdf_print_unavailable)
                            },
                            style = Floe.typography.evidence,
                            color = Floe.colors.secondaryLabel,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
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
                        contentDescription = stringResource(R.string.run_pdf_prev_cd),
                        onClick = onPrev,
                        enabled = page > 0,
                        visualSize = 36.dp,
                        iconSize = 18.dp,
                    )
                    FloeText(
                        text = stringResource(R.string.run_pdf_page_indicator, page + 1, pageCount),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.weight(1f),
                    )
                    FloeCircleButton(
                        icon = FloeIcons.ChevronForward,
                        contentDescription = stringResource(R.string.run_pdf_next_cd),
                        onClick = onNext,
                        enabled = page < pageCount - 1,
                        visualSize = 36.dp,
                        iconSize = 18.dp,
                    )
                    Spacer(Modifier.width(10.dp))
                    ZoomChip(label = stringResource(R.string.run_pdf_zoom_out), onClick = onZoomOut)
                    ZoomChip(label = stringResource(R.string.run_pdf_zoom_in), onClick = onZoomIn)
                    ZoomChip(label = stringResource(R.string.run_pdf_fit), onClick = onZoomFit)
                }
            }
        }
    }
}

@Composable
private fun PageViewport(
    modifier: Modifier,
    ui: RunOutputPdfPreviewActivity.PageUi?,
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
            null, is RunOutputPdfPreviewActivity.PageUi.Loading -> Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                FloeActivityIndicator(modifier = Modifier.size(24.dp))
            }

            is RunOutputPdfPreviewActivity.PageUi.Ready -> {
                val height = displayWidth * (ui.heightPx.toFloat() / ui.widthPx.toFloat())
                Image(
                    bitmap = ui.image,
                    contentDescription = null,
                    modifier = Modifier
                        .verticalScroll(vertical)
                        .horizontalScroll(horizontal)
                        .width(displayWidth)
                        .height(height),
                )
            }

            is RunOutputPdfPreviewActivity.PageUi.Failed -> Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.padding(24.dp),
                ) {
                    FloeText(
                        text = stringResource(R.string.run_pdf_render_failed),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloeCapsuleButton(stringResource(R.string.run_pdf_retry), onClick = onRetryPage)
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
