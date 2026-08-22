import Foundation
import llama
import FloeLlamaVisionShim
import FloeLocalModelCatalog

public enum LocalInferenceError: LocalizedError {
    case modelLoadFailed
    case contextCreationFailed
    case promptTooLong
    case decodeFailed
    case visionLoadFailed
    case visionInputFailed
    case insufficientMemory(required: UInt64, physical: UInt64)
    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed: "Unable to load the local GGUF model."
        case .contextCreationFailed: "Unable to create a local inference context."
        case .promptTooLong: "The prompt exceeds the local model context window."
        case .decodeFailed: "The local model failed while decoding."
        case .visionLoadFailed: "The local vision projector could not be loaded."
        case .visionInputFailed: "The local model could not decode the supplied image."
        case .insufficientMemory(let required, let physical):
            "This model needs more safe memory headroom (model files: \(required) bytes, device memory: \(physical) bytes). Choose a smaller model or omit vision input."
        }
    }
}

/// Serialized llama.cpp inference context. The framework is the official
/// iOS XCFramework; Metal is used on device and disabled in Simulator.
@available(macOS 15.4, iOS 18.4, *)
public actor LlamaTextEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var multimodal: UnsafeMutableRawPointer?
    private var backendInitialized = false

    public init(
        modelURL: URL,
        projectorURL: URL? = nil,
        resourceProfile: LocalInferenceResourceProfile
    ) throws {
        llama_backend_init()
        backendInitialized = true
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = resourceProfile.gpuLayers
        #endif
        guard let model = llama_model_load_from_file(modelURL.path, modelParams) else {
            llama_backend_free()
            backendInitialized = false
            throw LocalInferenceError.modelLoadFailed
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = resourceProfile.contextSize
        contextParams.n_batch = min(resourceProfile.contextSize, resourceProfile.batchSize)
        let threadCount = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threadCount
        contextParams.n_threads_batch = threadCount
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            llama_backend_free()
            backendInitialized = false
            throw LocalInferenceError.contextCreationFailed
        }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.55))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        var loadedMultimodal: UnsafeMutableRawPointer?
        if let projectorURL {
            #if targetEnvironment(simulator)
            let useGPU = false
            #else
            let useGPU = true
            #endif
            guard let multimodal = floe_mtmd_init(projectorURL.path, model, useGPU),
                  floe_mtmd_supports_vision(multimodal)
            else {
                llama_sampler_free(chain)
                llama_free(context)
                llama_model_free(model)
                llama_backend_free()
                backendInitialized = false
                throw LocalInferenceError.visionLoadFailed
            }
            loadedMultimodal = multimodal
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.sampler = chain
        self.multimodal = loadedMultimodal
    }

    isolated deinit {
        releaseResources()
    }

    /// Explicit, idempotent teardown lets the runtime release one mapped
    /// model completely before initializing another llama backend.
    public func shutdown() {
        releaseResources()
    }

    private func releaseResources() {
        if let sampler { llama_sampler_free(sampler) }
        if let multimodal { floe_mtmd_free(multimodal) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        multimodal = nil
        context = nil
        model = nil
        vocab = nil
        if backendInitialized {
            llama_backend_free()
            backendInitialized = false
        }
    }

    public func complete(prompt: String, images: [Data] = [], maxTokens: Int = 1024) throws -> String {
        guard let context, let vocab, let sampler else { throw LocalInferenceError.contextCreationFailed }
        llama_memory_clear(llama_get_memory(context), true)
        if !images.isEmpty {
            guard let multimodal else { throw LocalInferenceError.visionLoadFailed }
            return try completeVision(prompt: prompt, images: images, context: context, multimodal: multimodal, sampler: sampler, maxTokens: maxTokens)
        }
        let bytes = prompt.utf8.count
        let capacity = bytes + 16
        let buffer = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let tokenCount = llama_tokenize(vocab, prompt, Int32(bytes), buffer, Int32(capacity), true, true)
        guard tokenCount > 0, UInt32(tokenCount + Int32(maxTokens)) <= llama_n_ctx(context) else {
            throw LocalInferenceError.promptTooLong
        }
        var batch = llama_batch_init(Int32(max(512, Int(tokenCount))), 0, 1)
        defer { llama_batch_free(batch) }
        for index in 0..<Int(tokenCount) {
            add(buffer[index], position: Int32(index), logits: index == Int(tokenCount) - 1, to: &batch)
        }
        guard llama_decode(context, batch) == 0 else { throw LocalInferenceError.decodeFailed }
        var position = tokenCount
        var output = ""
        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token, vocab: vocab)
            batch.n_tokens = 0
            add(token, position: position, logits: true, to: &batch)
            guard llama_decode(context, batch) == 0 else { throw LocalInferenceError.decodeFailed }
            position += 1
        }
        return output
    }

    private func completeVision(
        prompt: String,
        images: [Data],
        context: OpaquePointer,
        multimodal: UnsafeMutableRawPointer,
        sampler: UnsafeMutablePointer<llama_sampler>,
        maxTokens: Int
    ) throws -> String {
        let retainedImages = images.map { $0 as NSData }
        var lengths = retainedImages.map(\.length)
        var pointers: [UnsafePointer<UInt8>?] = retainedImages.map {
            $0.bytes.assumingMemoryBound(to: UInt8.self)
        }
        var position: Int32 = 0
        var tokenCount = 0
        let result = prompt.withCString { promptPointer in
            pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                lengths.withUnsafeMutableBufferPointer { lengthBuffer in
                    floe_mtmd_eval_images(
                        multimodal, context, promptPointer, pointerBuffer.baseAddress,
                        lengthBuffer.baseAddress, images.count, 512, &position, &tokenCount
                    )
                }
            }
        }
        guard result == 0 else { throw LocalInferenceError.visionInputFailed }
        let needed = tokenCount + maxTokens
        guard needed <= Int(llama_n_ctx(context)) else { throw LocalInferenceError.promptTooLong }
        return try generate(context: context, sampler: sampler, startPosition: position, maxTokens: maxTokens)
    }

    private func generate(
        context: OpaquePointer,
        sampler: UnsafeMutablePointer<llama_sampler>,
        startPosition: llama_pos,
        maxTokens: Int
    ) throws -> String {
        guard let vocab else { throw LocalInferenceError.contextCreationFailed }
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        var position = startPosition
        var output = ""
        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token, vocab: vocab)
            batch.n_tokens = 0
            add(token, position: position, logits: true, to: &batch)
            guard llama_decode(context, batch) == 0 else { throw LocalInferenceError.decodeFailed }
            position += 1
        }
        return output
    }

    private func add(_ token: llama_token, position: llama_pos, logits: Bool, to batch: inout llama_batch) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func piece(_ token: llama_token, vocab: OpaquePointer) -> String {
        var initial = [CChar](repeating: 0, count: 16)
        let count = llama_token_to_piece(vocab, token, &initial, Int32(initial.count), 0, false)
        if count >= 0 { return String(decoding: initial.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self) }
        var expanded = [CChar](repeating: 0, count: Int(-count))
        let expandedCount = llama_token_to_piece(vocab, token, &expanded, Int32(expanded.count), 0, false)
        return String(decoding: expanded.prefix(max(0, Int(expandedCount))).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
