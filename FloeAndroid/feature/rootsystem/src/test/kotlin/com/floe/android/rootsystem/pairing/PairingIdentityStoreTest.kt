// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.pairing

import com.floe.android.contracts.CredentialStore
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingIdentityStoreTest {

    private class MemoryCredentialStore : CredentialStore {
        private val values = ConcurrentHashMap<String, ByteArray>()
        var failWrites = false

        override suspend fun read(reference: String): ByteArray? = values[reference]?.copyOf()

        override suspend fun write(reference: String, value: ByteArray) {
            if (failWrites) throw IllegalStateException("write failed")
            values[reference] = value.copyOf()
        }

        override suspend fun delete(reference: String) {
            values.remove(reference)
        }
    }

    @Test
    fun aCandidateIdentityOnlyBecomesTrustWhenPairingIsRecorded() = runBlocking {
        val credentials = MemoryCredentialStore()
        val store = PairingIdentityStore(credentials)

        val identity = store.loadOrCreate("floe-test")
        assertNotNull(store.load())
        assertNull("an unpaired candidate must not be trust", store.load(requirePaired = true))

        store.markPaired(identity)
        val paired = store.load(requirePaired = true)
        assertNotNull("a recorded pairing must load", paired)
        assertEquals(identity.adbPublicKey.toList(), paired!!.adbPublicKey.toList())
        assertEquals(identity.certificateBytes.toList(), paired.certificateBytes.toList())

        // Retries reuse the same candidate; they never silently replace it.
        assertEquals(
            identity.adbPublicKey.toList(),
            store.loadOrCreate("floe-other").adbPublicKey.toList(),
        )

        store.forget()
        assertNull(store.load())
        assertNull(store.load(requirePaired = true))
    }

    @Test
    fun aFailedReceiptWriteDoesNotUpgradeCandidateTrust() = runBlocking {
        val credentials = MemoryCredentialStore()
        val store = PairingIdentityStore(credentials)
        val identity = store.loadOrCreate("floe-test")

        credentials.failWrites = true
        val failure = runCatching { store.markPaired(identity) }.exceptionOrNull()
        assertTrue(failure is IdentityException)
        assertEquals("identity_pair_write", (failure as IdentityException).code)
        assertNull(store.load(requirePaired = true))
        assertNotNull(store.load())
    }

    @Test
    fun aCorruptRecordFailsClosed() = runBlocking {
        val credentials = MemoryCredentialStore()
        credentials.write(PairingIdentityStore.REFERENCE, byteArrayOf(1, 2, 3))
        val failure = runCatching {
            PairingIdentityStore(credentials).load(requirePaired = true)
        }.exceptionOrNull()

        assertTrue(failure is IdentityException)
        assertEquals("identity_malformed", (failure as IdentityException).code)
    }
}
