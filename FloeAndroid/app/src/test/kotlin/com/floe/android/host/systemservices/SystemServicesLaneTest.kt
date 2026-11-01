// SPDX-License-Identifier: MPL-2.0
//
// C06 system-services lane tests. Authored source; NOT RUN by this lane. The
// bridge is an in-memory ticket table; no JNI or device participates.

package com.floe.android.host.systemservices

import android.app.Activity
import com.floe.android.core.systemservices.ContactField
import com.floe.android.core.systemservices.ContactRecordRow
import com.floe.android.core.systemservices.ContactsService
import com.floe.android.core.systemservices.HealthAggregateRow
import com.floe.android.core.systemservices.HealthCapability
import com.floe.android.core.systemservices.HealthMetric
import com.floe.android.core.systemservices.HealthPageRow
import com.floe.android.core.systemservices.HealthProviderStatus
import com.floe.android.core.systemservices.HealthService
import com.floe.android.core.systemservices.HealthAggregation
import com.floe.android.core.systemservices.LocationCapability
import com.floe.android.core.systemservices.LocationFixRow
import com.floe.android.core.systemservices.LocationService
import com.floe.android.core.systemservices.NfcCapability
import com.floe.android.core.systemservices.NfcReadRow
import com.floe.android.core.systemservices.NfcService
import com.floe.android.core.systemservices.PermissionEvidence
import com.floe.android.core.systemservices.SystemAvailability
import com.floe.android.core.systemservices.SystemPermission
import com.floe.android.core.systemservices.SystemServicesEngine
import java.time.Instant
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class LaneLocation : LocationService {
    override fun capability(evidence: PermissionEvidence): LocationCapability =
        LocationCapability(true, true, SystemPermission.GRANTED, true)

    override suspend fun currentFix(timeoutMs: Long): LocationFixRow = LocationFixRow(
        -33.8688, 151.2093, 9.5, Instant.parse("2026-01-01T00:00:00Z"), true, "gps",
    )
}

private class LaneContacts : ContactsService {
    override fun capability(evidence: PermissionEvidence) =
        com.floe.android.core.systemservices.ContactsCapability(true, SystemPermission.GRANTED)

    override suspend fun scan(query: String?, field: ContactField):
        Pair<List<ContactRecordRow>, Boolean> = listOf(
        ContactRecordRow("1", "Ada Lovelace", "Analytical Engines", listOf("+61 2 5555"), listOf("ada@example.com")),
    ) to false
}

private class LaneNfc : NfcService {
    override fun capability() = NfcCapability(true, true)
    override suspend fun read(activity: Activity?, timeoutSeconds: Int) =
        NfcReadRow(emptyList(), 0, false, listOf("Ndef"), false, 1)
}

private class LaneHealth : HealthService {
    override suspend fun capability() = HealthCapability(HealthProviderStatus.AVAILABLE, emptySet())
    override suspend fun samples(
        metric: HealthMetric,
        start: Instant,
        end: Instant,
        limit: Int,
        pageToken: String?,
    ) = HealthPageRow(emptyList(), null, 0, false)
    override suspend fun aggregate(
        metric: HealthMetric,
        aggregation: HealthAggregation,
        start: Instant,
        end: Instant,
    ) = HealthAggregateRow(metric.wire, aggregation.wire, 1.0, metric.unit, 1, start, end, null)
}

private class FakeSystemBridge : SystemHostBridge {
    private val claims = LinkedBlockingQueue<Long>()
    private val requests = HashMap<Long, ByteArray>()
    val completed = LinkedBlockingQueue<Pair<Long, ByteArray?>>()
    val statuses = HashMap<Long, Int>()
    val epoch = AtomicLong(0)
    var laneClosed = false
    var closedAll = false
    private var next = 1L

    fun enqueue(request: JSONObject): Long {
        val claim = next
        next += 1
        requests[claim] = request.toString().toByteArray(Charsets.UTF_8)
        claims.put(claim)
        return claim
    }

    override fun bind(epoch: Long): Int {
        this.epoch.set(epoch)
        return 0
    }

    override fun laneReady(epoch: Long): Int = 0
    override fun next(timeoutMillis: Int): Long =
        claims.poll(timeoutMillis.toLong(), TimeUnit.MILLISECONDS) ?: 0
    override fun describe(claim: Long): ByteArray? = requests[claim]
    override fun complete(claim: Long, status: Int, data: ByteArray?): Int {
        statuses[claim] = status
        completed.put(claim to data)
        return 0
    }
    override fun shouldStop(claim: Long): Boolean = false
    override fun closeAll(timeoutMillis: Int): Int {
        closedAll = true
        return 0
    }
    override fun laneClosed(epoch: Long): Int {
        laneClosed = true
        return 0
    }
    override fun stats(): ByteArray? = "{\"pending\":0,\"completed\":1}".toByteArray()
}

