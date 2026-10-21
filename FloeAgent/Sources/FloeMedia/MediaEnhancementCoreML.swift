import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreML
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model resolution

/// Resolves an installed model id to its on-disk bundle directory. The app
/// backs this with the existing `ModelArtifactStore`; without a resolver
/// `mode=coreml` fails instead of silently using a native engine.
public protocol MediaModelResolving: Sendable {
    func installedModelPath(id: String) async -> String?
}

public enum MediaModelResolution {
    public static func store(_ store: ModelArtifactStore) -> any MediaModelResolving {
        StoreResolver(store: store)
    }

    private struct StoreResolver: MediaModelResolving {
        let store: ModelArtifactStore
        func installedModelPath(id: String) async -> String? {
            await store.installed(id: id)?.rootPath
        }
    }
}

// MARK: - Contract and bundle layout

/// `contract.json` beside a compiled model. Values are read, never inferred:
/// a mismatch between the requested operation and the contract is an error.
public struct MediaModelContract: Sendable, Codable, Equatable {
    public struct Tensor: Sendable, Codable, Equatable {
        public var name: String
        public var type: String
        public var shape: [Int]?
        public var colorLayout: String?
        public var scale: Double?
        public var range: [Double]?
    }

    public var id: String
    public var version: String
    public var kind: String
    public var capability: String
    public var scaleFactor: Int?
    public var tileSize: Int
    public var phase: Double?
    public var inputs: [Tensor]
    public var outputs: [Tensor]
    public var normalization: String?
    public var license: String?
    public var licenseEvidence: String?
    public var source: String?
    public var sourceCommit: String?
    public var readinessTolerance: Double?

    public var isInterpolation: Bool { capability == "video.interpolate" }
    public var isSuperResolution: Bool { capability == "video.superResolution" }
}

/// Bundle manifest written by `package_models.py`; every installed byte is
/// hash-checked before the model is used.
struct MediaModelBundleManifest: Codable {
    struct File: Codable {
        var path: String
        var sha256: String
        var sizeBytes: Int64?
    }

    var id: String
    var version: String
    var capability: String
    var files: [File]
}

/// Readiness record persisted beside the model so a qualified status survives
/// launches but is invalidated by any byte, version, contract or runtime
/// change. `lastInferenceAt` only advances when the fixture inference really
/// ran, so a cache hit is externally observable.
struct MediaModelReadinessRecord: Codable {
    static let schema = 2

    var schema: Int
    var fingerprint: String
    /// Aggregate digest of the manifest-listed bytes recomputed on every check.
    var modelBytesDigest: String
    var contractID: String
    var contractVersion: String
    /// Core ML / OS compatibility marker that can invalidate a cached result.
    var runtimeMarker: String
    var qualified: Bool
    var checkedAt: Date
    var lastInferenceAt: Date
    var detail: String
    var metrics: [String: Double]

    init(fingerprint: String, modelBytesDigest: String, contractID: String, contractVersion: String,
         runtimeMarker: String, qualified: Bool, checkedAt: Date = Date(), lastInferenceAt: Date,
         detail: String, metrics: [String: Double]) {
        self.schema = Self.schema
        self.fingerprint = fingerprint
        self.modelBytesDigest = modelBytesDigest
        self.contractID = contractID
        self.contractVersion = contractVersion
        self.runtimeMarker = runtimeMarker
        self.qualified = qualified
        self.checkedAt = checkedAt
        self.lastInferenceAt = lastInferenceAt
        self.detail = detail
        self.metrics = metrics
    }
}

/// Pure cache decision for `MediaModelReadiness` so the reuse rules are
/// unit-testable without a real Core ML bundle.
enum MediaModelReadinessCache {
    enum Decision: Equatable {
        /// Cached positive result, revalidated against current bytes/contract/runtime.
        case reuseQualified
        /// Cached negative result inside its bounded retry window.
        case reuseNegative
        /// Run the fixture inference and rewrite the record.
        case runInference(reason: String)
    }

