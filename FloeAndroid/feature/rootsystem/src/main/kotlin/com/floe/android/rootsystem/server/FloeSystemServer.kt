// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import com.floe.android.rootsystem.policy.AccessPolicy
import com.floe.android.rootsystem.policy.GrantRegistry
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

/**
 * app_process entry point for both Floe-owned backends.
 *
 * ADB mode (`--mode=adb`) is started by `libfloe_starter.so` as shell UID 2000;
 * root mode (`--mode=root`) is started only by the App's existing libsu grant
 * after a verified UID 0 check. The process refuses a UID that does not match
 * the mode, verifies the installed Floe package/signing/version, publishes the
 * binder through the Floe-only provider, and then serves typed operations.
 *
 * It never registers a global Shizuku service, never accepts a raw transaction
 * payload and never starts a model-authored command.
 */
object FloeSystemServer {

    @Volatile
    private var retainedBinder: FloeSystemServiceBinder? = null

    @Volatile
    private var retainedPublisher: ProviderPublisher? = null

    private val stopping = AtomicBoolean(false)

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()

        val parsed = ServerArguments.parse(args) ?: fail(ServerExit.ARGUMENTS)
        if (!AccessPolicy.modeAllowsUid(parsed.mode, Process.myUid())) fail(ServerExit.UID)

        val context = try {
            SystemContext.get()
        } catch (_: Throwable) {
            fail(ServerExit.CONTEXT)
        }

        val identity = ServerIdentity.resolve(context, parsed) ?: fail(ServerExit.IDENTITY)
        val registry = GrantRegistry()
        val operations = SystemOperations(context, identity)
        val clientSeen = AtomicBoolean(false)

        lateinit var publisher: ProviderPublisher
        val binder = FloeSystemServiceBinder(
            identity = identity,
            operations = operations,
            registry = registry,
            mode = parsed.mode,
            onStop = {
                if (stopping.compareAndSet(false, true)) {
                    operations.close()
                    publisher.stop()
                    Handler(Looper.getMainLooper()).postDelayed({
                        exitProcess(ServerExit.STOPPED)
                    }, 250)
                }
            },
            onClientSeen = {
                clientSeen.set(true)
                publisher.cancelInitialDeadline()
            },
        )
        retainedBinder = binder

        publisher = try {
            ProviderPublisher(
                identity = identity,
                token = parsed.token,
                binder = binder,
                hasClient = { clientSeen.get() },
                onInitialPublicationFailed = {
                    // The App already gave up waiting and no binder was ever
                    // published: exit instead of leaving an unreachable UID 2000
                    // helper retrying forever. Typed, non-zero exit code only.
                    exitProcess(ServerExit.PUBLISH)
                },
            )
        } catch (_: Throwable) {
            fail(ServerExit.BINDER)
        }
        retainedPublisher = publisher
        // Bounded lifecycle marker only: no package, signing, token or payload.
        Log.i(LOG_TAG, "start mode=" + identity.mode + " uid=" + identity.serverUid + " pid=" + identity.serverPid)
        publisher.start()

        Looper.loop()
    }

    private const val LOG_TAG = "FloeSystemServer"

    private fun fail(code: Int): Nothing {
        System.err.println("floe embedded system service failed to start (code=$code)")
        exitProcess(code)
    }
}
