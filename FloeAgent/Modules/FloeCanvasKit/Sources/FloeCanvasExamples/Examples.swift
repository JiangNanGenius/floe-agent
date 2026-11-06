import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

// Compatibility sample: legacy JSON bytes → snapshot → repository
// commit/undo → file-backed round trip. Run via `swift run floe-canvas-examples`.
//
// With no arguments the P0.1 baseline below runs unchanged. The `qualify`
// subcommand runs the P4a executable qualification harness (synthetic
// mixed research+flow archive, interop fixture round trip, scale benchmark,
// offline flow harness) and writes machine-readable results:
//
//   floe-canvas-examples qualify --output <ABS_DIR under Local/Private|Artifacts>

@main
enum FloeCanvasExamples {
    static func main() async {
        do { try await runCommand() }
        catch {
            FileHandle.standardError.write(Data("Canvas qualification failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runCommand() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "qualify" {
            arguments.removeFirst()
            try await runQualify(arguments)
            return
        }
        if arguments.first == "--help" || arguments.first == "-h" {
            print(QualifyCLI.usage)
            return
        }
        if !arguments.isEmpty {
            FileHandle.standardError.write(Data(
                ("unknown arguments: \(arguments.joined(separator: " "))\n"
                 + QualifyCLI.usage + "\n").utf8))
            throw ExitCode.invalidArgument
        }
        try await runP01Baseline()
    }

    private enum ExitCode: Error {
        case invalidArgument
        case qualificationFailed
    }

    // MARK: P0.1 baseline (unchanged behavior)

    static func runP01Baseline() async throws {
        let fixtureURL = Bundle.module.url(
            forResource: "legacy-sample",
            withExtension: "json",
            subdirectory: "Fixtures")!
        let bytes = try Data(contentsOf: fixtureURL)

        // 1. Legacy import: unknown kinds and unknown top-level keys are
        //    preserved and reported, not dropped.
        let imported = try LegacyCanvasAdapter.import(bytes)
        print("== legacy import ==")
        print("canvas: \(imported.snapshot.id.uuidString) "
              + "\"\(imported.snapshot.name)\" "
              + "pages=\(imported.snapshot.pages.count) "
              + "revision=\(imported.snapshot.revision)")
        for warning in imported.plan.warnings {
            print("warning: \(warning.code.rawValue) at \(warning.path): \(warning.detail)")
        }
        print("preserved keys: \(imported.plan.preservedKeys.joined(separator: ", "))")

        // 2. In-memory repository: one batch, one receipt, replay-safe.
        let repository = InMemoryCanvasRepository(snapshot: imported.snapshot)
        let pageID = imported.snapshot.selectedPageID
        let node = CanvasNodeSnapshot(
            content: .markdown(document: "# Summary", previewText: "Summary"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 300, y: 600),
                size: .init(width: 320, height: 200))
        )
        let batch = CanvasEditBatch(pageID: pageID, operations: [
            .insertNode(node)
        ])
        let receipt = try await repository.commit(
            batch, canvasID: imported.snapshot.id,
            expectedRevision: imported.snapshot.revision,
            requestID: UUID())
        print("\n== in-memory commit ==")
        print("revision \(receipt.previousRevision) → \(receipt.revision)")

        // Identical replay returns the same receipt without a new revision.
        let replay = try await repository.commit(
            batch, canvasID: imported.snapshot.id,
            expectedRevision: imported.snapshot.revision,
            requestID: receipt.requestID)
        print("replay same requestID: revision still \(replay.revision)")

        // Undo is its own revision bump.
        let undoReceipt = try await repository.undo(canvasID: imported.snapshot.id)
        print("undo: revision \(undoReceipt.previousRevision) → \(undoReceipt.revision)")

        // 3. File-backed qualification repository round trip.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-canvas-examples-\(UUID().uuidString)")
        let fileRepository = try FileCanvasRepository(root: root)
        try await fileRepository.create(
            canvasID: imported.snapshot.id,
            snapshot: imported.snapshot,
            requestID: UUID())
        // create() establishes revision 0 as the committed base.
        let fileReceipt = try await fileRepository.commit(
            batch, canvasID: imported.snapshot.id,
            expectedRevision: 0,
            requestID: UUID())
        let reloaded = try await fileRepository.load(
            canvasID: imported.snapshot.id)
        print("\n== file repository ==")
        print("revision \(fileReceipt.previousRevision) → \(fileReceipt.revision); "
              + "reloaded revision=\(reloaded.revision) "
              + "nodes=\(reloaded.selectedPage?.nodes.count ?? 0)")
        print("root: \(root.path)")
        try? FileManager.default.removeItem(at: root)

        // 4. Write-back keeps unknown legacy data.
        let exported = try LegacyCanvasAdapter.exportPreservingLegacy(imported)
        let exportedText = String(data: exported, encoding: .utf8) ?? ""
        print("\n== write-back ==")
        print("exported bytes: \(exported.count); "
              + "keeps experimentalFeature=\(exportedText.contains("experimentalFeature"))")
    }

    // MARK: P4a qualification harness

    static func runQualify(_ arguments: [String]) async throws {
        let options = try QualifyCLI.parse(arguments)
        let runDirectory = try QualifyCLI.makeRunDirectory(under: options.outputRoot)
        let reporter = QualifyReporter()
        let command = (["floe-canvas-examples", "qualify"] + arguments)
            .joined(separator: " ")

        print("== FloeCanvasKit P4a qualification ==")
        print("output root: \(runDirectory.path)")
        if options.fixtures == nil {
            print("note: --fixtures not provided; interop scenario reported unverified")
        }

        var failures = false

        func emit(_ report: ScenarioReport) async {
            await reporter.emit(report)
            let failed = report.checks.filter { $0.status == .fail }.count
            let passed = report.checks.filter { $0.status == .pass }.count
            let unverified = report.checks.filter { $0.status == .unverified }.count
            print("[\(report.scenario)] pass=\(passed) fail=\(failed) unverified=\(unverified)")
            for check in report.checks where check.status != .pass {
                print("  \(check.status.rawValue.uppercased()) \(check.id): \(check.detail)")
            }
            if failed > 0 { failures = true }
        }

        if !options.skipSynthetic {
            do {
                try await emit(SyntheticQualification.run(outputRoot: runDirectory))
            } catch {
                failures = true
                await reporter.emit(ScenarioReport(
                    scenario: SyntheticQualification.scenarioName,
                    checks: [Check(
                        id: "s1.fatal",
                        scenario: SyntheticQualification.scenarioName,
                        status: .fail,
                        detail: "scenario error: \(error)",
                        evidence: [])],
                    artifacts: [],
                    notes: []))
                print("[s1] FATAL: \(error)")
            }
        } else {
            await reporter.emit(skipped(SyntheticQualification.scenarioName, "s1"))
        }

        if !options.skipInterop, let fixtures = options.fixtures {
            do {
                try await emit(InteropQualification.run(
                    outputRoot: runDirectory, fixtures: fixtures))
            } catch {
                failures = true
                await reporter.emit(ScenarioReport(
                    scenario: InteropQualification.scenarioName,
                    checks: [Check(
                        id: "s2.fatal",
                        scenario: InteropQualification.scenarioName,
                        status: .fail,
                        detail: "scenario error: \(error)",
                        evidence: [])],
                    artifacts: [],
                    notes: []))
                print("[s2] FATAL: \(error)")
            }
        } else {
            await reporter.emit(skipped(
                InteropQualification.scenarioName, "s2",
                note: options.fixtures == nil
                    ? "fixtures directory not provided or not found"
                    : "skipped by --skip-interop"))
        }

        if !options.skipBenchmark {
            do {
                try await emit(ScaleBenchmark.run(
                    outputRoot: runDirectory, sizes: options.sizes))
            } catch {
                failures = true
                await reporter.emit(ScenarioReport(
                    scenario: ScaleBenchmark.scenarioName,
                    checks: [Check(
                        id: "s3.fatal",
                        scenario: ScaleBenchmark.scenarioName,
                        status: .fail,
                        detail: "scenario error: \(error)",
                        evidence: [])],
                    artifacts: [],
                    notes: []))
                print("[s3] FATAL: \(error)")
            }
        } else {
            await reporter.emit(skipped(ScaleBenchmark.scenarioName, "s3"))
        }

        if !options.skipFlow {
            do {
                try await emit(FlowQualification.run(outputRoot: runDirectory))
            } catch {
                failures = true
                await reporter.emit(ScenarioReport(
                    scenario: FlowQualification.scenarioName,
                    checks: [Check(
                        id: "s4.fatal",
                        scenario: FlowQualification.scenarioName,
                        status: .fail,
                        detail: "scenario error: \(error)",
                        evidence: [])],
                    artifacts: [],
                    notes: []))
                print("[s4] FATAL: \(error)")
            }
        } else {
            await reporter.emit(skipped(FlowQualification.scenarioName, "s4"))
        }

        let summary = await reporter.summary(command: command)
        let summaryData = try QualifyIO.encodeJSON(summary)
        let summaryName = try QualifyIO.write(
            summaryData, to: runDirectory, name: "summary.json")
        print("\ntotals: pass=\(summary.totals.pass) "
              + "fail=\(summary.totals.fail) "
              + "unverified=\(summary.totals.unverified)")
        print("summary: \(runDirectory.appendingPathComponent(summaryName).path)")
        if failures {
            throw ExitCode.qualificationFailed
        }
    }

    private static func skipped(
        _ scenario: String, _ prefix: String, note: String = "skipped by flag"
    ) -> ScenarioReport {
        ScenarioReport(
            scenario: scenario,
            checks: [Check(
                id: "\(prefix).skipped",
                scenario: scenario,
                status: .unverified,
                detail: note,
                evidence: [])],
            artifacts: [],
            notes: [])
    }
}
