// SPDX-License-Identifier: MPL-2.0
//! Fixed document-typesetting ABI. No arbitrary command entry point is exported.
use serde::Deserialize;
use std::{ffi::{CStr, CString, c_char, c_void}, fmt::Arguments, path::{Path, PathBuf}, sync::{atomic::{AtomicBool, AtomicPtr, AtomicU64, Ordering}, Mutex, OnceLock}, time::{Duration, Instant, UNIX_EPOCH}};
use tectonic::driver::ProcessingSessionBuilder;
use tectonic_errors::Result;
use tectonic_bridge_core::{SecuritySettings, SecurityStance};
use tectonic_status_base::{MessageKind, StatusBackend};

static RUN: Mutex<()> = Mutex::new(());
static ACTIVE_JOB: AtomicPtr<Job> = AtomicPtr::new(std::ptr::null_mut());
static EPOCH: OnceLock<Instant> = OnceLock::new();
type ProgressCallback = unsafe extern "C" fn(*const c_char, *mut c_void);
pub struct Job { cancelled: AtomicBool, deadline: AtomicU64, progress: Mutex<(Option<ProgressCallback>,usize)> }
struct ActiveGuard;
impl Drop for ActiveGuard { fn drop(&mut self) { ACTIVE_JOB.store(std::ptr::null_mut(),Ordering::Release); } }

#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Request {
    source_root: PathBuf,
    output_root: PathBuf,
    main_file: String,
    bundle_path: Option<PathBuf>,
    cache_root: PathBuf,
    expected_bundle_digest: Option<String>,
    #[serde(default="default_timeout")] timeout_seconds: u64,
    #[serde(default)] offline: bool,
}
fn default_timeout() -> u64 { 120 }
fn now() -> u64 { EPOCH.get_or_init(Instant::now).elapsed().as_millis().min(u64::MAX as u128) as u64 }
fn active() -> Option<&'static Job> { unsafe { ACTIVE_JOB.load(Ordering::Acquire).as_ref() } }
fn publish(message: &str) {
    if let Some(job)=active() {
        if let Ok(binding)=job.progress.lock() {
            if let Some(callback)=binding.0 {
                if let Ok(text)=CString::new(message) { unsafe { callback(text.as_ptr(),binding.1 as *mut c_void); } }
            }
        }
    }
}

#[derive(Default)]
struct Status { messages: Vec<String> }
impl StatusBackend for Status {
    fn report(&mut self, kind: MessageKind, args: Arguments, err: Option<&tectonic_errors::Error>) {
        if self.messages.len() < 4096 {
            let mut text = format!("{kind:?}: {args}");
            if let Some(e) = err { text.push_str(&format!(": {e:#}")); }
            text.truncate(text.floor_char_boundary(8192));
            publish(&text);
            self.messages.push(text);
        }
    }
    fn dump_error_logs(&mut self, output: &[u8]) {
        self.messages.push(String::from_utf8_lossy(&output[..output.len().min(262144)]).into_owned());
    }
}

/// Resource preparation uses its network timeout, separate from the TeX CPU budget.
struct ResourceBundle { inner: Box<dyn tectonic_bundles::Bundle> }
impl tectonic::io::IoProvider for ResourceBundle {
    fn input_open_name(&mut self,name:&str,status:&mut dyn StatusBackend)->tectonic::io::OpenResult<tectonic::io::InputHandle> {
        let start=now();
        let result=self.inner.input_open_name(name,status);
        if let Some(job)=active() { if job.deadline.load(Ordering::Acquire)!=0 { job.deadline.fetch_add(now().saturating_sub(start),Ordering::AcqRel); } }
        result
    }
}
impl tectonic_bundles::Bundle for ResourceBundle {
    fn get_digest(&mut self)->Result<tectonic::io::digest::DigestData> { self.inner.get_digest() }
    fn all_files(&self)->Vec<String> { self.inner.all_files() }
}

