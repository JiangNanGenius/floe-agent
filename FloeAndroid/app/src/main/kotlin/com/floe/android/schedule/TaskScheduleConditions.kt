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
    private data class Observation(val status: ConditionObservation, val queued: Int = 0)

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
                        Intent.ACTION_POWER_CONNECTED -> charging(app)
                        Intent.ACTION_POWER_DISCONNECTED -> false
                        Intent.ACTION_BATTERY_CHANGED -> charging(intent)
                        else -> return
                    }
                    // Battery broadcasts also carry level/temperature changes.
                    // Those must not create a fresh background probe when the
                    // actual charging state stayed unchanged.
                    if (intent.action == Intent.ACTION_BATTERY_CHANGED && synchronized(observations) {
                            val prefs = app.getSharedPreferences("floe.schedule.conditions", Context.MODE_PRIVATE)
                            prefs.contains("active.charging") && prefs.getBoolean("active.charging", false) == active
                        }) return
                    observe(app, listOf("charging" to active))
                    enqueue(app)
                }
            }
            ContextCompat.registerReceiver(app, receiver, IntentFilter().apply {
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
                addAction(Intent.ACTION_BATTERY_CHANGED)
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            powerReceiver = receiver
        }
        if (callback == null) {
            val monitor = object : ConnectivityManager.NetworkCallback() {
                // Since API26 (below minSdk), onAvailable is followed by
                // onCapabilitiesChanged. Read its ordered arguments instead
                // of racing a fresh synchronous ConnectivityManager snapshot.
                override fun onLost(network: Network) {
                    // For the DEFAULT callback this means its last network
                    // was lost with no replacement. A delayed loss must still
                    // record false even if a later reconnect is already live.
                    networkChanged(app, false)
                }
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    networkChanged(app, capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
                }
            }
            runCatching { app.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(monitor) }
                .onSuccess { callback = monitor }
                .onFailure { trace("network_callback_unavailable " + it.javaClass.simpleName) }
        }
        enqueue(app)
    }

    fun enqueue(context: Context) {
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork("floe.schedule.conditions.probe",
            // A new durable edge can arrive after the current worker's last
            // empty peek but before its success. KEEP drops that wakeup.
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            OneTimeWorkRequestBuilder<TaskScheduleConditionWorker>().build())
    }

    private fun connected(context: Context): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        return connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
    }

    private fun charging(intent: Intent?): Boolean = when (intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
        BatteryManager.BATTERY_STATUS_CHARGING, BatteryManager.BATTERY_STATUS_FULL -> true
        else -> false
    }

    private fun charging(context: Context): Boolean = charging(
        context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)))

    private fun networkChanged(context: Context, active: Boolean) {
        val observation = observe(context, listOf("networkConnected" to active))
        // Capabilities can change repeatedly without another connection.
        // Only a freshly queued edge needs another work-chain leaf. Existing
        // pending events already have a worker/retry or the periodic fallback.
        if (observation.queued > 0 || observation.status == ConditionObservation.STORAGE_UNAVAILABLE) enqueue(context)
    }

    /** Closed transport stages/counts only, never task text, IDs, network
     * names, credentials or model requests. Optional logging cannot change
     * the durable result (including on a JVM Android stub). */
    internal fun trace(stage: String) {
        runCatching { android.util.Log.i("FloeScheduleCondition", stage) }
    }

    private fun observe(context: Context, states: List<Pair<String, Boolean>>): Observation = synchronized(observations) {
        val prefs = context.getSharedPreferences("floe.schedule.conditions", Context.MODE_PRIVATE)
        val queue = JSONArray(prefs.getString("pending", "[]"))
        val now = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtime()
        val boot = bootIdentity ?: runCatching {
            "boot:${Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)}"
        }.getOrElse { "process:$processIdentity" }.also { bootIdentity = it }
        val editor = prefs.edit()
        val changed = states.any { (condition, active) ->
            !prefs.contains("active.$condition") || prefs.getBoolean("active.$condition", false) != active
        }
        val previousQueued = queue.length()
        for ((condition, active) in states) {
            if (TaskScheduleConditionPolicy.risingEdge(
                    prefs.getBoolean("active.$condition", false), active, elapsed,
                    if (prefs.contains("last_elapsed.$condition")) prefs.getLong("last_elapsed.$condition", -1) else null,
                    prefs.getString("last_boot.$condition", null) == boot)) {
                if (queue.length() >= 32) {
                    trace("observe queue_full pending=" + queue.length())
                    return@synchronized Observation(ConditionObservation.QUEUE_FULL)
                }
                queue.put(JSONObject().put("id", UUID.randomUUID().toString()).put("condition", condition).put("at", now))
                editor.putLong("last_elapsed.$condition", elapsed).putString("last_boot.$condition", boot)
            }
            // Migrate the old wall-clock debounce in the same preference write;
            // pending event IDs and observation timestamps stay unchanged.
            editor.remove("last.$condition").putBoolean("active.$condition", active)
        }
        // Commit the observed edge and stable event ID before starting native work.
        val durable = editor.putString("pending", queue.toString()).commit()
        if (changed || queue.length() != previousQueued || !durable) {
            trace("observe states=" + states.joinToString() + " queued=" +
                (queue.length() - previousQueued) + " pending=" + queue.length() + " durable=" + durable)
        }
        Observation(if (durable) ConditionObservation.DURABLE else ConditionObservation.STORAGE_UNAVAILABLE,
            queued = if (durable) queue.length() - previousQueued else 0)
    }

    suspend fun drain(context: Context, submit: suspend (Event) -> Boolean): Boolean = gate.withLock {
        val prefs = context.getSharedPreferences("floe.schedule.conditions", Context.MODE_PRIVATE)
        TaskScheduleConditionPolicy.drain(
            observe = {
                // Re-read actual state after making space, rather than replaying
                // the snapshot taken before a slow native submission.
                observe(context, listOf("charging" to charging(context), "networkConnected" to connected(context))).status
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
            val drained = TaskScheduleConditions.drain(applicationContext) { platform.submitConditionEvent(it) }
            TaskScheduleConditions.trace("worker drained=" + drained)
            if (drained) Result.success() else Result.retry()
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (error: Exception) {
            TaskScheduleConditions.trace("worker failed=" + error.javaClass.simpleName)
            Result.retry()
        }
    }
}

class TaskScheduleConditionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_POWER_CONNECTED, Intent.ACTION_POWER_DISCONNECTED,
                Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) TaskScheduleConditions.enqueue(context)
    }
}
