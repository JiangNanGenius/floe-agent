// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import java.lang.reflect.InvocationTargetException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression checks for the external App-provider publication surface.
 *
 * The real Binder transaction can only be proven on a device; these tests pin
 * the exact hidden-API shapes and bounds the repair was written against, so a
 * future refactor cannot silently select a resolver/manifest path again or
 * accept a shape that ActivityManager does not expose on the supported APIs.
 */
class AppProviderClientTest {

    private val string = "java.lang.String"
    private val int = "int"
    private val binder = "android.os.IBinder"
    private val bundle = "android.os.Bundle"
    private val attribution = "android.content.AttributionSource"

    @Test
    fun `api33 provider call uses attribution source and four arguments`() {
        val shape = listOf(attribution, string, string, string, bundle)
        assertTrue(AppProviderClient.callShapeMatches(33, shape))
        assertTrue(AppProviderClient.callShapeMatches(34, shape))
        assertFalse(AppProviderClient.callShapeMatches(33, listOf(string, string, string, string, bundle)))
        assertFalse(AppProviderClient.callShapeMatches(33, listOf(attribution, string, string, string)))
        assertFalse(AppProviderClient.callShapeMatches(33, listOf(attribution, string, string, string, string)))
    }

    @Test
    fun `api30 provider call keeps the feature id argument`() {
        val shape = listOf(string, string, string, string, string, bundle)
        assertTrue(AppProviderClient.callShapeMatches(30, shape))
        assertFalse(AppProviderClient.callShapeMatches(30, listOf(string, string, string, string, bundle)))
    }

    @Test
    fun `api29 provider call omits the feature id argument`() {
        val shape = listOf(string, string, string, string, bundle)
        assertTrue(AppProviderClient.callShapeMatches(29, shape))
        assertFalse(AppProviderClient.callShapeMatches(29, listOf(string, string, string, string, string, bundle)))
    }

    @Test
    fun `api28 provider call has no authority argument`() {
        val shape = listOf(string, string, string, bundle)
        assertTrue(AppProviderClient.callShapeMatches(28, shape))
        assertFalse(AppProviderClient.callShapeMatches(28, listOf(string, string, string, string, bundle)))
    }

    @Test
    fun `external provider entry point gained the tag in api29`() {
        val legacy = listOf(string, int, binder)
        val tagged = listOf(string, int, binder, string)
        assertTrue(AppProviderClient.externalShapeMatches(28, legacy))
        assertFalse(AppProviderClient.externalShapeMatches(28, tagged))
        assertTrue(AppProviderClient.externalShapeMatches(29, tagged))
        assertTrue(AppProviderClient.externalShapeMatches(33, tagged))
        assertFalse(AppProviderClient.externalShapeMatches(33, legacy))
        assertFalse(AppProviderClient.externalShapeMatches(33, listOf(string, string, binder, string)))
    }

    @Test
    fun `external provider removal keeps authority and token`() {
        assertTrue(AppProviderClient.removeShapeMatches(listOf(string, binder)))
        assertFalse(AppProviderClient.removeShapeMatches(listOf(string, string)))
        assertFalse(AppProviderClient.removeShapeMatches(listOf(binder, string)))
    }

    @Test
    fun `failure classification is stable and payload free`() {
        assertEquals(AppProviderClient.FAILURE_DENIED, AppProviderClient.classifyFailure(SecurityException()))
        assertEquals(
            AppProviderClient.FAILURE_DENIED,
            AppProviderClient.classifyFailure(InvocationTargetException(SecurityException("x"))),
        )
        assertEquals(
            AppProviderClient.FAILURE_TRANSPORT,
            AppProviderClient.classifyFailure(IllegalStateException("x")),
        )
        assertTrue(AppProviderClient.FAILURE_DENIED.none { it.isDigit() || it == ':' })
    }

    @Test
    fun `publish retry is bounded and resettable`() {
        val backoff = PublishBackoff()
        assertEquals(listOf(250L, 500L, 1_000L, 2_000L, 4_000L, 8_000L, 10_000L, 10_000L), List(8) {
            backoff.nextDelayMillis()
        })
        backoff.reset()
        assertEquals(250L, backoff.nextDelayMillis())
    }
}
