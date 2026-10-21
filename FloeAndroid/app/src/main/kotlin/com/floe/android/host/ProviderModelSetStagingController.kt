// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.ProviderModelSetNative
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Trusted-host MODEL-SET staging seam (App side), replaceable only
 * in-module so JVM fixtures exercise the real controller wiring without
 * the native library — the exact pattern of [HostDraftProbe] /
 * [HostSecureIngressSubmitter]. Production is the JNI bridge; there is NO
 * model/tool/V3 reachability and no command vocabulary.
 *
 * Refusal codes are closed identifiers (never row content); the numeric
 * native table lives on [ProviderModelSetNative].
 */
internal interface HostModelSetStager {
    /** Returns the canonical `msb:v1:<32hex>` stage id, or null (refused). */
    fun begin(
        providerID: String,
        baseResourceID: String,
        baseVersion: String,
        createIntent: Boolean,
        routeToken: String,
    ): String?

    /** Ordered idempotent chunk append; false on any typed refusal. */
    fun append(stageID: String, index: Int, chunk: ByteArray, routeToken: String): Boolean

    /** Seal + return the frozen ref `ms:v1:<32hex>.<64hex>`, or null. */
    fun seal(stageID: String, expectedCount: Int, routeToken: String): String?

    /** Exact-owner cancel of this editor's stage; idempotent. */
    fun cancel(stageID: String, routeToken: String): Boolean
}

internal object NativeHostModelSetStager : HostModelSetStager {
    override fun begin(
        providerID: String,
        baseResourceID: String,
        baseVersion: String,
        createIntent: Boolean,
        routeToken: String,
    ): String? = try {
        ProviderModelSetNative.beginModelSet(
            providerID, baseResourceID, baseVersion, createIntent, routeToken)
    } catch (t: Throwable) {
        // Native library absent / refused: fail closed. The save path
        // reports the typed staging failure; nothing is invented.
        null
    }

    override fun append(
        stageID: String,
        index: Int,
        chunk: ByteArray,
        routeToken: String,
    ): Boolean = try {
        ProviderModelSetNative.appendModelSetChunk(stageID, routeToken, index, chunk) == 0
    } catch (t: Throwable) {
        false
    } finally {
        chunk.fill(0)
    }

    override fun seal(
        stageID: String,
        expectedCount: Int,
        routeToken: String,
    ): String? = try {
        ProviderModelSetNative.sealModelSet(stageID, routeToken, expectedCount)
    } catch (t: Throwable) {
        null
    }

    override fun cancel(stageID: String, routeToken: String): Boolean = try {
        ProviderModelSetNative.cancelModelSet(stageID, routeToken) == 0
    } catch (t: Throwable) {
        // A failed cancel is a no-op against the exact-ownership rule; the
        // route/epoch fence retires the stage anyway (RAM only).
        false
    }
}

/** Terminal of one staging attempt: the frozen ref, or a closed refusal. */
internal sealed interface StagedModelSet {
    data class Frozen(val ref: String) : StagedModelSet
    data class Refused(val code: String) : StagedModelSet
}

/**
 * Owns the per-editor bounded staging of a FULL large selected-model body
 * into the trusted host (Main direction B/C — never the public JSON
 * ingress, never a truncated model set):
 *
 *  * rows are the EXACT same closed `ModelProfile` JSON objects the inline
 *    candidate would carry ([ProviderWire.modelProfileJson]) — same codec,
 *    same stable UUIDs, same capability defaults; nothing is re-encoded
 *    into a second representation;
 *  * chunks are ordered, each within the PROVEN per-chunk bound (the
 *    original single-model `config.model.save` payload class, 61,440
 *    bytes — NOT the 16 KiB candidate bound; budgets are not raised and
 *    the native registry re-enforces every bound authoritatively);
 *  * the stage binds the actual provider id + the live editor route + the
 *    actual base revision / create intent; sealing freezes the immutable
 *    canonical digest and returns the small frozen ref the candidate
 *    carries (mutually exclusive with inline selectedModels);
 *  * at most one live stage per editor is tracked here: a retry re-stages
 *    (the previous un-consumed stage is cancelled first) and an editor
 *    close cancels its un-consumed stage. An ACCEPTED save already owns
 *    its typed copy natively, so these cancels can never evict
 *    accepted-save data — they only discard un-consumed drafts, exactly
 *    as the draft-probe slot rules do;
 *  * a refused stage NEVER falls back to a partial/optimistic save: the
 *    save fails preflight with a closed typed code, honestly.
 */
