# Qwen first-generation diagnostic

Manual cloud workflow `local-inference-qualification.yml` loads the exact catalog-pinned Qwen3.8 snapshot using production `LocalModelStore` and `MLXTextEngine`, runs two short generations and a document-style prompt of at least 4,000 tokens with the constrained profile, records total request time, decode time, MLX memory and process peak RSS, then shuts down. No provider credential or paid API is used. The model downloads only into the ephemeral cloud runner.

This is a macOS host diagnostic. Success is not iPad jetsam, iOS memory allowance, Apple Pencil or physical-device acceptance. A failure supplies an independent reproduction, not proof that it caused the original device crash. Preserve the original uploaded report; it lacked complete termination metadata.
