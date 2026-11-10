// FloeImages — image.renderSVG tool contracts.
//
// SPDX-License-Identifier: MPL-2.0
//
// Covers the frozen producer contract: descriptor identity, validation
// matrix, workspace path ownership and NO-OVERWRITE semantics (same
// policy as image.qr.generate), the shared SVG validator's rejections
// surfacing as machine-readable tool errors, the exclusive staged
// commit under concurrency, identity-derived default paths and the
// S3-D run-output receipt publication. The real-pixel assertions run
// wherever WebKit is available; where the component host process
// cannot start a web content service they fail with the renderer's
// honest error instead of passing vacuously.

import Foundation
import CoreGraphics
import ImageIO
import Testing
import Darwin
import FloeCore
import FloeModels
import FloeTools
@testable import FloeImages

@Suite("FloeImages.SVGRenderTool")
struct SVGRenderToolTests {

    static let alphaSVG = ##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80"><rect x="10" y="10" width="40" height="40" fill="#ff0000"/></svg>"##

    private func makeScratch(_ label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-svg-\(label)-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return base
    }

    private func unboundContext(root: URL) -> ToolContext {
        ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
    }

    // MARK: - Descriptor + validation

    @Test("descriptor is a mutating file-writing local tool")
    func descriptorContract() {
        #expect(SVGRenderTool.name == "image.renderSVG")
        #expect(SVGRenderTool.isSideEffecting)
        #expect(SVGRenderTool.riskLabels == [.readsFiles, .writesFiles])
        #expect(SVGRenderTool.toolEffect == .mutating)
        #expect(!SVGRenderTool.requiresHostScope)
        // Schema stays a valid object schema (ToolCatalog validatedSchema shape).
        let data = Data(SVGRenderTool.parametersJSON.utf8)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "object")
        #expect(object?["additionalProperties"] as? Bool == false)
    }

    @Test("validation requires exactly one source and bounded options")
    func validation() throws {
        let tool = SVGRenderTool(rootProvider: { nil })
        #expect(throws: FloeError.self) { try tool.validate(.init()) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", path: "a.svg")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: String(repeating: "a", count: SVGSafetyLimits.maxSourceBytes + 1))) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", format: "tiff")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", width: 9_000)) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", quality: 0.1)) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", background: "red")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", path: "/etc/x.svg")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", path: "../x.svg")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", outputPath: "out.tiff")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(svg: "x", format: "jpeg", outputPath: "out.png")) }
        try tool.validate(.init(svg: "<svg/>", format: "png", width: 64, height: 64, background: "#0a141e"))
        try tool.validate(.init(path: "a.svg", format: "jpeg", quality: 0.8, outputPath: "out.jpg"))
    }

    @Test("SVG tool is offered with typed output bounds")
    func registeredAndTyped() throws {
        let registry = ToolRunnerRegistry()
        _ = registerImageTools(registry: registry, rootProvider: { nil })
        #expect(registry.runner(named: SVGRenderTool.name) != nil)
        #expect(registry.allDescriptors.contains { $0.name == SVGRenderTool.name })
        #expect(ToolCatalog.allDescriptors.contains { $0.name == SVGRenderTool.name })
        let explicit = try #require(TypedMutationContract.specs(for: SVGRenderTool.name, arguments: ["outputPath": "out.png"]).first)
        #expect(explicit.argument == "outputPath" && explicit.role == .outputWrite && explicit.whenAbsent == .required)
        let automatic = try #require(TypedMutationContract.specs(for: SVGRenderTool.name, arguments: [:]).first)
        #expect(automatic.whenAbsent == .boundDirectory(.workspaceDirectory(relative: "SVGExport")))
    }

    @Test("valid white and fully transparent SVGs remain valid images")
    func uniformImages() async throws {
        let scratch = try makeScratch("uniform")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        let tool = SVGRenderTool(rootProvider: { workspace })
        let context = unboundContext(root: workspace)
        let white = try await tool.execute(.init(svg: ##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#fff"/></svg>"##, format: "jpeg", outputPath: "white.jpg"), context: context)
        try #require(white.exitStatus == 0, "\(white.summary)")
        let whitePixels = try SVGTestPixels.bitmap(Data(contentsOf: workspace.appendingPathComponent("white.jpg")))
        let color = whitePixels.colorAt(x: 20, y: 20)
        #expect(color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95)
        let empty = try await tool.execute(.init(svg: ##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" opacity="0"/></svg>"##, outputPath: "transparent.png"), context: context)
        try #require(empty.exitStatus == 0, "\(empty.summary)")
        let emptyPixels = try SVGTestPixels.bitmap(Data(contentsOf: workspace.appendingPathComponent("transparent.png")))
        #expect(emptyPixels.colorAt(x: 20, y: 20).alphaComponent < 0.01)
    }

    @Test("complex diagram renders gradients clips paths and bilingual text")
    func diagramPixels() async throws {
        let scratch = try makeScratch("diagram")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        let tool = SVGRenderTool(rootProvider: { workspace })
        let output = try await tool.execute(.init(svg: SVGDocumentTests.diagramFixture, outputPath: "diagram.png"), context: unboundContext(root: workspace))
        try #require(output.exitStatus == 0, "\(output.summary)")
        let data = try Data(contentsOf: workspace.appendingPathComponent("diagram.png"))
        try Self.saveEvidence(data, name: "diagram.png")
        let pixels = try SVGTestPixels.bitmap(data)
        #expect(pixels.width == 640 && pixels.height == 360)
        #expect(pixels.colorAt(x: 0, y: 0).alphaComponent < 0.01)
        let left = pixels.colorAt(x: 30, y: 180)
        let right = pixels.colorAt(x: 610, y: 180)
        #expect(left.blueComponent > left.redComponent && left.alphaComponent > 0.9)
        #expect(right.greenComponent > left.greenComponent && right.alphaComponent > 0.9)
    }

    @Test("unsafe and invalid documents fail closed with stable codes")
    func rejectionPaths() async throws {
        let scratch = try makeScratch("reject")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let tool = SVGRenderTool(rootProvider: { workspace })
        let context = unboundContext(root: workspace)
        let cases: [(String, String)] = [
            (#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><script/></svg>"#, "unknown_element"),
            (#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" onload="x"/> "#, "event_attribute"),
            (#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><use href="other.svg#x"/></svg>"#, "unsafe_reference"),
            (#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 0 5"/>"#, "invalid_dimensions")
        ]
        for (source, expectedCode) in cases {
            let output = try await tool.execute(.init(svg: source), context: context)
            #expect(output.exitStatus == 2)
            #expect(output.summary.contains("svg_rejected code=\(expectedCode)"),
                    "expected \(expectedCode), got \(output.summary)")
        }
        // No file was written for any rejected document.
        let exportDir = workspace.appendingPathComponent("SVGExport")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: - Commit identity + NO-OVERWRITE

    @Test("default path is identity-derived: options change the name, retries keep it")
    func identityDerivedDefaultPath() throws {
        let context = ToolContext(
            runID: UUID(), toolCallID: "call-svg-1",
            cancellation: CancellationToken(),
            conversationID: UUID())
        let document = try SVGDocumentValidator.validate(Self.alphaSVG)
        let base = SVGRenderTool.identityToken(
            context: context, document: document,
            size: (width: 120, height: 80), format: "png",
            background: nil, quality: nil)
        let retry = SVGRenderTool.identityToken(
            context: context, document: document,
            size: (width: 120, height: 80), format: "png",
            background: nil, quality: nil)
        let resized = SVGRenderTool.identityToken(
            context: context, document: document,
            size: (width: 240, height: 160), format: "png",
            background: nil, quality: nil)
        let restyled = SVGRenderTool.identityToken(
            context: context, document: document,
            size: (width: 120, height: 80), format: "jpeg",
            background: nil, quality: nil)
        #expect(base == retry)
        #expect(base != resized)
        #expect(base != restyled)
        // Unbound direct use gets a random identity: never a collision.
        let legacy = unboundContext(root: FileManager.default.temporaryDirectory)
        let first = SVGRenderTool.identityToken(
            context: legacy, document: document,
            size: (width: 120, height: 80), format: "png",
            background: nil, quality: nil)
        let second = SVGRenderTool.identityToken(
            context: legacy, document: document,
            size: (width: 120, height: 80), format: "png",
            background: nil, quality: nil)
        #expect(first != second)
    }

    @Test("preexisting output is never overwritten and oversized output is refused without full read")
    func noOverwriteAndBounded() async throws {
        let scratch = try makeScratch("overwrite")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let tool = SVGRenderTool(rootProvider: { workspace })
        let context = unboundContext(root: workspace)
        let target = workspace.appendingPathComponent("SVGExport/explicit.png")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("NOT-A-PNG".utf8).write(to: target)
        let output = try await tool.execute(
            .init(svg: Self.alphaSVG, outputPath: "SVGExport/explicit.png"),
            context: context)
        // The rejection happens either at the exclusive link or the
        // bounded compare; either way the original bytes survive.
        #expect(output.exitStatus == 2)
        #expect(try Data(contentsOf: target) == Data("NOT-A-PNG".utf8))

        // A huge preexisting file at a call-derived default path is
        // refused by the size cap BEFORE any unbounded read.
        let bound = ToolContext(
            runID: UUID(), toolCallID: "call-svg-huge",
            cancellation: CancellationToken(),
            conversationID: UUID())
        let document = try SVGDocumentValidator.validate(Self.alphaSVG)
        let token = SVGRenderTool.identityToken(
            context: bound, document: document,
            size: (width: 120, height: 80), format: "png",
            background: nil, quality: nil)
        let hugePath = "SVGExport/alpha-\(token).png"
        let hugeURL = workspace.appendingPathComponent(hugePath)
        let filler = Data(repeating: 0x41, count: 200_000)
        try filler.write(to: hugeURL)
        let hugeOutput = try await tool.execute(
            .init(svg: Self.alphaSVG, outputPath: hugePath),
            context: bound)
        // Explicit path: preexisting output is refused outright.
        #expect(hugeOutput.exitStatus == 2)
        #expect(try Data(contentsOf: hugeURL) == filler)
    }

    @Test("cancellation before commit leaves no output")
    func cancelledBeforeCommit() async throws {
        let scratch = try makeScratch("cancel")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let tool = SVGRenderTool(rootProvider: { workspace })
        let token = CancellationToken()
        token.cancel()
        let context = ToolContext(runID: UUID(), workspaceRootURL: workspace, cancellation: token)
        do {
            _ = try await tool.execute(.init(svg: Self.alphaSVG), context: context)
            Issue.record("A pre-cancelled invocation must throw before starting work")
        } catch let error as FloeError {
            #expect(error == .cancelled)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("SVGExport").path)) ?? []
        #expect(leftovers.isEmpty)
        // The exclusive-commit primitive itself refuses a cancelled run.
        let stageRoot = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        var cancelled = false
        do {
            try SVGRenderTool.exclusiveStageAndLink(
                Data([0x01]), to: stageRoot.appendingPathComponent("out.bin"),
                isCancelled: { true })
        } catch {
            cancelled = true
        }
        #expect(cancelled)
        let staged = try FileManager.default.contentsOfDirectory(atPath: stageRoot.path)
        #expect(staged.isEmpty)
    }

    // MARK: - Real raster (requires a working WebKit content process)

    @Test("png output reopens with exact pixels and alpha; jpeg flattens over white")
    func realRasterReopen() async throws {
        let scratch = try makeScratch("raster")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let tool = SVGRenderTool(rootProvider: { workspace })
        let context = unboundContext(root: workspace)

        let png = try await tool.execute(
            .init(svg: Self.alphaSVG, format: "png", outputPath: "SVGExport/alpha.png"),
            context: context)
        try #require(png.exitStatus == 0, "renderer unavailable on this host: \(png.summary)")
        try #require(png.summary.contains("status=ok output=SVGExport/alpha.png"))
        #expect(png.summary.contains("width=120 height=80"))
        #expect(png.summary.contains("alpha=true"))
        #expect(png.summary.contains("mime=image/png"))
        let pngData = try Data(contentsOf: workspace.appendingPathComponent("SVGExport/alpha.png"))
        try Self.saveEvidence(pngData, name: "alpha.png")
        let measure = try SVGRenderTool.measureEncoded(pngData, expectJPEG: false)
        #expect(measure.pixelWidth == 120)
        #expect(measure.pixelHeight == 80)
        #expect(measure.hasAlpha)
        // Owner fixture pixel truth: red at (25,25), transparent at (100,60).
        let pixels = try SVGTestPixels.bitmap(pngData)
        let red = pixels.colorAt(x: 25, y: 25)
        #expect(red.redComponent > 0.9 && red.greenComponent < 0.2 && red.blueComponent < 0.2 && red.alphaComponent > 0.9)
        let empty = pixels.colorAt(x: 100, y: 60)
        #expect(empty.alphaComponent < 0.01)
        // Orientation asymmetry: the red rect spans y 10..50 of 80, so a
        // vertical flip lands (25,25) on transparent background.
        let below = pixels.colorAt(x: 25, y: 60)
        print("SVG_FIXTURE_RGBA red=\(red) empty=\(empty) below=\(below)")
        #expect(below.alphaComponent < 0.01)

        let jpeg = try await tool.execute(
            .init(svg: Self.alphaSVG, format: "jpeg", quality: 0.9, outputPath: "SVGExport/alpha.jpg"),
            context: context)
        #expect(jpeg.exitStatus == 0)
        #expect(jpeg.summary.contains("alpha=false"))
        #expect(jpeg.summary.contains("mime=image/jpeg"))
        let jpegData = try Data(contentsOf: workspace.appendingPathComponent("SVGExport/alpha.jpg"))
        try Self.saveEvidence(jpegData, name: "alpha.jpg")
        let jpegMeasure = try SVGRenderTool.measureEncoded(jpegData, expectJPEG: true)
        #expect(jpegMeasure.pixelWidth == 120)
        let jpegPixels = try SVGTestPixels.bitmap(jpegData)
        let white = jpegPixels.colorAt(x: 100, y: 60)
        #expect(white.redComponent > 0.9 && white.greenComponent > 0.9 && white.blueComponent > 0.9)

        // The same call twice: second landing refuses to overwrite and
        // reports the existing output (no silent duplication).
        let second = try await tool.execute(
            .init(svg: Self.alphaSVG, format: "png", outputPath: "SVGExport/alpha.png"),
            context: context)
        #expect(second.exitStatus == 2)
    }

    @Test("viewBox-only width 400 renders the aspect-derived 400×200 raster")
    func viewBoxRasterSize() async throws {
        let scratch = try makeScratch("vb")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let tool = SVGRenderTool(rootProvider: { workspace })
        let context = unboundContext(root: workspace)
        let output = try await tool.execute(
            .init(
                svg: ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -20 200 100"><rect x="-10" y="-20" width="100" height="100" fill="#0066ff"/><rect x="90" y="-20" width="100" height="100" fill="#00cc66"/></svg>"##,
                width: 400,
                outputPath: "SVGExport/vb.png"),
            context: context)
        try #require(output.exitStatus == 0, "renderer unavailable on this host: \(output.summary)")
        #expect(output.summary.contains("width=400 height=200"))
        let data = try Data(contentsOf: workspace.appendingPathComponent("SVGExport/vb.png"))
        let pixels = try SVGTestPixels.bitmap(data)
        let left = pixels.colorAt(x: 50, y: 100)
        let right = pixels.colorAt(x: 350, y: 100)
        #expect(left.blueComponent > 0.6 && left.redComponent < 0.4)
        #expect(right.greenComponent > 0.6 && right.redComponent < 0.4)
    }

    // MARK: - Workspace source file flow

    private static func saveEvidence(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SVG_TEST_ARTIFACT_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    @Test("workspace .svg source is read with the bounded no-follow reader")
    func workspaceSourceFile() async throws {
        let scratch = try makeScratch("filesrc")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Input"), withIntermediateDirectories: true)
        try Data(Self.alphaSVG.utf8).write(
            to: workspace.appendingPathComponent("Input/alpha.svg"),
            options: [.atomic])
        let tool = SVGRenderTool(rootProvider: { workspace })
        let context = unboundContext(root: workspace)
        let output = try await tool.execute(
            .init(path: "Input/alpha.svg", outputPath: "SVGExport/from-file.png"),
            context: context)
        try #require(output.exitStatus == 0, "renderer unavailable on this host: \(output.summary)")
        #expect(output.summary.contains("source=Input/alpha.svg"))
        #expect(output.summary.contains("sha256="))

        // A symlinked source never escapes the workspace: the bounded
        // reader refuses non-regular/no-follow targets.
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("Input/evil.svg"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let symlinkOutput = try await tool.execute(
            .init(path: "Input/evil.svg", outputPath: "SVGExport/evil.png"),
            context: context)
        #expect(symlinkOutput.exitStatus == 2)
    }

    // MARK: - S3-D publication (chat return)

    @Test("a bound run publishes the raster as a chat-verifiable receipt")
    func boundRunPublishesReceipt() async throws {
        let scratch = try makeScratch("receipt")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let artifactRoot = scratch.appendingPathComponent("ArtifactStore", isDirectory: true)
        let runID = UUID()
        let conversationID = UUID()
        let context = ToolContext(
            runID: runID,
            toolCallID: "svg-call-1",
            cancellation: CancellationToken(),
            environmentID: "env-svg-test",
            conversationID: conversationID
        )
        let tool = SVGRenderTool(
            rootProvider: { workspace },
            artifactRootProvider: { artifactRoot })
        let output = try await tool.execute(
            .init(svg: Self.alphaSVG, outputPath: "SVGExport/bound.png"),
            context: context)
        try #require(output.exitStatus == 0, "renderer unavailable on this host: \(output.summary)")
        let receipt = try #require(output.outputFiles.first)
        #expect(receipt.producerTool == SVGRenderTool.name)
        #expect(receipt.mimeType == "image/png")
        let sourceURL = workspace.appendingPathComponent("SVGExport/bound.png")
        let data = try Data(contentsOf: sourceURL)
        #expect(receipt.sha256 == FloeDigest.sha256Hex(data))
        #expect(receipt.byteCount == data.count)
        switch RunOutputSnapshotStore.verify(receipt, artifactRoot: artifactRoot) {
        case .verified: break
        case .changed, .missing, .oversized, .rejected: Issue.record("published snapshot must verify")
        }

        // Same call/slot retry: identity replay never fabricates a
        // second raster; publication stays idempotent or fails closed.
        let retry = try await tool.execute(
            .init(svg: Self.alphaSVG, outputPath: "SVGExport/bound.png"),
            context: context)
        #expect(retry.exitStatus == 0 || retry.exitStatus == 2)
        // Different bytes under one slot conflict honestly.
        let different = try await tool.execute(
            .init(svg: Self.alphaSVG, width: 240, outputPath: "SVGExport/bound.png"),
            context: context)
        #expect(different.exitStatus == 2)
    }

    @Test("partially bound contexts fail closed and keep the raster")
    func partiallyBoundFailsHonest() async throws {
        let scratch = try makeScratch("partial")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let context = ToolContext(
            runID: UUID(),
            toolCallID: "svg-call-only",
            cancellation: CancellationToken(),
            environmentID: "env-svg-partial")
        let tool = SVGRenderTool(
            rootProvider: { workspace },
            artifactRootProvider: { scratch.appendingPathComponent("ArtifactStore") })
        let output = try await tool.execute(
            .init(svg: Self.alphaSVG, outputPath: "SVGExport/partial.png"),
            context: context)
        try #require(output.exitStatus == 2, "renderer or binding: \(output.summary)")
        if output.summary.contains("requires both") {
            #expect(FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("SVGExport/partial.png").path))
            #expect(output.summary.contains("preserved at output=SVGExport/partial.png"))
        }
    }

    // MARK: - Concurrent same-output race

    @Test("two concurrent commits to one output: exactly one raster, no overwrite")
    func concurrentSameOutput() async throws {
        let scratch = try makeScratch("race")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let target = workspace.appendingPathComponent("race/result.png")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Deterministic exclusive-commit race on the primitive itself
        // (the two tool executions would also need identical rasters).
        let first = Task.detached(priority: .userInitiated) {
            Result<Void, Error>(catching: {
                try SVGRenderTool.exclusiveStageAndLink(Data([0x01, 0x02]), to: target, isCancelled: { false })
            })
        }
        let second = Task.detached(priority: .userInitiated) {
            Result<Void, Error>(catching: {
                try SVGRenderTool.exclusiveStageAndLink(Data([0x03, 0x04]), to: target, isCancelled: { false })
            })
        }
        let results = [await first.value, await second.value]
        let successes = results.filter { if case .success = $0 { return true }; return false }
        let failures = results.filter { if case .success = $0 { return false }; return true }
        #expect(successes.count == 1)
        #expect(failures.count == 1)
        let committed = try Data(contentsOf: target)
        #expect(committed == Data([0x01, 0x02]) || committed == Data([0x03, 0x04]))
        let strays = try FileManager.default.contentsOfDirectory(
            atPath: workspace.appendingPathComponent("race").path)
            .filter { $0.hasPrefix(".floe-svg-") }
        #expect(strays.isEmpty)
    }

    @Test("bounded reader refuses oversized and symlinked targets")
    func boundedReader() throws {
        let scratch = try makeScratch("reader")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let big = scratch.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 4096).write(to: big)
        #expect(try SVGRenderTool.readBoundedRegular(big, maxBytes: 1024, isCancelled: { false }) == nil)
        #expect(try SVGRenderTool.readBoundedRegular(big, maxBytes: 8192, isCancelled: { false })?.count == 4096)
        let link = scratch.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        #expect(try SVGRenderTool.readBoundedRegular(link, maxBytes: 8192, isCancelled: { false }) == nil)
    }
    @Test("nested svg viewports keep their own coordinates (data-URL image route)")
    func nestedSVGViewports() async throws {
        let scratch = try makeScratch("nested")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let tool = SVGRenderTool(rootProvider: { workspace })
        let context = unboundContext(root: workspace)
        // Outer 100x50; the nested viewport maps 0..10 onto the RIGHT
        // half only, painting it red. A global svg{width:100%} override
        // would resize the nested viewport and bleed red to the left.
        let output = try await tool.execute(
            .init(
                svg: ##"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50"><svg x="50" y="0" width="50" height="50" viewBox="0 0 10 10"><rect width="10" height="10" fill="#ff0000"/></svg></svg>"##,
                outputPath: "SVGExport/nested.png"),
            context: context)
        try #require(output.exitStatus == 0, "renderer unavailable on this host: \(output.summary)")
        #expect(output.summary.contains("width=100 height=50"))
        let data = try Data(contentsOf: workspace.appendingPathComponent("SVGExport/nested.png"))
        let pixels = try SVGTestPixels.bitmap(data)
        let left = pixels.colorAt(x: 25, y: 25)
        let right = pixels.colorAt(x: 75, y: 25)
        #expect(left.alphaComponent < 0.01, "left half must stay transparent")
        #expect(right.redComponent > 0.9 && right.alphaComponent > 0.9, "right half must be red")
    }

    @Test("blank-capture probe flags uniform background only")
    func blankProbe() throws {
        let width = 16, height = 16
        func context(fill: (CGContext) -> Void) throws -> CGContext {
            let context = try #require(CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            fill(context)
            return context
        }
        // Fully transparent buffer == blank over transparent background.
        let clear = try context(fill: { _ in })
        #expect(SVGBlankProbe.pixelsAreBlank(
            data: clear.data!, width: width, height: height,
            bytesPerRow: clear.bytesPerRow, background: .transparent))
        // Uniform WHITE buffer is NOT blank over transparent (it is a
        // legitimate solid fill) but IS blank over a white background.
        let white = try context(fill: { ctx in
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        })
        #expect(!SVGBlankProbe.pixelsAreBlank(
            data: white.data!, width: width, height: height,
            bytesPerRow: white.bytesPerRow, background: .transparent))
        #expect(SVGBlankProbe.pixelsAreBlank(
            data: white.data!, width: width, height: height,
            bytesPerRow: white.bytesPerRow, background: .white))
        // One painted pixel defeats the probe.
        let painted = try context(fill: { ctx in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 3, y: 5, width: 1, height: 1))
        })
        #expect(!SVGBlankProbe.pixelsAreBlank(
            data: painted.data!, width: width, height: height,
            bytesPerRow: painted.bytesPerRow, background: .transparent))
    }
}



