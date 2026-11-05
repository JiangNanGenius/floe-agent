# Shared ARM64 Linux image

The App uses one interpreted ARM64 machine and a read-only Debian 13 base.
Each resolved project has a persistent writable overlay and its own mount,
PID, IPC, UTS, network and task-cgroup lifecycle. This separates dependency,
data and process lifetimes; it is not a native-code security sandbox.
Commands retain the existing shell, PTY and background-job services.

CPU topology is reserved at boot; the online CPU count can change without reboot.
RAM changes require stopping the shared runtime. CPU and RAM are shared settings: 1–4 online cores and 256–1024 MiB. A task inherits
that physical budget, with a bounded process count and whole-tree
cancellation. There are at most eight concurrent project runners. Project
files and dependency shares are distinct; shared downloads are read-only.

## Inputs and construction

boot-inputs.json pins official Debian kernel, firmware, BusyBox and module
bytes. packages.lock.tsv records exact binary and source identities. The
basic image adds no science stack beyond the existing NumPy.

1. Export the pinned ARM64 OCI layer, preserving Unix ownership, modes, links
   and device nodes. Work in a disposable Linux root.
2. Prepare /base with the exact basic package versions in the lock. Validate
   dpkg-query against it. Use the exact Debian archive/snapshot for a removed
   version; never substitute a current version. Keep copyright notices.
3. Create an ext4 disk with /base and an empty /state, 4096-byte blocks, label
   FLOE_ARM64_BASE and 16 GiB logical capacity. Check it with e2fsck.
   Never copy a used project's mutable disk into a release.
4. Build ../../runner/floe_exec.c and floe_project_supervisor.c with
   aarch64-linux-musl-gcc -std=gnu11 -O2 -static -Wall -Wextra -Werror
   -D_GNU_SOURCE. Record compiler version and exact source revision.
5. Run build-initrd.py with those binaries and pinned official packages.
   It verifies and selects only the declared boot files.
6. Record SHA-512 and sizes for firmware, kernel, initrd and clean disk in
   the existing LinuxGuestImage manifest. Declare smp_capable=true and
   max_vcpus=4 only after a real four-core boot and online CPU adjustment pass.
7. Run package-image.py. The App pins the resulting complete ZIP digest.

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
