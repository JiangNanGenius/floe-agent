# Durable service lifecycle qualification

This package reuses the production background job tests through a source symlink.
It checks persistence, task ownership, cancellation acknowledgement, target
validation and terminal transitions without building Office or model runtimes.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path FloeAgent/Qualification/Services \
  --scratch-path ~/Library/Caches/CodexBuild/Floe/services/qualification --jobs 6
```

Run sequentially with other SwiftPM jobs using this scratch directory. It is
macOS component evidence. The full-App `LocalShellRuntimeTests` separately
exercise real Node/Python HTTP services, preview authorization and shutdown.

The same package also reuses Linux lifecycle, port-rule and durable running-input tests. Filter those suites for changes to startup, forwarding or browser handoff routing; this remains macOS component evidence, not full-App or device acceptance.
