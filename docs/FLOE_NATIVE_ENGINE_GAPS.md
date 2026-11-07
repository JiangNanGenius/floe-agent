# Floe heavy editor gaps and existing capability baseline

Updated: 2026-11-08. [简体中文](FLOE_NATIVE_ENGINE_GAPS.zh-CN.md)

The initial review identified missing heavy editor categories; the user subsequently authorized full GIS/notation/font predevelopment: persistent project manipulation, structured editing and complex iPad interaction that a one-off script output cannot replace. Existing features can improve gradually; algorithm and performance improvements are not new editor requirements in this round. Count existing and in-progress workbenches as covered. Preserve Floe-authored MPL-2.0 and each third party's actual terms.

## 0 Confirmed gaps and subsequent implementation

The user subsequently authorized **full predevelopment of E04.2–E04.4**. The three independent modules now implement the agreed scope; the unified native qualification host is checking entrypoints, durable reopen and exports. See the [complete scope and integration boundaries](FLOE_GIS_SCORE_FONT_PREDEVELOPMENT.zh-CN.md). The category comparison below preserves the original gap assessment, rather than describing these implementations as still absent. Mainline owns production Space/Notes/task composition; component evidence does not establish full-App or physical-iPad acceptance.

The initial scope review used `76c3981d6f31540b3b557792e1591aafe24c3e1d` plus the shared working tree. Editor entrypoints, project types and targeted searches for domain formats/editing models did not then reveal a complete dedicated editor path for the categories below. This is not an exhaustive classification of all professional software. Same-day mainline coordination confirmed that a complete PCB/schematic editor was already planned, its actual App editing entrypoint is missing, and mainline has taken ownership of completing it. Preserve E04.1 as existing planned scope; the new category candidates are E04.2–E04.4.

| ID | Missing category | Editor shape | Distinction from existing capabilities | Current implementation |
| --- | --- | --- | --- | --- |
| E04.1 | Actual App gap in the previously planned complete PCB/schematic editor (EDA) | Complete schematic and PCB projects; components/symbols/footprints, connectivity/netlists, layers/routing, ERC/DRC, manufacturing output and save/reopen inherit the original plan rather than narrowing it to partial routing | CAD, diagrams and Gerber/drill previews do not provide the complete circuit-design project; KiCad schematic/PCB formats are explicitly unsupported | Existing planned scope owned by mainline; do not start a duplicate implementation |
| E04.2 | GIS | Layers, feature/attribute editing, coordinate systems, rasters/terrain, spatial analysis and offline projects | Map display, CAD terrain and biological spatial data do not establish a general GIS editor | Module implemented; unified-host acceptance and production App composition tracked separately |
| E04.3 | Music notation / score engraving | Measures, staves, multiple voices, notes/rests, expressions, lyrics, scores/parts and MusicXML | Tracks, keyboard and MIDI exist; the initial review lacked a score document model and notation editor | Notation module implemented; mainline continues existing music-editor enhancements |
| E04.4 | Font / glyph design | Glyph outlines, character mapping, spacing/kerning, ligatures and font export | Font picking, text layout and ordinary vector drawing do not provide a font project | Module and native font compiler implemented; mainline intake tracked separately |

