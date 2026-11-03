// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.fonts

import android.content.Context
import android.net.Uri
import com.floe.android.core.fonts.ManagedFontStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicBoolean

/** Library operations belong to the App, not the lifetime of a settings sheet. */
internal class FontSettingsHost(context: Context, private val scope: CoroutineScope) {
    data class State(val busy: Boolean = false, val entries: List<ManagedFontStore.Entry> = emptyList(),
        val outcome: String? = null)
    private val app = context.applicationContext
    val store = ManagedFontStore(app)
    private val working = AtomicBoolean(false)
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()
    private fun run(operation: () -> String?) {
        if (!working.compareAndSet(false, true)) return
        mutable.value = mutable.value.copy(busy = true, outcome = null)
        scope.launch(Dispatchers.IO) {
            try {
                val result = operation()
                mutable.value = State(entries = store.list(), outcome = result)
            } catch (e: CancellationException) { throw e }
            catch (_: com.floe.android.core.fonts.FontCommitUncertain) {
                mutable.value = mutable.value.copy(busy = false, outcome = "uncertain")
            }
            catch (_: Exception) { mutable.value = mutable.value.copy(busy = false, outcome = "failed") }
            finally { working.set(false); mutable.value = mutable.value.copy(busy = false) }
        }
    }
    fun refresh() = run { null }
    fun install(uri: Uri) = run {
        require(uri.scheme == "content") { "A document grant is required" }
        val stream = app.contentResolver.openInputStream(uri) ?: error("Font unavailable")
        store.install(stream)
        "installed"
    }
    fun remove(id: String) = run { if (store.remove(id)) "removed" else "missing" }
}
