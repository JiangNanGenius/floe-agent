// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import com.floe.android.core.networkmonitor.CoverageAggregate
import com.floe.android.core.networkmonitor.CoverageMetrics
import com.floe.android.core.networkmonitor.CoveragePoint
import com.floe.android.core.networkmonitor.CoverageReportRenderer
import com.floe.android.core.networkmonitor.CoverageScanStatus
import com.floe.android.core.networkmonitor.CoverageSession
import com.floe.android.core.pcap.PcapAnalysisStatus
import com.floe.android.core.pcap.PcapFilters
import com.floe.android.core.pcap.PcapFlow
import com.floe.android.core.pcap.PcapProtocol
import com.floe.android.core.pcap.PcapServiceFilter
import com.floe.android.core.pcap.PcapSummary
import com.floe.android.core.pcap.PcapSummaryView
import com.floe.android.feature.network.CoverageAccessPointUi
import com.floe.android.feature.network.CoverageAggregateUi
import com.floe.android.feature.network.CoverageFloorplanUi
import com.floe.android.feature.network.CoverageGridCellUi
import com.floe.android.feature.network.CoverageLegendUi
import com.floe.android.feature.network.CoveragePointUi
import com.floe.android.feature.network.CoverageProbeUi
import com.floe.android.feature.network.CoverageSessionItemUi
import com.floe.android.feature.network.CoverageSessionUi
import com.floe.android.feature.network.PcapAnalysisItemUi
import com.floe.android.feature.network.PcapAnalysisUi
import com.floe.android.feature.network.PcapDnsRowUi
import com.floe.android.feature.network.PcapFilterQuery
import com.floe.android.feature.network.PcapFlowRowUi
import com.floe.android.feature.network.PcapHttpRowUi
import com.floe.android.feature.network.PcapProtocolRowUi
import com.floe.android.feature.network.PcapTimelineRowUi

/** Pure host projections from the bounded core models to the feature UI. */
object NetworkArtifactProjection {
    fun pcapItem(summary: PcapSummary, agentReadable: Boolean = false): PcapAnalysisItemUi = PcapAnalysisItemUi(
        analysisID = summary.analysisID,
        createdAtEpochMillis = summary.createdAtEpochMillis,
        status = summary.status.wire,
        format = summary.format.wire,
        sourceLabel = summary.sourceLabel,
        detailed = summary.detailed,
        packetCount = summary.packetCount,
        flowCount = summary.totalFlowCount,
        sourceBytes = summary.sourceBytes,
        parseMillis = summary.parseMillis,
        agentReadable = agentReadable,
    )

    fun pcap(
        summary: PcapSummary,
        query: PcapFilterQuery,
        agentReadable: Boolean = false,
    ): PcapAnalysisUi {
        val filters = query.toCore()
        val view = PcapSummaryView.of(summary, filters)
        return PcapAnalysisUi(
            item = pcapItem(summary, agentReadable),
            startEpochMillis = summary.startEpochMillis,
            endEpochMillis = summary.endEpochMillis,
            totalBytes = summary.totalByteCount,
            matchedFlows = view.matchedFlows.size.toLong(),
            matchedPackets = view.matchedPackets,
            matchedBytes = view.matchedBytes,
            filters = query,
            protocols = summary.protocols.map {
                PcapProtocolRowUi(it.protocol.wire, it.packetCount, it.byteCount)
            },
            flows = view.matchedFlows.map(::flow),
            timeline = view.matchedTimeline.map {
                PcapTimelineRowUi(it.startEpochMillis, it.bucketMillis, it.packetCount, it.byteCount)
            },
            dns = view.matchedDns.map {
                PcapDnsRowUi(it.timestampEpochMillis, it.direction, it.name, it.recordType, it.responseCode)
            },
            http = view.matchedHttp.map {
                PcapHttpRowUi(it.timestampEpochMillis, it.direction, it.methodOrStatus,
                    it.host, it.path, it.payloadBytes)
            },
            limitations = summary.limitations,
            stoppedReason = summary.stoppedReason,
            cancelled = summary.cancelled,
        )
    }

    fun coverageItem(session: CoverageSession): CoverageSessionItemUi = CoverageSessionItemUi(
        sessionID = session.sessionID,
        name = session.name,
        updatedAtEpochMillis = session.updatedAtEpochMillis,
        pointCount = session.points.size,
        namedLocations = session.namedLocations,
        hasFloorplan = session.floorplan != null,
        agentReadable = session.agentReadable,
    )

