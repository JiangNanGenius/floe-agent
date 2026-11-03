// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.workbench.GenerationKind
import com.floe.android.feature.workbench.GenerationModelRoute
import com.floe.android.feature.workbench.ImageGenerationRequest
import com.floe.android.feature.workbench.ImageRequestState
import com.floe.android.feature.workbench.MediaCandidate
import com.floe.android.feature.workbench.MediaCandidateState
import com.floe.android.feature.workbench.MediaJobState
import com.floe.android.feature.workbench.MediaJobStatus
import com.floe.android.feature.workbench.VideoGenerationRequest
import com.floe.android.feature.workbench.ui.MediaInlineFailure
import com.floe.android.feature.workbench.ui.MediaInlineNotice
import com.floe.android.feature.workbench.ui.R
import com.floe.android.feature.workbench.ui.formatMediaDate
import com.floe.android.feature.workbench.ui.presentation.MediaBitmapLoader
import com.floe.android.feature.workbench.ui.presentation.MediaPreviewPaths
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import java.util.Locale
import java.util.UUID

/**
 * Generation sheet: configured model routes, a confirmed-review submission,
 * durable image requests/video jobs and candidates.
 *
 * Nothing here invents a model, price or placeholder image. A route that the
 * native host reports unavailable is not offered; provider credentials never
 * reach this UI. Candidate import goes through the host's CAS acceptance and
 * never replaces the project before acceptance.
 */
@Composable
internal fun MediaGenerationSheet(
    controller: MediaEditorController,
    onDismiss: () -> Unit,
) {
    val generation = controller.r2?.generation ?: return
    var tab by remember { mutableIntStateOf(0) }
    LaunchedEffect(controller.projectID) { generation.refreshAll() }
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                FloeText(
                    stringResource(R.string.media_r2_generate),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                if (generation.refreshing || generation.loadingCatalog) {
                    FloeActivityIndicator()
                }
                FloeCapsuleAction(
                    label = stringResource(R.string.media_refresh),
                    onClick = { generation.refreshAll() },
                    enabled = !generation.refreshing,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_done),
                    onClick = onDismiss,
                )
            }
            FloeDivider()
            FloeSegmented(
                options = listOf(
                    stringResource(R.string.media_r2_tab_assistant),
                    stringResource(R.string.media_r2_tab_candidates),
                    stringResource(R.string.media_r2_tab_jobs),
                ),
                selectedIndex = tab,
                onSelect = { tab = it },
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            )
            generation.failure?.let { failure ->
                MediaInlineFailure(
                    failure = failure,
                    onRetry = {
                        generation.clearFailure()
                        generation.refreshAll()
                    },
                )
            }
            generation.notice?.let { notice ->
                MediaInlineNotice(stringResource(notice.res()))
            }
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 16.dp),
            ) {
                when (tab) {
                    0 -> AssistantSection(controller)
                    1 -> CandidatesSection(controller)
                    else -> JobsSection(controller)
                }
            }
        }
    }
}