    /// Negative results expire so a transient failure (a busy GPU, a missing
    /// fixture that was later restored) cannot stick forever.
    static let negativeRetryInterval: TimeInterval = 15 * 60

    static func decide(
        record: MediaModelReadinessRecord?,
        fingerprint: String,
        modelBytesDigest: String,
        contractID: String,
        contractVersion: String,
        runtimeMarker: String,
        now: Date = Date(),
        negativeRetryInterval: TimeInterval = negativeRetryInterval
    ) -> Decision {
        guard let record else { return .runInference(reason: "no cached readiness record") }
        guard record.schema == MediaModelReadinessRecord.schema else {
            return .runInference(reason: "readiness record schema changed")
        }
        guard record.fingerprint == fingerprint, record.modelBytesDigest == modelBytesDigest else {
            return .runInference(reason: "model bytes or contract changed")
        }
        guard record.contractID == contractID, record.contractVersion == contractVersion else {
            return .runInference(reason: "model version changed")
        }
        guard record.runtimeMarker == runtimeMarker else {
            return .runInference(reason: "runtime changed")
        }
        if record.qualified { return .reuseQualified }
        if now.timeIntervalSince(record.checkedAt) <= negativeRetryInterval { return .reuseNegative }
        return .runInference(reason: "cached negative result expired")
    }
}

// MARK: - Runtime

/// Core ML model loading, tile inference and readiness qualification.
public actor MediaCoreMLRuntime {
    private let resolver: (any MediaModelResolving)?
    private var loaded: [String: LoadedEnhancementModel] = [:]

    public init(resolver: (any MediaModelResolving)?) {
        self.resolver = resolver
    }

    public func model(id: String) async throws -> LoadedEnhancementModel {
        if let cached = loaded[id] { return cached }
        guard let resolver else {
            throw FloeError.invalidConfiguration("mode=coreml requires the app to supply a model resolver (no model store is connected)")
        }
        guard let path = await resolver.installedModelPath(id: id) else {
            throw FloeError.notFound("model \(id) is not installed")
        }
        let model = try LoadedEnhancementModel(bundlePath: URL(fileURLWithPath: path))
        loaded[id] = model
        return model
    }

    public func invalidate(id: String) {
        loaded[id] = nil
    }
}

/// One loaded compiled model plus its verified contract.
public final class LoadedEnhancementModel: @unchecked Sendable {
    public let modelID: String
    public let contract: MediaModelContract
    public let bundleURL: URL
    public let model: MLModel
    public let modelFingerprint: String
    /// Parsed bundle manifest; readiness verifies every listed byte.
    let manifest: MediaModelBundleManifest?

    init(bundlePath: URL) throws {
        let fileManager = FileManager.default
        let contractURL = bundlePath.appendingPathComponent("contract.json")
        guard fileManager.fileExists(atPath: contractURL.path) else {
            throw FloeError.validationFailed("model bundle \(bundlePath.lastPathComponent) has no contract.json")
        }
        let contractData = try Data(floeContentsOf: contractURL)
        let contract = try JSONDecoder().decode(MediaModelContract.self, from: contractData)
        self.contract = contract
        self.modelID = contract.id
        self.bundleURL = bundlePath

        let manifestURL = bundlePath.appendingPathComponent("manifest.json")
        var fingerprintParts: [String] = [FloeDigest.sha256Hex(contractData)]
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifestData = try Data(floeContentsOf: manifestURL)
            fingerprintParts.append(FloeDigest.sha256Hex(manifestData))
            let manifest = try JSONDecoder().decode(MediaModelBundleManifest.self, from: manifestData)
            for file in manifest.files {
                let url = bundlePath.appendingPathComponent(file.path)
                guard fileManager.fileExists(atPath: url.path) else {
                    throw FloeError.validationFailed("model bundle is missing \(file.path)")
                }
            }
            self.manifest = manifest
        } else {
            fingerprintParts.append("no-manifest")
            self.manifest = nil
        }
        self.modelFingerprint = FloeDigest.sha256Hex(fingerprintParts.joined(separator: ":").data(using: .utf8) ?? Data())

