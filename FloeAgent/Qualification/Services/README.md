# Durable service lifecycle qualification

This package reuses the production background job tests through a source symlink.
It checks persistence, task ownership, cancellation acknowledgement, target
validation and terminal transitions without building Office or model runtimes.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path FloeAgent/Qualification/Services \
  --scratch-path FloeAgent/.build --jobs 2
```

Run sequentially with other SwiftPM jobs using this scratch directory. It is
macOS component evidence. The full-App `LocalShellRuntimeTests` separately
exercise real Node/Python HTTP services, preview authorization and shutdown.
