// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasLayout
import FloeCanvasExchange

// MARK: - Scenario 3: scale benchmark (ICH12 evidence, no invented FPS)
//
// Generates deterministic mixed pages at the requested sizes, then measures
// real host operations: JSON decode, layout index build, 60 viewport pan
// queries, local edit application, and file-repository save/reopen, plus
// point-in-time process resident memory. Every number is labeled with the
// actual platform/build configuration; there are no fabricated frame rates.
// Warmup and measured iterations are reported separately, and a 10k-page
// giant raster export is intentionally NOT attempted — rendering stays in
// region/viewport scope.

enum ScaleBenchmark {
    static let scenarioName = "s3-scale-benchmark"

    struct SizeReport: Codable, Sendable {
        var size: Int
        var nodeCount: Int
        var connectionCount: Int
        var timingsMilliseconds: [String: Double]
        var memoryBytes: [String: Int64?]
        var memoryLabels: [String: String]
        var sanity: [String: Bool]
        var renderScope: String
    }

    struct BenchmarkReport: Codable, Sendable {
        var platform: String
        var buildConfiguration: String
        var note: String
        var sizes: [SizeReport]
    }

    static func run(outputRoot: URL, sizes: [Int]) async throws -> ScenarioReport {
        var checks: [Check] = []
        var artifacts: [String] = []
        var notes: [String] = []
        let directory = outputRoot.appendingPathComponent("benchmark", isDirectory: true)

        var sizeReports: [SizeReport] = []

        for size in sizes {
            let page = makePage(nodeCount: size, seed: UInt64(size))
            let snapshot = CanvasSnapshot(
                id: SyntheticQualification.uuid(0xB000 + UInt64(size)),
                name: "P4a-Scale-\(size)",
                pages: [page],
                selectedPageID: page.id)

            var timings: [String: Double] = [:]
            var memory: [String: Int64?] = [:]
            var memoryLabels: [String: String] = [:]
            var sanity: [String: Bool] = [:]

            func sampleMemory(_ key: String) {
                let sample = MemorySampler.take()
                memory[key] = sample.residentBytes
                memoryLabels[key] = sample.label
            }

            sampleMemory("beforeDecode")

            // decode: canonical encode + decode round trip.
            let encoded = try CanvasExchangeJSON.encode(snapshot)
            _ = try CanvasExchangeJSON.decode(CanvasSnapshot.self, from: encoded) // warmup
            var decodeSamples: [Double] = []
            var decoded: CanvasSnapshot?
            for _ in 0..<3 {
                let (result, seconds) = try MeasureClock(label: "decode").measure {
                    try CanvasExchangeJSON.decode(CanvasSnapshot.self, from: encoded)
                }
                decoded = result
                decodeSamples.append(seconds.milliseconds)
            }
            timings["decode.medianMs"] = decodeSamples.sorted()[decodeSamples.count / 2]
            sanity["decode.roundTripPagesEqual"] = decoded?.pages == snapshot.pages

            sampleMemory("afterDecode")

            // index build.
            _ = try CanvasPageLayoutIndex(page: page) // warmup
            var indexSamples: [Double] = []
            var index: CanvasPageLayoutIndex?
            for _ in 0..<3 {
                let (result, seconds) = try MeasureClock(label: "index").measure {
                    try CanvasPageLayoutIndex(page: page)
                }
                index = result
                indexSamples.append(seconds.milliseconds)
            }
            timings["indexBuild.medianMs"] = indexSamples.sorted()[indexSamples.count / 2]

            sampleMemory("afterIndexBuild")

            // pan: 60 viewport queries sweeping the board.
            guard let builtIndex = index else {
                throw CanvasKitError.invalidSnapshot("index build failed for \(size)")
            }
            let fullRect = CanvasLayoutGeometry.rect(from: CanvasGeometry.Frame(
                center: .init(x: 0, y: 0),
                size: .init(width: 4_000_000, height: 4_000_000)))
            let visibleAll = builtIndex.visibleNodes(in: fullRect)
            sanity["index.visibleAllEqualsNodeCount"] = visibleAll.count == page.nodes.count

            var panVisibleCounts: [Int] = []
            let (panResult, panSeconds) = try MeasureClock(label: "pan").measure {
                var counts: [Int] = []
                var rng = DeterministicRNG(seed: UInt64(size) ^ 0x5EED)
                for step in 0..<60 {
                    let centerX = -2000 + Double(step) * 68 + rng.double() * 40
                    let centerY = -1500 + Double(step % 17) * 180 + rng.double() * 40
                    let rect = CanvasLayoutGeometry.rect(from: CanvasGeometry.Frame(
                        center: .init(x: centerX, y: centerY),
                        size: .init(width: 900, height: 640)))
                    counts.append(builtIndex.visibleNodes(in: rect).count)
                }
                return counts
            }
            panVisibleCounts = panResult
            timings["pan.60Queries.totalMs"] = panSeconds.milliseconds
            // per-query timing: divide total by count (honest average)
            timings["pan.queryAvgMs"] =
                panSeconds.milliseconds / 60
            sanity["pan.returnedResults"] = panVisibleCounts.count == 60

            // nearby (search/focus) query.
            let (_, nearbySeconds) = try MeasureClock(label: "nearby").measure {
                _ = builtIndex.nearby(to: .init(x: 0, y: 0), radius: 500)
            }
            timings["nearby.singleQueryMs"] = nearbySeconds.milliseconds

            // local edit: apply a move on a fresh copy each time.
            let editTarget = page.nodes[page.nodes.count - 1]
            let editBatch = CanvasEditBatch(
                pageID: page.id,
                scope: .wholeDocument,
                operations: [.move(
                    nodeID: editTarget.id,
                    center: .init(
                        x: editTarget.frame.center.x + 12,
                        y: editTarget.frame.center.y + 8))])
            _ = try CanvasEditEngine.apply(editBatch, to: snapshot) // warmup
            var editSamples: [Double] = []
            var editResult: CanvasEditResult?
            for _ in 0..<10 {
                let (result, seconds) = try MeasureClock(label: "edit").measure {
                    try CanvasEditEngine.apply(editBatch, to: snapshot)
                }
                editResult = result
                editSamples.append(seconds.milliseconds)
            }
            timings["localEdit.applyMedianMs"] =
                editSamples.sorted()[editSamples.count / 2]
            sanity["edit.changedTarget"] =
                editResult?.changedNodeIDs.contains(editTarget.id) == true

            // save/reopen through the real file repository (fsync discipline).
            sampleMemory("beforeSave")
            let repoRoot = outputRoot.appendingPathComponent(
                "benchmark-repo-\(size)-\(UUID().uuidString)", isDirectory: true)
            let (reopenResult, saveSeconds) = try await MeasureClock(label: "save").measureAsync {
                () async throws -> CanvasSnapshot in
                let repository = try FileCanvasRepository(root: repoRoot)
                try await repository.create(
                    canvasID: snapshot.id, snapshot: snapshot,
                    requestID: SyntheticQualification.uuid(0xB100 + UInt64(size)))
                try await repository.commit(
                    editBatch, canvasID: snapshot.id,
                    expectedRevision: snapshot.revision,
                    requestID: SyntheticQualification.uuid(0xB200 + UInt64(size)))
                return try await repository.load(canvasID: snapshot.id)
            }
            timings["saveCommitReopen.totalMs"] = saveSeconds.milliseconds
            sanity["save.reopenEqual"] = editResult.map {
                $0.snapshot.pages == reopenResult.pages
            } == true && reopenResult.revision == snapshot.revision + 1
            sampleMemory("afterReopen")
            try? FileManager.default.removeItem(at: repoRoot)

            // Render scope: region/viewport-only; no giant raster.
            var renderScopeNote = "render skipped for this size"
            if size == sizes.first {
                // Explicit selection scope == a viewport-sized render; no
                // giant raster is produced for any size.
                let scope = CanvasExportScope.selection(
                    Set(page.nodes.prefix(12).map(\.id)))
                let png = try await CanvasExchange.export(
                    snapshot, format: .png,
                    options: CanvasExportOptions(
                        pageID: page.id, scope: scope, appearance: .light))
                let name = try QualifyIO.write(
                    png.primary.data, to: directory,
                    name: "render-scope-\(size).png")
                artifacts.append("benchmark/\(name)")
                renderScopeNote =
                    "selection-scope (viewport-sized) PNG export written for "
                    + "the smallest size"
                sanity["render.scopePngMagic"] =
                    png.primary.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            } else {
                sanity["render.scopePngMagic"] = true // not applicable
            }
            if size >= 10_000 {
                renderScopeNote =
                    "10k+ giant raster export intentionally not attempted; "
                    + "rendering stays in region/viewport scope"
            }

            sizeReports.append(SizeReport(
                size: size,
                nodeCount: page.nodes.count,
                connectionCount: page.connections.count,
                timingsMilliseconds: timings,
                memoryBytes: memory,
                memoryLabels: memoryLabels,
                sanity: sanity,
                renderScope: renderScopeNote))

            // Checks for this size.
            checks.append(Check(
                id: "s3.decode.\(size)",
                scenario: scenarioName,
                status: sanity["decode.roundTripPagesEqual"] == true ? .pass : .fail,
                detail: "canonical JSON encode→decode returns an equal snapshot",
                evidence: [
                    "median \(timings["decode.medianMs"] ?? -1) ms",
                    "encodedBytes=\(encoded.count)",
                ]))
            checks.append(Check(
                id: "s3.index.\(size)",
                scenario: scenarioName,
                status: (sanity["index.visibleAllEqualsNodeCount"] == true)
                    ? .pass : .fail,
                detail: "layout index build; full-extent query returns exactly "
                    + "all nodes",
                evidence: [
                    "median build \(timings["indexBuild.medianMs"] ?? -1) ms",
                    "visibleAll=\(visibleAll.count)/\(page.nodes.count)",
                ]))
            checks.append(Check(
                id: "s3.pan.\(size)",
                scenario: scenarioName,
                status: (sanity["pan.returnedResults"] == true
                    && sanity["index.visibleAllEqualsNodeCount"] == true)
                    ? .pass : .fail,
                detail: "60 viewport pan queries answered from the spatial "
                    + "index (avg per query measured; no FPS claimed)",
                evidence: [
                    "total \(timings["pan.60Queries.totalMs"] ?? -1) ms",
                    "avg \(timings["pan.queryAvgMs"] ?? -1) ms/query",
                ]))
            checks.append(Check(
                id: "s3.edit.\(size)",
                scenario: scenarioName,
                status: (sanity["edit.changedTarget"] == true) ? .pass : .fail,
                detail: "local edit engine apply moves one node (median of 10)",
                evidence: [
                    "median \(timings["localEdit.applyMedianMs"] ?? -1) ms",
                ]))
            checks.append(Check(
                id: "s3.saveReopen.\(size)",
                scenario: scenarioName,
                status: (sanity["save.reopenEqual"] == true) ? .pass : .fail,
                detail: "file repository create+commit+load round trip; reopen "
                    + "equals the saved state at the next revision",
                evidence: [
                    "total \(timings["saveCommitReopen.totalMs"] ?? -1) ms",
                ]))
            let memorySample = memory["afterReopen"] ?? nil
            checks.append(Check(
                id: "s3.memory.\(size)",
                scenario: scenarioName,
                status: memorySample != nil ? .pass : .unverified,
                detail: memorySample != nil
                    ? "process resident memory sampled via task_vm_info "
                        + "(point-in-time, not peak)"
                    : "process resident memory unavailable on this platform",
                evidence: memory.map { "\($0.key)=\($0.value.map(String.init) ?? "nil")" }))
        }

        let report = BenchmarkReport(
            platform: BaseInfo.current().platform,
            buildConfiguration: BaseInfo.current().buildConfiguration,
            note: "Host CPU wall-clock timings in the labeled build "
                + "configuration. These are退化护栏/degradation evidence, not "
                + "frame rates; no simulator/device FPS is invented. Memory is "
                + "task_vm_info resident_size at sampling points.",
            sizes: sizeReports)
        let data = try QualifyIO.encodeJSON(report)
        let name = try QualifyIO.write(data, to: directory, name: "benchmark.json")
        artifacts.append("benchmark/\(name)")

        notes.append(
            "no giant raster export at 10k; render scope limited to a region "
            + "of the smallest sample")
        notes.append(
            "warmup iterations precede measured iterations for decode/index; "
            + "edit median over 10 applies; save/reopen measured once per size")

        return ScenarioReport(
            scenario: scenarioName,
            checks: checks,
            artifacts: artifacts,
            notes: notes)
    }

