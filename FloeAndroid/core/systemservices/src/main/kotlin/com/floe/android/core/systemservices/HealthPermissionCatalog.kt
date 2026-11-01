// SPDX-License-Identifier: MPL-2.0
//
// Granular Health Connect READ permission catalog. One permission per metric;
// Floe never requests write, background-read, history or medical-data access.

package com.floe.android.core.systemservices

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import kotlin.reflect.KClass

object HealthPermissionCatalog {
    val metrics: List<HealthMetric> = HealthMetric.entries.filter { it.supportedOnAndroid }

    fun recordClass(metric: HealthMetric): KClass<out Record> = when (metric) {
        HealthMetric.STEPS -> StepsRecord::class
        HealthMetric.ACTIVE_ENERGY -> ActiveCaloriesBurnedRecord::class
        HealthMetric.HEART_RATE -> HeartRateRecord::class
        HealthMetric.RESTING_HEART_RATE -> RestingHeartRateRecord::class
        HealthMetric.SLEEP -> SleepSessionRecord::class
        HealthMetric.WORKOUTS -> ExerciseSessionRecord::class
        HealthMetric.BODY_MASS -> WeightRecord::class
        HealthMetric.OXYGEN_SATURATION -> OxygenSaturationRecord::class
        HealthMetric.HEART_RATE_VARIABILITY -> HeartRateVariabilityRmssdRecord::class
        HealthMetric.ACTIVITY_SUMMARY -> throw SystemServiceFailure(
            SystemServiceFailureCode.HEALTH_UNSUPPORTED_METRIC,
            "activity summary is not available on Android Health Connect",
        )
    }

    /** Only the nine supported read permissions; no write/background/history. */
    fun readPermissions(): Set<String> = metrics.mapTo(LinkedHashSet()) { metric ->
        HealthPermission.getReadPermission(recordClass(metric))
    }
}
