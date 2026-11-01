// SPDX-License-Identifier: MPL-2.0
//
// Real read-only Health Connect access for C06. The AndroidX client handles
// the API-28+ provider install/update distinction; this lane never calls a
// version-specific platform class without the client's own availability
// check. Only explicit granular READ permissions are used; there is no write,
// delete, background-read or clinical-data path.

package com.floe.android.core.systemservices

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.aggregate.AggregateMetric
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
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Duration
import java.time.Instant
import kotlin.reflect.KClass

class HealthConnectPlatformClient(context: Context) : HealthService {
    private val appContext = context.applicationContext

    fun providerStatus(): HealthProviderStatus = when (HealthConnectClient.getSdkStatus(appContext)) {
        HealthConnectClient.SDK_AVAILABLE -> HealthProviderStatus.AVAILABLE
        HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> HealthProviderStatus.UPDATE_REQUIRED
        else -> HealthProviderStatus.UNAVAILABLE
    }

    override suspend fun capability(): HealthCapability {
        val status = providerStatus()
        if (status != HealthProviderStatus.AVAILABLE) {
            return HealthCapability(status, emptySet())
        }
        val client = try {
            HealthConnectClient.getOrCreate(appContext)
        } catch (_: RuntimeException) {
            return HealthCapability(HealthProviderStatus.UNAVAILABLE, emptySet())
        }
        val granted = try {
            client.permissionController.getGrantedPermissions()
        } catch (_: RuntimeException) {
            return HealthCapability(status, emptySet())
        }
        val metrics = HealthMetric.entries
            .filter { it.supportedOnAndroid }
            .filter { metric -> granted.contains(HealthPermission.getReadPermission(HealthPermissionCatalog.recordClass(metric))) }
            .map { it.wire }
            .toSet()
        return HealthCapability(status, metrics)
    }

    override suspend fun samples(
        metric: HealthMetric,
        start: Instant,
        end: Instant,
        limit: Int,
        pageToken: String?,
    ): HealthPageRow {
        val client = availableClient()
        val page = readPage(client, metric, start, end, limit, pageToken, ascending = true)
        val rows = page.first.mapNotNull { record -> row(metric, record) }
        return HealthPageRow(
            rows = rows,
            nextPageToken = page.second,
            totalScanned = rows.size,
            truncated = page.second != null,
        )
    }

