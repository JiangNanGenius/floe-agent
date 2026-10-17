# Native environment and thread UI qualification

This small iOS app compiles the production appearance selector, semantic tokens,
container manager, reasoning frame, tool frame and step-group view. The
management API is the production `EnvironmentManagementService` from FloePackages.

The app bootstrap uses a deterministic synthetic sandbox. App-owned event routing,
approval execution and rich-artifact presentation have explicit fixture stand-ins;
this does not qualify the full application, attachments, or real provider runs.
The environment list is seeded for screenshots and is not a deletion acceptance
fixture. Host `EnvironmentManagementTests` exercise the actual lifecycle API.

```sh
cd FloeAgent/Qualification/NativeManagement
xcodegen generate
# Run inside the project's ONE canonical existing simulator through the
# serialized single-device wrapper (validates the pinned device read-only,
# holds the exclusive lock for the whole xcodebuild run, exports
# FLOE_SIMULATOR_UDID to the child; never creates, clones or substitutes —
# see the repository AGENTS single-simulator policy):
python3 ../../scripts/select_test_simulator.py --canonical --with-lock /bin/sh -c \
  'xcodebuild -project FloeManagementSmoke.xcodeproj -scheme FloeManagementSmoke \
     -destination "platform=iOS Simulator,id=$FLOE_SIMULATOR_UDID" \
     -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
     -derivedDataPath /tmp/FloeManagementDerived CODE_SIGNING_ALLOWED=NO test'
```

Launch with `--appearance` for General's theme section, `--thread` for the
synthetic thread, or no argument for environment management. The app normally
follows system appearance. UI tests tap all three appearance choices, open
reasoning, collapse a tool batch, append a running call and verify that completed
calls stay folded while the active call remains visible.