@Composable
private fun AssistantSection(controller: MediaEditorController) {
    val generation = controller.r2?.generation ?: return
    val catalog = generation.catalog
    if (catalog == null) {
        if (generation.loadingCatalog) {
            Row(
                Modifier.fillMaxWidth().padding(16.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.media_r2_models_loading),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        } else {
            FloeText(
                stringResource(R.string.media_r2_models_unavailable),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(16.dp),
            )
        }
        return
    }
    val imageRoutes = generation.imageRoutes.filter { it.enabled && it.available }
    val videoRoutes = generation.videoRoutes.filter { it.enabled && it.available }
    if (imageRoutes.isEmpty() && videoRoutes.isEmpty()) {
        FloeText(
            stringResource(R.string.media_r2_no_models_configured),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(16.dp),
        )
        val reason = (catalog.image + catalog.video)
            .firstNotNullOfOrNull { it.unavailableReason }
        if (reason != null) {
            FloeText(
                reason,
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        return
    }
    if (controller.isImageProject) {
        ImageGenerationSection(controller)
    }
    VideoGenerationSection(controller)
    GenerationPendingNotice(controller)
}

@Composable
private fun ImageGenerationSection(controller: MediaEditorController) {
    val generation = controller.r2?.generation ?: return
    val routes = generation.imageRoutes.filter { it.enabled && it.available }
    SectionHeader(stringResource(R.string.media_r2_image_generation))
    if (routes.isEmpty()) {
        FloeText(
            stringResource(R.string.media_r2_no_image_models),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
        return
    }
    var routeID by remember(routes) { mutableStateOf(routes.first().routeID) }
    val route = routes.firstOrNull { it.routeID == routeID } ?: routes.first()
    var prompt by remember(route.routeID) { mutableStateOf("") }
    val sizes = route.parameters.sizes
    var size by remember(route.routeID) { mutableStateOf(sizes?.firstOrNull()) }
    var count by remember(route.routeID) { mutableIntStateOf(1) }
    var sourceAssetID by remember(route.routeID) { mutableStateOf<String?>(null) }
    var review by remember { mutableStateOf<ImageReview?>(null) }
    val imageAssets = controller.project.assets.filter { it.kind == "image" }
    val supportsSource = route.referenceImagePolicy.maxImages > 0 || imageAssets.isNotEmpty()

    RouteChips(routes, route.routeID) { routeID = it }
    FloePlainFormField(
        label = stringResource(R.string.media_r2_image_prompt),
        value = prompt,
        onValueChange = { prompt = it.take(4000) },
        singleLine = false,
        maxLines = 5,
        minLines = 2,
        enabled = !generation.imageSubmitting,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
    if (sizes != null) {
        OptionChips(
            label = stringResource(R.string.media_r2_size),
            values = sizes,
            selected = size,
            onSelect = { size = it },
        )
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeText(
            stringResource(R.string.media_r2_count, count),
            style = Floe.typography.body,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(
            label = "−",
            onClick = { count = (count - 1).coerceAtLeast(1) },
            enabled = count > 1,
            showHairline = false,
        )
        FloeCapsuleAction(
            label = "+",
            onClick = { count = (count + 1).coerceAtMost(route.parameters.maxCount.coerceAtLeast(1)) },
            enabled = count < route.parameters.maxCount,
            showHairline = false,
        )
    }
    if (supportsSource && imageAssets.isNotEmpty()) {
        FloeText(
            stringResource(R.string.media_r2_source_image),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(start = 16.dp, top = 4.dp),
        )
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_none),
                onClick = { sourceAssetID = null },
                tint = if (sourceAssetID == null) Floe.colors.accent else null,
            )
            imageAssets.forEach { asset ->
                FloeCapsuleAction(
                    label = asset.originalName,
                    onClick = { sourceAssetID = asset.id },
                    tint = if (sourceAssetID == asset.id) Floe.colors.accent else null,
                )
            }
        }
    }
    FloeText(
        route.costNote,
        style = Floe.typography.metadata,
        color = Floe.colors.tertiaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_review_generate),
            onClick = {
                review = ImageReview(
                    route = route,
                    prompt = prompt.trim(),
                    size = size,
                    count = count,
                    sourceAssetID = sourceAssetID,
                )
            },
            enabled = prompt.isNotBlank() && !generation.imageSubmitting,
            tint = Floe.colors.accent,
        )
    }
    review?.let { pending ->
        ReviewCard(
            title = stringResource(R.string.media_r2_review_image_title),
            lines = listOf(
                stringResource(R.string.media_r2_model_value, pending.route.providerName,
                    pending.route.remoteModelID),
                stringResource(R.string.media_r2_prompt_value, pending.prompt.take(240)),
                pending.size?.let { stringResource(R.string.media_r2_size_value, it) },
                stringResource(R.string.media_r2_count_value, pending.count),
                pending.sourceAssetID?.let {
                    stringResource(
                        R.string.media_r2_source_value,
                        controller.asset(it)?.originalName ?: it,
                    )
                },
                pending.route.costNote,
            ).filterNotNull(),
            confirmLabel = stringResource(R.string.media_r2_generate),
            busy = generation.imageSubmitting,
            onConfirm = {
                controller.submitImageGeneration(
                    ImageGenerationRequest(
                        prompt = pending.prompt,
                        modelRouteID = pending.route.routeID,
                        size = pending.size,
                        count = pending.count,
                        sourceAssetID = pending.sourceAssetID,
                        idempotencyKey = UUID.randomUUID().toString(),
                    ),
                )
                review = null
            },
            onDismiss = { review = null },
        )
    }
}

@Composable
private fun VideoGenerationSection(controller: MediaEditorController) {
    val generation = controller.r2?.generation ?: return
    val routes = generation.videoRoutes.filter { it.enabled && it.available }
    if (routes.isEmpty()) return
    SectionHeader(stringResource(R.string.media_r2_video_generation))
    var routeID by remember(routes) { mutableStateOf(routes.first().routeID) }
    val route = routes.firstOrNull { it.routeID == routeID } ?: routes.first()
    var prompt by remember(route.routeID) { mutableStateOf("") }
    var duration by remember(route.routeID) {
        mutableStateOf(route.parameters.durationSeconds?.firstOrNull())
    }
    var aspect by remember(route.routeID) {
        mutableStateOf(route.parameters.aspectRatios?.firstOrNull())
    }
    var resolution by remember(route.routeID) {
        mutableStateOf(route.parameters.resolutions?.firstOrNull())
    }
    var sourceAssetID by remember(route.routeID) { mutableStateOf<String?>(null) }
    var review by remember { mutableStateOf<VideoReview?>(null) }
    val imageAssets = controller.project.assets.filter { it.kind == "image" }
    val supportsSource = route.parameters.supportsImageToVideo ||
        route.referenceImagePolicy.maxImages > 0

    RouteChips(routes, route.routeID) { routeID = it }
    FloePlainFormField(
        label = stringResource(R.string.media_r2_video_prompt),
        value = prompt,
        onValueChange = { prompt = it.take(4000) },
        singleLine = false,
        maxLines = 5,
        minLines = 2,
        enabled = !generation.videoSubmitting,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
    route.parameters.durationSeconds?.takeIf { it.isNotEmpty() }?.let { values ->
        OptionChips(
            label = stringResource(R.string.media_r2_duration),
            values = values.map { String.format(Locale.US, "%.0fs", it) },
            selected = duration?.let { String.format(Locale.US, "%.0fs", it) },
            onSelect = { label ->
                duration = values.firstOrNull {
                    String.format(Locale.US, "%.0fs", it) == label
                }
            },
        )
    }
    route.parameters.aspectRatios?.takeIf { it.isNotEmpty() }?.let { values ->
        OptionChips(
            label = stringResource(R.string.media_r2_aspect),
            values = values,
            selected = aspect,
            onSelect = { aspect = it },
        )
    }
    route.parameters.resolutions?.takeIf { it.isNotEmpty() }?.let { values ->
        OptionChips(
            label = stringResource(R.string.media_r2_resolution),
            values = values,
            selected = resolution,
            onSelect = { resolution = it },
        )
    }
    if (supportsSource && imageAssets.isNotEmpty()) {
        FloeText(
            stringResource(R.string.media_r2_source_image),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(start = 16.dp, top = 4.dp),
        )
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_none),
                onClick = { sourceAssetID = null },
                tint = if (sourceAssetID == null) Floe.colors.accent else null,
            )
            imageAssets.forEach { asset ->
                FloeCapsuleAction(
                    label = asset.originalName,
                    onClick = { sourceAssetID = asset.id },
                    tint = if (sourceAssetID == asset.id) Floe.colors.accent else null,
                )
            }
        }
    }
    FloeText(
        route.costNote,
        style = Floe.typography.metadata,
        color = Floe.colors.tertiaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_review_submit),
            onClick = {
                review = VideoReview(
                    route = route,
                    prompt = prompt.trim(),
                    duration = duration,
                    aspect = aspect,
                    resolution = resolution,
                    sourceAssetID = sourceAssetID,
                )
            },
            enabled = prompt.isNotBlank() && !generation.videoSubmitting,
            tint = Floe.colors.accent,
        )
    }
    review?.let { pending ->
        ReviewCard(
            title = stringResource(R.string.media_r2_review_video_title),
            lines = listOf(
                stringResource(R.string.media_r2_model_value, pending.route.providerName,
                    pending.route.remoteModelID),
                stringResource(R.string.media_r2_prompt_value, pending.prompt.take(240)),
                pending.duration?.let {
                    stringResource(R.string.media_r2_duration_value,
                        String.format(Locale.US, "%.0fs", it))
                },
                pending.aspect?.let { stringResource(R.string.media_r2_aspect_value, it) },
                pending.resolution?.let {
                    stringResource(R.string.media_r2_resolution_value, it)
                },
                pending.sourceAssetID?.let {
                    stringResource(
                        R.string.media_r2_source_value,
                        controller.asset(it)?.originalName ?: it,
                    )
                },
                pending.route.costNote,
            ).filterNotNull(),
            confirmLabel = stringResource(R.string.media_r2_submit),
            busy = generation.videoSubmitting,
            onConfirm = {
                controller.submitVideoGeneration(
                    VideoGenerationRequest(
                        prompt = pending.prompt,
                        modelRouteID = pending.route.routeID,
                        durationSeconds = pending.duration,
                        aspectRatio = pending.aspect,
                        resolution = pending.resolution,
                        sourceAssetID = pending.sourceAssetID,
                        idempotencyKey = UUID.randomUUID().toString(),
                    ),
                )
                review = null
            },
            onDismiss = { review = null },
        )
    }
}

