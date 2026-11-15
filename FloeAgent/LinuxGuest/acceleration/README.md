# Linux acceleration entrypoints

`floe-accel` runs inside the resolved Linux environment. Install it as
`/usr/local/bin/floe-accel` (0755) in the clean base image or an owned guest
environment. It starts no display or desktop by itself. Interactive clients
inherit the project's existing `DISPLAY`; open Floe's Screen when needed.

The dispatcher preserves arguments and child exit status. Missing components
fail with exit 69. Non-Linux hosts fail with exit 126 before any backend runs.
File/device presence in `status --json` is an inventory, not acceleration proof.

| Entry | Actual guest implementation |
| --- | --- |
| `floe-accel graphics status` | `vulkaninfo --summary` |
| `floe-accel graphics info` | `glxinfo -B`, using the current project display |
| `floe-accel video list --json` | `floe-codec` capability query |
| `floe-accel video decode …` / `encode …` | Bounded native-codec bridge client; standard V4L2 clients use the installed driver directly |
| `floe-accel compute status` | `floe-blas-run --status` |
| `floe-accel compute mode auto` | Persist this environment's provider activation policy for new processes |
| `floe-accel compute run -- python3 script.py` | The unchanged guest program, launched with the optional standard BLAS provider |
| `floe-accel compute probe --size 512` | `floe-blas-probe`; report actual GPU submissions and CPU fallback separately |
| `floe-accel blender status --json` | Guest Blender and backend capability checks |
| `floe-accel blender open --backend gpu` | Linux Blender on the existing on-demand screen |
| `floe-accel blender edit …` / `export …` / `render …` | Guest workbench commands; see `floe-accel blender --help` |

The BLAS provider accelerates supported standard BLAS operations. Elementwise
Python/NumPy loops, unsupported shapes or types and ordinary CPU code retain
their CPU path. Installed Vulkan libraries alone do not prove that NumPy used
the GPU. An already running process retains its loaded libraries; use a new
process after changing provider policy. The optional runner hook wraps only
actual task children, leaving the shared runner and supervisor unpreloaded.

The Terminal's Graphics and acceleration panel routes through the same Linux
command and environment lease services as ordinary execution. A Blender launch
gets a separate managed shell session, so it cannot inject input into an active
terminal. Closing the panel cancels short queries; it does not stop Blender.
Stop Blender explicitly or let environment teardown close its owned session.

Blender GPU requests must report unsupported capabilities rather than silently
use software graphics. Software graphics is a separate user choice. Video
hardware output and native software output are counted separately by the host.
VM RAM and GPU allocation settings remain in the existing environment settings.
