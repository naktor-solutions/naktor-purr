import Foundation
import llama
import os.log

// Thin Swift wrapper around llama.cpp's C API. Owns a single
// `llama_model` + `llama_context` pair and exposes one synchronous
// `generate` entry point.
//
// All llama_* calls in this file are intentionally synchronous and
// CPU/GPU heavy - callers must dispatch via `Task.detached` (or another
// background executor) so the main actor never blocks on a decode.
//
// Lifecycle:
//   * `init(modelPath:)` calls llama_backend_init once and loads the
//     model. Throws if the GGUF can't be opened (corrupt file, OOM,
//     unsupported quant).
//   * `generate(prompt:)` runs a full prompt-eval + token-generation
//     loop and returns the decoded text. Safe to call repeatedly on
//     the same instance.
//   * `deinit` frees the context and model. We deliberately do NOT
//     call llama_backend_free here - other backends/instances may still
//     be alive in the same process and backend_init is idempotent
//     anyway.

// generate() tokenizes with parse_special=true, so a literal
// "<start_of_turn>" / "<end_of_turn>" inside interpolated content becomes a
// real control token and breaks out of its chat turn. Every prompt builder
// must pass untrusted content (dictations, selections, meeting transcripts,
// user-authored instructions) through neutralize() before splicing it into
// a template.
enum GemmaTemplate {
    static func neutralize(_ text: String) -> String {
        var out = text
        while true {
            let next =
                out
                .replacingOccurrences(of: "<start_of_turn>", with: "")
                .replacingOccurrences(of: "<end_of_turn>", with: "")
            if next == out { return out }
            out = next
        }
    }
}

