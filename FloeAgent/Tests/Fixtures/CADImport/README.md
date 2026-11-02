# Static scene import fixtures

Synthetic nested cubes generated with Blender 4.5.10 LTS, build 6dc0b208d1b5. They contain no user assets. The Blender file has one animation channel intentionally outside the static import contract; only its saved frame is compared. A saved file-browser home path was nulled without changing any block offsets. Both resulting files were independently reopened in Blender and compared against the expected Y-up millimetre bounds and base colours. USD mesh names may differ from the owning transform names.

`expected.json` binds the exact input hashes. `independent-readback.json` records the independent comparison; neither is proof of native App import until the corresponding tests run. The geometry is a basic test construction, dedicated to CC0-1.0.

`world-transforms.blend` covers all six Euler orders, quaternion and axis-angle rotation, parent inverse, delta transforms and reflected scale. Its expected matrices and bounds come from Blender itself; the file-browser path was removed in the same way.
