# Shared ARM64 Linux image

The App uses one interpreted ARM64 machine and a read-only Debian 13 base.
Each resolved project has a persistent writable overlay, an owned runner,
and task mount, IPC, UTS and cgroup lifetimes. This separates dependency,
data and process lifetimes; it is not a native-code security sandbox.
Commands retain the existing shell, PTY and background-job services.

CPU topology is reserved at boot; the online CPU count can change without reboot.
Images declaring `deviceCapabilities.onlineMemory` carry the pinned virtio-mem
driver and the explicit memory-online policy: RAM can grow while projects run.
A lower target waits while project leases remain active; existing work is not
killed to force a shrink. Older images retain their fixed-RAM behavior.
CPU and RAM are shared settings: 1–4 online cores and 256–1024 MiB. A task inherits
that physical budget, with a bounded process count and whole-tree
cancellation. There are at most eight concurrent project runners. Project
files and dependency shares are distinct; shared downloads are read-only.

GPU-capable images use Mesa Venus and Zink with the standard virtio-GPU render
node. The host budget defaults to 1 GiB, allocated on demand; a live budget
change preserves existing resources and does not resize the fixed GPU address
aperture. Only the verified virtual render node is exposed to a project,
including the pinned kernel's MMIO parent/virtio-child layout.

The screen starts on demand through the existing local-service lifecycle.
TigerVNC and xterm provide a window without a desktop session. A project gets
its own X11 display number; commands retain their private temporary directory
and IPC namespace. The display launcher uses that project display and a
transient password file, rather than passing its contents in arguments.
Closing the viewer leaves the service available; stopping the screen ends its
owned process tree. Actual accelerated window presentation and App behavior
require separate qualification from Vulkan compute or offscreen rendering.

## Inputs and construction

boot-inputs.json pins official Debian kernel, firmware, BusyBox and module
bytes. packages.lock.tsv records exact binary and source identities. The
basic image adds no science stack beyond the existing NumPy.

1. Export the pinned ARM64 OCI layer, preserving Unix ownership, modes, links
   and device nodes. Work in a disposable Linux root.
2. Prepare /base with the exact basic package versions in the lock. Validate
   dpkg-query against it. Use the exact Debian archive/snapshot for a removed
   version; never substitute a current version. Keep copyright notices.
   Run `python3 prepare-package-sources.py --root /path/to/clean/base`, then
   the same command with `--check`. This uses the App's single reviewed
   `Sources/FloeExecution/Resources/LinuxPackageSources.json` catalog:
   official Debian is selected and Tsinghua TUNA is prepared. Both APT
   profiles and the official/TUNA single-index PyPI config files live in
   `/etc/floe/package-sources`; the same catalog is copied into
   `/usr/share/floe/package-sources.json`. Debian security stays official,
   with Debian archive keyring validation and HTTPS. No extra PyPI index or
   TLS/signature bypass is configured.
   Keep Debian's normal `/etc/apt/sources.list` and `sources.list.d` paths:
   do not install a global `Dir::Etc` override. The recipe manages only a
   recognized Debian distribution file, saves its exact original bytes and
   leaves other repositories effective. Ordinary `exec.shell` commands may
   add, edit or select repositories; preset IDs and Settings are convenient
   choices, not a CLI repository allowlist. Only explicit preset selection
   migrates a recognized older Floe path override; inspection is read-only.
   Never prepare an image from a used environment. New bytes require a new
   actual qualification run, ID/manifest/archive, rather than relabeling an
   old frozen image. The real guest qualification must read `apt-config
   shell SOURCE Dir::Etc::sourcelist/f PARTS Dir::Etc::sourceparts/d`, verify
   TUNA selection and restoration, and confirm an added ordinary source file
   remains discoverable. Qualify the existing production managed venv/pip
   path with the same source presets.
3. Create an ext4 disk with /base and an empty /state, 4096-byte blocks, label
   FLOE_ARM64_BASE and 16 GiB logical capacity. Check it with e2fsck.
   Never copy a used project's mutable disk into a release.
4. Build ../../runner/floe_exec.c and floe_project_supervisor.c with
   aarch64-linux-musl-gcc -std=gnu11 -O2 -static -Wall -Wextra -Werror
   -D_GNU_SOURCE. Record compiler version and exact source revision.
   For a display-capable image, install ../../runner/floe-display-start at
   `/base/usr/local/libexec/floe-display-start` with mode 0755. Resolve the
   exact TigerVNC, xterm, Mesa/Vulkan and shared-library package versions
   from packages.lock.tsv through a real APT/dpkg transaction. Keep the base
   clean and `/state` empty; do not bake a test project or running screen in.
