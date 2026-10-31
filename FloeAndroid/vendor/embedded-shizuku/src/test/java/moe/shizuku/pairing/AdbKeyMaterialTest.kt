// SPDX-License-Identifier: Apache-2.0
package moe.shizuku.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.interfaces.RSAPublicKey
import java.util.Base64

class AdbKeyMaterialTest {

    private fun keyPair() = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()

    @Test
    fun adbPublicKeyUsesAndroidEncodingAndNameSuffix() {
        val pair = keyPair()
        val encoded = AdbPublicKey.encode(pair.public as RSAPublicKey, "floe-device")
        val text = String(encoded, Charsets.US_ASCII)
        assertTrue(text.endsWith(" floe-device\u0000"))
        val base64Part = text.substringBefore(' ')
        val suffixBytes = " floe-device\u0000".toByteArray()
        assertEquals(base64Part.length + suffixBytes.size, encoded.size)
        val raw = Base64.getDecoder().decode(base64Part)
        assertEquals(AdbPublicKey.ENCODED_BYTES, raw.size)
        assertEquals(Base64.getEncoder().encodeToString(raw), base64Part)
        assertEquals(AdbPublicKey.MODULUS_WORDS, readInt(raw, 0))
        assertEquals(((pair.public as RSAPublicKey).publicExponent.toInt()), readInt(raw, raw.size - 4))
    }

    @Test
    fun adbPublicKeyRejectsNon2048BitKeysAndInvalidNames() {
        val pair = keyPair()
        assertNotNull(
            runCatching { AdbPublicKey.encode(pair.public as RSAPublicKey, "bad name") }.exceptionOrNull(),
        )
        assertNotNull(
            runCatching { AdbPublicKey.encode(pair.public as RSAPublicKey, "bad\u0000name") }.exceptionOrNull(),
        )
        val small = KeyPairGenerator.getInstance("RSA").apply { initialize(1024) }.generateKeyPair()
        assertNotNull(
            runCatching { AdbPublicKey.encode(small.public as RSAPublicKey, "floe") }.exceptionOrNull(),
        )
    }

    @Test
    fun selfSignedCertificateParsesAndVerifies() {
        val pair = keyPair()
        val certificate = SelfSignedCertificate.create(pair)
        assertEquals("CN=00", certificate.subjectX500Principal.name)
        assertEquals(certificate.subjectX500Principal, certificate.issuerX500Principal)
        certificate.verify(pair.public)
        assertEquals(pair.public, certificate.publicKey)
    }

    @Test
    fun identityCodecRoundTripsAndRejectsCorruption() {
        val pair = keyPair()
        val certificate = SelfSignedCertificate.create(pair)
        val identity = AdbIdentity(pair, certificate, "floe-device")
        val encoded = AdbIdentityCodec.encode(identity)
        val decoded = AdbIdentityCodec.decode(encoded) as AdbIdentityCodec.Result.Ok
        assertEquals("floe-device", decoded.identity.displayName)
        assertEquals(identity.adbPublicKey.toList(), decoded.identity.adbPublicKey.toList())
        assertEquals(identity.certificateBytes.toList(), decoded.identity.certificateBytes.toList())

        assertEquals(
            "size",
            (AdbIdentityCodec.decode(ByteArray(0)) as AdbIdentityCodec.Result.Rejected).code,
        )
        assertEquals(
            "magic",
            (AdbIdentityCodec.decode(encoded.copyOf().also { it[0] = 0 }) as AdbIdentityCodec.Result.Rejected).code,
        )
        assertEquals(
            "version",
            (AdbIdentityCodec.decode(encoded.copyOf().also { it[4] = 2 }) as AdbIdentityCodec.Result.Rejected).code,
        )
        assertEquals(
            "length",
            (AdbIdentityCodec.decode(encoded.copyOf(encoded.size - 1)) as AdbIdentityCodec.Result.Rejected).code,
        )
    }

    private fun readInt(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)
}
