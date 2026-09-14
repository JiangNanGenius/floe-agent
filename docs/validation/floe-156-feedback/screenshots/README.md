# Feedback repair screenshots

These are development qualification captures, not screenshots of a released build.

| File | Device / SDK | Source | Observed state | Usage |
| --- | --- | --- | --- | --- |
| ipad-management-fixture.png | iPad mini (A17 Pro), iOS 27 simulator | NativeManagement component host, 6aef1f9 plus uncommitted UI test fixtures | Real environment overview rendered; project/session/shared rows visible | Component evidence only; replace with full-App capture for user guide |

Screenshots are captured unaltered. The fixture has no Python/Node installer; rendering its management pages does not establish installation success. Full-App iPad/iPhone screenshots and navigation verification are still pending.

iPad component navigation was subsequently checked: the selected project opens its details and the Python page. Long/short reasoning captures have the same 156-pixel background span at x=50 (unscaled native screenshots); advancing the fixture to the next round hides both prior tool cards. See `manifest.json` for original image dimensions and SHA-256 values.

Cloud run 34792006293 passed all 4 component UI tests on each of iPad and iPhone. The 16 original screenshots and their test identifiers are retained under `cloud-components/`; this does not qualify the full App. `ipad-speech-hidden-complete.png` is the separate actual Whisper download host with Settings dismissed, not a transcription test.
