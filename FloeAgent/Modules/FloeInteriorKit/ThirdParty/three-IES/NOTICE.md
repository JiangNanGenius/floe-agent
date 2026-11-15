# IES field and symmetry reference

`FloeBuildingAnalysis/IESPhotometry.swift` adapts the LM-63 field layout and angular symmetry handling from the MIT-licensed three.js IES loader. Copyright 2010–2026 three.js authors; the complete MIT license is retained beside this notice.

Fixed input: `mrdoob/three.js` revision `00e83040432badf3e9b0dccf90ae57da65033d21`, `examples/jsm/loaders/IESLoader.js`, SHA256 `53238ccd54f20d4a3af09d1ee5d4a0fbb839d694e2bb4ac96715191f49d1908a`.

The Swift adaptation preserves absolute candela instead of the upstream rendering texture's peak normalization. It adds bounded numeric parsing and rejects unsupported tilt/goniometer/angle coverage instead of guessing. It does not embed the three.js renderer. Supporting a measured distribution is distinct from validating a complete illumination simulation.
