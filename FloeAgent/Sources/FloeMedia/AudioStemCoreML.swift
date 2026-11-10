// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import CoreML

public struct AudioStemTensor: Codable, Sendable, Equatable {
    public enum Layout: String, Codable, Sendable { case channelFrame, frameChannel, batchChannelFrame, batchFrameChannel }
    public enum DataType: String, Codable, Sendable { case float32, float16, double }
    public var name: String
    public var layout: Layout
    public var dataType: DataType
    public init(name: String, layout: Layout = .batchChannelFrame, dataType: DataType = .float32) { self.name = name; self.layout = layout; self.dataType = dataType }
    public func shape(channels: Int, frames: Int) -> [Int] {
        switch layout {
        case .channelFrame: [channels, frames]
        case .frameChannel: [frames, channels]
        case .batchChannelFrame: [1, channels, frames]
        case .batchFrameChannel: [1, frames, channels]
        }
    }
    fileprivate var mlType: MLMultiArrayDataType {
        switch dataType { case .float32: .float32; case .float16: .float16; case .double: .double }
    }
    fileprivate func offset(channel: Int, frame: Int, strides: [Int]) -> Int {
        switch layout {
        case .channelFrame: channel * strides[0] + frame * strides[1]
        case .frameChannel: frame * strides[0] + channel * strides[1]
        case .batchChannelFrame: channel * strides[1] + frame * strides[2]
        case .batchFrameChannel: frame * strides[1] + channel * strides[2]
        }
    }
}

/// A compatible waveform model is declared explicitly. Spectrogram-only,
/// recurrent-state and stacked-stem models require a matching conversion or
/// adapter; this runner never infers their semantics from tensor names.
public struct AudioStemModelContract: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var kind: String
    public var capability: String
    public var modelPath: String
    public var sampleRate: Double
    public var channelCount: Int
    public var chunkFrames: Int
    public var overlapFrames: Int
    public var input: AudioStemTensor
    public var vocals: AudioStemTensor
    public var accompaniment: AudioStemTensor
    public var inputScale: Double
    public var inputBias: Double
    public var vocalsScale: Double
    public var vocalsBias: Double
    public var accompanimentScale: Double
    public var accompanimentBias: Double
    public var license: String
    public var source: String
    public var qualityNotes: [String]
    public init(id: String, version: String, sampleRate: Double, channelCount: Int, chunkFrames: Int, overlapFrames: Int,
        input: AudioStemTensor, vocals: AudioStemTensor, accompaniment: AudioStemTensor,
        modelPath: String = "model.mlmodelc", inputScale: Double = 1, inputBias: Double = 0,
        vocalsScale: Double = 1, vocalsBias: Double = 0, accompanimentScale: Double = 1, accompanimentBias: Double = 0,
        license: String, source: String, qualityNotes: [String] = []) {
        schemaVersion = 1; self.id = id; self.version = version; kind = "coreml"; capability = "audio.separate.vocals"
        self.modelPath = modelPath; self.sampleRate = sampleRate; self.channelCount = channelCount
        self.chunkFrames = chunkFrames; self.overlapFrames = overlapFrames; self.input = input; self.vocals = vocals; self.accompaniment = accompaniment
        self.inputScale = inputScale; self.inputBias = inputBias; self.vocalsScale = vocalsScale; self.vocalsBias = vocalsBias
        self.accompanimentScale = accompanimentScale; self.accompanimentBias = accompanimentBias
        self.license = license; self.source = source; self.qualityNotes = qualityNotes
    }
    public func validate() throws {
        guard schemaVersion == 1, kind == "coreml", capability == "audio.separate.vocals",
              !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_" )).contains($0) }),
              version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
              sampleRate.isFinite, (8_000...192_000).contains(sampleRate), (1...2).contains(channelCount),
              (256...524_288).contains(chunkFrames), overlapFrames >= 0, overlapFrames <= chunkFrames / 2,
              modelPath.hasSuffix(".mlmodelc"), AudioStemModelBundle.safeRelativePath(modelPath),
              [input.name, vocals.name, accompaniment.name].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              Set([input.name, vocals.name, accompaniment.name]).count == 3,
              [inputScale, inputBias, vocalsScale, vocalsBias, accompanimentScale, accompanimentBias].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              inputScale != 0, vocalsScale != 0, accompanimentScale != 0,
              !license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, license.utf8.count <= 16_384,
              let url = URL(string: source), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              qualityNotes.count <= 32, qualityNotes.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            throw AudioPCMProcessingError.invalidInput("incompatible or incomplete audio stem model contract")
        }
    }
}

