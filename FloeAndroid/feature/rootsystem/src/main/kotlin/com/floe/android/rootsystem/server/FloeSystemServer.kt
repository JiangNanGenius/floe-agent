// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.os.Handler
import android.os.Looper
import android.os.Process
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

        lateinit var publisher: ProviderPublisher
        val binder = FloeSystemServiceBinder(
            identity = identity,
            operations = operations,
            registry = registry,
            mode = parsed.mode,
            onStop = {
                if (stopping.compareAndSet(false, true)) {
                    publisher.stop()
                    Handler(Looper.getMainLooper()).postDelayed({
                        exitProcess(ServerExit.STOPPED)
                    }, 250)
                }
            },
        )
        retainedBinder = binder

        publisher = try {
            ProviderPublisher(
                context = context,
                identity = identity,
                token = parsed.token,
                binder = binder,
            )
        } catch (_: Throwable) {
            fail(ServerExit.BINDER)
        }
        retainedPublisher = publisher
        publisher.start()

        Looper.loop()
    }

    private fun fail(code: Int): Nothing {
        System.err.println("floe embedded system service failed to start (code=$code)")
        exitProcess(code)
    }
}