@Composable
private fun GenerationPendingNotice(controller: MediaEditorController) {
    val generation = controller.r2?.generation ?: return
    generation.pendingImageRequest?.let { request ->
        ReviewCard(
            title = stringResource(R.string.media_r2_unconfirmed_request),
            lines = listOf(
                stringResource(R.string.media_r2_unconfirmed_body),
                stringResource(R.string.media_r2_prompt_value, request.prompt.take(240)),
            ),
            confirmLabel = stringResource(R.string.media_r2_submit_again),
            busy = generation.imageSubmitting,
            onConfirm = { generation.retryPendingImage(controller.revision) },
            onDismiss = { generation.discardPendingImage() },
            dismissLabel = stringResource(R.string.media_r2_discard),
        )
    }
    generation.pendingVideoRequest?.let { request ->
        ReviewCard(
            title = stringResource(R.string.media_r2_unconfirmed_request),
            lines = listOf(
                stringResource(R.string.media_r2_unconfirmed_body),
                stringResource(R.string.media_r2_prompt_value, request.prompt.take(240)),
            ),
            confirmLabel = stringResource(R.string.media_r2_submit_again),
            busy = generation.videoSubmitting,
            onConfirm = { generation.retryPendingVideo(controller.revision) },
            onDismiss = { generation.discardPendingVideo() },
            dismissLabel = stringResource(R.string.media_r2_discard),
        )
    }
}

