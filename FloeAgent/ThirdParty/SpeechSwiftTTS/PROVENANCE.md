# Speech Swift TTS subset

Source: https://github.com/soniqo/speech-swift

Revision: `7baf2781d5c6a5d38b008a96eef3dca61c55f369`.
License: Apache-2.0; retained in `LICENSE`.

Only AudioCommon, MLXCommon, Qwen3TTS and MossTTSNano are included. The local
package manifest selects these targets and reuses Floe's existing exact MLX
and swift-transformers pins. Unrelated recognition, server, chat and CLI
components are omitted. Model weights are separate optional verified downloads
and are not bundled in this source tree.

`SOURCE_SHA256.json` records the original copied source files. Local changes are
listed in `PATCHES.md`. App integration loads only
verified local model directories, keeps the process memory policy app-owned,
and fences/cancels inference and audio by session.

Floe also exposes a scoped GPU cache reclamation boundary after materialized PCM and joined generation. It preserves model weights, sampling and the process-wide cache/wired-memory policy. Twelve multilingual units and three cancellation/reuse cycles were qualified on the native macOS host before App integration.