        let compiled = bundlePath.appendingPathComponent("model.mlmodelc", isDirectory: true)
        let package = bundlePath.appendingPathComponent("model.mlpackage", isDirectory: true)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.allowLowPrecisionAccumulationOnGPU = false
        if fileManager.fileExists(atPath: compiled.path) {
            self.model = try MLModel(contentsOf: compiled, configuration: configuration)
        } else if fileManager.fileExists(atPath: package.path) {
            let temporary = try MLModel.compileModel(at: package)
            self.model = try MLModel(contentsOf: temporary, configuration: configuration)
        } else {
            throw FloeError.notFound("model bundle \(bundlePath.lastPathComponent) has neither model.mlmodelc nor model.mlpackage")
        }
    }

    /// Runs the model on an image feature provider. The caller owns the
    /// returned feature value; tile buffers are copied before this returns.
    func run(inputs: [String: MLFeatureValue]) throws -> MLFeatureProvider {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        return try model.prediction(from: provider)
    }
}

// MARK: - Readiness

/// Learned-model readiness: hash verification plus a bounded real inference on
/// the bundle's own fixture, compared against the conversion-time expected
/// output. Installation alone never reports runnable.
public enum MediaModelReadiness {
    public static func report(installed: [(id: String, rootPath: String)]) async -> [MediaCapabilities.Model] {
        var models: [MediaCapabilities.Model] = []
        for record in installed {
            let url = URL(fileURLWithPath: record.rootPath)
            var model: MediaCapabilities.Model?
            do {
                let loaded = try LoadedEnhancementModel(bundlePath: url)
                let qualification = try Self.qualify(loaded)
                model = MediaCapabilities.Model(
                    id: loaded.modelID,
                    capability: loaded.contract.capability,
                    installed: true,
                    kind: "coreml",
                    license: loaded.contract.license,
                    runnable: qualification.qualified,
                    unavailableReason: qualification.qualified ? nil : qualification.detail
                )
            } catch {
                model = MediaCapabilities.Model(
                    id: record.id, capability: "unknown", installed: true, kind: "coreml", license: nil,
                    runnable: false, unavailableReason: "model bundle failed to load: \(error.localizedDescription)"
                )
            }
            if let model { models.append(model) }
        }
        return models
    }

    /// Hash-verifies every manifest file, then reuses a persisted
    /// qualification only when the complete fingerprint (contract + manifest),
    /// the recomputed byte digest, the model version and the runtime marker
    /// all still match. A cache hit performs no inference; any byte change
    /// invalidates the record and forces a fresh bounded fixture inference.
    public static func qualify(_ loaded: LoadedEnhancementModel) throws -> (qualified: Bool, detail: String) {
        let recordURL = loaded.bundleURL.appendingPathComponent(".floe-readiness.json")
        let runtimeMarker = currentRuntimeMarker()
        guard let manifest = loaded.manifest else {
            return (false, "model bundle has no manifest.json; readiness cannot be hash-verified")
        }
        guard manifest.id == loaded.contract.id, manifest.version == loaded.contract.version else {
            return (false, "bundle manifest and contract disagree on id/version")
        }
        // Recomputed on every check: this is the byte-change detector.
        var byteDigestParts: [String] = []
        for file in manifest.files {
            let url = loaded.bundleURL.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return persistAndReturn(
                    false, detail: "model bundle is missing \(file.path)",
                    fingerprint: loaded.modelFingerprint, bytes: "missing", runtimeMarker: runtimeMarker,
                    contract: loaded.contract, recordURL: recordURL, ranInference: false
                )
            }
            let digest = (try? FloeDigest.sha256Hex(ofFileAt: url)) ?? ""
            guard digest.caseInsensitiveCompare(file.sha256) == .orderedSame else {
                return persistAndReturn(
                    false, detail: "model bytes changed (\(file.path) sha256 mismatch); the qualified readiness is invalid",
                    fingerprint: loaded.modelFingerprint, bytes: "mismatch:\(file.path)", runtimeMarker: runtimeMarker,
                    contract: loaded.contract, recordURL: recordURL, ranInference: false
                )
            }
            byteDigestParts.append("\(file.path):\(digest)")
        }
        let byteDigest = FloeDigest.sha256Hex(byteDigestParts.joined(separator: "\n").data(using: .utf8) ?? Data())