@Composable
private fun CandidatesSection(controller: MediaEditorController) {
    val generation = controller.r2?.generation ?: return
    val candidates = generation.candidates
    if (candidates.isEmpty()) {
        FloeText(
            stringResource(R.string.media_r2_no_candidates),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(16.dp),
        )
        return
    }
    FloeText(
        stringResource(R.string.media_r2_candidates_note),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    )
    candidates.forEach { candidate ->
        CandidateRow(controller, candidate)
        FloeDivider()
    }
}

@Composable
private fun CandidateRow(
    controller: MediaEditorController,
    candidate: MediaCandidate,
) {
    val generation = controller.r2?.generation ?: return
    val busy = candidate.candidateID in generation.busyCandidates
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CandidateThumb(controller, candidate)
        Column(Modifier.weight(1f)) {
            FloeText(
                candidate.relativePath.substringAfterLast('/'),
                style = Floe.typography.metadata,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                listOfNotNull(
                    candidate.modelDisplayName,
                    candidate.kind.name.lowercase(Locale.US),
                ).joinToString(" · "),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                maxLines = 1,
            )
            FloeBadgePill(
                text = stringResource(candidateStateRes(candidate.state)),
                tone = when (candidate.state) {
                    MediaCandidateState.PENDING -> FloeBadgeTone.ACCENT
                    MediaCandidateState.ACCEPTED -> FloeBadgeTone.SUCCESS
                    MediaCandidateState.REJECTED -> FloeBadgeTone.SECONDARY
                    MediaCandidateState.STALE -> FloeBadgeTone.PENDING
                },
            )
        }
        when (candidate.state) {
            MediaCandidateState.PENDING -> {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_import),
                    onClick = { controller.acceptGenerationCandidate(candidate.candidateID) },
                    enabled = !busy && !controller.busy && !controller.needsReload,
                    tint = Floe.colors.accent,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_reject),
                    onClick = { controller.rejectGenerationCandidate(candidate.candidateID) },
                    enabled = !busy,
                    tint = Floe.colors.destructive,
                    showHairline = false,
                )
            }
            else -> if (busy) FloeActivityIndicator()
        }
    }
}