internal class ProviderModelSetStagingController(
    private val stager: HostModelSetStager = NativeHostModelSetStager,
) {
    /** editorID → (stageID, routeToken) of this editor's live stage. */
    private val liveStages = ConcurrentHashMap<String, Pair<String, String>>()

    /**
     * Stage the complete [rows] body and return the frozen reference for
     * the save candidate. [baseResourceID]/[baseVersion] are the ACTUAL
     * persisted revision pair (create ⇒ `provider.<id>` + "0"), taken from
     * the same values the command envelope/lease will carry — never a
     * second invented binding.
     */
    fun stage(
        editorID: String,
        providerID: String,
        baseResourceID: String,
        baseVersion: String,
        createIntent: Boolean,
        routeToken: String,
        rows: List<JsonObject>,
    ): StagedModelSet {
        if (!isOpaqueHostRouteToken(routeToken)) {
            return StagedModelSet.Refused("model_set_route_unavailable")
        }
        // The proven supported per-provider bound (UNCHANGED native 512):
        // refuse locally with a closed code rather than feeding chunks
        // native must refuse. An empty body never needs staging (the small
        // inline path covers it), so a staged call with zero rows is a
        // caller bug, refused honestly.
        if (rows.isEmpty()) return StagedModelSet.Refused("model_set_empty")
        if (rows.size > MAX_STAGE_ROWS) return StagedModelSet.Refused("model_set_count")
        // Retry/re-stage discipline: discard this editor's previous
        // un-consumed stage BEFORE taking native capacity.
        cancelRecorded(editorID)
        val stageID = stager.begin(
            providerID, baseResourceID, baseVersion, createIntent, routeToken,
        ) ?: return StagedModelSet.Refused("model_set_unavailable")
        liveStages[editorID] = stageID to routeToken
        var index = 0
        var pending = ArrayList<JsonObject>()
        // pendingBytes = 2 (the "[]" enclosure) + rows + commas.
        var pendingBytes = 2
        for (row in rows) {
            // Original config.model.save accepts a bare snapshot up to
            // 61,440 bytes. Array enclosure must not shrink that bound.
            val rowText = row.toString()
            val rowBytes = rowText.encodeToByteArray().size
            if (rowBytes > MAX_ROW_JSON_BYTES) {
                discardCurrent(editorID)
                return StagedModelSet.Refused("model_set_row_unsupported")
            }
            if (rowBytes + 2 > MAX_CHUNK_BYTES) {
                if (pending.isNotEmpty()) {
                    if (!flushChunk(editorID, index, pending)) {
                        return StagedModelSet.Refused("model_set_chunk_refused")
                    }
                    index += 1
                    pending = ArrayList()
                    pendingBytes = 2
                }
                // A singleton bare snapshot preserves the original legal
                // final two bytes without raising any chunk/frame bound.
                if (!flushEncodedChunk(editorID, index, rowText.encodeToByteArray())) {
                    return StagedModelSet.Refused("model_set_chunk_refused")
                }
                index += 1
                continue
            }
            val projected = if (pending.isEmpty()) 2 + rowBytes
                else pendingBytes + 1 + rowBytes
            if (pending.isNotEmpty() && projected > MAX_CHUNK_BYTES) {
                if (!flushChunk(editorID, index, pending)) {
                    return StagedModelSet.Refused("model_set_chunk_refused")
                }
                index += 1
                pending = ArrayList()
                pendingBytes = 2
            }
            pending.add(row)
            pendingBytes = if (pending.size == 1) 2 + rowBytes else pendingBytes + 1 + rowBytes
        }
        if (pending.isNotEmpty()) {
            if (!flushChunk(editorID, index, pending)) {
                return StagedModelSet.Refused("model_set_chunk_refused")
            }
        }
        val ref = stager.seal(stageID, rows.size, routeToken)
        if (ref == null) {
            discardCurrent(editorID)
            return StagedModelSet.Refused("model_set_seal_refused")
        }
        // The stage stays RECORDED for the exact-owner cancel discipline:
        // an accepted save owns its typed copy natively, so editor close
        // (or the next re-stage) can safely cancel only the record.
        return StagedModelSet.Frozen(ref)
    }

    /**
     * Editor close / route retirement: cancel this editor's un-consumed
     * stage (staging or sealed). Never touches another editor's stage
     * (exact-owner native rule), and never affects an accepted save's
     * retained typed values.
     */
    fun discardFor(editorID: String) {
        cancelRecorded(editorID)
    }

    /** Host stop hygiene: discard every stage THIS controller tracks.
     *  The native epoch/route fences own the authoritative retirement
     *  regardless; this only releases the App-side bookkeeping. */
    fun discardAll() {
        liveStages.keys.toList().forEach { cancelRecorded(it) }
    }

    /** Test/fixture seam: the editor's currently tracked stage, if any. */
    internal fun trackedStage(editorID: String): Pair<String, String>? =
        liveStages[editorID]

    private fun flushChunk(
        editorID: String,
        index: Int,
        rows: List<JsonObject>,
    ): Boolean = flushEncodedChunk(editorID, index, JsonArray(rows).toString().encodeToByteArray())

    private fun flushEncodedChunk(editorID: String, index: Int, bytes: ByteArray): Boolean {
        if (bytes.size > MAX_CHUNK_BYTES) {
            discardCurrent(editorID)
            return false
        }
        val accepted = liveStages[editorID]?.let { (stageID, route) ->
            stager.append(stageID, index, bytes, route)
        } ?: false
        if (!accepted) discardCurrent(editorID)
        return accepted
    }

    /** Drop + cancel the tracked stage (idempotent against native retire). */
    private fun discardCurrent(editorID: String) {
        liveStages.remove(editorID)?.let { (stageID, route) ->
            runCatching { stager.cancel(stageID, route) }
        }
    }

    private fun cancelRecorded(editorID: String) {
        discardCurrent(editorID)
    }

    private companion object {
        /** The exact config.model.save bare-snapshot bound. The final
         *  two bytes use a bare singleton chunk; native validates it with
         *  the same original codec. No public/frame budget changes. */
        const val MAX_ROW_JSON_BYTES = 61_440
        /** Same class for one ordered chunk (native enforces authoritatively). */
        const val MAX_CHUNK_BYTES = 61_440
        /** The UNCHANGED native supported per-provider model bound. */
        const val MAX_STAGE_ROWS = 512
    }
}