        let cached = readRecord(recordURL)
        let decision = MediaModelReadinessCache.decide(
            record: cached,
            fingerprint: loaded.modelFingerprint,
            modelBytesDigest: byteDigest,
            contractID: loaded.contract.id,
            contractVersion: loaded.contract.version,
            runtimeMarker: runtimeMarker
        )
        switch decision {
        case .reuseQualified:
            if let cached {
                var refreshed = cached
                refreshed.checkedAt = Date()
                writeRecord(refreshed, to: recordURL)
                return (true, cached.detail + " (cached, bytes revalidated)")
            }
            return (false, "cached readiness vanished during revalidation")
        case .reuseNegative:
            if let cached {
                return (false, cached.detail + " (cached negative; retried after the retry window)")
            }
            return (false, "cached negative readiness vanished during revalidation")
        case .runInference:
            let fixtures = loaded.bundleURL.appendingPathComponent("fixtures", isDirectory: true)
            let expectedURL = fixtures.appendingPathComponent("expected.png")
            guard FileManager.default.fileExists(atPath: expectedURL.path) else {
                return persistAndReturn(
                    false, detail: "model bundle has no fixture for readiness qualification",
                    fingerprint: loaded.modelFingerprint, bytes: byteDigest, runtimeMarker: runtimeMarker,
                    contract: loaded.contract, recordURL: recordURL, ranInference: false
                )
            }
            let tolerance = loaded.contract.readinessTolerance ?? 0.03
            let result: (Bool, String, [String: Double])
            if loaded.contract.isInterpolation {
                result = try runInterpolationFixture(loaded, fixtures: fixtures, expectedURL: expectedURL, tolerance: tolerance)
            } else if loaded.contract.isSuperResolution {
                result = try runSuperResolutionFixture(loaded, fixtures: fixtures, expectedURL: expectedURL, tolerance: tolerance)
            } else {
                result = (false, "unsupported model capability \(loaded.contract.capability)", [:])
            }
            return persistAndReturn(
                result.0, detail: result.1,
                fingerprint: loaded.modelFingerprint, bytes: byteDigest, runtimeMarker: runtimeMarker,
                contract: loaded.contract, recordURL: recordURL, ranInference: true, metrics: result.2
            )
        }
    }

    private static func persistAndReturn(
        _ qualified: Bool,
        detail: String,
        fingerprint: String,
        bytes: String,
        runtimeMarker: String,
        contract: MediaModelContract,
        recordURL: URL,
        ranInference: Bool,
        metrics: [String: Double] = [:]
    ) -> (qualified: Bool, detail: String) {
        let previous = readRecord(recordURL)
        let lastInference = ranInference ? Date() : (previous?.lastInferenceAt ?? .distantPast)
        let record = MediaModelReadinessRecord(
            fingerprint: fingerprint,
            modelBytesDigest: bytes,
            contractID: contract.id,
            contractVersion: contract.version,
            runtimeMarker: runtimeMarker,
            qualified: qualified,
            lastInferenceAt: lastInference,
            detail: detail,
            metrics: metrics
        )
        writeRecord(record, to: recordURL)
        return (qualified, detail)
    }

    private static func readRecord(_ url: URL) -> MediaModelReadinessRecord? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(floeContentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MediaModelReadinessRecord.self, from: data)
    }

    private static func writeRecord(_ record: MediaModelReadinessRecord, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Runtime compatibility marker: a Core ML or OS change invalidates a
    /// cached qualification even when the model bytes are unchanged.
    static func currentRuntimeMarker() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "os=\(os);compute=all;framework=coreml"
    }

    private static func runInterpolationFixture(
        _ loaded: LoadedEnhancementModel,
        fixtures: URL,
        expectedURL: URL,
        tolerance: Double
    ) throws -> (Bool, String, [String: Double]) {
        let frame0 = try loadPixelBuffer(fixtures.appendingPathComponent("frame0.png"), width: loaded.contract.tileSize, height: loaded.contract.tileSize)
        let frame1 = try loadPixelBuffer(fixtures.appendingPathComponent("frame1.png"), width: loaded.contract.tileSize, height: loaded.contract.tileSize)
        let phase = loaded.contract.phase ?? 0.5
        let timestep = try MLMultiArray(shape: [1, 1], dataType: .float32)
        timestep[0] = NSNumber(value: phase)
        let names = loaded.contract.inputs.map(\.name)
        let inputs: [String: MLFeatureValue] = [
            names.first ?? "frame0": MLFeatureValue(pixelBuffer: frame0),
            names.dropFirst().first ?? "frame1": MLFeatureValue(pixelBuffer: frame1),
            "timestep": MLFeatureValue(multiArray: timestep)
        ]
        let prediction = try loaded.run(inputs: inputs)
        guard let output = prediction.featureValue(for: loaded.contract.outputs.first?.name ?? "frame")?.imageBufferValue else {
            return (false, "model produced no frame image", [:])
        }
        let diff = try meanAbsoluteDifference(output, try loadPixelBuffer(expectedURL, width: loaded.contract.tileSize, height: loaded.contract.tileSize))
        return (diff <= tolerance, String(format: "fixture mean(abs diff)=%.5f tolerance=%.3f", diff, tolerance), ["fixtureMeanAbsDiff": diff])
    }

    private static func runSuperResolutionFixture(
        _ loaded: LoadedEnhancementModel,
        fixtures: URL,
        expectedURL: URL,
        tolerance: Double
    ) throws -> (Bool, String, [String: Double]) {
        let scale = loaded.contract.scaleFactor ?? 2
        let size = loaded.contract.tileSize
        let input = try loadPixelBuffer(fixtures.appendingPathComponent("input.png"), width: size, height: size)
        let inputName = loaded.contract.inputs.first?.name ?? "image"
        let outputName = loaded.contract.outputs.first?.name ?? "image_out"
        let inputs: [String: MLFeatureValue] = [inputName: MLFeatureValue(pixelBuffer: input)]
        let prediction = try loaded.run(inputs: inputs)
        guard let output = prediction.featureValue(for: outputName)?.imageBufferValue else {
            return (false, "model produced no \(outputName) output", [:])
        }
        guard CVPixelBufferGetWidth(output) == size * scale, CVPixelBufferGetHeight(output) == size * scale else {
            return (false, "model output \(CVPixelBufferGetWidth(output))x\(CVPixelBufferGetHeight(output)) does not match \(scale)x", [:])
        }
        let expected = try loadPixelBuffer(expectedURL, width: size * scale, height: size * scale)
        let diff = try meanAbsoluteDifference(output, expected)
        return (diff <= tolerance, String(format: "fixture mean(abs diff)=%.5f tolerance=%.3f", diff, tolerance), ["fixtureMeanAbsDiff": diff])
    }

    static func loadPixelBuffer(_ url: URL, width: Int, height: Int) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FloeError.validationFailed("Fixture \(url.lastPathComponent) could not be decoded")
        }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, MediaImageBridge.bgra, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw FloeError.internalError("Could not allocate a fixture pixel buffer")
        }
        let context = fixtureContext
        context.render(
            CIImage(cgImage: image),
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return buffer
    }

    private static let fixtureContext = CIContext(options: [.cacheIntermediates: false])

    static func meanAbsoluteDifference(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) throws -> Double {
        let width = min(CVPixelBufferGetWidth(lhs), CVPixelBufferGetWidth(rhs))
        let height = min(CVPixelBufferGetHeight(lhs), CVPixelBufferGetHeight(rhs))
        let lhsImage = CIImage(cvPixelBuffer: lhs)
        let rhsImage = CIImage(cvPixelBuffer: rhs)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var lhsBytes = [UInt8](repeating: 0, count: width * height * 4)
        var rhsBytes = [UInt8](repeating: 0, count: width * height * 4)
        let gray = CGColorSpaceCreateDeviceGray()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? gray
        fixtureContext.render(lhsImage, toBitmap: &lhsBytes, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: colorSpace)
        fixtureContext.render(rhsImage, toBitmap: &rhsBytes, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: colorSpace)
        var sum: Double = 0
        let count = width * height * 3
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            for channel in 0..<3 {
                sum += abs(Double(lhsBytes[index + channel]) - Double(rhsBytes[index + channel])) / 255.0
            }
        }
        return sum / Double(max(1, count))
    }
}