@Composable
private fun CandidateThumb(
    controller: MediaEditorController,
    candidate: MediaCandidate,
) {
    var bitmap by remember(candidate.candidateID, candidate.sha256) {
        mutableStateOf<Bitmap?>(null)
    }
    LaunchedEffect(candidate.candidateID, candidate.sha256) {
        val path = MediaPreviewPaths.resolve(controller.mediaRootPath, candidate.relativePath)
        bitmap = path?.let { MediaBitmapLoader.load(it) }
    }
    Box(
        Modifier.size(56.dp).clip(RoundedCornerShape(8.dp))
            .background(Floe.colors.fillTertiary),
        contentAlignment = Alignment.Center,
    ) {
        val image = bitmap
        if (image != null) {
            Image(
                bitmap = image.asImageBitmap(),
                contentDescription = stringResource(R.string.media_r2_candidate_preview),
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            IconGlyph(
                if (candidate.kind == GenerationKind.VIDEO) {
                    FloeIcons.PlayRuns
                } else {
                    FloeIcons.Photo
                },
                Floe.colors.secondaryLabel,
                22.dp,
            )
        }
    }
}

@Composable
private fun JobsSection(controller: MediaEditorController) {
    val generation = controller.r2?.generation ?: return
    if (generation.imageRequests.isEmpty() && generation.jobs.isEmpty()) {
        FloeText(
            stringResource(R.string.media_r2_no_jobs),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(16.dp),
        )
        return
    }
    if (generation.imageRequests.isNotEmpty()) {
        SectionHeader(stringResource(R.string.media_r2_image_requests))
        generation.imageRequests.forEach { request ->
            RequestRow(
                title = stringResource(R.string.media_r2_image_request),
                state = stringResource(imageRequestStateRes(request.state)),
                detail = formatMediaDate(request.updatedAt),
                error = request.errorCode,
                busy = request.requestID in generation.busyJobs,
                actions = {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_refresh),
                        onClick = { controller.refreshImageRequest(request.requestID) },
                        enabled = request.requestID !in generation.busyJobs,
                        showHairline = false,
                    )
                    if (request.state != ImageRequestState.DISMISSED) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.media_r2_dismiss),
                            onClick = { controller.dismissImageRequest(request.requestID) },
                            enabled = request.requestID !in generation.busyJobs,
                            tint = Floe.colors.destructive,
                            showHairline = false,
                        )
                    }
                },
            )
        }
    }
    if (generation.jobs.isNotEmpty()) {
        SectionHeader(stringResource(R.string.media_r2_video_jobs))
        generation.jobs.forEach { job ->
            JobRow(controller, job)
        }
    }
}

