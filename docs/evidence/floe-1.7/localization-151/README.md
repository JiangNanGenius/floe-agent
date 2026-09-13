# Localization gate correction

Release [34746045819](https://github.com/JiangNanGenius/floe-agent/actions/runs/34746045819), source `57f82f1`, completed its full concurrent Swift run without the WASM stall. Only the FloeCore localization namespace check failed; the full log is retained in that run's diagnostic artifact. The summary here retains the outcome and offending keys.

The fix namespaces the 21 keys and updates UI references without changing translations or completeness rules. All three original localization completeness tests passed locally; this does not replace tagged-source cloud qualification.

The separately run JavaScript engine/bundled-package and tool suites also passed locally (13 and 12 tests), with deadline and cancellation assertions retained. The tagged-source release is [34746784780](https://github.com/JiangNanGenius/floe-agent/actions/runs/34746784780), source `8d370cf`.