// MARK: - Tiled Core ML engines

/// RIFE 4.25 Lite interpolation. The converted model is a fixed tile
/// network; full frames are processed as overlapping tiles with padded edges.
final class CoreMLInterpolationEngine: MediaInterpolationEngine, @unchecked Sendable {
    let name: String
    let interpolatedPerPair: Int

    private let loaded: LoadedEnhancementModel
    private let width: Int
    private let height: Int
    private let quality: MediaEnhancementQuality
    private let bridge: MediaImageBridge
    private let store: MediaPixelBufferStore

    init(loaded: LoadedEnhancementModel, width: Int, height: Int, framesPerPair: Int,
         quality: MediaEnhancementQuality, bridge: MediaImageBridge, store: MediaPixelBufferStore) throws {
        guard loaded.contract.isInterpolation else {
            throw FloeError.validationFailed("model \(loaded.modelID) is a \(loaded.contract.capability) model, not interpolation")
        }
        self.loaded = loaded
        self.name = "coreml.\(loaded.modelID)"
        self.width = width
        self.height = height
        self.quality = quality
        self.bridge = bridge
        self.store = store
        self.interpolatedPerPair = max(0, framesPerPair - 1)
    }

    func prepare() throws -> [String] {
        var warnings: [String] = []
        if width > loaded.contract.tileSize || height > loaded.contract.tileSize {
            warnings.append("frame exceeds the \(loaded.contract.tileSize)px model tile; tiled inference with \(quality.tileOverlap)px overlap")
        }
        return warnings + ["engine=\(name) tile=\(loaded.contract.tileSize) prepared"]
    }

