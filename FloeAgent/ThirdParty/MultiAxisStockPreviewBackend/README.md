# Bounded multi-axis stock preview

This optional managed backend reuses the unchanged MIT MillSimSharp core at `3cdd4f54ef94e6b95f2a149dad246b4e73aad4e9` (DLL SHA-256 `3405064ebc312dbe38bacfdfb0eea8015354447ae3f749e4089cb8f584d1351d`). The complete pinned upstream source is already retained at `../BasicMachiningBackend/MillSimSharp-3cdd4f54-source.tar.gz`. MIT and MPL-2.0 notices accompany the backend package. No GPL library is linked.

The qualified execution target is an explicitly selected, connected same-Mac arm64 macOS environment, through existing `jobs.submit -> exec.shell`. First preparation reuses the basic machining environment's pinned .NET 8.0.33 runtime. The app bundles IL and notices only. No runtime/SDK is added to iOS or the riscv64 guest base image; no host interpreter or alternate target fallback is permitted.

Input is a saved native CAD snapshot plus bounded XYZ tip positions and IJK axes toward spindle. Motion is linear XYZ with canonical shortest-quaternion interpolation, not rotary machine joint commands. An outward-rounded part bounding box is full blank stock; native part geometry is reference only. The backend returns sampled nominal stock and conservative continuous remaining-volume lower/upper meshes. A cylindrical noncutting holder versus explicit static box fixtures returns `intersecting`, `clear` or `uncertain-refine`. A sampled miss never proves clearance. Nonmanifold edges/vertex links or invalid normals refuse publication and retain pending evidence.

Limits: 2–9 poses, ±100 mm coordinates, tool radius 1–10 mm, cutting length 2–25 mm, stock resolution 0.25/0.5/1 mm, ≤131072 stock cells, ≤1024 steps per segment, adjacent canonical orientation ≤150 degrees, bounded fixture/certificate work. Small/no material, output budgets or topology can refuse a request. Nominal voxel meshes are approximations, not BRep.

This is stock preview, not CAM planning, turn-mill, machine IK/joint limits, target gouge/force/deflection, or complete machine safety. Full E38 is not accepted by this component.

`build-wrapper.sh` accepts explicit .NET runtime, Roslyn compiler DLL, net8 reference directory, pinned core DLL, and output directory; it installs nothing. The reviewed IL is built with .NET 8.0.33 reference assemblies and Roslyn 4.12.0. Different source paths/toolchains can change deterministic IL hashes: rebuild the resource manifest and package pins together. Never change a published cache version in place.