Local evidence: [engineering preview formats](../FloeAgent/Sources/FloeWorkspace/EngineeringPreviewPackage.swift), [Space content types](../FloeAgent/FloeApp/Space/PersonalContentLibrary.swift), [existing MIDI model](../FloeAgent/Modules/FloeMusicKit/Sources/FloeMusicCore/MIDI.swift). Product-shape references: [KiCad PCB](https://www.kicad.org/discover/pcb-design/), [QGIS feature editing](https://documentation.qgis.org/3.44/en/docs/user_manual/working_with_vector/editing_geometry_attributes.html), [MuseScore notation](https://handbook.musescore.org/), [FontForge font design](https://fontforge.org/docs/). These references do not select or authorize reuse of their source code.

LaTeX, Office/PDF/Notes, images/painting/basic vectors, video, music/audio, CAD/Mesh/buildings, animation/physics/CAE, manufacturing/printing, chemistry, biology, diagrams/canvas and the code IDE are not new missing categories. Professional vector design, publishing layout, compositing and scientific plotting overlap existing workbenches; retain them as possible specializations rather than declaring the entire category absent. The existing inventory and E01–E03 below are background, not a new enhancement or performance program for this round.

The initial audit used `60f803afae967905529cbb01e0c8229ae0b92cdb` plus the shared working tree. The implementation baseline is now mainline checkpoint `9b016097d7169cdf864ca25ccbc4f280b0d07a6b`, including the unchanged analysis sources, both tests and qualification package. Independently developed LaTeX work is not all included in that commit. Implementation and evidence do not imply a published installer; pending scope is not an ETA.

Same-day update: mainline iteration 25 completed App/Unit/UI compilation and preserved passing evidence for 84 distinct cases across batches. Two final automated UI fixtures failed; the same App was manually checked, while the final locator edits were not rebuilt or reported green. The separate 18 numerical tests are not counted again. See [mainline verification](qualification/next-round-integration-20261108/README.md). An independent license-inventory check now passes; the original stale-lock failure remains preserved. This does not resolve L01's GPL combination question.

## 1 Distinguish execution paths

| Path | Current examples | Planning consequence |
| --- | --- | --- |
| Native Apple code and frameworks | OCCT, Manifold, Rust machining, Rapier, Netgen, MFEM, Avogadro/UFF, AVFoundation, VideoToolbox, Core Image, Metal, Core ML | Reuse existing services before porting another engine. |
| Bundled WebKit, JavaScript, WASM and WebGL | Kiri:Moto slicing, selected format/chemistry bridges and offline rendering | Local execution is not necessarily native C++; WebGL GPU work is also not Linux CPU emulation. Measure before replacing kernels. |
| Locally interpreted Linux guest | Python, scientific workers and CLI tools through `exec.shell` | Guest C/Fortran libraries still incur CPU-emulation overhead; prioritize representative comparisons here. |
| User-configured external environments/services | Scientific calculations, remote commands and model providers | No local guest-emulation overhead. Preserve configuration/use without requiring developer-owned accounts as a gate. |

Sources: [execution routing](../FloeAgent/Sources/FloeTools/CapabilityExecutionRouter.swift), [ARM64 engine](../FloeAgent/ThirdParty/ARM64EMU/README.md), [actual slicing host](../FloeAgent/FloeApp/Space/Printing/NativePrintBackend.swift). NumPy uses precompiled C for many array operations ([documentation](https://numpy.org/doc/stable/user/whatisnumpy.html)); a Python API alone does not establish a bottleneck.

## 2 Existing implementation and the post-completion baseline

| Area | Existing implementation | Work being completed | Subsequent scope |
| --- | --- | --- | --- |
| Office, PDF and Notes | Editing, exports, protected PDF, files and persistence | Reuse current document/result return paths and separate editor state | Existing foundation; no duplicate document engine. |
| Diagrams, mixed canvas and interactive content | Native diagrams, mixed canvas, templates/flows, save and AI interfaces | Mainline input, previews and tool accessibility | Canvas, diagrams and basic vector editing are not new domains. |
| Images, painting and video | Media v2 editor/timeline; 52 local commands from a 107-entry catalog; native `video.interpolate`/`video.superResolution`; existing background-removal backend | N03/N11/N12/N13 UI, input, selections/assets/results and tool wiring; classify the other 55 entries | Reuse available services before implementing genuinely absent heavy kernels. |
| Music, audio and meetings | Tracks, keyboard/MIDI, synth/mix, recording, WAV/MP3, meetings and waveforms | Concurrent recording/transcription, recovery/tail processing and cross-workbench audio inspection | Reuse audio pipelines; advanced live multitrack/plugins are not completed capabilities. |
| CAD, Mesh, buildings and rendering | OCCT/Manifold, mesh booleans/voxel reconstruction, 2D/3D exchange, buildings/IFC, local rendering and animation | N11/N17 input/planar navigation and existing viewport/tool integration | Modeling, reconstruction, buildings and rendering belong to the baseline. |
| Manufacturing/machining | Native R11, turning/milling paths, archive/reopen/preview and bounded parameter catalog | Research sessions and tool adapters; no claim that all parameters or industrial machine behaviors execute | Continue existing work, subject to L01's GPL dependency resolution. |
| 3D printing | Preparation, slicing, layer preview, exports and persistence using bundled WebKit/Kiri:Moto | Existing project/slicing flows; large-Mesh performance still requires measurement | Performance candidate, not an assumed C++ rewrite or an already-native slicer. |
| Physics, animation and CAE | Native tet4, Rapier, particles, Netgen, MFEM electrostatics/acoustics and CAD result viewport | Fourth-batch Mesh, skin/Morph/ragdoll/camera, GLB/MP4 and history are included; four App integration cases have passing evidence, including rig/camera and sequential exports | These bounded capabilities enter the existing baseline. Advanced structures/nonlinear, CFD, magnetics/RF and coupled solvers remain existing-plan backend gaps. |
| Chemistry | Native editing/3D, Avogadro/UFF, balancing/spectra and RDKit/Gemmi/OpenMM/xTB environment adapters | Space/Notes, jobs/cancel/results/tools are wired and under mainline checks; xTB is not a bundled native runtime | Accelerate selected local workloads while preserving existing UI and protocols. |
| Biology | Sequence, structure, microscopy, omics and networks; component has 21 native methods, 32 optional scientific methods and 22 tools | App composition and registration are connected; 11 host/tool contracts passed, with actual sequence creation, save/reopen and analysis UI reviewed. External scientific backends and live model calls were not newly accepted | Include the current workbench; measure heavy methods instead of recreating five workbenches. |
| LaTeX | Shared native editing/storage/PDF preview, source/visual UI, references, templates, SyncTeX and tool adapter; production typesetting uses task-bound existing Linux `exec.shell`/jobs, without the native TeX experiment dependency | Owner handoff reports independent iPad dual-mode editing/formula/PDF/save/reopen, 11 real Debian13 ARM64 typesetting cases and 3 isolation/timeout/cancellation checks passed; the owner is still integrating and accepting main-App entrypoints, ownership, tool discovery and execution | Count as an in-progress editor. Native TeX experiments are excluded from production App dependencies; CLI separation does not establish license or App Store approval. |
| Local models, OCR and speech | Existing resource/inference services, Vision OCR, speech/transcription | Model configuration, resources and domain wiring remain separately verified | Reuse inference rather than introducing another runtime per domain. |
| Toolbox, scripts and lightweight statistics | Network/connections/serial assistant, files/tasks/environments and `data.analyze` with 18 numerical tests | History and ordinary serial work continue; USB serial is deferred pending approval by latest user direction | Keep lightweight statistics as a helper rather than a new heavy mathematics workbench. |

Preserve [N01–N17 and C01–C67](FLOE_NEXT_ROUND_ENGINES_AND_USABILITY_PLAN.zh-CN.md) and the independently owned LaTeX item list at `docs/FLOE_LATEX_PREDEVELOPMENT_PLAN.zh-CN.md`, including ownership and unfinished goals. Current source supersedes older “component not integrated” descriptions only where the actual App adapters now exist.

Sources: [App integration](FLOE_PREDEVELOPMENT_APP_INTEGRATION.zh-CN.md), [CAD/Mesh/buildings](CAD_MESH_BUILDING_PREDEVELOPMENT_20261106.zh-CN.md), [simulation boundaries](FLOE_3D_SIMULATION_IMPLEMENTATION_STATUS.zh-CN.md), [native chemistry](../FloeAgent/Modules/FloeChemistryNative/README.md) and [workers](../FloeAgent/Modules/FloeChemistryKit/README.md), [biology](../FloeAgent/Modules/FloeBiologyKit/README.md) and [App composition](../FloeAgent/FloeApp/Space/Biology/BiologyAppComposition.swift). Current LaTeX boundaries are in its `Package.swift`, `THIRD_PARTY.md`, `Integration/APP_INTEGRATION.zh-CN.md` and [original plan](FLOE_LATEX_PREDEVELOPMENT_PLAN.zh-CN.md). Earlier evidence for 15 core tests and 2 native-host experiments remains historical component evidence, not proof that the production App links or may use that native TeX backend. This review does not rerun those checks or treat uncommitted sources as committed dependencies.

## 3 Existing work background (retained by its owners)

| Work | Completion boundary |
| --- | --- |
| Physics/biology App intake | The bounded App cases and manual flows above are verified. Reuse component evidence rather than repeating unchanged checks. External scientific backends, live providers and physical-device behavior remain separate and are not established by App25 compilation or contracts. |
| LaTeX actual App integration | Reuse shared native editing services and existing Linux worker/jobs. The owner completes project and Space/task/Notes ownership, tool discovery and real execution acceptance without qualification-host authority shortcuts or the quarantined native TeX experiment. |
| Media and general tools | Check actual schemas, parameters, selection, source revision, execution, result and export; keep unconnected commands explicit. |
| Usability | Continue N03–N17 layout/history/meeting/files/previews/input work; USB remains explicitly deferred. |

New circuits/GIS and a repository-wide performance audit are not gates for this batch or authorization to expand publication.

## 4 Historical enhancement directions and new-category index

E01–E03 describe future improvements to existing features. They are not new editors or this task's execution order.

### E01 Heavy gaps in existing media workbenches

Catalog-versus-command comparison leaves **55 entries: 29 image and 26 video**. This identifies missing workbench command integration, not 55 absent algorithms across the whole App.

- `image.resize`, `image.canvas-size`, `video.transcribe` and `video.caption-style` already point to concrete services/commands; wire them first.
- Subject masks/refined edges and image repair/inpainting first reuse image services and configured models. Background removal already has a backend.
- `video.tracking`/`video.stabilize` and `video.noise`/`video.voice-separate` combine substantial computation with interaction. Determine per feature whether it needs a service adapter, model adapter or new kernel.
- Curves/LUT/scopes/HDR and audio processing retain their original catalog identities; a listed menu is not execution evidence.
- Interpolation and super-resolution already have native tools. Remaining workbench integration does not justify another implementation.

Reuse the current editor, transaction, revision, cancellation, undo and export paths. [Local commands](../FloeAgent/FloeApp/Workbench/MediaV2/MediaV2Commands.swift), [catalog](../FloeAgent/Sources/FloeWorkbench/PreparedTools/MediaPreparedBundledCatalog.swift), [native media tools](../FloeAgent/Sources/FloeMedia/MediaEnhancement.swift).

### E02 Heavy scientific backends

Compare biological PCA/neighborhoods/clustering, alignment and microscopy, plus chemical conformers/force fields/OpenMM/xTB. Existing scientific methods and file/job protocols are the starting point, not an entire Python-stack rewrite.

Identify actual size, execution location and hotspots; compare identical inputs for time, peak memory, numerical error and cancellation. Prefer [Accelerate](https://developer.apple.com/accelerate/)/Metal, suitable signed domain libraries and existing Eigen/MFEM capabilities. Extract shared matrix/sparse/FFT services only when real cross-module consumers exist. GPL scientific implementations do not automatically become native App dependencies.

Measure large-Mesh slicing separately through input preparation, slicing, preview and export. WebKit implementation alone does not prove a native replacement is faster. Distinguish local WebKit, interpreted Linux and external native machines; Mac/Simulator timings do not establish physical-iPad speedups.

### E03 Continue advanced CAE

Advanced/spectral/nonlinear/contact structures, transient heat, CFD, magnetics/RF and coupling retain the existing simulation scope and owner. Reuse mesh/material/boundary/field/viewport/storage services. Qualify selected modules for licenses, memory and both Apple targets before intake; do not create a second physics/CAE product.

### E04 New independent heavy domains

Section 0 is the current classification. E04.1 records the actual App gap in the existing complete PCB/schematic plan, owned by mainline; it is not this thread's new recommendation or a reduction of its original scope. E04.2 is GIS, E04.3 score engraving and E04.4 font design. This thread has since implemented the three independent modules under the user's full-predevelopment authorization. Production App composition and publication remain separately owned by mainline. Ordinary statistics, algebra, small ODEs, Bode/PID plots, cleaning and reports keep the script route.

## 5 MPL 2.0 and external source

Preserve Floe-authored MPL-2.0 and third-party notices. MPL's copyleft is file-level; permission to combine code does not remove other licenses' distribution obligations. [Mozilla FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/), [MPL/GPL guidance](https://www.mozilla.org/en-US/MPL/2.0/combining-mpl-and-gpl/). Do not change the root license or add unrequested dual licensing to make reuse possible.

Prefer suitable MIT/BSD/ISC/Apache-2.0 dependency closures with full notices, pins and patches. Record the selected branch of dual licenses. Assess LGPL/exceptions and source/relink obligations per actual use. GPL/AGPL or unknown source is not a default native-App dependency; a C ABI, dynamic library, process name or language translation alone is not a licensing conclusion. Fonts, weights, datasets, packages and auxiliary programs also retain their own terms.

| ID | Concrete finding | Action |
| --- | --- | --- |
| L01 | [TurningNative/LibLathe is declared GPL-2.0](../FloeAgent/Modules/FloeManufacturingKit/THIRD_PARTY.md); [Core depends on it](../FloeAgent/Modules/FloeManufacturingKit/Package.swift), [production code imports it](../FloeAgent/Modules/FloeManufacturingKit/Sources/FloeManufacturingCore/NativeEngine.swift), and the App includes Core/UI | Mainline owner has been informed to resolve final linking/distribution. Preserve source and behavior; establish a suitable license/authorization or independent implementation. The historical separate-research-host statement does not clear the actual App graph. No clean-status claim until resolved. |
| L02 | Biology's environment dependencies include GPL igraph/leidenalg, not linked into the native component | Distinguish environment tools from host linking. Do not mechanically port GPL implementations and relabel them MPL; select suitable implementations or independently implement public specifications. |
| L03 | Existing OCCT/Netgen and new TeX dependencies/fonts/resources have individual terms | Retain existing assessments and source/relink materials; check actual slices, resources and dependencies rather than only root licenses. |
| L04 | The original read-only check failed on the FloeCADKit lock; after mainline re-resolved it, this thread independently confirmed a pass: 243 components, 55 bundled notices and 40 Swift package rows | Preserve failure and success separately. Check actual native-Module coverage and dual-license choices; inventory success is not a resolution of L01's specific combination. |

Retain the [CAD license assessment](FLOE_CAD_3D_REUSE_LICENSE_EVALUATION_20261031.zh-CN.md). Prefer engine/file subsets that satisfy this project's distribution objective. GPL is not inherently unusable; this constraint follows the user's chosen distribution policy.

## 6 Conditions for future implementation and historical evidence

- Preserve actual inputs, source/engine identity, results, cancellation, save/readback and model calls; UI and AI use the same original and service.
- Reuse unchanged build/component evidence and check affected behavior. Current implementation does not wait for E04.
- Measure acceleration and distinguish component/App/Simulator/device results; downloads and menu counts are not acceptance.
- Keep notices and source materials aligned with selected dependencies and actual artifacts. Concrete unresolved links remain visible.

The initial audit changed documentation only: no new production engine, version, upload or device operation. [Audit record](qualification/native-engine-inventory-20261108/results.json) captures 29 implementation/plan source hashes, the catalog comparison and license findings. Earlier [data.analyze qualification](qualification/native-data-analysis-20261108/results.json) remains 18 numerical tests plus object compilation, not full-App or heavy-computation completion.

Subsequent implementation, 2026-11-08: FloeGISKit, FloeScoreKit, FloeFontKit and shared FloeHeavyEditorSupport now exist, with native UI work continuing under their independent owner. Notation exposes timing/SMF and an injectable playback adapter without editing existing DAW sources. Mainline has verified music save/reopen and real 30-second audio export, and all eight LaTeX App identity/authority cases have now passed; see the [music and Building checkpoint](qualification/music-tool-contract-20261108/README.md). LaTeX production entrypoints use existing Linux jobs, while the native TeX experiment remains outside the App. The full in-App Linux/PDF cycle remains unverified. Keep implementation evidence separate from the initial audit.
