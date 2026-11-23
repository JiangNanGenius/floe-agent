// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import android.content.Context
import com.floe.android.host.SharedUriGrantAuthority
import com.floe.android.safgateway.AndroidSafBackend
import com.floe.android.safgateway.SafGatewayService
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * App wiring for Space → Files.
 *
 * ONE controller/service for the process: browsing state and an in-flight
 * provider write must survive screen recreation, and the destination's
 * `viewDetached` only fences view-scoped work. The gateway uses the shared
 * `SafSharedGrantBroker`, so this page's lifecycle can never release a URI
 * permission another feature still references. Nothing here is created until
 * the user actually opens Space → Files.
 */
internal object SpaceFilesHost {
    private val lock = Any()

    @Volatile
    private var instance: SpaceFilesController? = null

    fun controller(context: Context): SpaceFilesController {
        instance?.let { return it }
        return synchronized(lock) {
            instance ?: build(context.applicationContext).also { instance = it }
        }
    }

    private fun build(appContext: Context): SpaceFilesController {
        val backend = AndroidSafBackend(appContext)
        val service = SafGatewayService(
            backend = backend,
            releaseBroker = SharedUriGrantAuthority.broker,
        )
        return SpaceFilesController(
            service = service,
            backend = backend,
            store = SpaceFilesPreferencesRootStore(appContext),
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
            ioDispatcher = Dispatchers.IO,
            cacheRoot = File(appContext.cacheDir, "space-files"),
            // Edit working copies + recovery originals survive cache eviction
            // and process death (the journal reconciles after a restart).
            editsRoot = File(appContext.filesDir, "space-files-edits"),
        )
    }
}
