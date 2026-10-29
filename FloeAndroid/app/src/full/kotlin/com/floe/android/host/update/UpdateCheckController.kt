// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Honest outcome of one update check. */
internal sealed interface AppCheckState {
    data object Idle : AppCheckState
    data object Checking : AppCheckState
    data class UpToDate(val checkedAtMillis: Long) : AppCheckState
    data class UpdateAvailable(val release: AndroidRelease, val manual: Boolean) : AppCheckState
    data class Unavailable(val kind: UnavailableKind) : AppCheckState
}

internal enum class UnavailableKind { NETWORK, RATE_LIMITED, NO_ANDROID_RELEASE, MALFORMED }

/**
 * Update discovery lifecycle.
 *
 *  * Automatic checks are triggered by real App foreground/startup events,
 *    respect the persisted enabled flag and a persisted cooldown, and are
 *    single-flight. A network/rate-limit/malformed failure only sets a typed
 *    unavailable state — it never throws into app startup, the editor or the
 *    browser, and it never presents a dialog.
 *  * A manual check from Settings bypasses the cooldown (still single-flight)
 *    and always surfaces the result, including an already-dismissed version.
 *  * "Later" persists the dismissed version so the SAME release is not
 *    re-presented on every recomposition/resume; a newer release presents
 *    again.
 *
 * Everything here is framework-free so the full-flavor unit tests can drive
 * it with fakes; the Android-side owner is [AppUpdateController].
 */
internal class UpdateCheckController(
    private val scope: CoroutineScope,
    private val feed: ReleaseFeed,
    private val store: UpdateStore,
    private val currentVersion: FloeVersion?,
    private val nowMillis: () -> Long,
    private val autoIntervalMs: Long = UpdateConfig.AUTO_CHECK_INTERVAL_MS,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutable = MutableStateFlow<AppCheckState>(AppCheckState.Idle)
    val state: StateFlow<AppCheckState> = mutable.asStateFlow()
    private val inFlight = AtomicBoolean(false)

    /** The exact presentation instance the user dismissed with "Later". */
    @Volatile
    private var dismissedPresentation: AppCheckState.UpdateAvailable? = null

    fun maybeAutoCheck() {
        if (!store.autoCheckEnabled) return
        val now = nowMillis()
        val last = store.lastCheckAtMillis
        if (last > 0L && now >= last && now - last < autoIntervalMs) return
        // A clock that moved backwards must not wedge automatic checks.
        if (last > 0L && now < last) return
        check(manual = false)
    }

    fun manualCheck() = check(manual = true)

    fun setAutoCheckEnabled(enabled: Boolean) {
        val changed = store.autoCheckEnabled != enabled
        store.autoCheckEnabled = enabled
        if (enabled && changed) maybeAutoCheck()
    }

    fun markDialogDismissed(release: AndroidRelease) {
        store.dismissedVersion = release.version.toString()
        val current = mutable.value as? AppCheckState.UpdateAvailable
        if (current != null && current.release.version.toString() == release.version.toString()) {
            dismissedPresentation = current
        }
    }

    /**
     * "Later" suppression: only the exact dismissed release version is muted,
     * and a manual check's own result may be dismissed too (the next manual
     * check is a new presentation). Automatic checks keep the persisted
     * version mute so a resume does not re-present the same release.
     */
    fun shouldPresentDialog(): Boolean {
        val current = mutable.value as? AppCheckState.UpdateAvailable ?: return false
        if (current === dismissedPresentation) return false
        return current.manual || store.dismissedVersion != current.release.version.toString()
    }

    private fun check(manual: Boolean) {
        val version = currentVersion
        if (version == null) {
            mutable.value = AppCheckState.Unavailable(UnavailableKind.MALFORMED)
            return
        }
        if (!inFlight.compareAndSet(false, true)) return
        mutable.value = AppCheckState.Checking
        scope.launch(ioDispatcher) {
            try {
                val candidates = ArrayList<AndroidRelease>()
                var page = 1
                while (true) {
                    val result = feed.fetchPage(page)
                    candidates += AndroidReleaseFeed.parsePage(result.body)
                    page = result.nextPage ?: break
                }
                val release = AndroidReleaseSelection.newest(candidates, version)
                val checkedAt = nowMillis()
                store.lastCheckAtMillis = checkedAt
                mutable.value = if (release == null) {
                    if (candidates.isEmpty()) {
                        AppCheckState.Unavailable(UnavailableKind.NO_ANDROID_RELEASE)
                    } else {
                        AppCheckState.UpToDate(checkedAt)
                    }
                } else {
                    AppCheckState.UpdateAvailable(release, manual)
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: FeedFailure) {
                mutable.value = AppCheckState.Unavailable(
                    when (failure) {
                        is FeedFailure.RateLimited -> UnavailableKind.RATE_LIMITED
                        else -> UnavailableKind.NETWORK
                    },
                )
            } catch (failure: Exception) {
                mutable.value = AppCheckState.Unavailable(UnavailableKind.NETWORK)
            } finally {
                inFlight.set(false)
            }
        }
    }
}
