// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.SystemClock
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** OS delivery state only. Native schedule/occurrence rows remain the execution authority. */
internal object TaskScheduleConditions {
    private val gate = Mutex()
    private val observations = Any()
    private var powerReceiver: BroadcastReceiver? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var bootIdentity: String? = null // Accessed only under observations.
    private val processIdentity = UUID.randomUUID().toString()
    data class Event(val id: String, val condition: String, val at: Long)

    @Synchronized
    fun attach(context: Context) {
        val app = context.applicationContext
        val work = WorkManager.getInstance(app)
        work.enqueueUniquePeriodicWork("floe.schedule.conditions.monitor", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<TaskScheduleConditionWorker>(15, TimeUnit.MINUTES).build())
        // Manifest POWER_CONNECTED is not a background wake source on Android 8+.
        // OS-constrained work covers process death; live callbacks preserve observed
        // disconnect edges even if a queued probe executes after reconnection.
        for ((name, constraints) in listOf(
            "charging" to Constraints.Builder().setRequiresCharging(true).build(),
            "network" to Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
        )) {
            work.enqueueUniquePeriodicWork("floe.schedule.conditions.$name", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<TaskScheduleConditionWorker>(15, TimeUnit.MINUTES)
                    .setConstraints(constraints).build())
        }
        if (powerReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val active = when (intent.action) {
                        Intent.ACTION_POWER_CONNECTED -> true
                        Intent.ACTION_POWER_DISCONNECTED -> false
                        else -> return
                    }
                    observe(app, listOf("charging" to active))
                    enqueue(app)
                }
            }
            ContextCompat.registerReceiver(app, receiver, IntentFilter().apply {
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            powerReceiver = receiver
        }
        if (callback == null) {
            val monitor = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { networkChanged(app) }
                override fun onLost(network: Network) { networkChanged(app) }
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { networkChanged(app) }
            }
            runCatching { app.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(monitor) }
                .onSuccess { callback = monitor }
        }
        enqueue(app)
    }

    fun enqueue(context: Context) {
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork("floe.schedule.conditions.probe",
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<TaskScheduleConditionWorker>().build())
    }

    private fun connected(context: Context): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        return connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
    }

    private fun networkChanged(context: Context) {
        // Losing an old network while another validated network is active is not
        // a disconnect/reconnect occurrence.
        observe(context, listOf("networkConnected" to connected(context)))
        enqueue(context)
    }

    private fun observe(context: Context, states: List<Pair<String, Boolean>>): ConditionObservation = synchronized(observations) {
        val prefs = context.getSharedPreferences("floe.schedule.conditions", Context.MODE_PRIVATE)
        val queue = JSONArray(prefs.getString("pending", "[]"))
        val now = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtime()
        val boot = bootIdentity ?: runCatching {
            "boot:${Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)}"
        }.getOrElse { "process:$processIdentity" }.also { bootIdentity = it }
        val editor = prefs.edit()
        for ((condition, active) in states) {
            if (TaskScheduleConditionPolicy.risingEdge(
                    prefs.getBoolean("active.$condition", false), active, elapsed,
                    if (prefs.contains("last_elapsed.$condition")) prefs.getLong("last_elapsed.$condition", -1) else null,
                    prefs.getString("last_boot.$condition", null) == boot)) {
                if (queue.length() >= 32) return@synchronized ConditionObservation.QUEUE_FULL
                queue.put(JSONObject().put("id", UUID.randomUUID().toString()).put("condition", condition).put("at", now))
                editor.putLong("last_elapsed.$condition", elapsed).putString("last_boot.$condition", boot)
            }
            // Migrate the old wall-clock debounce in the same preference write;
            // pending event IDs and observation timestamps stay unchanged.
            editor.remove("last.$condition").putBoolean("active.$condition", active)
        }
        // Commit the observed edge and stable event ID before starting native work.
        if (editor.putString("pending", queue.toString()).commit()) ConditionObservation.DURABLE
        else ConditionObservation.STORAGE_UNAVAILABLE
    }

    suspend fun drain(context: Context, submit: suspend (Event) -> Boolean): Boolean = gate.withLock {
        val prefs = context.getSharedPreferences("floe.schedule.conditions", Context.MODE_PRIVATE)
        TaskScheduleConditionPolicy.drain(
            observe = {
                // Re-read actual state after making space, rather than replaying
                // the snapshot taken before a slow native submission.
                val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
                observe(context, listOf("charging" to charging, "networkConnected" to connected(context)))
            },
            peek = { synchronized(observations) {
                val queue = JSONArray(prefs.getString("pending", "[]"))
                if (queue.length() == 0) null else queue.getJSONObject(0).let {
                    Event(it.getString("id"), it.getString("condition"), it.getLong("at"))
                }
            } },
            acknowledge = { event -> synchronized(observations) {
                // A live receiver may append during native submission. Re-read so
                // acknowledging one event cannot discard those later observations.
                val queue = JSONArray(prefs.getString("pending", "[]"))
                if (queue.length() == 0 || queue.getJSONObject(0).getString("id") != event.id) false
                else {
                    queue.remove(0)
                    prefs.edit().putString("pending", queue.toString()).commit()
                }
            } },
            submit = submit,
        )
    }

}

class TaskScheduleConditionWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val platform = TaskSchedulePlatform.current ?: return Result.retry()
        return try {
            if (TaskScheduleConditions.drain(applicationContext) { platform.submitConditionEvent(it) }) Result.success()
            else Result.retry()
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { Result.retry() }
    }
}

class TaskScheduleConditionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_POWER_CONNECTED, Intent.ACTION_POWER_DISCONNECTED,
                Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) TaskScheduleConditions.enqueue(context)
    }
}