    fun coverage(
        session: CoverageSession,
        nowEpochMillis: Long,
        floorplanImage: ByteArray?,
    ): CoverageSessionUi = CoverageSessionUi(
        item = coverageItem(session),
        aggregate = aggregate(CoverageMetrics.aggregate(session, nowEpochMillis)),
        points = session.points.map { point(it, nowEpochMillis) },
        floorplan = session.floorplan?.let {
            CoverageFloorplanUi(it.width, it.height, it.mimeType, it.byteCount, floorplanImage)
        },
        limitations = CoverageReportRenderer.limitations(session, nowEpochMillis),
        sampledAtEpochMillis = session.points.maxOfOrNull { it.scan.capturedAtEpochMillis }
            ?: session.updatedAtEpochMillis,
    )

    private fun flow(flow: PcapFlow): PcapFlowRowUi = PcapFlowRowUi(
        firstEpochMillis = flow.firstEpochMillis,
        lastEpochMillis = flow.lastEpochMillis,
        protocol = flow.protocol.wire,
        ipVersion = flow.ipVersion.number,
        source = flow.source.address,
        sourcePort = flow.source.port,
        destination = flow.destination.address,
        destinationPort = flow.destination.port,
        packets = flow.packetCount,
        bytes = flow.byteCount,
        tcpFlags = flow.tcpFlags,
    )

    private fun point(point: CoveragePoint, now: Long): CoveragePointUi {
        val best = point.scan.accessPoints.maxByOrNull { it.rssiDbm }
        return CoveragePointUi(
            pointID = point.pointID,
            label = point.label,
            x = point.x,
            y = point.y,
            capturedAtEpochMillis = point.scan.capturedAtEpochMillis,
            rssiDbm = point.rssiDbm,
            level = point.signalLevel,
            ageMs = point.ageMillis(now),
            stale = point.isStale(now),
            scanStatus = point.scan.status.wire,
            refreshStatus = point.scan.refreshStatus.wire,
            cachedAgeMs = point.scan.cachedAgeMs,
            permissionRequired = point.scan.status == CoverageScanStatus.PERMISSION_REQUIRED,
            channel = best?.channel,
            band = best?.band,
            accessPoints = point.scan.accessPoints.map {
                CoverageAccessPointUi(it.ssid, it.bssid, it.rssiDbm, it.channel, it.band, it.ageMs)
            },
            probe = point.probe?.let {
                CoverageProbeUi(it.kind, it.status, it.latencyMs, it.bitsPerSecond,
                    it.payloadBytes, it.errorCode)
            },
        )
    }

    private fun aggregate(aggregate: CoverageAggregate): CoverageAggregateUi = CoverageAggregateUi(
        pointCount = aggregate.pointCount,
        staleCount = aggregate.staleCount,
        permissionRequiredCount = aggregate.permissionRequiredCount,
        cachedScanCount = aggregate.cachedScanCount,
        noSignalCount = aggregate.noSignalCount,
        rssiMin = aggregate.rssiMin,
        rssiMax = aggregate.rssiMax,
        rssiAverage = aggregate.rssiAverage,
        estimatedCoveragePercent = aggregate.estimatedCoveragePercent,
        unsampledCells = aggregate.unsampledCells,
        bandCounts = aggregate.bandCounts,
        channelCounts = aggregate.channelCounts,
        legend = aggregate.legend.map {
            CoverageLegendUi(it.level, it.minimumDbm, it.maximumDbm, it.pointCount)
        },
        grid = aggregate.grid.map {
            CoverageGridCellUi(it.column, it.row, it.sampleCount, it.averageRssiDbm, it.bestRssiDbm)
        },
    )
}

fun PcapFilterQuery.toCore(): PcapFilters = PcapFilters(
    protocols = protocols.mapNotNull(PcapProtocol::fromWire).toSet(),
    services = services.mapNotNull {
        when (it) {
            "dns" -> PcapServiceFilter.DNS
            "http" -> PcapServiceFilter.HTTP
            else -> null
        }
    }.toSet(),
    address = address,
    port = port,
    startEpochMillis = startEpochMillis,
    endEpochMillis = endEpochMillis,
)

fun PcapFilters.toQuery(): PcapFilterQuery = PcapFilterQuery(
    protocols = protocols.map { it.wire }.toSet(),
    services = services.map { it.name.lowercase() }.toSet(),
    address = address,
    port = port,
    startEpochMillis = startEpochMillis,
    endEpochMillis = endEpochMillis,
)
