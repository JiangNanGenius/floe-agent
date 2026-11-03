// SPDX-License-Identifier: MPL-2.0
//
// C02 App-host adapter for the guided MCP service setup.
//
// Main constructs ONE instance with the Application scope and the trusted
// asset opener, then delegates the IntegrationUiCallbacks guided-setup
// methods here and collects [state] into the integrations destination
// projection. It never owns MCP configuration, credentials or a process: all
// effects are the native domain's real project/environment/job/service/save
// path. `onCommitted` asks the existing MCP settings controller to re-read
// the real server row.
package com.floe.android.host.mcpsetup

import com.floe.android.feature.integrations.McpSetupEnvironmentUi
import com.floe.android.feature.integrations.McpSetupOptionsUi
import com.floe.android.feature.integrations.McpSetupProjectUi
import com.floe.android.feature.integrations.McpSetupReceiptUi
import com.floe.android.feature.integrations.McpSetupRecordUi
import com.floe.android.feature.integrations.McpSetupStartRequestUi
import com.floe.android.feature.integrations.McpSetupStepUi
import com.floe.android.feature.integrations.McpSetupUiState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

class McpSetupHostController(
    scope: CoroutineScope,
    assetOpen: (String) -> ByteArray,
    onCommitted: () -> Unit,
) {
    private val coordinator = McpSetupCoordinator(
        scope = scope,
        client = McpSetupClient(),
        template = McpSetupTemplateProviding {
            McpSetupTemplateAsset.load(assetOpen)
        },
        onCommitted = { _ -> onCommitted() },
    )

    val state: StateFlow<McpSetupUiState> = coordinator.state
        .map { snapshot -> snapshot.toUi() }
        .stateIn(scope, SharingStarted.Eagerly, coordinator.state.value.toUi())

    fun load(projectId: String? = null) {
        coordinator.load(projectId)
    }

    fun loadEnvironments(projectId: String) {
        coordinator.selectProject(projectId)
    }

    fun start(request: McpSetupStartRequestUi): Boolean {
        coordinator.start(
            McpSetupDraftDto(
                displayName = request.displayName,
                projectId = request.projectId,
                environmentId = request.environmentId,
                portText = request.portText,
                details = request.details,
                allowInCanvas = request.allowInCanvas,
            ),
        )
        return true
    }

    fun cancel(recordId: String, revision: Long) {
        val current = coordinator.state.value.record
        if (current == null || current.id != recordId || current.revision != revision) {
            coordinator.load()
            return
        }
        coordinator.cancel()
    }

    fun discard(recordId: String, revision: Long) {
        val current = coordinator.state.value.record
        if (current == null || current.id != recordId || current.revision != revision) {
            coordinator.load()
            return
        }
        coordinator.discard()
    }

    fun clearError() = coordinator.clearError()

    fun retryCommit(recordId: String, revision: Long) {
        coordinator.retryCommit(recordId, revision)
    }

    /** Leaving the surface: a live operation is cancelled through its owned
     * native lanes; terminal records stay available for review/removal. */
    fun close() {
        if (coordinator.state.value.busy || coordinator.state.value.record?.busy == true) {
            coordinator.cancel()
        }
    }

    private fun McpSetupSnapshot.toUi(): McpSetupUiState {
        val optionsUi = McpSetupOptionsUi(
            loading = loading,
            projects = projects.map { McpSetupProjectUi(it.id, it.name) },
            environments = environments.map {
                McpSetupEnvironmentUi(it.id, it.label, it.backend)
            },
            selectedProjectId = selectedProjectId,
            templateAvailable = templateAvailable,
            serviceLaneAvailable = capabilities?.serviceLaneAvailable == true,
            generationAvailable = capabilities?.generationAvailable == true,
            stdioAvailable = capabilities?.stdioLaneAvailable == true,
            errorMessage = error?.message,
        )
        return McpSetupUiState(
            options = optionsUi,
            record = record?.toUi(),
            busy = busy,
            errorCode = error?.code,
            errorMessage = error?.message,
        )
    }

    private fun McpSetupRecordDto.toUi(): McpSetupRecordUi = McpSetupRecordUi(
        id = id,
        revision = revision,
        phase = phase,
        busy = busy,
        displayName = displayName,
        projectName = projectName,
        environmentLabel = environmentLabel,
        port = port,
        serviceEndpoint = serviceEndpoint,
        errorCode = errorCode,
        errorMessage = errorMessage,
        steps = steps.map {
            McpSetupStepUi(
                name = it.name,
                state = it.state,
                exitCode = it.exitCode,
                errorCode = it.errorCode,
            )
        },
        receipt = receipt?.let {
            McpSetupReceiptUi(
                endpoint = it.endpoint,
                smokeDigest = it.smokeDigest,
                verifiedTools = it.verifiedTools,
                serverId = it.serverId,
            )
        },
    )
}
