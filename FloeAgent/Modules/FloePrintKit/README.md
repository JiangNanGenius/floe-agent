# FloePrintKit

Swift 6 input, configuration, artifact, layer-preview and slicing-lifecycle contracts for the native print workbench. See [中文说明](README.zh-CN.md).

The App integration lives in `FloeApp/Space/Printing`, with its offline WebKit adapter in `FloeApp/Resources/Printing`. The adapter uses the pinned Kiri:Moto subset in `ThirdParty/KiriMoto`; it does not expose a general script runtime. The original independent runner remains in `Qualification/Printing`.

- Immutable millimetre triangle meshes and bounded binary STL import.
- Per-project plates and objects, revision-guarded edits, transforms and undo in the App session.
- `PrintMachineConfiguration`: Cartesian/CoreXY/i3/Delta/SCARA firmware descriptions, bed size/origin, head and tool offsets, plain custom G-code blocks, and resin platform/lift/exposure layout.
- `PrintInput`: geometry, process, complete machine configuration, pinned engine and adapter `floe-print-app-4` enter the content fingerprint.
- `PrintArtifact`: validates actual G-code/CTB output against the requested machine and process. `PrintGCodePreview` and `PrintCTBPreview` read the saved output for layer playback.
- `PrintSlicingService`: owns the serial backend and cancellation boundary independently of editor lifetime.

The editor uses bed-centred XY geometry with Z=0 on the platform. FDM output applies origin/head/tool translation once and remains Cartesian; firmware owns motor mixing. Custom G-code uses fixed literal placeholders, never expression evaluation. Resin orientation changes the sliced layout; lift/exposure settings reach CTB. The printer owns its physical Z motor direction.

Output currently supports one tool per plate, G-code and CTB v3. Multi-tool color changes within one plate, support painting, drainage holes, mesh repair, 3MF project roundtrip and printer-specific network transfer remain incomplete. The system share sheet exports the complete file. Generic profiles do not certify manufacturer hardware.

Source compilation, actual App navigation/layout, slicing runtime and physical printing are distinct evidence. Prior FDM/CTB qualification is retained; it does not certify newly configured machines or hardware. Follow the current repository instructions for focused builds and acceptance.

Floe code is MPL-2.0. Preserve upstream and dependency licenses and local patches. The independent decoder is qualification tooling and is not linked into the App.
