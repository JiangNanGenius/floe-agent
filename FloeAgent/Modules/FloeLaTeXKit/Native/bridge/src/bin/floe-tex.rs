// SPDX-License-Identifier: MPL-2.0
//! Development-only host runner using the exact embedded library ABI.
use std::{env, ffi::{CStr, CString}};
fn main() {
    let args:Vec<String>=env::args().collect();
    let request = args.get(1).expect("usage: floe-tex request.json [--repeat=N] [--cancel-ms=N] [--pre-cancel]");
    let data = std::fs::read_to_string(request).expect("read build request");
    let input = CString::new(data).expect("valid UTF-8 request");
    let repeats=args.iter().find_map(|a|a.strip_prefix("--repeat=")).and_then(|x|x.parse::<usize>().ok()).unwrap_or(1).clamp(1,20);
    for _ in 0..repeats { unsafe {
        let job=floe_tex_native::floe_tex_job_create();
        if args.iter().any(|a|a=="--pre-cancel") { floe_tex_native::floe_tex_job_cancel(job); }
        let cancellation=args.iter().find_map(|a|a.strip_prefix("--cancel-ms=")).and_then(|x|x.parse::<u64>().ok()).map(|ms|{
            let identity=job as usize;
            std::thread::spawn(move||{std::thread::sleep(std::time::Duration::from_millis(ms));floe_tex_native::floe_tex_job_cancel(identity as *mut floe_tex_native::Job);})
        });
        let result = floe_tex_native::floe_tex_compile(input.as_ptr(),job);
        if let Some(thread)=cancellation { thread.join().unwrap(); }
        let text = CStr::from_ptr(result).to_string_lossy().into_owned();
        println!("{text}");
        floe_tex_native::floe_tex_free(result);
        floe_tex_native::floe_tex_job_free(job);
        let json: serde_json::Value = serde_json::from_str(&text).unwrap();
        if json["success"] != true { std::process::exit(1); }
    }}
}
