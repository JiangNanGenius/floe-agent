# Native media workbench qualification

This minimal iOS App compiles the production media editor/player against FloeMedia,
FloeTools and FloeCore. It avoids the full App/Office/MLX build. It does not test
workspace navigation, chat attachment integration, shared jobs or a physical device.

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

Launch with `--model-smoke`. The App exercises the production editor model:
source inspection, save/reopen, a 1–5 second trim at 2x speed, volume 0.5,
320×180 output at 15 fps, and output metadata/playability inspection. Results are
written to `Documents/media-model-results.json`. Every boolean, including `passed`,
must be true. Rendering the screen alone does not establish these checks.

Launch without the argument for manual playback, editing, cancel/retry and VoiceOver
checks. Preserve UI and model-test evidence separately. No automated touch/gesture
acceptance is implied by the model smoke test.