class SystemServicesLaneTest {
    private fun engine(): SystemServicesEngine =
        SystemServicesEngine(LaneLocation(), LaneContacts(), LaneNfc(), LaneHealth())

    @Test
    fun locationTicketCompletesWithRealFixShape() = runBlocking {
        val bridge = FakeSystemBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val lane = SystemServicesLane(scope, engine(), { null }, bridge)
        assertTrue(lane.start(4))
        val claim = bridge.enqueue(
            JSONObject().put("claimEpoch", 4).put("operation", "location.fix"),
        )
        val completed = withTimeout(5_000) {
            while (true) {
                val value = bridge.completed.poll(250, TimeUnit.MILLISECONDS)
                if (value != null) return@withTimeout value
            }
            @Suppress("UNREACHABLE_CODE")
            null
        }
        assertEquals(claim, completed!!.first)
        val response = JSONObject(String(completed.second!!, Charsets.UTF_8))
        assertEquals(true, response.optBoolean("ok"))
        assertEquals(-33.8688, response.optDouble("latitude"), 0.0001)
        assertEquals(true, response.optBoolean("precise"))
        assertEquals(0, bridge.statuses[claim])
        assertEquals(true, lane.stop(2_000))
        assertEquals(true, bridge.closedAll)
        assertEquals(true, bridge.laneClosed)
        scope.cancel()
    }

    @Test
    fun contactsTicketUsesBoundedRows() = runBlocking {
        val bridge = FakeSystemBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val lane = SystemServicesLane(scope, engine(), { null }, bridge)
        assertTrue(lane.start(7))
        bridge.enqueue(
            JSONObject()
                .put("claimEpoch", 7)
                .put("operation", "contacts.scan")
                .put("offset", 0)
                .put("limit", 100),
        )
        val completed = withTimeout(5_000) {
            while (true) {
                val value = bridge.completed.poll(250, TimeUnit.MILLISECONDS)
                if (value != null) return@withTimeout value
            }
            @Suppress("UNREACHABLE_CODE")
            null
        }
        val response = JSONObject(String(completed!!.second!!, Charsets.UTF_8))
        assertEquals(true, response.optBoolean("ok"))
        assertEquals(1, response.optJSONArray("rows")!!.length())
        assertEquals("Ada Lovelace", response.optJSONArray("rows")!!.getJSONObject(0).optString("displayName"))
        lane.stop(2_000)
        scope.cancel()
    }

    @Test
    fun healthPermissionFailureIsAnHonestErrorReply() = runBlocking {
        val bridge = FakeSystemBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val lane = SystemServicesLane(scope, engine(), { null }, bridge)
        assertTrue(lane.start(8))
        bridge.enqueue(
            JSONObject()
                .put("claimEpoch", 8)
                .put("operation", "health.samples")
                .put("metric", "steps")
                .put("start", "2026-01-01T00:00:00Z")
                .put("end", "2026-01-08T00:00:00Z")
                .put("limit", 50),
        )
        val completed = withTimeout(5_000) {
            while (true) {
                val value = bridge.completed.poll(250, TimeUnit.MILLISECONDS)
                if (value != null) return@withTimeout value
            }
            @Suppress("UNREACHABLE_CODE")
            null
        }
        val response = JSONObject(String(completed!!.second!!, Charsets.UTF_8))
        assertEquals(false, response.optBoolean("ok"))
        assertEquals("healthPermissionDenied", response.optString("code"))
        lane.stop(2_000)
        scope.cancel()
    }

    @Test
    fun staleGenerationTicketIsFenced() = runBlocking {
        val bridge = FakeSystemBridge()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val lane = SystemServicesLane(scope, engine(), { null }, bridge)
        assertTrue(lane.start(9))
        bridge.enqueue(
            JSONObject().put("claimEpoch", 3).put("operation", "location.fix"),
        )
        val completed = withTimeout(5_000) {
            while (true) {
                val value = bridge.completed.poll(250, TimeUnit.MILLISECONDS)
                if (value != null) return@withTimeout value
            }
            @Suppress("UNREACHABLE_CODE")
            null
        }
        assertEquals(-102, bridge.statuses[completed!!.first])
        lane.stop(2_000)
        scope.cancel()
    }
}