@Composable
private fun JobRow(controller: MediaEditorController, job: MediaJobStatus) {
    val generation = controller.r2?.generation ?: return
    val terminal = job.state in setOf(
        MediaJobState.COMPLETED,
        MediaJobState.FAILED,
        MediaJobState.CANCELLED,
        MediaJobState.INTERRUPTED,
    )
    RequestRow(
        title = stringResource(R.string.media_r2_video_job),
        state = stringResource(jobStateRes(job.state)),
        detail = listOfNotNull(
            formatMediaDate(job.updatedAt),
            job.progressHint?.let { String.format(Locale.US, "%.0f%%", it * 100) },
        ).joinToString(" · "),
        error = job.lastErrorCode,
        busy = job.jobID in generation.busyJobs,
        actions = {
            FloeCapsuleAction(
                label = stringResource(R.string.media_refresh),
                onClick = { controller.refreshGenerationJob(job.jobID) },
                enabled = job.jobID !in generation.busyJobs,
                showHairline = false,
            )
            if (!terminal) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_cancel),
                    onClick = { controller.cancelGenerationJob(job.jobID) },
                    enabled = job.canCancel && job.jobID !in generation.busyJobs,
                    tint = Floe.colors.destructive,
                    showHairline = false,
                )
            }
            if (job.resultAvailable) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_deliver),
                    onClick = { controller.deliverGenerationResult(job.jobID) },
                    enabled = job.jobID !in generation.busyJobs,
                    tint = Floe.colors.accent,
                )
            }
        },
    )
    if (job.state == MediaJobState.OUTCOME_UNKNOWN) {
        FloeText(
            stringResource(R.string.media_r2_outcome_unknown_body),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
        )
    }
}

@Composable
private fun RequestRow(
    title: String,
    state: String,
    detail: String,
    error: String?,
    busy: Boolean,
    actions: @Composable () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                FloeText(title, style = Floe.typography.bodyEmphasized)
                FloeText(
                    state,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                if (detail.isNotBlank()) {
                    FloeText(
                        detail,
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                    )
                }
                if (error != null) {
                    FloeText(
                        stringResource(R.string.media_r2_request_failed),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                }
            }
            if (busy) {
                FloeActivityIndicator()
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) { actions() }
            }
        }
    }
}