    func interpolate(current: CVPixelBuffer, next: CVPixelBuffer, phases: [Float], outputs: [CVPixelBuffer], cancellation: CancellationToken?) throws {
        guard phases.count == outputs.count, !phases.isEmpty,
              phases.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }) else {
            throw FloeError.validationFailed("Interpolation requires one interior phase per output")
        }
        let tile = loaded.contract.tileSize
        guard width >= 1, height >= 1 else { throw FloeError.internalError("invalid interpolation target") }
        let tileStride = max(1, tile - quality.tileOverlap)
        for (index, phase) in phases.enumerated() {
            let timestep = try MLMultiArray(shape: [1, 1], dataType: .float32)
            timestep[0] = NSNumber(value: phase)
            for originY in stride(from: 0, to: height, by: tileStride) {
                for originX in stride(from: 0, to: width, by: tileStride) {
                    try cancellation?.throwIfCancelled()
                    let coreWidth = min(tileStride, width - originX)
                    let coreHeight = min(tileStride, height - originY)
                    let padLeft = min(quality.tileOverlap, originX)
                    let padTop = min(quality.tileOverlap, originY)
                    let rect = CGRect(
                        x: originX - padLeft, y: originY - padTop,
                        width: min(tile, width + padLeft - originX), height: min(tile, height + padTop - originY)
                    )
                    let tile0 = try tileBuffer(from: current, rect: rect, size: tile, offset: CGPoint(x: rect.minX, y: rect.minY))
                    let tile1 = try tileBuffer(from: next, rect: rect, size: tile, offset: CGPoint(x: rect.minX, y: rect.minY))
                    let inputs: [String: MLFeatureValue] = [
                        "frame0": MLFeatureValue(pixelBuffer: tile0),
                        "frame1": MLFeatureValue(pixelBuffer: tile1),
                        "timestep": MLFeatureValue(multiArray: timestep)
                    ]
                    let prediction = try loaded.run(inputs: inputs)
                    try cancellation?.throwIfCancelled()
                    guard let output = prediction.featureValue(for: "frame")?.imageBufferValue else {
                        throw FloeError.internalError("model \(loaded.modelID) produced no frame")
                    }
                    try composite(
                        output: output,
                        destination: outputs[index],
                        coreRect: CGRect(x: originX, y: originY, width: coreWidth, height: coreHeight),
                        tileRect: rect
                    )
                }
            }
        }
    }

    func teardown() {}

    private func tileBuffer(from source: CVPixelBuffer, rect: CGRect, size: Int, offset: CGPoint) throws -> CVPixelBuffer {
        let buffer = try store.makeBuffer(format: MediaImageBridge.bgra, width: size, height: size)
        let image = bridge.image(source).clampedToExtent().cropped(to: CGRect(origin: offset, size: CGSize(width: size, height: size)))
        let translated = image.transformed(by: CGAffineTransform(translationX: -offset.x, y: -offset.y))
        bridgeContext.render(
            translated, to: buffer,
            bounds: CGRect(x: 0, y: 0, width: size, height: size),
            colorSpace: bridge.colorSpace
        )
        return buffer
    }

    private func composite(output: CVPixelBuffer, destination: CVPixelBuffer, coreRect: CGRect, tileRect: CGRect) throws {
        let scaleX = CGFloat(CVPixelBufferGetWidth(output)) / CGFloat(loaded.contract.tileSize)
        let scaleY = CGFloat(CVPixelBufferGetHeight(output)) / CGFloat(loaded.contract.tileSize)
        let scaledCore = CGRect(
            x: (coreRect.minX - tileRect.minX) * scaleX,
            y: (coreRect.minY - tileRect.minY) * scaleY,
            width: coreRect.width * scaleX,
            height: coreRect.height * scaleY
        )
        let outputImage = CIImage(cvPixelBuffer: output).transformed(
            by: CGAffineTransform(translationX: coreRect.minX * scaleX - scaledCore.minX, y: coreRect.minY * scaleY - scaledCore.minY)
        )
        let destinationRect = CGRect(
            x: coreRect.minX * scaleX, y: coreRect.minY * scaleY,
            width: scaledCore.width, height: scaledCore.height
        )
        bridgeContext.render(outputImage, to: destination, bounds: destinationRect, colorSpace: bridge.colorSpace)
    }

    private var bridgeContext: CIContext {
        bridge.cicontext
    }
}