fn compile(request: Request, status: &mut Status) -> Result<(PathBuf,String)> {
    use tectonic_errors::prelude::*;
    let source = request.source_root.canonicalize()?;
    let relative = Path::new(&request.main_file);
    if relative.is_absolute() || relative.components().any(|c| matches!(c, std::path::Component::ParentDir)) { bail!("Invalid main file"); }
    let main = source.join(relative).canonicalize()?;
    if !main.starts_with(&source) { bail!("Main file is outside this project"); }
    let input = std::fs::read(&main)?;
    if input.len() > 16 * 1024 * 1024 { bail!("Main source exceeds the document limit"); }
    std::fs::create_dir_all(&request.output_root)?;
    std::fs::create_dir_all(&request.cache_root)?;
    let mut bundle = if let Some(path) = request.bundle_path {
        Box::new(tectonic_bundles::dir::DirBundle::new(path)) as Box<dyn tectonic_bundles::Bundle>
    } else {
        let url = tectonic_bundles::get_fallback_bundle_url(tectonic_engine_xetex::FORMAT_SERIAL);
        tectonic_bundles::detect_bundle(url, request.offline, Some(request.cache_root.join("Resources")))?
            .ok_or_else(|| tectonic_errors::Error::msg("The typesetting resource bundle is unavailable"))?
    };
    let digest = bundle.get_digest()?.to_string();
    if let Some(expected)=request.expected_bundle_digest { if expected != digest { bail!("The typesetting resource version changed; select the pinned resource bundle before rebuilding"); } }
    let mut builder = ProcessingSessionBuilder::new_with_security(SecuritySettings::new(SecurityStance::DisableInsecures));
    builder.primary_input_path(&main)
        .tex_input_name(&request.main_file)
        .filesystem_root(&source)
        .output_dir(&request.output_root)
        .format_cache_path(&request.cache_root)
        .format_name("latex")
        .bundle(Box::new(ResourceBundle{inner:bundle}))
        .keep_logs(true)
        .keep_intermediates(true)
        .synctex(true)
        .print_stdout(false)
        .build_date(UNIX_EPOCH + Duration::from_secs(1))
        .shell_escape_disabled();
    if let Some(job)=active() { job.deadline.store(now().saturating_add(request.timeout_seconds.clamp(1,600)*1000),Ordering::Release); }
    let mut session = builder.create(status)?;
    session.run(status)?;
    let mut output = request.output_root.join(relative);
    output.set_extension("pdf");
    if !output.is_file() { bail!("The engine produced no PDF"); }
    Ok((output,digest))
}

/// Called from the token scanner; cooperative engine abort stays within TeX's
/// existing exception boundary rather than unwinding through Swift frames.
#[no_mangle]
pub extern "C" fn floe_tex_checkpoint() -> i32 {
    active().map(|job| i32::from(job.cancelled.load(Ordering::Acquire) || (job.deadline.load(Ordering::Acquire)!=0 && now()>=job.deadline.load(Ordering::Relaxed)))).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn floe_tex_job_create() -> *mut Job {
    Box::into_raw(Box::new(Job{cancelled:AtomicBool::new(false),deadline:AtomicU64::new(0),progress:Mutex::new((None,0))}))
}
#[no_mangle]
pub unsafe extern "C" fn floe_tex_job_cancel(job:*mut Job) { if let Some(job)=job.as_ref() { job.cancelled.store(true,Ordering::Release); } }
#[no_mangle]
pub unsafe extern "C" fn floe_tex_job_progress(job:*mut Job,callback:Option<ProgressCallback>,context:*mut c_void) {
    if let Some(job)=job.as_ref() { if let Ok(mut binding)=job.progress.lock() { *binding=(callback,context as usize); } }
}
#[no_mangle]
pub unsafe extern "C" fn floe_tex_job_free(job:*mut Job) { if !job.is_null() { drop(Box::from_raw(job)); } }

/// The caller owns the returned UTF-8 JSON and releases it with `floe_tex_free`.
#[no_mangle]
pub unsafe extern "C" fn floe_tex_compile(request: *const c_char, job:*mut Job) -> *mut c_char {
    let mut status = Status::default();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<(PathBuf,String)> {
        let _guard = RUN.lock().map_err(|_| tectonic_errors::Error::msg("Engine state is unavailable"))?;
        if job.is_null() { return Err(tectonic_errors::Error::msg("Missing build cancellation identity")); }
        if (*job).cancelled.load(Ordering::Acquire) { return Err(tectonic_errors::Error::msg("Typesetting cancelled")); }
        ACTIVE_JOB.store(job,Ordering::Release);
        let _active_guard=ActiveGuard;
        (*job).deadline.store(0,Ordering::Release);
        if request.is_null() { return Err(tectonic_errors::Error::msg("Missing build request")); }
        let input = CStr::from_ptr(request).to_str()?;
        let request = serde_json::from_str::<Request>(input)?;
        compile(request, &mut status)
    }));
    let cancelled=job.as_ref().map(|j|j.cancelled.load(Ordering::Acquire)).unwrap_or(false);
    let response = match result {
        Ok(Ok((path,digest))) => serde_json::json!({"success":true,"engine":"xetex","version":"tectonic-0.17.0","pdfPath":path,"bundleDigest":digest,"messages":status.messages}),
        Ok(Err(error)) => serde_json::json!({"success":false,"cancelled":cancelled,"error":format!("{error:#}"),"messages":status.messages}),
        Err(_) => serde_json::json!({"success":false,"error":"The typesetting engine failed","messages":status.messages}),
    };
    CString::new(response.to_string()).unwrap_or_else(|_| CString::new("{\"success\":false}").unwrap()).into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn floe_tex_free(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}
