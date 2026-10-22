# Floe integration patches

Upstream revision and original file digests are retained in PROVENANCE.md and
SOURCE_SHA256.json. The latter records upstream bytes, not patched replacements.

- AudioCommon/SpeechStreamSession.swift: new producer-completion handle.
- Qwen3TTS/Qwen3TTS.swift and MossTTSNano/MossTTSNanoModel.swift: add
  `synthesizeStreamSession`, preserving the original streaming entry points.
  The app cancels and **joins** inference before model reuse or reservation
  release. Cancelling a stream consumer alone can return before the producer
  has stopped, which is unsafe for Qwen's explicitly non-thread-safe model.

- Qwen3TTS/GenerationCache.swift: expose a scoped drain and allocator-cache
  reclamation point after materialized PCM and joined generation. No global
  cache limit or wired-memory setting is changed.

No weights, sampling, tokenization, codec or signal processing algorithms change.