    override suspend fun aggregate(
        metric: HealthMetric,
        aggregation: HealthAggregation,
        start: Instant,
        end: Instant,
    ): HealthAggregateRow {
        if (!metric.quantity) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_QUERY_FAILED,
                "aggregate is limited to quantity metrics",
            )
        }
        if (aggregation == HealthAggregation.SUM && !metric.supportsSum) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.INVALID_REQUEST,
                "sum is limited to steps and active energy",
            )
        }
        val client = availableClient()
        if (aggregation == HealthAggregation.MOST_RECENT) {
            val page = readPage(client, metric, start, end, 1, null, ascending = false)
            val record = page.first.firstOrNull()
                ?: return HealthAggregateRow(
                    metric = metric.wire,
                    aggregation = aggregation.wire,
                    value = null,
                    unit = metric.unit,
                    recordCount = 0,
                    start = start,
                    end = end,
                    detail = "noRecordsInRange=true",
                )
            val rendered = row(metric, record)
            return HealthAggregateRow(
                metric = metric.wire,
                aggregation = aggregation.wire,
                value = rendered?.value,
                unit = rendered?.unit ?: metric.unit,
                recordCount = 1,
                start = start,
                end = end,
                detail = "mostRecent=true",
            )
        }
        val aggregateMetric = aggregateMetric(metric, aggregation)
        if (aggregateMetric != null) {
            val result = client.aggregate(
                AggregateRequest(
                    metrics = setOf(aggregateMetric),
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                ),
            )
            val value: Double? = when (metric) {
                HealthMetric.STEPS -> result[StepsRecord.COUNT_TOTAL]?.toDouble()
                HealthMetric.ACTIVE_ENERGY ->
                    result[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories
                HealthMetric.HEART_RATE -> when (aggregation) {
                    HealthAggregation.AVERAGE -> result[HeartRateRecord.BPM_AVG]?.toDouble()
                    HealthAggregation.MINIMUM -> result[HeartRateRecord.BPM_MIN]?.toDouble()
                    HealthAggregation.MAXIMUM -> result[HeartRateRecord.BPM_MAX]?.toDouble()
                    else -> null
                }
                HealthMetric.RESTING_HEART_RATE -> when (aggregation) {
                    HealthAggregation.AVERAGE -> result[RestingHeartRateRecord.BPM_AVG]?.toDouble()
                    HealthAggregation.MINIMUM -> result[RestingHeartRateRecord.BPM_MIN]?.toDouble()
                    HealthAggregation.MAXIMUM -> result[RestingHeartRateRecord.BPM_MAX]?.toDouble()
                    else -> null
                }
                HealthMetric.BODY_MASS -> when (aggregation) {
                    HealthAggregation.AVERAGE -> result[WeightRecord.WEIGHT_AVG]?.inKilograms
                    HealthAggregation.MINIMUM -> result[WeightRecord.WEIGHT_MIN]?.inKilograms
                    HealthAggregation.MAXIMUM -> result[WeightRecord.WEIGHT_MAX]?.inKilograms
                    else -> null
                }
                else -> null
            }
            val count = when {
                metric == HealthMetric.HEART_RATE -> result[HeartRateRecord.MEASUREMENTS_COUNT]?.toInt() ?: -1
                else -> -1
            }
            return HealthAggregateRow(
                metric = metric.wire,
                aggregation = aggregation.wire,
                value = value,
                unit = metric.unit,
                recordCount = count,
                start = start,
                end = end,
                detail = if (count < 0) "recordCount=unavailable" else null,
            )
        }
        // Oxygen saturation and HRV expose no stable Health Connect aggregate
        // constants in the pinned client. Compute over a bounded read and
        // refuse to publish a partial statistic when the range is too large.
        val values = readQuantityValues(client, metric, start, end)
        if (values.isEmpty()) {
            return HealthAggregateRow(
                metric = metric.wire,
                aggregation = aggregation.wire,
                value = null,
                unit = metric.unit,
                recordCount = 0,
                start = start,
                end = end,
                detail = "noRecordsInRange=true",
            )
        }
        val value = when (aggregation) {
            HealthAggregation.AVERAGE -> values.average()
            HealthAggregation.MINIMUM -> values.min()
            HealthAggregation.MAXIMUM -> values.max()
            else -> null
        }
        return HealthAggregateRow(
            metric = metric.wire,
            aggregation = aggregation.wire,
            value = value,
            unit = metric.unit,
            recordCount = values.size,
            start = start,
            end = end,
            detail = "boundedRead=true",
        )
    }

    private fun availableClient(): HealthConnectClient {
        when (providerStatus()) {
            HealthProviderStatus.AVAILABLE -> Unit
            HealthProviderStatus.UPDATE_REQUIRED -> throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_PROVIDER_UPDATE_REQUIRED,
                "Health Connect needs an update",
            )
            HealthProviderStatus.UNAVAILABLE -> throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_PROVIDER_ABSENT,
                "Health Connect is not available on this device",
            )
        }
        return try {
            HealthConnectClient.getOrCreate(appContext)
        } catch (failure: RuntimeException) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_PROVIDER_ABSENT,
                "Health Connect could not be opened",
                detail = failure.javaClass.simpleName.take(64),
            )
        }
    }

    private suspend fun readPage(
        client: HealthConnectClient,
        metric: HealthMetric,
        start: Instant,
        end: Instant,
        limit: Int,
        pageToken: String?,
        ascending: Boolean,
    ): Pair<List<Record>, String?> {
        val range = TimeRangeFilter.between(start, end)
        return when (metric) {
            HealthMetric.STEPS -> readTyped(client, StepsRecord::class, range, limit, pageToken, ascending)
            HealthMetric.ACTIVE_ENERGY ->
                readTyped(client, ActiveCaloriesBurnedRecord::class, range, limit, pageToken, ascending)
            HealthMetric.HEART_RATE ->
                readTyped(client, HeartRateRecord::class, range, limit, pageToken, ascending)
            HealthMetric.RESTING_HEART_RATE ->
                readTyped(client, RestingHeartRateRecord::class, range, limit, pageToken, ascending)
            HealthMetric.SLEEP ->
                readTyped(client, SleepSessionRecord::class, range, limit, pageToken, ascending)
            HealthMetric.WORKOUTS ->
                readTyped(client, ExerciseSessionRecord::class, range, limit, pageToken, ascending)
            HealthMetric.BODY_MASS ->
                readTyped(client, WeightRecord::class, range, limit, pageToken, ascending)
            HealthMetric.OXYGEN_SATURATION ->
                readTyped(client, OxygenSaturationRecord::class, range, limit, pageToken, ascending)
            HealthMetric.HEART_RATE_VARIABILITY ->
                readTyped(client, HeartRateVariabilityRmssdRecord::class, range, limit, pageToken, ascending)
            HealthMetric.ACTIVITY_SUMMARY -> throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_UNSUPPORTED_METRIC,
                "activity summary is not available on Android Health Connect",
            )
        }
    }

    private suspend fun <T : Record> readTyped(
        client: HealthConnectClient,
        recordType: KClass<T>,
        range: TimeRangeFilter,
        limit: Int,
        pageToken: String?,
        ascending: Boolean,
    ): Pair<List<Record>, String?> {
        val response = client.readRecords(
            ReadRecordsRequest(
                recordType = recordType,
                timeRangeFilter = range,
                ascendingOrder = ascending,
                pageSize = limit,
                pageToken = pageToken,
            ),
        )
        return response.records to response.pageToken
    }

    private fun row(metric: HealthMetric, record: Record): HealthSampleRowRow? = when (metric) {
        HealthMetric.STEPS -> (record as? StepsRecord)?.let {
            HealthSampleRowRow(metric.wire, it.startTime, it.endTime, it.count.toDouble(), metric.unit, null)
        }
        HealthMetric.ACTIVE_ENERGY -> (record as? ActiveCaloriesBurnedRecord)?.let {
            HealthSampleRowRow(
                metric.wire, it.startTime, it.endTime, it.energy.inKilocalories, metric.unit, null,
            )
        }
        HealthMetric.HEART_RATE -> (record as? HeartRateRecord)?.let {
            val samples = it.samples
            val average = if (samples.isEmpty()) null else samples.map { sample -> sample.beatsPerMinute }
                .average()
            val minimum = samples.minOfOrNull { sample -> sample.beatsPerMinute }
            val maximum = samples.maxOfOrNull { sample -> sample.beatsPerMinute }
            HealthSampleRowRow(
                metric.wire,
                it.startTime,
                it.endTime,
                average,
                metric.unit,
                "samples=${samples.size}" +
                    (minimum?.let { value -> " bpmMin=$value" } ?: "") +
                    (maximum?.let { value -> " bpmMax=$value" } ?: ""),
            )
        }
        HealthMetric.RESTING_HEART_RATE -> (record as? RestingHeartRateRecord)?.let {
            HealthSampleRowRow(
                metric.wire, it.time, it.time, it.beatsPerMinute.toDouble(), metric.unit, null,
            )
        }
        HealthMetric.SLEEP -> (record as? SleepSessionRecord)?.let {
            val minutes = Duration.between(it.startTime, it.endTime).toMinutes()
            HealthSampleRowRow(
                metric.wire,
                it.startTime,
                it.endTime,
                minutes.toDouble(),
                metric.unit,
                "stages=${it.stages.size}",
            )
        }
        HealthMetric.WORKOUTS -> (record as? ExerciseSessionRecord)?.let {
            val minutes = Duration.between(it.startTime, it.endTime).toMinutes()
            HealthSampleRowRow(
                metric.wire,
                it.startTime,
                it.endTime,
                minutes.toDouble(),
                metric.unit,
                "exerciseType=${it.exerciseType}" +
                    (it.title?.take(80)?.let { title -> " title=$title" } ?: ""),
            )
        }
        HealthMetric.BODY_MASS -> (record as? WeightRecord)?.let {
            HealthSampleRowRow(metric.wire, it.time, it.time, it.weight.inKilograms, metric.unit, null)
        }
        HealthMetric.OXYGEN_SATURATION -> (record as? OxygenSaturationRecord)?.let {
            HealthSampleRowRow(
                metric.wire,
                it.time,
                it.time,
                SystemServicesPolicy.oxygenFraction(it.percentage.value),
                metric.unit,
                "sourcePercent=${it.percentage.value}",
            )
        }
        HealthMetric.HEART_RATE_VARIABILITY -> (record as? HeartRateVariabilityRmssdRecord)?.let {
            HealthSampleRowRow(
                metric.wire, it.time, it.time, it.heartRateVariabilityMillis, metric.unit, null,
            )
        }
        HealthMetric.ACTIVITY_SUMMARY -> null
    }

    private suspend fun readQuantityValues(
        client: HealthConnectClient,
        metric: HealthMetric,
        start: Instant,
        end: Instant,
    ): List<Double> {
        val values = mutableListOf<Double>()
        var token: String? = null
        var pages = 0
        while (values.size < SystemServicesBounds.MAX_HEALTH_SCAN_ROWS && pages < 20) {
            val page = readPage(
                client,
                metric,
                start,
                end,
                SystemServicesBounds.MAX_HEALTH_PAGE,
                token,
                ascending = true,
            )
            for (record in page.first) {
                row(metric, record)?.value?.let { values.add(it) }
                if (values.size >= SystemServicesBounds.MAX_HEALTH_SCAN_ROWS) break
            }
            token = page.second
            pages += 1
            if (token == null) break
        }
        if (token != null &&
            (values.size >= SystemServicesBounds.MAX_HEALTH_SCAN_ROWS || pages >= 20)
        ) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.HEALTH_QUERY_FAILED,
                "aggregate range contains too many records; narrow the range",
            )
        }
        return values
    }

    private fun aggregateMetric(
        metric: HealthMetric,
        aggregation: HealthAggregation,
    ): AggregateMetric<*>? = when (metric) {
        HealthMetric.STEPS ->
            if (aggregation == HealthAggregation.SUM) StepsRecord.COUNT_TOTAL else null
        HealthMetric.ACTIVE_ENERGY ->
            if (aggregation == HealthAggregation.SUM) ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL else null
        HealthMetric.HEART_RATE -> when (aggregation) {
            HealthAggregation.AVERAGE -> HeartRateRecord.BPM_AVG
            HealthAggregation.MINIMUM -> HeartRateRecord.BPM_MIN
            HealthAggregation.MAXIMUM -> HeartRateRecord.BPM_MAX
            else -> null
        }
        HealthMetric.RESTING_HEART_RATE -> when (aggregation) {
            HealthAggregation.AVERAGE -> RestingHeartRateRecord.BPM_AVG
            HealthAggregation.MINIMUM -> RestingHeartRateRecord.BPM_MIN
            HealthAggregation.MAXIMUM -> RestingHeartRateRecord.BPM_MAX
            else -> null
        }
        HealthMetric.BODY_MASS -> when (aggregation) {
            HealthAggregation.AVERAGE -> WeightRecord.WEIGHT_AVG
            HealthAggregation.MINIMUM -> WeightRecord.WEIGHT_MIN
            HealthAggregation.MAXIMUM -> WeightRecord.WEIGHT_MAX
            else -> null
        }
        else -> null
    }


}