@Composable
private fun ReviewCard(
    title: String,
    lines: List<String>,
    confirmLabel: String,
    busy: Boolean,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    dismissLabel: String = stringResource(R.string.media_cancel),
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.fillTertiary)
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FloeText(title, style = Floe.typography.bodyEmphasized)
        lines.filter { it.isNotBlank() }.forEach { line ->
            FloeText(
                line,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(top = 4.dp),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeCapsuleAction(
                label = dismissLabel,
                onClick = onDismiss,
                enabled = !busy,
            )
            FloeCapsuleAction(
                label = confirmLabel,
                onClick = onConfirm,
                enabled = !busy,
                tint = Floe.colors.accent,
            )
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    FloeDivider(Modifier.padding(top = 8.dp))
    FloeText(
        title,
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

@Composable
private fun RouteChips(
    routes: List<GenerationModelRoute>,
    selectedID: String,
    onSelect: (String) -> Unit,
) {
    FloeText(
        stringResource(R.string.media_r2_model),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 16.dp, top = 4.dp),
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        routes.forEach { route ->
            FloeCapsuleAction(
                label = "${route.providerName} · ${route.remoteModelID}",
                onClick = { onSelect(route.routeID) },
                tint = if (route.routeID == selectedID) Floe.colors.accent else null,
            )
        }
    }
}

@Composable
private fun OptionChips(
    label: String,
    values: List<String>,
    selected: String?,
    onSelect: (String) -> Unit,
) {
    FloeText(
        label,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 16.dp, top = 4.dp),
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        values.forEach { value ->
            FloeCapsuleAction(
                label = value,
                onClick = { onSelect(value) },
                tint = if (value == selected) Floe.colors.accent else null,
            )
        }
    }
}

private fun GenerationNotice.res(): Int = when (this) {
    GenerationNotice.IMAGE_SUBMITTED -> R.string.media_r2_notice_image_submitted
    GenerationNotice.VIDEO_SUBMITTED -> R.string.media_r2_notice_video_submitted
    GenerationNotice.JOB_REFRESHED -> R.string.media_r2_notice_refreshed
    GenerationNotice.JOB_CANCELLED -> R.string.media_r2_notice_cancelled
    GenerationNotice.RESULT_DELIVERED -> R.string.media_r2_notice_delivered
    GenerationNotice.RESULT_NOT_READY -> R.string.media_r2_notice_not_ready
    GenerationNotice.CANDIDATE_ACCEPTED -> R.string.media_r2_notice_candidate_accepted
    GenerationNotice.CANDIDATE_REJECTED -> R.string.media_r2_notice_candidate_rejected
    GenerationNotice.REQUEST_DISMISSED -> R.string.media_r2_notice_dismissed
    GenerationNotice.OUTCOME_UNKNOWN -> R.string.media_r2_notice_outcome_unknown
    GenerationNotice.UNKNOWN_REQUEST -> R.string.media_r2_notice_unknown_request
}

private fun imageRequestStateRes(state: ImageRequestState): Int = when (state) {
    ImageRequestState.SUBMITTED -> R.string.media_r2_state_submitted
    ImageRequestState.RUNNING -> R.string.media_r2_state_running
    ImageRequestState.COMPLETED -> R.string.media_r2_state_completed
    ImageRequestState.FAILED -> R.string.media_r2_state_failed
    ImageRequestState.INTERRUPTED -> R.string.media_r2_state_interrupted
    ImageRequestState.OUTCOME_UNKNOWN -> R.string.media_r2_state_unknown
    ImageRequestState.DISMISSED -> R.string.media_r2_state_dismissed
}

private fun jobStateRes(state: MediaJobState): Int = when (state) {
    MediaJobState.SUBMITTED -> R.string.media_r2_state_submitted
    MediaJobState.RUNNING -> R.string.media_r2_state_running
    MediaJobState.WAITING_FOR_PROVIDER -> R.string.media_r2_state_waiting
    MediaJobState.DOWNLOADING -> R.string.media_r2_state_downloading
    MediaJobState.COMPLETED -> R.string.media_r2_state_completed
    MediaJobState.FAILED -> R.string.media_r2_state_failed
    MediaJobState.CANCELLED -> R.string.media_r2_state_cancelled
    MediaJobState.INTERRUPTED -> R.string.media_r2_state_interrupted
    MediaJobState.OUTCOME_UNKNOWN -> R.string.media_r2_state_unknown
}

private fun candidateStateRes(state: MediaCandidateState): Int = when (state) {
    MediaCandidateState.PENDING -> R.string.media_r2_candidate_pending
    MediaCandidateState.ACCEPTED -> R.string.media_r2_candidate_accepted
    MediaCandidateState.REJECTED -> R.string.media_r2_candidate_rejected
    MediaCandidateState.STALE -> R.string.media_r2_candidate_stale
}

private data class ImageReview(
    val route: GenerationModelRoute,
    val prompt: String,
    val size: String?,
    val count: Int,
    val sourceAssetID: String?,
)

private data class VideoReview(
    val route: GenerationModelRoute,
    val prompt: String,
    val duration: Double?,
    val aspect: String?,
    val resolution: String?,
    val sourceAssetID: String?,
)