5. Run build-initrd.py with those binaries and pinned official packages.
   It verifies and selects only the declared boot files.
6. Record SHA-512 and sizes for firmware, kernel, initrd and clean disk in
   the existing LinuxGuestImage manifest. Declare smp_capable=true and
   max_vcpus=4 only after a real four-core boot and online CPU adjustment pass.
7. Run package-image.py. The App pins the resulting complete ZIP digest.

`prepare-gpu-inputs.py` prepares a separate boot-input candidate containing
the DRM/virtio-gpu modules from the exact pinned kernel package. It verifies
module digests, architecture, dependencies and matching build identities;
it neither replaces the current lock nor qualifies or publishes an image.
For example:

    python3 prepare-gpu-inputs.py --kernel-deb /path/to/pinned-kernel.deb --out /path/to/boot-inputs.gpu.json
    python3 prepare-gpu-inputs.py --kernel-deb /path/to/pinned-kernel.deb --out /path/to/boot-inputs.gpu.json --check

The second command is read-only. Pass `--boot-inputs` to extend a separately
prepared online-memory candidate while preserving its existing pins.

The project runner supplies `VN_PERF=no_async_mem_alloc` and the pinned Venus
ICD for a real virtual render node. This makes allocation failure synchronous
at the host's resource budget. Images carrying the reviewed private Mesa pair
select the `floe` GLVND vendor and `/usr/lib/floe-gpu` driver for GL clients.
The normal system Mesa remains installed. The Xvnc server drops those
client-only settings and its inherited `DISPLAY`; its display is supplied as
an argument. This prevents the implicit device-selection layer from trying
to connect to the server itself before the event loop starts. The xterm and
ordinary clients retain their project `DISPLAY`. Older GPU images keep their
original Zink loader defaults. See `gpu-mesa/` for exact source/build pins,
the readback patch and all license notices.

`DISPLAY` only identifies the on-demand project screen; setting it starts no
server. Headless enumeration tools can explicitly clear it. GPU rendering is
followed by CPU pixel readback for the viewer; correct presentation requires
actual changing pixels and the application's real hardware renderer.

Runner 2.2.0 keeps protocol 3 and advertises `serviceTree=cgroup-v1` only in a
usable project cgroup2 runtime. `KILL` acknowledges termination scheduling;
`ALIVE` stays true until the leader is reaped and the owned cgroup is proven
empty. A failed proof retains ownership for retry. Nonisolated runtimes report
`process-group-v1`, which cannot prove termination of setsid descendants.
The App must check the actual capability and keep the same runtime identity
before releasing service state, forwards, display files and environment leases.

The downloadable image catalog is compiled into the App and pins exact
archive identities. Add a GPU image only to an App containing the native GPU
backend, viewer and tree-stop consumer; retain the separate basic-v3 entry
for older clients. A device-capability declaration alone does not supply a
missing native backend. Record the first actual App version/build at release
freeze; do not reuse a content package's version floor.

Kernel command line (the owner replaces maxcpus with the saved core count):

    earlycon=pl011,0x9000000 console=ttyAMA0 rdinit=/init maxcpus=2 floe.base=/mnt/base floe.state=/mnt/state floe.runner=/usr/local/bin/floe-exec floe.workspace=/workspace

Firmware, kernel and initrd are verified with the image. There is no separate
bundled RISC-V boot-pair update.

## Corresponding source

Reuse ../debian-source-map.py with packages.lock.tsv to resolve, fetch and
SHA-256-check exact Debian source packages. Include boot-only BusyBox, its
Built-Using glibc, the kernel and EDK2. Resolve index gaps from exact snapshots.
Publish mappings, original descriptors, source files and checksums with the
component, this recipe and runner source. Package copyright notices remain
authoritative. Floe runner is MPL-2.0; musl is MIT; libgcc runtime exceptions
apply. Keep those notices in the source bundle.

## Restore and lifetime

Restore initial state stops and joins owned work, durably fences admission,
replaces dependency layers and atomically swaps the managed working disk.
It retains project files, chats, installed Skill records and shared downloads.
An interrupted restore stays unavailable until retried. Re-download verifies
a fresh archive without replacing project data.

The cutover does not execute or migrate RISC-V binaries. Existing incompatible
environments must be restored before use. Completed history retains its old
target; resumable bindings refresh only after restore commits. A Mac Bridge
task does not download or start this image.
