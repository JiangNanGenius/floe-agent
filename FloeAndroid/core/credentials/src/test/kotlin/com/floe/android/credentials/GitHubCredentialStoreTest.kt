// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import com.floe.android.contracts.CredentialStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Facade/ownership checks only; actual Android Keystore use is device QA. */
class GitHubCredentialStoreTest {
    private class Store : CredentialStore {
        val records = mutableMapOf<String, ByteArray>()
        var retainedWriteBuffer: ByteArray? = null
        var readFailure: Exception? = null
        override suspend fun read(reference: String): ByteArray? {
            readFailure?.let { throw it }
            return records[reference]?.copyOf()
        }
        override suspend fun write(reference: String, value: ByteArray) {
            retainedWriteBuffer = value
            records[reference] = value.copyOf()
        }
        override suspend fun delete(reference: String) { records.remove(reference) }
    }

    @Test fun canonicalGitAccountIsIsolatedAndTransientWriteCopyIsErased() = runBlocking {
        val platform = Store()
        platform.records["provider.other"] = byteArrayOf(7, 8, 9)
        val git = GitHubCredentialStore(platform)
        val fixture = "ghp_SYNTHETIC_LOCAL_ONLY_123456".toByteArray()
        assertEquals("ref:v1:f586914cf395e428bc460f173ea92f5d0c73f1bab8b9fdf24fdf5b58f7204b3b", GitHubCredentialStore.REFERENCE)
        git.save(fixture)
        assertTrue(git.hasToken())
        assertArrayEquals(fixture, platform.records[GitHubCredentialStore.REFERENCE])
        assertTrue(platform.retainedWriteBuffer!!.all { it == 0.toByte() })
        assertTrue(fixture.any { it != 0.toByte() })
        git.delete()
        assertFalse(git.hasToken())
        assertArrayEquals(byteArrayOf(7, 8, 9), platform.records["provider.other"])
    }

    @Test fun invalidTokenCannotReplaceAnExistingCredential() = runBlocking {
        val platform = Store()
        val git = GitHubCredentialStore(platform)
        val fixture = "ghp_SYNTHETIC_LOCAL_ONLY_123456".toByteArray()
        git.save(fixture)
        try {
            git.save("bad token with spaces".toByteArray())
            fail("must reject before write")
        } catch (_: CredentialStoreException.InvalidValue) { }
        assertArrayEquals(fixture, platform.records[GitHubCredentialStore.REFERENCE])
    }

    @Test fun platformReadFailureIsNeverReportedAsMissing() = runBlocking {
        val platform = Store().also { it.readFailure = CredentialStoreException.StorageFailure() }
        try {
            GitHubCredentialStore(platform).hasToken()
            fail("unreadable is not absent")
        } catch (_: CredentialStoreException.StorageFailure) { }
    }
}
