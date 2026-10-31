# EngineeringScene qualification fixtures — origins and licenses

These files are the owned fixtures for the native App-host
`EngineeringSceneResourceWitnessTests` and the
`EngineeringPreviewSceneControlUITests` native-control path. They are copied
into both test bundles only; the production App bundle does not ship them.

## Floe-authored fixtures (MPL-2.0)

Authored by the Floe-owned generator
`Local/Private/cad106-native-closure-20261031/viewer-native-scene-resource-qualification/fixtures/generate_scene_fixtures.py`
(standard library only; deterministic for a fixed Python/zlib). The generator
writes the geometry, animation, skin, morph, instancing, PNG and `.gltf`
container bytes from first principles; there is no third-party model data and
no customer engineering data.

| File | Role |
| --- | --- |
| `scene-hierarchy.glb` | Two named scenes, three materials (one 4-quadrant PNG texture), three meshes, one `EXT_mesh_gpu_instancing` node with 3 instances, one perspective source camera, four clips (`LINEAR`/`STEP`/`CUBICSPLINE`) |
| `scene-texture-a.glb`, `scene-texture-b.glb` | One unlit textured quad each; identical geometry, different 64×64 four-quadrant PNG bytes, to prove material texture identity comes from source bytes |
| `scene-skin.glb` | Two-joint `SkinnedMesh`, one rotation clip |
| `scene-morph.glb` | One morph target, one weights clip |
| `scene-siblings.gltf`, `scene-siblings.bin`, `textures/quadrants.png` | External `.bin` plus a nested external PNG, for controlled single-file vs directory-grant association |
| `textures/quadrants-ktx2.ktx2` | UASTC KTX2 of `textures/quadrants.png` (input to `scene-ktx2.glb`) |
| `scene-meshopt.glb` | `EXT_meshopt_compression` encoding of an owned textured quad |
| `scene-ktx2.glb` | `KHR_texture_basisu` packaging of the UASTC KTX2 (owned quad) |

Owned fixture bytes are MPL-2.0, the same license as this repository.

## Khronos Draco sample

`Box.gltf` + `Box.bin` are copied byte-for-byte from:

- Repository: `https://github.com/KhronosGroup/glTF-Sample-Assets`
- Commit: `8f492390ddc7a2ae221a1369ef560589cf8c70fb` (`main`)
- Paths: `Models/Box/glTF-Draco/Box.gltf`, `Models/Box/glTF-Draco/Box.bin`
- Upstream digests (verified here):
  - `Box.gltf` `3c46acecdfa90b012ec9052d8a1dfa61358e6d56a9e333504189cc78a2de4d1b`
  - `Box.bin` `610dc6e08aba7c2720c8e4ec0578efd91cf2d88a5e638dab7811a22f0235bf2e`
- Copyright © 2017 Cesium. Licensed under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode);
  the full legal code is retained in `LICENSE-KHRONOS-BOX-CC-BY-4.0.txt`.
  No modifications were made.
- Model page: `Models/Box/README.md` in the same repository.

## Encoding tools (fixture production only, not runtime)

The App never runs these tools. They produced two fixture files, which are
then decoded in the App by the already-bundled three.js r176
`DRACOLoader`, `MeshoptDecoder`, `KTX2Loader` and `Basis` transcoder.

- `gltfpack 0.20.0` (meshoptimizer), MIT, npm tarball
  `gltfpack-0.20.0.tgz` SHA-256
  `31e91a87b4a2dbfb7fef3f49af6e5a42b13a5196f2c883b601938e2700aaea82`;
  `package/cli.js` SHA-256
  `76789855bb65e9b1384388c9dde4708b7c449cda1110f568baadd106bc9b77cc`;
  `package/library.wasm` SHA-256
  `fd17ca8e24dce896499227826c99f69e049cb0463b902fd5fe0ec15fbe990059`.
  Command for `scene-meshopt.glb`:
  `node package/cli.js -i scene-texture-a.glb -o scene-meshopt.glb -c -kn -km`
  (the npm build has no BasisU support).
  License text: `LICENSE-GLTFPACK-MIT.txt`.
- `basisu 1.16.3` (Basis Universal, Apache-2.0), npm tarball
  `basisu-1.16.3.tgz` SHA-256
  `b79c0b858730a0bc89a9ac2926195a49082b5af1b4c66f03440655374161e8ca`;
  macOS arm64 binary SHA-256
  `11c385f91b503be3270335f748bb269471b343c8e69bf24c32f0c66d4720daff`.
  Command for `textures/quadrants-ktx2.ktx2`:
  `basisu -ktx2 -uastc -ktx2_no_zstandard -output_file textures/quadrants-ktx2.ktx2 textures/quadrants.png`.
  The KTX2 container has `vkFormat == VK_FORMAT_UNDEFINED` (Basis UASTC,
  color model 166, supercompression NONE), so the App's Basis transcoder path
  is exercised, not a raw-format passthrough.
  License text: `LICENSE-BASISU-APACHE-2.0.txt`.

## Integrity

The test files pin the source digest through `FloeDigest.sha256Hex` at run
time and refuse a fixture whose declared digest changes. The packet
`MANIFEST.json` records the exact SHA-256 of every fixture and license file.
