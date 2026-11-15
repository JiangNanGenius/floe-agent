# Floe OpenGL/GLX and headless EGL probe

`floe_gl_probe.py` is the guest-side probe used by
`floe-accel graphics info` and `floe-accel graphics egl`. Install it as
`/usr/local/bin/floe-gl-probe` (0755, `#!/usr/bin/env python3`). It has no
build step and uses only the EGL/GLX/GL libraries already present in the image.

## What it proves

- `glx` opens the project's actual X display, creates a GLX context and a
  framebuffer/pbuffer, clears a 16x16 RGBA region, reads the pixels back and
  requires an exact match. The report carries the renderer, version, vendor,
  GLX version and the readback bytes.
- `egl` requests a surfaceless/platform EGL display, creates a context and a
  pbuffer or FBO, performs the same clear/readback and reports the EGL
  vendor/version when available.
- `hardware` is `true` only for known hardware renderer markers, `false` for
  known software markers (llvmpipe/softpipe/swrast/lavapipe) and `null` when
  the renderer string alone cannot establish it. A renderer string is never
  presented as proof of GPU acceleration.

Exit codes: `0` context/render/readback verified, `2` usage, `69` required
display/library/platform unavailable, `70` context/render/readback failed.
The JSON object is printed in every case, including failure.

## Limits

- A software renderer can pass the pixel check; it is reported as software,
  not as GPU acceleration.
- The probe does not start Xvnc, a desktop or a Wayland compositor. `glx`
  requires the project screen/`DISPLAY`; `egl` is headless only when the
  installed EGL platform actually supports surfaceless/pbuffer operation.
- No conformance, performance or App/iPad acceptance claim. Real v8 evidence
  with Xvnc/llvmpipe is recorded separately as private qualification evidence;
  it is not a GPU claim.