/// Real-ESRGAN x2plus/x4plus tiled inference.
final class CoreMLSuperResolutionEngine: MediaSuperResolutionEngine, @unchecked Sendable {
    let name: String
    let outputWidth: Int
    let outputHeight: Int

    private let loaded: LoadedEnhancementModel
    private let width: Int
    private let height: Int
    private let quality: MediaEnhancementQuality
    private let bridge: MediaImageBridge
    private let store: MediaPixelBufferStore
    private let tileStride: Int
    private let inputName: String
    private let outputName: String

    init(loaded: LoadedEnhancementModel, width: Int, height: Int, scaleFactor: Int,
         quality: MediaEnhancementQuality, bridge: MediaImageBridge, store: MediaPixelBufferStore) throws {
        guard loaded.contract.isSuperResolution else {
            throw FloeError.validationFailed("model \(loaded.modelID) is a \(loaded.contract.capability) model, not super resolution")
        }
        guard (loaded.contract.scaleFactor ?? 0) == scaleFactor else {
            throw FloeError.validationFailed(
                "model \(loaded.modelID) provides \(loaded.contract.scaleFactor ?? 0)x but \(scaleFactor)x was requested"
            )
        }
        self.loaded = loaded
        self.name = "coreml.\(loaded.modelID)"
        self.width = width
        self.height = height
        self.outputWidth = width * scaleFactor
        self.outputHeight = height * scaleFactor
        self.quality = quality
        self.bridge = bridge
        self.store = store
        self.tileStride = max(1, loaded.contract.tileSize - quality.tileOverlap)
        self.inputName = loaded.contract.inputs.first?.name ?? "image"
        self.outputName = loaded.contract.outputs.first?.name ?? "image_out"
    }

