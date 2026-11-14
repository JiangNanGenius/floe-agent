# Native media player qualification

This minimal iOS App compiles the remaining production media consumer,
`MediaPlayerView`, against FloeMedia, FloeTools and FloeCore. It avoids the full
App/Office/MLX build. It does not test workspace navigation, chat attachment
integration, shared jobs or a physical device.

The retired single-asset editor, its model/export smoke, the old image editor
(`FloeImageEditorView`) and the ZLImageEditor/VideoEditorKit dependencies were
removed from this host with the main App's retirement. Historical qualification
evidence for those retired components stays in the dated docs and release
records; it is not a current acceptance claim.

Generate the project with `xcodegen generate --spec FloeAgent/Qualification/NativeMedia/project.yml`.
Build the `FloeMediaUISmoke` scheme with a full Xcode, an explicit booted test simulator,
`CODE_SIGNING_ALLOWED=NO`, and a separate DerivedData path. The bundle identifier is
`dev.floe.media-ui-smoke`; use only your dedicated qualification simulator.

Install the App, then place a six-second MOV with video and audio in its Documents
folder as `input.mov`. A synthetic source can be created with:

```bash
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 6 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac input.mov
```

Launch the App for manual playback, scrub, speed, PiP, fullscreen and VoiceOver
checks. No automated touch/gesture acceptance is implied by installing it.
