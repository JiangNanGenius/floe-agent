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
| `floe-accel graphics status` | `vulkaninfo --summary` with `DISPLAY`/`WAYLAND_DISPLAY` cleared, so pure device enumeration does not take an XCB/Wayland WSI path |
| `floe-accel graphics info` | `floe-gl-probe glx` (or `glxinfo -B`), using the current project display; it creates a context and verifies a real pixel readback |
| `floe-accel graphics egl` | `floe-gl-probe egl` (or `eglinfo`/`es2_info`); headless EGL only when the installed platform supports it |
| `floe-accel video list --json` | `floe-codec` capability query |
| `floe-accel video decode …` / `encode …` | Bounded native-codec bridge client; standard V4L2 clients use the installed driver directly |
| `floe-accel compute status` | `floe-blas-run --status` |
| `floe-accel compute mode auto` | Persist this environment's provider activation policy for new processes |
| `floe-accel compute run -- python3 script.py` | The unchanged guest program, launched with the optional standard BLAS provider |
| `floe-accel compute probe --size 512` | `floe-blas-probe`; report actual GPU submissions and CPU fallback separately |
| `floe-accel compute opencl status` | `floe-opencl-probe status`; real ICD loader/platform/device enumeration |
| `floe-accel compute opencl probe --device any` | `floe-opencl-probe run`; device fill/copy/readback/map verification, plus a compiled kernel when the device reports a compiler |
| `floe-accel blender status --json` | Guest Blender and backend capability checks |
| `floe-accel blender open --backend gpu` | Linux Blender on the existing on-demand screen |
| `floe-accel blender edit …` / `export …` / `render …` | Guest workbench commands; see `floe-accel blender --help` |

`floe-accel --capabilities` reports the single marker `floe-accel-api: 2`.
The App uses the installed dispatcher only when that marker and the requested
help entry are both present; otherwise it runs its bundled copy. This keeps an
older installed dispatcher from hiding the display-clearing and new OpenGL/
OpenCL entries while preserving its old JSON output for direct callers.

The dispatcher's `status --json` stays on schema 1. It scans the actual
`/dev/dri/card*`, `/dev/dri/renderD*` and `/dev/video*` nodes instead of fixed
indexes, so a valid non-default node is not missed. Decoder/encoder presence is
not inferred from a V4L2 node index; `floe-codec` reports the supported roles.
New keys are additive and optional for older readers. Choose Install Acceleration Tools in the terminal to install the utilities offline in the selected Linux project. The installer provides:

- `/usr/local/bin/floe-accel` (this dispatcher)
- `/usr/local/bin/floe-gl-probe` (`graphics/floe_gl_probe.py`)
- `/usr/local/bin/floe-opencl-probe` (`opencl/tools/floe_opencl_probe.py`)

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
OpenCL is only reported after the system loader returns a platform and a
device. The probe does not create an ICD from a filename, does not turn a CPU
device into GPU acceleration and does not claim kernel support when the device
reports no compiler. The OpenCL runtime remains an image component; installing
the App tools adds the probe, not a GPU OpenCL driver. Renderer strings alone
are not hardware proof: the GL probe records the actual renderer and whether
the pixel readback and classification are software, hardware or unknown.

VM RAM and GPU allocation settings remain in the existing environment settings.