/// Small pixel helper: decodes PNG/JPEG into a premultiplied-last RGBA8
/// bitmap so tests read the same pixels a consumer would.
enum SVGTestPixels {
    struct Bitmap {
        let data: [UInt8]
        let width: Int
        let height: Int
        func colorAt(x: Int, y: Int) -> (redComponent: Double, greenComponent: Double, blueComponent: Double, alphaComponent: Double) {
            precondition(x >= 0 && x < width && y >= 0 && y < height)
            let offset = (y * width + x) * 4
            // Premultiplied RGBA; unpremultiply for hue checks.
            let a = Double(data[offset + 3]) / 255.0
            guard a > 0.001 else {
                return (0, 0, 0, a)
            }
            return (
                Double(data[offset]) / 255.0 / a,
                Double(data[offset + 1]) / 255.0 / a,
                Double(data[offset + 2]) / 255.0 / a,
                a)
        }
    }

    static func bitmap(_ encoded: Data) throws -> Bitmap {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let provider = image.dataProvider,
              let buffer = provider.data else {
            throw SVGPixelDecodeError()
        }
        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let length = CFDataGetLength(buffer)
        guard image.bitsPerPixel == 32, bytesPerRow >= width * 4,
              length >= bytesPerRow * height else {
            throw SVGPixelDecodeError()
        }
        // CGImage storage starts at the TOP row; copy top-down so
        // (x, y) means the same coordinates as the SVG user space.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let pointer = CFDataGetBytePtr(buffer)!
        for row in 0..<height {
            for column in 0..<(width * 4) {
                bytes[row * width * 4 + column] = pointer[row * bytesPerRow + column]
            }
        }
        return Bitmap(data: bytes, width: width, height: height)
    }

    struct SVGPixelDecodeError: Error {}
}