public struct AudioStemVerifiedBundle: Sendable {
    public let root: URL
    public let modelURL: URL
    public let contract: AudioStemModelContract
    public let fingerprint: String
}

/// Called for both user-imported bundles and existing ModelArtifactStore
/// records. Hashes, exact membership, provenance and notices are verified;
/// no new downloader, trust root or executable installer is introduced.
public enum AudioStemModelBundle {
    public static let maximumBytes = 512 * 1_024 * 1_024
    private struct Manifest: Decodable {
        struct File: Decodable { let path: String; let sha256: String; let sizeBytes: Int64 }
        let id: String; let version: String; let capability: String; let files: [File]
    }
    public static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 512 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }
    public static func verify(at root: URL, expectedID: String? = nil, expectedVersion: String? = nil, work: AudioPCMWork = .init()) throws -> AudioStemVerifiedBundle {
        try work.check()
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard root.isFileURL else { throw AudioPCMProcessingError.invalidInput("model bundle must be a local directory") }
        let manifestData = try read(root.appendingPathComponent("manifest.json"), maximum: 1_048_576)
        let contractData = try read(root.appendingPathComponent("contract.json"), maximum: 65_536)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let contract = try JSONDecoder().decode(AudioStemModelContract.self, from: contractData)
        try contract.validate()
        guard manifest.id == contract.id, manifest.version == contract.version, manifest.capability == contract.capability,
              expectedID.map({ $0 == contract.id }) ?? true, expectedVersion.map({ $0 == contract.version }) ?? true,
              (4...8_192).contains(manifest.files.count) else { throw AudioPCMProcessingError.invalidInput("audio model manifest/contract identity mismatch") }
        let paths = manifest.files.map(\.path)
        guard Set(paths).count == paths.count,
              Set(paths.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == paths.count,
              Set(paths).isSuperset(of: ["contract.json", "LICENSE.txt", "PROVENANCE.json"]),
              paths.contains(where: { $0.hasPrefix(contract.modelPath + "/") }) else { throw AudioPCMProcessingError.invalidInput("audio model is missing required files or has conflicting names") }
        var total: Int64 = 0
        for file in manifest.files {
            try work.check()
            guard safeRelativePath(file.path), file.sizeBytes >= 0, file.sizeBytes <= maximumBytes,
                  file.sha256.count == 64, file.sha256.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else { throw AudioPCMProcessingError.invalidInput("invalid audio model manifest member") }
            total += file.sizeBytes; guard total <= maximumBytes else { throw AudioPCMProcessingError.limitExceeded("audio model bundle exceeds 512 MiB") }
            let url = root.appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize.map(Int64.init) == file.sizeBytes,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  try digest(url, work: work) == file.sha256 else { throw AudioPCMProcessingError.changedSource }
        }
        var enumerationError: (any Error)?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw AudioPCMProcessingError.invalidInput("cannot enumerate audio model bundle") }
        var seen = Set<String>()
        for case let url as URL in iterator {
            try work.check()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AudioPCMProcessingError.invalidInput("audio model bundle contains a symbolic link") }
            if values.isRegularFile == true {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root.path + "/") else { throw AudioPCMProcessingError.invalidInput("model member outside bundle") }
                let relative = String(path.dropFirst(root.path.count + 1))
                guard relative == "manifest.json" || relative == ".floe-readiness.json" || paths.contains(relative) else { throw AudioPCMProcessingError.invalidInput("unlisted audio model member") }
                if paths.contains(relative) { seen.insert(relative) }
            }
        }
        if let enumerationError { throw enumerationError }
        guard seen == Set(paths) else { throw AudioPCMProcessingError.changedSource }
        return .init(root: root, modelURL: root.appendingPathComponent(contract.modelPath), contract: contract,
            fingerprint: SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined())
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximum else { throw AudioPCMProcessingError.invalidInput("bounded regular model metadata is required") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count == size else { throw AudioPCMProcessingError.changedSource }
        return data
    }
    private static func digest(_ url: URL, work: AudioPCMWork) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { try work.check(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct AudioStemSeparationResult: Sendable {
    public let vocals: AudioPCM
    public let accompaniment: AudioPCM
    public let input: AudioPCMMeasurement
    public let modelID: String
    public let modelVersion: String
    public let modelFingerprint: String
    public let predictionCount: Int
    public let reconstructionErrorRMS: Double
    public let qualityNotes: [String]
}

/// Service-owned inference on a serial worker actor. Cancellation is observed
/// between bounded Core ML predictions; an in-flight synchronous prediction
/// is not falsely advertised as interruptible. No hardware audio is opened.
public actor AudioStemCoreMLService {
    public typealias Resolver = @Sendable (String) async -> URL?
    private let resolve: Resolver
    private let computeUnits: MLComputeUnits
    private var cachedFingerprint: String?
    private var cachedModel: MLModel?
    public init(computeUnits: MLComputeUnits = .all, resolveModel: @escaping Resolver) { self.computeUnits = computeUnits; resolve = resolveModel }
    public func contract(modelID: String) async throws -> AudioStemModelContract {
        guard let root = await resolve(modelID) else { throw AudioPCMProcessingError.invalidInput("import or install the selected audio stem model first") }
        return try AudioStemModelBundle.verify(at: root, expectedID: modelID).contract
    }
    public func separate(_ pcm: AudioPCM, modelID: String, work: AudioPCMWork = .init()) async throws -> AudioStemSeparationResult {
        try work.check(); try pcm.validate()
        guard let root = await resolve(modelID) else { throw AudioPCMProcessingError.invalidInput("import or install the selected audio stem model first") }
        let bundle = try AudioStemModelBundle.verify(at: root, expectedID: modelID, work: work), contract = bundle.contract
        guard pcm.sampleRate == contract.sampleRate, pcm.channels.count == contract.channelCount else { throw AudioPCMProcessingError.invalidInput("convert the source to the audio model's declared sample rate and channel count before inference") }
        let model: MLModel
        if cachedFingerprint == bundle.fingerprint, let cachedModel { model = cachedModel }
        else {
            let configuration = MLModelConfiguration(); configuration.computeUnits = computeUnits
            model = try MLModel(contentsOf: bundle.modelURL, configuration: configuration)
            try Self.validate(model.modelDescription, contract: contract)
            cachedFingerprint = bundle.fingerprint; cachedModel = model
        }
        let count = pcm.frameCount, channels = contract.channelCount, chunk = contract.chunkFrames, step = chunk - contract.overlapFrames
        var vocals = [[Float]](repeating: [Float](repeating: 0, count: count), count: channels), accompaniment = vocals
        var normalization = [Float](repeating: 0, count: count), predictions = 0
        for start in stride(from: 0, to: count, by: step) {
            try work.check()
            let input = try MLMultiArray(shape: contract.input.shape(channels: channels, frames: chunk).map(NSNumber.init), dataType: contract.input.mlType)
            let strides = input.strides.map(\.intValue)
            for channel in 0..<channels {
                for frame in 0..<chunk {
                    let sample = start + frame < count ? Double(pcm.channels[channel][start + frame]) : 0
                    Self.set(sample * contract.inputScale + contract.inputBias, at: contract.input.offset(channel: channel, frame: frame, strides: strides), in: input)
                }
            }
            let features = try MLDictionaryFeatureProvider(dictionary: [contract.input.name: MLFeatureValue(multiArray: input)])
            let output = try Self.predictSynchronously(model, features: features)
            try work.check(); predictions += 1
            guard let voice = output.featureValue(for: contract.vocals.name)?.multiArrayValue,
                  let music = output.featureValue(for: contract.accompaniment.name)?.multiArrayValue else { throw AudioPCMProcessingError.invalidInput("Core ML returned no declared audio stem tensors") }
            try Self.validate(voice, tensor: contract.vocals, contract: contract); try Self.validate(music, tensor: contract.accompaniment, contract: contract)
            let vs = voice.strides.map(\.intValue), ms = music.strides.map(\.intValue)
            for frame in 0..<min(chunk, count - start) {
                var weight: Float = 1
                if start > 0, frame < contract.overlapFrames { weight *= Float(frame + 1) / Float(contract.overlapFrames + 1) }
                if start + chunk < count, frame >= chunk - contract.overlapFrames { weight *= Float(chunk - frame) / Float(contract.overlapFrames + 1) }
                normalization[start + frame] += weight
                for channel in 0..<channels {
                    let a = Self.get(contract.vocals.offset(channel: channel, frame: frame, strides: vs), from: voice) * contract.vocalsScale + contract.vocalsBias
                    let b = Self.get(contract.accompaniment.offset(channel: channel, frame: frame, strides: ms), from: music) * contract.accompanimentScale + contract.accompanimentBias
                    guard a.isFinite, b.isFinite, abs(a) <= 1_000_000, abs(b) <= 1_000_000 else { throw AudioPCMProcessingError.invalidInput("Core ML returned non-finite audio stems") }
                    vocals[channel][start + frame] += Float(a) * weight; accompaniment[channel][start + frame] += Float(b) * weight
                }
            }
            work.progress(Double(min(count, start + chunk)) / Double(count))
        }
        var error = 0.0
        for i in 0..<count {
            if i % 8_192 == 0 { try work.check() }
            guard normalization[i] > 0 else { throw AudioPCMProcessingError.invalidInput("audio model overlap-add left uncovered frames") }
            for channel in 0..<channels {
                vocals[channel][i] /= normalization[i]; accompaniment[channel][i] /= normalization[i]
                let residual = Double(vocals[channel][i]) + Double(accompaniment[channel][i]) - Double(pcm.channels[channel][i])
                error += residual * residual
            }
        }
        let verified = try AudioStemModelBundle.verify(at: root, expectedID: modelID, work: work)
        guard verified.fingerprint == bundle.fingerprint else { throw AudioPCMProcessingError.changedSource }
        return .init(vocals: try .init(sampleRate: pcm.sampleRate, channels: vocals), accompaniment: try .init(sampleRate: pcm.sampleRate, channels: accompaniment),
            input: .init(pcm), modelID: contract.id, modelVersion: contract.version, modelFingerprint: bundle.fingerprint, predictionCount: predictions,
            reconstructionErrorRMS: sqrt(error / Double(count * channels)), qualityNotes: contract.qualityNotes + ["Stem names are declared by the configured model. Inference/tensor validity does not guarantee isolation quality; bleed, artifacts and overlap seams may remain."])
    }
    private static func validate(_ description: MLModelDescription, contract: AudioStemModelContract) throws {
        guard Set(description.inputDescriptionsByName.keys) == [contract.input.name],
              Set(description.outputDescriptionsByName.keys) == [contract.vocals.name, contract.accompaniment.name] else { throw AudioPCMProcessingError.invalidInput("audio model feature names differ from the contract") }
        for (tensor, features) in [(contract.input, description.inputDescriptionsByName), (contract.vocals, description.outputDescriptionsByName), (contract.accompaniment, description.outputDescriptionsByName)] {
            guard let feature = features[tensor.name], feature.type == .multiArray, let array = feature.multiArrayConstraint,
                  array.shape.map(\.intValue) == tensor.shape(channels: contract.channelCount, frames: contract.chunkFrames), array.dataType == tensor.mlType else { throw AudioPCMProcessingError.invalidInput("audio model tensor shape/type differs from the contract") }
        }
    }
    private static func predictSynchronously(_ model: MLModel, features: any MLFeatureProvider) throws -> any MLFeatureProvider {
        // Keep Core ML's synchronous overload on this service's worker actor;
        // the SDK also provides an async overload in async calling contexts.
        try model.prediction(from: features)
    }
    private static func validate(_ array: MLMultiArray, tensor: AudioStemTensor, contract: AudioStemModelContract) throws {
        guard array.dataType == tensor.mlType, array.shape.map(\.intValue) == tensor.shape(channels: contract.channelCount, frames: contract.chunkFrames) else { throw AudioPCMProcessingError.invalidInput("audio prediction tensor shape/type differs from the contract") }
    }
    private static func set(_ value: Double, at offset: Int, in array: MLMultiArray) {
        switch array.dataType {
        case .float32: array.dataPointer.assumingMemoryBound(to: Float.self)[offset] = Float(value)
        case .float16: array.dataPointer.assumingMemoryBound(to: Float16.self)[offset] = Float16(value)
        case .double: array.dataPointer.assumingMemoryBound(to: Double.self)[offset] = value
        default: break // The validated, newly-created tensor has a known type.
        }
    }
    private static func get(_ offset: Int, from array: MLMultiArray) -> Double {
        switch array.dataType {
        case .float32: Double(array.dataPointer.assumingMemoryBound(to: Float.self)[offset])
        case .float16: Double(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        case .double: array.dataPointer.assumingMemoryBound(to: Double.self)[offset]
        default: .nan
        }
    }
}
