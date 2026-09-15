# Real Agent video qualification

This small UI runner controls a separately installed **full Floe App from an immutable source artifact**. It does not link Floe modules, inject responses, or create the demonstrated Markdown file. A completed CI artifact supplies the App; its SHA is recorded independently of this driver.

Run only with explicit user authorization for paid Volcengine text calls. The workflow is manual, refuses automatic reruns, and uses the user's temporary `FLOE_LIVE_DEMO_ARK_KEY` secret. Remove that GitHub secret after the authorized run. No reviewer receives it. Generated image/video APIs are not used.

1. Validate the exact simulator App artifact. Ad-hoc sign its disposable copy with its own simulator Keychain identity, recording the executable hashes before and after signing. No App code is rebuilt or edited; this is not device/distribution signing. Install it and let normal migrations finish.
2. Seed only secret-free model metadata into the disposable database.
3. Pass the credential with Xcode's `TEST_RUNNER_` environment mechanism. The UI runner pastes it into Floe's SecureField; Floe saves it to its ordinary non-syncing Keychain account. This setup is outside the recording.
4. Record the normal Agent receiving a task, creating `review-demo.md` and reading it back. Keep the normal human approval policy; the driver may approve at most two requests whose visible tool names match these authorized file operations. Other requests fail the demonstration. The UI test does not supply tool results.
5. Check persisted successful tool calls and the actual file, then export the screen recording, screenshots, file digest and synthetic result summary. Do not export the database, credential test result bundle or Keychain.
6. Remove the disposable simulator and temporary CI credential. Simulator evidence is not physical-device acceptance or Apple approval.

Driver compilation is small and can run locally with two jobs. Heavy Floe compilation and recording should use cloud CI on memory-constrained Macs. Existing App acceptance failures remain failures regardless of demo success.
