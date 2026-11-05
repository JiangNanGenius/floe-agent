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
    private var callback: ConnectivityManager.NetworkCallback? = null
    data class Event(val id: String, val condition: String, val at: Long)

    fun attach(context: Context) {
        val app = context.applicationContext
        val work = WorkManager.getInstance(app)
        work.enqueueUniquePeriodicWork("floe.schedule.conditions.monitor", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<TaskScheduleConditionWorker>(15, TimeUnit.MINUTES).build())
        if (callback == null) {
            val monitor = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { enqueue(app) }
                override fun onLost(network: Network) { enqueue(app) }
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { enqueue(app) }
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

    suspend fun drain(context: Context, submit: suspend (Event) -> Boolean): Boolean = gate.withLock {
        val prefs = context.getSharedPreferences("floe.schedule.conditions", Context.MODE_PRIVATE)
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        val connected = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        val queue = JSONArray(prefs.getString("pending", "[]"))
        val now = System.currentTimeMillis()
        val editor = prefs.edit()
        for ((condition, active) in listOf("charging" to charging, "networkConnected" to connected)) {
            if (active && !prefs.getBoolean("active.$condition", false) &&
                now - prefs.getLong("last.$condition", 0) >= 30_000) {
                if (queue.length() >= 32) return@withLock false
                queue.put(JSONObject().put("id", UUID.randomUUID().toString()).put("condition", condition).put("at", now))
                editor.putLong("last.$condition", now)
            }
            editor.putBoolean("active.$condition", active)
        }
        // Persist event IDs together with the edge before submitting anything.
        if (!editor.putString("pending", queue.toString()).commit()) return@withLock false
        while (queue.length() > 0) {
            val item = queue.getJSONObject(0)
            if (!submit(Event(item.getString("id"), item.getString("condition"), item.getLong("at")))) return@withLock false
            queue.remove(0)
            if (!prefs.edit().putString("pending", queue.toString()).commit()) return@withLock false
        }
        true
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
