# Feedback repair screenshots

These are development qualification captures, not screenshots of a released build.

| File | Device / SDK | Source | Observed state | Usage |
| --- | --- | --- | --- | --- |
| ipad-management-fixture.png | iPad mini (A17 Pro), iOS 27 simulator | NativeManagement component host, 6aef1f9 plus uncommitted UI test fixtures | Real environment overview rendered; project/session/shared rows visible | Component evidence only; replace with full-App capture for user guide |

Screenshots are captured unaltered. The fixture has no Python/Node installer; rendering its management pages does not establish installation success. Full-App iPad/iPhone screenshots and navigation verification are still pending.

iPad component navigation was subsequently checked: the selected project opens its details and the Python page. Long/short reasoning captures have the same 156-pixel background span at x=50 (unscaled native screenshots); advancing the fixture to the next round hides both prior tool cards. See `manifest.json` for original image dimensions and SHA-256 values.

Cloud run 34792006293 passed all 4 component UI tests on each of iPad and iPhone. The 16 original screenshots and their test identifiers are retained under `cloud-components/`; this does not qualify the full App. `ipad-speech-hidden-complete.png` is the separate actual Whisper download host with Settings dismissed, not a transcription test.

Full-App run 34798414773 (`a633134`) exported three original iPad screenshots under `full-app-a633/ipad/`: Notes library, workspace PDF picker, and the imported PDF in the full-screen editor. The manifest retains original attachment names and SHA-256 hashes. The UI case exceeded its 180-second deadline and failed; Xcode subsequently spent 600 seconds unsuccessfully collecting verbose diagnostics. There is no exported body-search screenshot and no valid iPhone case result in that run. These images document visible development states, not completed UI acceptance. The full-screen capture also records the left-aligned paper layout being corrected in the next candidate.

Run 34802103604 (`a6a57e9`) has a finalized passing iPad Notes xcresult: one case, zero failures/skips, 60.917 seconds. Its four unmodified PNGs are in `full-app-a6/ipad/`. The workspace picker is suitable for illustrating the development import flow. The body-search capture retains a keyboard obscuring the snippet, so it is preserved as test evidence only. The paper-centering revision is later than these captures. The phone failed on an offscreen, duplicate-title test locator; that result and the separate App-unit bundle were not finalized before their diagnostic-collection deadlines. No phone PNG was exported from this run, and the overall run failed.
