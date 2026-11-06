// SPDX-License-Identifier: MIT OR Apache-2.0
// Floe native machining core — frozen C ABI (CONTRACT.md 2026-11-04).
//
// Provenance:
//  * upstream/kinematics/* — OpenMill charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6,
//    byte-identical, MIT license option (upstream/LICENSE-MIT).
//  * src/ac.rs — Floe bounded physical adapter around that chain (adapted from the
//    component-qualified stage at e38-ac-trunnion-kinematics-20261103).
//  * src/sdf.rs — mechanical Rust port of the pinned MIT MillSimSharp
//    finite-cylinder cutter geometry (3cdd4f54ef94e6b95f2a149dad246b4e73aad4e9).
//  * src/tetra.rs — mechanical Rust port of the pinned MIT marching-tetrahedra
//    mesher (mikolalysenko/isosurface@22eba3c8 via PinnedTetrahedralSurface.cs).
//  * src/collision.rs — native Parry3d 0.17.6 queries (OpenMill declares parry3d 0.17).
//
// Errors and panics never cross the C boundary: every entry point returns a
// newly allocated UTF-8 JSON object; failures are exactly {"ok":false,...}.
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

mod ac;
mod assembly;
mod bounded_mesh;
pub(crate) mod cam;
mod collision;
mod core;
#[allow(dead_code)]
mod kinematics;
pub use kinematics::types::PostConfig;
mod machine;
mod model;
mod sdf;
mod stock;
mod tetra;
#[path = "../upstream/tool_holder.rs"]
mod upstream_tool_holder;

// R4 CAM upstream extracts (OpenMill@0432a8c, MIT; see upstream/r4/README.md
// for the per-file provenance and change map).
pub(crate) mod upstream_r4;

pub use core::Fail;
use model::failure_json;

pub type ProgressFn = extern "C" fn(*mut c_void, f64, *const c_char) -> i32;

/// Throttled, cancellation-aware progress reporter. No callbacks are made
/// after the synchronous entry point returns.
pub struct Progress {
    cb: Option<ProgressFn>,
    ctx: *mut c_void,
}

impl Progress {
    fn new(cb: Option<ProgressFn>, ctx: *mut c_void) -> Self {
        Progress { cb, ctx }
    }

    pub fn report(&self, fraction: f64, phase: &str) -> Result<(), Fail> {
        if let Some(cb) = self.cb {
            let cphase = CString::new(phase).unwrap_or_else(|_| CString::new("phase").unwrap());
            let rc = cb(self.ctx, fraction, cphase.as_ptr());
            if rc != 0 {
                return Err(Fail::Cancelled);
            }
        }
        Ok(())
    }

    pub fn quiet() -> Self {
        Progress {
            cb: None,
            ctx: std::ptr::null_mut(),
        }
    }
}

fn run_guarded<F>(f: F) -> CString
where
    F: FnOnce() -> String,
{
    let result = catch_unwind(AssertUnwindSafe(f));
    match result {
        Ok(s) => CString::new(s).unwrap_or_else(|_| {
            CString::new(failure_json("internal error: result JSON contained NUL"))
                .unwrap()
        }),
        Err(_) => CString::new(failure_json("internal error: panic contained at the C ABI"))
            .unwrap(),
    }
}

unsafe fn read_request(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null request_json pointer".into());
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(|s| s.to_string())
        .map_err(|_| "request_json is not valid UTF-8".to_string())
}

#[no_mangle]
pub extern "C" fn fm_core_execute(
    request_json: *const c_char,
    callback: Option<ProgressFn>,
    context: *mut c_void,
) -> *mut c_char {
    let out = run_guarded(|| {
        let request = match unsafe { read_request(request_json) } {
            Ok(r) => r,
            Err(e) => return failure_json(&e),
        };
        let progress = Progress::new(callback, context);
        match core::run_core(&request, &progress) {
            Ok(result) => serde_json::to_string(&result)
                .unwrap_or_else(|e| failure_json(&format!("result serialization failed: {e}"))),
            Err(Fail::Cancelled) => failure_json("cancelled"),
            Err(Fail::Message(m)) => failure_json(&m),
        }
    });
    out.into_raw()
}

#[no_mangle]
pub extern "C" fn fm_core_ac(
    request_json: *const c_char,
    callback: Option<ProgressFn>,
    context: *mut c_void,
) -> *mut c_char {
    let out = run_guarded(|| {
        let request = match unsafe { read_request(request_json) } {
            Ok(r) => r,
            Err(e) => return failure_json(&e),
        };
        let progress = Progress::new(callback, context);
        match ac::run_ac(&request, &progress) {
            Ok(result) => serde_json::to_string(&result)
                .unwrap_or_else(|e| failure_json(&format!("result serialization failed: {e}"))),
            Err(Fail::Cancelled) => failure_json("cancelled"),
            Err(Fail::Message(m)) => failure_json(&m),
        }
    });
    out.into_raw()
}

/*
 * R5 generalized machine-axis-chain/body collision query
 * (see r5/evidence/native-worker/API_SCHEMA.json for the exact schema):
 * serial parent-ID linear/revolute chains with rigid base frame and explicit
 * units/travel limits (unwrapped multi-turn windows), identified attached
 * solid bodies (box/cylinder/capsule/bounded mesh) plus static fixtures,
 * single or synchronized multi-joint motion with held jointPositions,
 * permitted intentional contacts excluded via allowedContactPairs, discrete
 * adaptive sampling with actual Parry3d pair queries under budget, and
 * forward-transform output per sample. FK only; no IK; continuous sweep
 * between samples is not certified.
 */
#[no_mangle]
pub extern "C" fn fm_machine_query(
    request_json: *const c_char,
    callback: Option<ProgressFn>,
    context: *mut c_void,
) -> *mut c_char {
    let out = run_guarded(|| {
        let request = match unsafe { read_request(request_json) } {
            Ok(r) => r,
            Err(e) => return failure_json(&e),
        };
        let progress = Progress::new(callback, context);
        match machine::run_machine_query(&request, &progress) {
            Ok(result) => serde_json::to_string(&result)
                .unwrap_or_else(|e| failure_json(&format!("result serialization failed: {e}"))),
            Err(Fail::Cancelled) => failure_json("cancelled"),
            Err(Fail::Message(m)) => failure_json(&m),
        }
    });
    out.into_raw()
}

#[no_mangle]
pub extern "C" fn fm_core_free(json: *mut c_char) {
    if !json.is_null() {
        unsafe {
            drop(CString::from_raw(json));
        }
    }
}
