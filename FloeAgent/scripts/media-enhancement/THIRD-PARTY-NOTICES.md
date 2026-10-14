# Third-party notices — media-enhancement conversion tooling

This directory contains host-only conversion tooling for the pinned Floe media
models. Nothing here is shipped inside the app, and no model weights are stored
in Git. The generated Core ML bundles carry their own `LICENSE.txt` notice
files (composed by `fetch_assets.py`, copied by `package_models.py`).

| Upstream project | Used for | License | Pinned revision |
| --- | --- | --- | --- |
| [XPixelGroup/BasicSR](https://github.com/XPixelGroup/BasicSR) | `RRDBNet`, `ResidualDenseBlock`, `RRDB`, `make_layer`, `pixel_unshuffle` (vendored in `rrdbnet_arch.py`) | Apache-2.0 | tag `v1.4.2`, commit `651835a1b9d38dbbdaf45750f56906be2364f01a` |
| [hzwer/Practical-RIFE](https://github.com/hzwer/Practical-RIFE) | RIFE 4.25 Lite reference code (`model/warplayer.py`) and weights archive | MIT | commit `bbfd2ea90910789a860ea3e2b32a240cd577b75e` |
| [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) | Real-ESRGAN x2plus/x4plus checkpoints and reference pipeline | BSD-3-Clause (repository license; see weights note) | commit `a4abfb2979a7bbff3f69f58f58ae324608821e27` |

## BasicSR (vendored source)

`rrdbnet_arch.py` is a minimally patched copy of
`basicsr/archs/rrdbnet_arch.py` at the pinned commit:

- upstream file sha256 `6aa8eb3f77e918b90eeff4ebfaf8745abe0c40eb8fcc03abbc1928693d70ab58`
- helper file `basicsr/archs/arch_util.py` sha256
  `45b322b874057c4bff382cc8f1b64554857b9aa4e0c47e73fe67e4afc0b28ac1`
- full license text: `rrdbnet_arch.LICENSE.txt` (upstream `LICENSE.txt`, sha256
  `5447872f21ddc29dc0dc060d5c885513c01c904e9da9931bba69898a6fb4d415`;
  the repository path `LICENSE` is a directory, not a file)

Local patches (no math changes): registry import/decorator dropped, `make_layer`
and `pixel_unshuffle` inlined from the same commit, the random
`default_init_weights` call in `ResidualDenseBlock.__init__` dropped in favor of
a no-op shim (the pinned checkpoint is always loaded), docstring/quote
normalization only.

Verification:

```sh
Local/Scratch/media-enhancement/venv/bin/python \
  FloeAgent/scripts/media-enhancement/verify_rrdbnet_source.py \
  --fetch-dir <scratch>/rrdbnet-upstream \
  --vendored FloeAgent/scripts/media-enhancement/rrdbnet_arch.py \
  --output <evidence>/rrdbnet-source-verification.json
```

This checks the pinned hashes, compares every math-bearing function node for
node, and (with torch) requires bit-identical outputs for scale 2 and scale 4.

## Practical-RIFE (code and weights)

- commit `bbfd2ea90910789a860ea3e2b32a240cd577b75e`; `LICENSE` sha256
  `7932fb49341512b959b1744a6d9cbb39e5a1ec89da438a34d0454d5d8df9fecd`.
- The pinned README states: “The content of these links is under the same MIT
  license as this project.” (README sha256
  `b695ac5d4a69c2f551512678883f8234d784c286d805ca546f4873cb465959b4`), so the
  weights archive published through that README is recorded as MIT.
- weights archive sha256
  `e84366c23e0eb1a637a55aad2e4f3442ec2bf4c388043b4aabbf590be289e6e8`;
  converted checkpoint `flownet.pkl` sha256
  `81cdba223fe72a120130cc8552e5d2ecac824259d406f0c15323b3decf96b8b1`.

## Real-ESRGAN (weights)

- commit `a4abfb2979a7bbff3f69f58f58ae324608821e27`; `LICENSE` (BSD-3-Clause)
  sha256 `4a699ec4863d96a91fc265948a0c90033f7e8735d515524dcf3444736406e0c2`.
- checkpoints: `RealESRGAN_x4plus.pth` sha256
  `4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1`,
  `RealESRGAN_x2plus.pth` sha256
  `49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb`.
- **Weights license limitation (honest):** upstream publishes no separate
  weights-specific license grant; only the repository BSD-3-Clause license
  exists. The generated bundles record this and stay local/internal until the
  rights are clarified. Do not publish the official model catalog from this
  evidence alone.

## Conversion-host dependencies

`fetch_assets.py`, `convert_*.py` and `package_models.py` run only inside the
task-owned venv (`Local/Scratch/media-enhancement/venv`) and are not app
dependencies. They import PyTorch, coremltools, NumPy and Pillow; those keep
their own upstream licenses.