    // MARK: Deterministic mixed page generation

    static func makePage(nodeCount: Int, seed: UInt64) -> CanvasPageSnapshot {
        var rng = DeterministicRNG(seed: seed)
        var nodes: [CanvasNodeSnapshot] = []
        var connections: [CanvasConnectionSnapshot] = []
        let columns = max(1, Int((Double(nodeCount) * 260.0 * 200.0 / 1_800_000.0).squareRoot()))
        for index in 0..<nodeCount {
            let gridX = index % max(columns, 1)
            let gridY = index / max(columns, 1)
            let x = Double(gridX) * 300 + rng.double() * 40 - 3000
            let y = Double(gridY) * 240 + rng.double() * 40 - 2000
            let id = UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012llx",
                0xBEEF_0000_0000 + UInt64(index)))!
            let kind = index % 5
            let content: CanvasContent
            switch kind {
            case 0:
                content = .markdown(
                    document: "# 卡片 \(index)\n\n规模样本 mixed card 🧊 #\(index)",
                    previewText: nil)
            case 1:
                content = .shape(
                    kind: .roundedRectangle,
                    text: "形状 \(index)")
            case 2:
                content = .text("纯文本样本 \(index)")
            case 3:
                content = .table(
                    header: ["列 A", "列 B"],
                    rows: [["\(index)", "值"]])
            default:
                content = .code(
                    language: "swift",
                    source: "let card\(index) = \(index)")
            }
            nodes.append(CanvasNodeSnapshot(
                id: id,
                title: "card-\(index)",
                content: content,
                frame: CanvasGeometry.Frame(
                    center: .init(x: x, y: y),
                    size: .init(width: 220, height: 140)),
                zIndex: index))
            if index > 0, index % 3 == 0 {
                connections.append(CanvasConnectionSnapshot(
                    id: UUID(uuidString: String(
                        format: "00000000-0000-4000-8000-%012llx",
                        0xCAFE_0000_0000 + UInt64(index)))!,
                    sourceNodeID: nodes[index - 1].id,
                    destinationNodeID: id,
                    kind: .arrow,
                    label: index % 9 == 0 ? "关联 \(index)" : nil))
            }
        }
        return CanvasPageSnapshot(
            id: SyntheticQualification.uuid(0xB0FF + UInt64(nodeCount)),
            name: "scale-\(nodeCount)",
            nodes: nodes,
            connections: connections,
            background: .grid)
    }
}
