// SPDX-License-Identifier: MIT OR Apache-2.0
// Host probe for the frozen C ABI. Usage:
//   fm_probe core <request.json>     — call fm_core_execute via the real FFI
//   fm_probe ac   <request.json>     — call fm_core_ac via the real FFI
// Progress callbacks are printed to stderr (throttled by the library).
use std::ffi::{c_void, CString};
use std::io::Read;

// Ensure the library rlib is linked into this example.
use FloeMachiningNative as _;

extern "C" {
    fn fm_core_execute(
        request_json: *const std::ffi::c_char,
        callback: Option<extern "C" fn(*mut c_void, f64, *const std::ffi::c_char) -> i32>,
        context: *mut c_void,
    ) -> *mut std::ffi::c_char;
    fn fm_core_ac(
        request_json: *const std::ffi::c_char,
        callback: Option<extern "C" fn(*mut c_void, f64, *const std::ffi::c_char) -> i32>,
        context: *mut c_void,
    ) -> *mut std::ffi::c_char;
    fn fm_core_free(json: *mut std::ffi::c_char);
}

extern "C" fn progress_cb(_ctx: *mut c_void, fraction: f64, phase: *const std::ffi::c_char) -> i32 {
    let phase = unsafe { std::ffi::CStr::from_ptr(phase) }
        .to_string_lossy()
        .into_owned();
    eprintln!("[progress] {fraction:.3} {phase}");
    0
}

extern "C" fn cancel_cb(_ctx: *mut c_void, _fraction: f64, _phase: *const std::ffi::c_char) -> i32 {
    1 // request cancellation immediately
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: fm_probe core|ac [request.json] (stdin when omitted)");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let mut request = String::new();
    if args.len() >= 3 {
        request = std::fs::read_to_string(&args[2]).expect("read request file");
    } else {
        std::io::stdin().read_to_string(&mut request).expect("stdin");
    }
    let creq = CString::new(request).expect("request has NUL");
    let result = unsafe {
        let ptr = match mode {
            "core" => fm_core_execute(creq.as_ptr(), Some(progress_cb), std::ptr::null_mut()),
            "core-cancel" => fm_core_execute(creq.as_ptr(), Some(cancel_cb), std::ptr::null_mut()),
            "ac" => fm_core_ac(creq.as_ptr(), Some(progress_cb), std::ptr::null_mut()),
            "ac-cancel" => fm_core_ac(creq.as_ptr(), Some(cancel_cb), std::ptr::null_mut()),
            _ => {
                eprintln!("unknown mode {mode}");
                std::process::exit(2)
            }
        };
        let s = std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned();
        fm_core_free(ptr);
        s
    };
    println!("{result}");
}
