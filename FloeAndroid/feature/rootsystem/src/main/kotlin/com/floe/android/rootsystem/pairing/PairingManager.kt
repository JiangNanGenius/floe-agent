// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.pairing

import android.os.Build
import com.floe.android.contracts.CredentialStore
import com.floe.android.rootsystem.PairingResult
import com.floe.android.rootsystem.RootSystemConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import moe.shizuku.pairing.AdbIdentity
import moe.shizuku.pairing.AdbPairingClient
import moe.shizuku.pairing.KeyingMaterialExporter
import moe.shizuku.pairing.KeyingMaterialExporters

/**
 * Owns the user-initiated pairing attempt. A 6-digit code is kept in RAM only,
 * wiped in a finally block and never written to a preference, log or saved
 * state. Pairing is never started implicitly by App start or service probe.
 */
internal class PairingManager(
    private val credentials: CredentialStore,
    private val config: RootSystemConfig,
) {
    private val identities = PairingIdentityStore(credentials)

    @Volatile
    private var activeClient: AdbPairingClient? = null

    @Volatile
    private var cachedIdentity: AdbIdentity? = null

    suspend fun hasTrust(): Boolean = withContext(Dispatchers.IO) {
        try {
            identities.load() != null
        } catch (e: IdentityException) {
            throw e
        }
    }

    suspend fun identity(): AdbIdentity = withContext(Dispatchers.IO) {
        cachedIdentity ?: identities.loadOrCreate(displayName()).also { cachedIdentity = it }
    }

    suspend fun pair(pairingPort: Int, pairingCode: CharArray): PairingResult {
        if (!KeyingMaterialExporters.adbPairingSupported(Build.VERSION.SDK_INT)) {
            pairingCode.fill('\u0000')
            return PairingResult.Unsupported("pairing_requires_api30")
        }
        if (pairingPort !in 1..65535) {
            pairingCode.fill('\u0000')
            return PairingResult.Failed("port")
        }
        if (pairingCode.size != com.floe.android.rootsystem.policy.PairingPolicy.CODE_LENGTH ||
            pairingCode.any { it !in '0'..'9' }
        ) {
            pairingCode.fill('\u0000')
            return PairingResult.Failed("pairing_code")
        }
        return withContext(Dispatchers.IO) {
            try {
                val identity = identity()
                val exporter = KeyingMaterialExporters.forDevice()
                val client = AdbPairingClient(
                    host = "127.0.0.1",
                    port = pairingPort,
                    pairingCode = pairingCode,
                    identity = identity,
                    exporter = exporter,
                    readTimeoutMillis = config.pairingTimeoutMillis,
                )
                activeClient = client
                when (val outcome = client.pair()) {
                    is AdbPairingClient.Outcome.Success -> PairingResult.Success
                    is AdbPairingClient.Outcome.InvalidCode -> PairingResult.InvalidCode
                    is AdbPairingClient.Outcome.Unsupported -> PairingResult.Unsupported(outcome.code)
                    is AdbPairingClient.Outcome.Timeout -> PairingResult.Timeout
                    is AdbPairingClient.Outcome.TransportError -> PairingResult.Failed("transport_${outcome.code}")
                    is AdbPairingClient.Outcome.ProtocolError -> PairingResult.Failed("protocol_${outcome.code}")
                }
            } catch (e: IdentityException) {
                PairingResult.Unsupported(e.code)
            } finally {
                pairingCode.fill('\u0000')
                activeClient = null
            }
        }
    }

    fun cancel() {
        val client = activeClient
        activeClient = null
        runCatching { client?.close() }
    }

    suspend fun forget() = withContext(Dispatchers.IO) {
        cachedIdentity = null
        identities.forget()
    }

    private fun displayName(): String {
        val model = Build.MODEL ?: "device"
        return "floe-$model"
    }
}
