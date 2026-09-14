# Native Whisper transfer qualification

Build with Xcode 27 and `xcodegen generate`, then run `FloeSpeechDownloadSmoke` on an iPad or iPhone Simulator. This target compiles the production `WhisperModelStore`, `WhisperDownloadCoordinator` and settings view and embeds the production SHA-256 manifest. It does not contain WhisperKit or perform inference.

Open **语音识别设置**, start the download, then go back immediately. `Documents/speech-download-evidence.json` records visibility and byte progress every second. On completion the fixture acquires the model lease, checking every file against its manifest. Relaunch checks the persisted installation; the App delegate restores requested background transfers using the production coordinator.

Keep the JSON before a relaunch (each process starts a new sample list). A successful download is not inference or real-device acceptance. The explicit download is about 491 MB and requires temporary staging space. Do not put downloaded weights or simulator state into Git.
