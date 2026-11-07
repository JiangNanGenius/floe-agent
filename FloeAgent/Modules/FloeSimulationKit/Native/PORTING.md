# Apple native components

The production compute path is Swift → static C ABI → CPU library in the same process. Build-time Python/CMake/Cargo tools do not become runtime execution or remote-solver fallbacks. The generated XCFrameworks are ignored; retain the verified build artifact and run `verify_apple.py --check` before using it.

| Component | Pinned source | Current execution boundary |
| --- | --- | --- |
| Rapier | 0.36.1 with Cargo.lock | Existing rigid, kinematic, joints, regular deformables, particles/fields |
| Netgen | 6.2.2507, archive SHA-256 `daf6e4fe83f768cc5b6d594bb23b8a8cca47bdadc81ecb0902e0ffd598592055` | Tagged closed triangular surfaces on macOS arm64; additionally OCCT B-rep on iOS device/Simulator arm64 |
| OCCT | Existing FloeCADKit 7.8.1 archive, exposed by `FloeOCCTKernel` | One shared kernel at the final iOS link; no second OCCT archive inside the mesher |
| MFEM | 4.8, archive SHA-256 `65472f732d273832c64b2c39460649dd862df674222c71bfa82cf2da76705052` | Serial CPU H1 electrostatics and complex pressure acoustics, orders 1–3, tetrahedral domain |

Netgen local patches are applied by its build script: atomic termination flag, node/element insertion budgets, host-only `makerls` rule generation for Apple cross-compilation, and a fixed upstream version instead of the enclosing repository's Git version. Global Netgen state is serialized; cancellation is observed through an atomic session flag, and the service waits for the worker to return. Boundary triangles are converted to exact volume facets after positive-orientation normalization. Surface refinement preserves source attributes and conformity. B-rep tags are resolved through OCCT shape identity after unit transformation, rather than assuming Netgen's face order matches the input TopExp order.

MFEM is built with exceptions and thread safety, without MPI/OpenMP/GPU/BLAS packages. The only upstream configuration patch quotes an empty cross-compilation processor variable in an excluded miniapp's CMake file. Unsupported equations are not advertised. Floating electrostatic components, contradictory prescribed values, invalid media, matrix/result budgets and failed true-residual read-back are rejected. Acoustic conditioning uses a positive elliptic preconditioner for both complex blocks; the physical operator is unchanged. The stored energy uses quadrature, and reported element gradients are volume averages. Energy-equivalent capacitance is a scalar for the applied electrode pattern, not a multiport capacitance matrix.

The static framework layout gives each C++ component its own module map. Flat static-library headers named `include/module.modulemap` collided in Swift Build; that failed packaging layout was replaced, with the original failure retained in private evidence. SDK deprecation warnings in the unchanged OCCT headers are retained separately from errors.

Unfinished ports remain FEBio/Chrono, advanced spectra/thermal analysis, SU2, magnetic/eddy-current formulations, Palace/RF, complete multiphysics checkpoint adapters and ozz/skinning/video export. Downloaded sources or configuration structs do not count as working solvers. The iOS B-rep → Netgen → MFEM → archive/CSV component check is not whole-App or industrial numerical acceptance.
