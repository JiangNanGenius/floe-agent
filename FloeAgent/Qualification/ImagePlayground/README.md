# Image Playground system capability

`FloeApp/Media/AppleImagePlayground` implements one model-callable native tool,
`image.playground`. It uses Apple's system panel inside the owning Floe task.
It does not create a separate image editor. The model supplies a prompt and an
optional workspace-relative original; the call waits for the user to select an
image or cancel, then publishes the actual selected image through the existing
workspace and immutable run-output services.

## Platform boundary

- Availability comes from `ImagePlaygroundViewController.isAvailable` and the
  existing Apple-capability preference, not an OS version or region guess.
- The checked SDK is Xcode 27.2 (27B52). Generation supports the App's iOS 26
  deployment target; the explicit `editExisting` strategy requires iOS 27.
  Requested dimensions use the closest supported size, not an exact-size promise.
- Apple's panel owns selection and cancellation. Public APIs do not offer an
  unattended confirmation or a supported way to skip that panel.
- No Floe image-provider key is required. Newer Apple models may use Private
  Cloud Compute, so the capability does not promise offline inference.
- This route offers Apple's image styles. External-provider and emoji styles
  are excluded: external images have their own provider tool, and emoji output
  is a glyph rather than this tool's image-file result.

Sources: [Image Playground](https://developer.apple.com/documentation/imageplayground),
[system view controller](https://developer.apple.com/documentation/imageplayground/imageplaygroundviewcontroller),
[WWDC 2026](https://developer.apple.com/videos/play/wwdc2026/375/).
SDK declarations, including availability guards, must be checked again after
upgrading the upload toolchain. Regional rollout announcements do not establish
availability for every iPad, account or language.

## Ownership and return path

`AppleImagePlaygroundService` is App-owned. Its required `enabled` and
`ownerIsLive` callbacks reuse the existing capability and run lifecycle.
Native views register explicit host and conversation identities. Exactly one
active, visible host must own the conversation; model arguments cannot choose
a scene, conversation, run or host URL. The host must account for other modal
surfaces before accepting a new request. An inactive scene preserves a request
already in progress; navigation, cancellation or loss of the original run
settles that request without writing to another task.

The native bridge calls `beginPresentation` when it constructs its controller.
A call cancelled before that point can retry without waiting for a dismissal
that will never occur. Mounted requests retain the busy gate until their exact
dismissal callback. Late and duplicate completion/dismissal callbacks cannot
settle a different request.

The system's temporary image URL is read and validated before dismissing the
panel. The original PNG/JPEG/HEIC/HEIF encoding, dimensions, MIME type and digest
are retained. Inputs and results are bounded to 32 MiB and 32 million primary
pixels. A new file is committed atomically below
`GeneratedImages/Apple/<run UUID>/`, preserving the source. Existing path scope,
symlink containment, cancellation and run-output snapshot rules remain in use.
The tool is mutating, nonconcurrent and main-run-only; temporary chat and child
execution cannot invoke it. Existing tool approval policies remain authoritative.

## Focused qualification

The standalone checks compile and run the production contract and coordinator
on macOS, then perform real Swift 6 arm64 iOS Simulator object compilation of
the production UIKit bridge. They never boot, install, reset or alter a
Simulator and do not run Apple's image model. Synthetic PNG fixtures are
explicitly test images.

Run through the repository's shared native build window, with a task-owned
internal-SSD cache and repository-owned evidence directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 Local/Private/shared-native-window/with_native_window.py \
  --label image-playground-component -- \
  python3 FloeAgent/Qualification/ImagePlayground/qualify.py \
  --build-dir "$image_playground_build_dir" \
  --evidence-dir "$image_playground_evidence_dir"
```

Set those two variables to the current task's actual output directories before
running. To include the tool adapter, supply `--app-products` pointing to real
matching App products, with each needed native dependency's actual module map
through `--clang-module-map`. No substitute Floe modules are generated. Add
`--compile-output-tests FloeAgent/Tests/FloeAppTests/AppleImagePlaygroundTests.swift`
to object-compile the persistence XCTest source against these production
qualification sources. Only its testable module import is adapted in the
task's build directory. That step does not execute the XCTest or establish
full-App integration.

The runtime checks cover encoded-image validation, input validation, device and
foreground eligibility, task ownership, exact temporary-file bytes, callback
and dismissal fencing, background preservation, navigation, Swift-task and
runtime-token cancellation, pre-mount cancellation/retry and older-system edit
rejection. Unchanged contract evidence may be reused only after verifying both
production and test source identity; original failed logs remain evidence.

The App integration adds the tool to the existing registry and capability
filter and installs a stable host for the current chat/Notes/Studio assistant.
`AppleImagePlaygroundTests.swift` exercises workspace publication, immutable
outputs, cancellation, the temporary-chat ceiling, path scope and symlink
containment. The shared integration owner adds it to the focused
`FloePredevelopmentTests` target, regenerates the Xcode project and runs that
test class through the canonical reused iPad's locking wrapper.

A component object build is not full-App compilation, XCTest execution, system
panel acceptance or real Apple inference. Actual selection/cancellation in the
owning foreground task, the saved-file return path and absence of cross-task
updates require separate App evidence on a supported system. No version,
signing, TestFlight or public-release operation belongs to this qualification.
