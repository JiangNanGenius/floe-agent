// SPDX-License-Identifier: MPL-2.0
use std::ffi::{CStr, CString, c_char};
use std::path::Path;
use std::ptr;

#[repr(C)]
pub struct FloeFontResult {
    pub bytes: *mut u8,
    pub length: usize,
    pub error: *mut c_char,
}

fn failure(message: String) -> FloeFontResult {
    let message = message.replace('\0', "");
    FloeFontResult { bytes: ptr::null_mut(), length: 0, error: CString::new(message).unwrap().into_raw() }
}

/// Compiles an already-authorized, staged UFO/Designspace source. The Swift
/// service owns confinement, archive extraction, lifecycle and export approval.
/// No process, shell, interpreter or downloaded executable is invoked.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_font_compile(source_path: *const c_char) -> FloeFontResult {
    let result = std::panic::catch_unwind(|| {
        if source_path.is_null() { return Err("Missing staged font source".to_string()); }
        let source = unsafe { CStr::from_ptr(source_path) }.to_str().map_err(|_| "Invalid source path".to_string())?;
        let input = fontc::Input::new(Path::new(source)).map_err(|e| e.to_string())?;
        let source = input.create_source().map_err(|e| e.to_string())?;
        fontc::generate_font(source, fontc::Options::default()).map_err(|e| e.to_string())
    });
    match result {
        Ok(Ok(bytes)) => { let slice = bytes.into_boxed_slice(); let length = slice.len();
            FloeFontResult { bytes: Box::into_raw(slice) as *mut u8, length, error: ptr::null_mut() } },
        Ok(Err(error)) => failure(error),
        Err(_) => failure("Font compilation failed".to_string()),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_font_result_free(result: FloeFontResult) {
    if !result.bytes.is_null() {
        let slice = ptr::slice_from_raw_parts_mut(result.bytes, result.length);
        unsafe { drop(Box::from_raw(slice)); }
    }
    if !result.error.is_null() { unsafe { drop(CString::from_raw(result.error)); } }
}
