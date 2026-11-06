// SPDX-License-Identifier: MIT OR Apache-2.0
// R4 native CAM domain (r4/CONTRACT.md + r4/native/API.md): tool library,
// explicit move model, workpiece frame, strategy generators and the shared-
// stock executor. Upstream OpenMill@0432a8c extracts live under
// crate::upstream_r4 (see upstream/r4/README.md).
pub(crate) mod exec;
pub(crate) mod frame;
pub(crate) mod moves;
pub(crate) mod partmesh;
pub(crate) mod strategies;
pub(crate) mod tools;