final class LlamaSession {
    enum LlamaError: LocalizedError {
        case modelLoadFailed(path: String)
        case contextInitFailed
        case tokenizeFailed
        case decodeFailed(code: Int32)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path):
                return "Could not load Gemma GGUF model at \(path)."
            case .contextInitFailed:
                return "Could not create llama.cpp inference context."
            case .tokenizeFailed:
                return "Failed to tokenize prompt."
            case .decodeFailed(let code):
                return "llama_decode failed (code \(code))."
            case .cancelled:
                return "Generation was cancelled."
            }
        }
    }

    // Parameters callers can tune per generate() call.
    struct Parameters {
        var maxTokens: Int = 1000
        var temperature: Float = 0.3
        var repetitionPenalty: Float = 1.1
        var repetitionContextSize: Int32 = 64
        var nBatch: UInt32 = 512
    }

    private let log = Logger(subsystem: "com.naktor.barktor", category: "llama")
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let context: OpaquePointer

    init(modelPath: String) throws {
        // Disable Metal residency sets before ggml creates the Metal device
        // (during the model load below). Residency sets keep GPU memory wired for
        // a ~3-minute window; if the app quits inside it with model buffers still
        // live, ggml-metal's teardown asserts `[rsets->data count] == 0` and
        // SIGABRTs during the process's atexit cleanup. The env var (read once at
        // device init) skips residency sets entirely - GPU memory just turns
        // evictable after ~1 s idle, a negligible cost for our occasional
        // summaries/edits. Upstream's documented workaround: ggml-org/llama.cpp#11427.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        llama_backend_init()

        var modelParams = llama_model_default_params()
        // Offload every transformer block to Metal. Gemma 3 4B at Q4_K_M
        // is ~2.5 GB; that fits in the GPU partition of unified memory on
        // every Apple-Silicon Mac the app supports (8 GB and up).
        modelParams.n_gpu_layers = 999
        modelParams.use_mmap = true

        guard let loaded = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed(path: modelPath)
        }
        self.model = loaded

        guard let v = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw LlamaError.modelLoadFailed(path: modelPath)
        }
        self.vocab = v

        var ctxParams = llama_context_default_params()
        // 4096 covers a 24K-char transcript head/tail window (~6K prompt
        // tokens) + a 1000-token response without saturating the rotating
        // KV cache on 8 GB Macs.
        ctxParams.n_ctx = 4096
        ctxParams.n_batch = 512
        // Leave two cores for the rest of the app (audio, UI). Capping at 8
        // mirrors the upstream Swift example - extra threads past that
        // hurt more than they help on M-series.
        let threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        ctxParams.n_threads = Int32(threads)
        ctxParams.n_threads_batch = Int32(threads)

        guard let c = llama_init_from_model(loaded, ctxParams) else {
            llama_model_free(loaded)
            throw LlamaError.contextInitFailed
        }
        self.context = c

        log.info(
            "Llama model loaded: \(modelPath, privacy: .public) (n_ctx=\(ctxParams.n_ctx, privacy: .public), threads=\(threads, privacy: .public))"
        )
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    // Runs prompt eval + token generation to completion and returns the
    // assembled output. Honours Task cancellation between sampling
    // iterations (so the watchdog in MeetingSummarizer can abort a stuck
    // run by cancelling the surrounding Task).
    func generate(prompt: String, parameters: Parameters = .init()) throws -> String {
        // 1. Tokenize the prompt. We call llama_tokenize twice: first with
        //    a nil buffer to discover the exact token count (returned as a
        //    negative value), then with a sized buffer to actually fill.
        let promptBytes = prompt.utf8.count
        var probe: [llama_token] = []
        let probedNeg = prompt.withCString { cStr in
            llama_tokenize(vocab, cStr, Int32(promptBytes), &probe, 0, true, true)
        }
        let needed = Int(-probedNeg)
        guard needed > 0 else { throw LlamaError.tokenizeFailed }

        var tokens = [llama_token](repeating: 0, count: needed)
        let actual = prompt.withCString { cStr in
            tokens.withUnsafeMutableBufferPointer { buf in
                llama_tokenize(
                    vocab, cStr, Int32(promptBytes), buf.baseAddress, Int32(buf.count), true, true)
            }
        }
        guard actual > 0 else { throw LlamaError.tokenizeFailed }
        tokens = Array(tokens.prefix(Int(actual)))

        // 2. Build the sampler chain. Penalties first (so they apply
        //    before temperature warps the distribution), then temperature,
        //    then a seeded distribution sampler. Mirrors the chain used in
        //    llama.cpp's official examples for chat-style generation.
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw LlamaError.contextInitFailed
        }
        defer { llama_sampler_free(sampler) }

        llama_sampler_chain_add(
            sampler,
            llama_sampler_init_penalties(
                Int32(parameters.repetitionContextSize),
                parameters.repetitionPenalty,
                0.0,
                0.0
            )
        )
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(parameters.temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

        // 3. Decode the prompt. `n_seq_max=1` is enough - we only ever run a
        //    single sequence at a time.
        var batch = llama_batch_init(Int32(parameters.nBatch), 0, 1)
        defer { llama_batch_free(batch) }

        // Drop any KV-cache state left by a previous generate() on this reused
        // session. Re-decoding overlapping positions without a clear stacks
        // duplicate cells, so the model would attend to stale context.
        llama_memory_clear(llama_get_memory(context), true)

        // A single llama_batch holds at most the context's n_batch tokens;
        // packing a longer prompt into one batch overflows it. Decode the
        // prompt in n_batch-sized chunks instead, setting the logits bit only
        // on the very last token so the model yields a next-token distribution.
        let chunkSize = Int(parameters.nBatch)
        var offset = 0
        while offset < tokens.count {
            let end = min(offset + chunkSize, tokens.count)
            llamaBatchClear(&batch)
            for i in offset..<end {
                llamaBatchAdd(&batch, tokens[i], Int32(i), [0], i == tokens.count - 1)
            }
            let promptRC = llama_decode(context, batch)
            if promptRC != 0 { throw LlamaError.decodeFailed(code: promptRC) }
            offset = end
        }

        // 4. Token-by-token generation. Each step samples one token,
        //    converts it to text, then feeds it back as a single-token
        //    batch. We stop on EOG (Gemma 3 emits <end_of_turn>), on the
        //    max-token cap, or on Task cancellation.
        var output = ""
        var pos = Int32(tokens.count)
        let maxTokens = parameters.maxTokens

        for _ in 0..<maxTokens {
            if Task.isCancelled { throw LlamaError.cancelled }

            let newToken = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, newToken) { break }

            output.append(Self.tokenToString(token: newToken, vocab: vocab))

            llamaBatchClear(&batch)
            llamaBatchAdd(&batch, newToken, pos, [0], true)
            pos += 1

            let stepRC = llama_decode(context, batch)
            if stepRC != 0 { throw LlamaError.decodeFailed(code: stepRC) }
        }

        return output
    }

    // Convert a single llama_token to a Swift String. token_to_piece may
    // need a larger buffer than 16 bytes for multi-byte UTF-8 sequences;
    // when it returns a negative count we retry with the size it asked
    // for. Invalid (partial-UTF-8) pieces are dropped silently - the next
    // token usually completes the rune.
    private static func tokenToString(token: llama_token, vocab: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 16)
        var written = buf.withUnsafeMutableBufferPointer {
            llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
        }
        if written < 0 {
            let needed = Int(-written)
            buf = [CChar](repeating: 0, count: needed)
            written = buf.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
            }
        }
        guard written > 0 else { return "" }
        // Append a NUL so String(cString:) terminates correctly even when
        // the piece used every byte of the buffer.
        var bytes = Array(buf.prefix(Int(written)))
        bytes.append(0)
        return String(cString: bytes)
    }
}

// Mirrors the helpers in llama.cpp's official Swift example. The C
// `llama_batch` struct exposes parallel arrays we have to populate by
// hand - there's no batch.append() in the public API.
private func llamaBatchClear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llamaBatchAdd(
    _ batch: inout llama_batch,
    _ id: llama_token,
    _ pos: llama_pos,
    _ seqIDs: [llama_seq_id],
    _ logits: Bool
) {
    let i = Int(batch.n_tokens)
    batch.token[i] = id
    batch.pos[i] = pos
    batch.n_seq_id[i] = Int32(seqIDs.count)
    for (offset, sid) in seqIDs.enumerated() {
        batch.seq_id[i]![offset] = sid
    }
    batch.logits[i] = logits ? 1 : 0
    batch.n_tokens += 1
}
