# virtio-media boot overlay and image gate

This directory assembles the guest-side video stack **from verified inputs**.
It never edits the frozen initrd, the kernel package or the base image.

## Inputs (exact pins: `config/video-module-pins.json`)

| Input | Pin |
| --- | --- |
| Debian linux-image | `linux-image-6.12.107+deb13-arm64_6.12.107-1_arm64.deb` sha256 |
| Kernel release / vermagic | `6.12.107+deb13-arm64 SMP mod_unload modversions aarch64` |
| virtio-media module | `virtio-media.ko` sha256 `fd6ea3e…61e4e3`, 1,330,816 bytes |
| Module.symvers | sha256 `4e1420af…3a2a` |
| floe-codec | source-built AArch64 ELF; actual hash recorded in the receipt |

The module source is the vendored ChromeOS driver in `../driver/`; the
primary build recipe is `../scripts/build_module.py`. The pinned `.ko` was
built once against the pinned kernel headers and loaded successfully in the
the primary's private guest evidence; this recipe
does not reimplement that build.

## Assemble

```sh
python3 boot_overlay/install_recipe.py \
  --built-ko <verified virtio-media.ko> \
  --floe-codec <verified floe-codec> \
  --symvers <pinned Module.symvers> \
  --out <overlay-dir>
```

Output:

```
lib/modules/85..NN-<stock dependency>.ko
lib/modules/NN-virtio-media.ko
lib/modules/modules.dep
usr/local/bin/floe-codec
INSTALL_RECEIPT.json
```

The dependency closure is computed from the built module's real undefined
imports through the pinned `Module.symvers`; every stock module is extracted
from the pinned image deb and hashed. Missing providers, hash mismatches and a
non-AArch64 client fail closed.

## Gate

```sh
python3 boot_overlay/image_gate.py --overlay <overlay-dir> --manifest <image-manifest.json>
```

The gate requires `deviceCapabilities.videoAcceleration == true` in the
verified image manifest, checks the receipt hashes, `modules.dep` coverage and
the installed client ELF. It does **not** prove initrd assembly, module load or
`/dev/video` operation; those remain primary runtime checks.

## Image-manifest contract

```json
"deviceCapabilities": {
  "onlineMemory": true,
  "vulkanGPU": true,
  "videoAcceleration": true
}
```

Absent/false `videoAcceleration` is not an error: the App creates a
video-disabled ABI4 machine and reports video unavailable. It may still persist
a native-software preference for a future capable image.