    func prepare() throws -> [String] {
        var warnings: [String] = []
        if width > loaded.contract.tileSize || height > loaded.contract.tileSize {
            warnings.append("frame exceeds the \(loaded.contract.tileSize)px model tile; tiled inference with \(quality.tileOverlap)px overlap")
        }
        return warnings + ["engine=\(name) tile=\(loaded.contract.tileSize) scale=\(loaded.contract.scaleFactor ?? 0) prepared"]
    }

    func teardown() {}

    func scale(current: CVPixelBuffer, output: CVPixelBuffer, cancellation: CancellationToken?) throws {
        let tile = loaded.contract.tileSize
        let scale = CGFloat(loaded.contract.scaleFactor ?? 1)
        for originY in stride(from: 0, to: height, by: tileStride) {
            for originX in stride(from: 0, to: width, by: tileStride) {
                try cancellation?.throwIfCancelled()
                let coreWidth = min(tileStride, width - originX)
                let coreHeight = min(tileStride, height - originY)
                let padLeft = min(quality.tileOverlap, originX)
                let padTop = min(quality.tileOverlap, originY)
                let rect = CGRect(
                    x: originX - padLeft, y: originY - padTop,
                    width: min(tile, width + padLeft - originX), height: min(tile, height + padTop - originY)
                )
                let tileInput = try tileBuffer(from: current, rect: rect, size: tile, offset: CGPoint(x: rect.minX, y: rect.minY))
                let prediction = try loaded.run(inputs: [inputName: MLFeatureValue(pixelBuffer: tileInput)])
                try cancellation?.throwIfCancelled()
                guard let tileOutput = prediction.featureValue(for: outputName)?.imageBufferValue else {
                    throw FloeError.internalError("model \(loaded.modelID) produced no image")
                }
                let scaledCore = CGRect(
                    x: (CGFloat(originX) - rect.minX) * scale,
                    y: (CGFloat(originY) - rect.minY) * scale,
                    width: CGFloat(coreWidth) * scale,
                    height: CGFloat(coreHeight) * scale
                )
                let destinationRect = CGRect(
                    x: CGFloat(originX) * scale, y: CGFloat(originY) * scale,
                    width: scaledCore.width, height: scaledCore.height
                )
                let outputImage = CIImage(cvPixelBuffer: tileOutput).transformed(
                    by: CGAffineTransform(translationX: destinationRect.minX - scaledCore.minX, y: destinationRect.minY - scaledCore.minY)
                )
                bridge.cicontext.render(outputImage, to: output, bounds: destinationRect, colorSpace: bridge.colorSpace)
            }
        }
    }

    private func tileBuffer(from source: CVPixelBuffer, rect: CGRect, size: Int, offset: CGPoint) throws -> CVPixelBuffer {
        let buffer = try store.makeBuffer(format: MediaImageBridge.bgra, width: size, height: size)
        let image = bridge.image(source).clampedToExtent().cropped(to: CGRect(origin: offset, size: CGSize(width: size, height: size)))
        let translated = image.transformed(by: CGAffineTransform(translationX: -offset.x, y: -offset.y))
        bridge.cicontext.render(
            translated, to: buffer,
            bounds: CGRect(x: 0, y: 0, width: size, height: size),
            colorSpace: bridge.colorSpace
        )
        return buffer
    }
}

#endif
