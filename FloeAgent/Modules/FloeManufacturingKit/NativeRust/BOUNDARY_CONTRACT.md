# Native stock boundary reconstruction — R11

The C ABI and JSON version remain unchanged. Successful fresh results include
`declared-stock-boundary-v1` and `cylinder-domain-field-v1` in `capabilities`.
The latter identifies the R11 radial-domain implementation in a linked binary.
The library remains entirely native; qualification Python/C hosts are developer
tools and are not product execution dependencies.

## Geometry and material are distinct measurements

Pristine boxes use the declared planes/eight corners. Filled circular layers use
closed rings; every untouched layer retains the declared blank radius even after
another layer is machined. Machined layers use the bounded voxel-area radius.
End planes use the declared physical height, not ceil-rounded grid height.
Occupancy, removal accounting and cumulative material checkpoints are unchanged.
The preview mesh's volume therefore need not equal the centre-sampled material
volume. The regression separately checks mixed analytic/voxel layer volume,
the known declared-shape correction, the original 0.1% polygon-volume tolerance,
untouched radii and occupancy conservation. It does not shrink an untouched blank
or relax the volume tolerance to hide the old failure.

## General cylindrical meshes

R10 extracted an unconstrained halo surface and then projected exterior points
onto the cylinder. A measured bore/slot case had zero bad raw edges but ten
four-face edges after projection at the end cap. Nonlinear projection folded
small cap triangles into overlapping interior faces; collinear T-junction repair
cannot resolve those folds safely.

R11 intersects the nodal occupancy field with the declared radial distance
*before* the unchanged pinned tetrahedral extractor. The normalized radial norm
is convex. Each interpolated nodal distance bounds the true distance from above,
and the intersected field is at least that distance, so an interpolated zero
crossing stays within the cylinder. Near-zero domain nodes are biased toward air
to retain the extractor's strict nonzero contract without expanding the blank.
The existing physical-plane constraints, degenerate-face handling, collinear
repairs, edge-orientation checks and explicit budgets remain in place.

This remains a voxel cut-surface approximation. It is not exact B-rep recovery,
continuous swept collision certification or proof of arbitrary tiny features.
An invalid/open/over-budget mesh still returns an explicit failure. Errors do not
fall back to the old oversized mesh or silently cap machining holes.

## Build and link

Use `Scripts/build_native.sh` with the current Xcode explicitly selected.
`FLOE_NATIVE_XCF_OUTPUT=/absolute/private/candidate.xcframework` builds a candidate
without replacing the canonical Vendor directory. Actual compilation and
promotion must follow the repository's shared native lease.

Keep cargo's static archive unchanged. On the measured Xcode 27.2/Rust 1.98.1
combination, Apple `strip -x` removed Rust's private `.llvm` disambiguators and
created 29 duplicate symbols in a bare C link. The original archive linked
successfully. The final candidate therefore keeps its symbols and does not
require duplicate-symbol suppression or special link flags. Static archives are
larger; archive size is separate from the final linked App size.

The XCFramework contains namespaced static frameworks for the three Apple arm64
platforms. Headers/module maps, upstream pins and C++ integration are unchanged.
The final candidate passed per-slice Mach-O platform checks and actual macOS
C-ABI mesh/collision/cancellation readback before atomic canonical promotion.
Mainline owns App/UI integration, release qualification and any distribution.
