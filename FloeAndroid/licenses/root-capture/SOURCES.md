# Root capture helper sources

The Full-only root capture helper is built from these exact upstream release
archives. The build script refuses a mismatched archive and never downloads a
prebuilt binary.

| Component | Official URL | SHA-256 |
| --- | --- | --- |
| tcpdump 4.99.5 | https://www.tcpdump.org/release/tcpdump-4.99.5.tar.gz | `8c75856e00addeeadf70dad67c9ff3dd368536b2b8563abf6854d7c764cd3adb` |
| libpcap 1.10.5 | https://www.tcpdump.org/release/libpcap-1.10.5.tar.gz | `37ced90a19a302a7f32e458224a00c365c117905c2cd35ac544b6880a81488f0` |

Build inputs and output identity:

- Android NDK `30.0.16248370` (pinned by `app/build.gradle.kts`).
- Target `aarch64-linux-android28`, API 28 minimum.
- Static libpcap linked into tcpdump; no prebuilt JNI or third-party `.so`.
- `-fPIE -pie -Wl,-z,max-page-size=16384 -Wl,-z,relro -Wl,-z,now`.
- Stripped with the same NDK `llvm-strip`; source date is fixed for
  reproducible outputs.
- The helper is packaged as `lib/arm64-v8a/libfloecapture_helper.so` only in
  the **Full** variant, with a matching
  `assets/root-capture/helper.json` digest manifest. Play never packages
  either file.

The exact upstream license texts are preserved verbatim in
`tcpdump-LICENSE` and `libpcap-LICENSE`. No local source patch is applied to
either package beyond the build configuration. Corresponding source is the
unmodified upstream archive named above.

Build command:

```sh
bash scripts/root-capture/build-helper.sh --stage
```

`verify-helper.py` rejects any output that is not AArch64, PIE, 16 KiB
segment-aligned, unexpectedly linked, RPATH/RUNPATH-bearing or over the byte
cap. The generated archive digest is bound in the manifest and re-checked by
both the App preflight and the root server before execution.
