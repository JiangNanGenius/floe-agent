# Build 179 — release-source SDK 27 Notes evidence

Immutable source `a510ea6df8ff4a366e237ad5bad3410e5023c92b`, tag `v1.7.0-beta.36`, [release run 35228451173](https://github.com/JiangNanGenius/floe-agent/actions/runs/35228451173), artifact `10501664960`. Each simulator passed three Notes cases; the native Office case was skipped. Devices: iPad mini (A17 Pro), iPhone 18 Pro. These are original attachment bytes; the manifest retains identifiers and hashes. The primary reviewer visually inspected all six retained images.

The images show focused writing, brush controls, document-body search and document-scoped assistant presentation. The iPhone simulator has no configured model, so the assistant image is layout evidence only, not inference or tool-use evidence. Pencil hardware, native Office and the reported physical iPad MLX crash are not established by these images.

| Screen | iPad | iPhone |
| --- | --- | --- |
| Brush controls | [Original](ipad-notes-native-brushes.png) | — |
| Document assistant | [Original](ipad-notes-document-assistant.png) | [Original](iphone-notes-document-assistant.png) |
| Focused writing | [Original](ipad-notes-focused-writing.png) | — |
| Body search | [Original](ipad-notes-document-body-search.png) | — |
| Full-screen document | — | [Original](iphone-notes-imported-pdf-fullscreen.png) |

The SDK 27 job passed and produced a verified unsigned IPA. The overall release run failed when the separate accepted-SDK Notes step exceeded 20 minutes; iPad passed after one import-test retry, and iPhone was interrupted before its final result. Upload did not start. This evidence does not imply TestFlight availability.
