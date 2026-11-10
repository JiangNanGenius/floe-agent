// SPDX-License-Identifier: MPL-2.0
//! Fixed document-typesetting ABI. No arbitrary command entry point is exported.
mod display_list;
mod legacy;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::{
    ffi::{c_char, c_void, CStr, CString},
    fmt::Arguments,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicPtr, AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    time::{Instant, SystemTime},
};
use tectonic::driver::ProcessingSessionBuilder;
use tectonic_bridge_core::{SecuritySettings, SecurityStance};
use tectonic_errors::Result;
use tectonic_status_base::{MessageKind, StatusBackend};

static RUN: Mutex<()> = Mutex::new(());
static ACTIVE_JOB: AtomicPtr<Job> = AtomicPtr::new(std::ptr::null_mut());
static EPOCH: OnceLock<Instant> = OnceLock::new();
type ProgressCallback = unsafe extern "C" fn(*const c_char, *mut c_void);
pub struct Job {
    cancelled: AtomicBool,
    deadline: AtomicU64,
    progress: Mutex<(Option<ProgressCallback>, usize)>,
    output_root: Mutex<Option<PathBuf>>,
    assets: Mutex<BTreeMap<String, serde_json::Value>>,
}
struct ActiveGuard;
impl Drop for ActiveGuard {
    fn drop(&mut self) {
        ACTIVE_JOB.store(std::ptr::null_mut(), Ordering::Release);
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    #[serde(default)]
    mode: Option<String>,
    source_root: PathBuf,
    output_root: PathBuf,
    main_file: String,
    bundle_path: Option<PathBuf>,
    cache_root: PathBuf,
    expected_bundle_digest: Option<String>,
    #[serde(default = "default_timeout")]
    timeout_seconds: u64,
    #[serde(default)]
    offline: bool,
    #[serde(default = "default_resource_timeout")]
    resource_timeout_seconds: u64,
    #[serde(default = "default_resource_total_timeout")]
    resource_total_timeout_seconds: u64,
}
fn default_timeout() -> u64 {
    120
}
fn default_resource_timeout() -> u64 {
    60
}
fn default_resource_total_timeout() -> u64 {
    600
}
fn network_cancelled() -> bool {
    active()
        .map(|job| job.cancelled.load(Ordering::Acquire))
        .unwrap_or(true)
}
fn network_started() {
    publish("FLOE_TEX_RESOURCE_DOWNLOAD");
}

fn now() -> u64 {
    EPOCH
        .get_or_init(Instant::now)
        .elapsed()
        .as_millis()
        .min(u64::MAX as u128) as u64
}
fn active() -> Option<&'static Job> {
    unsafe { ACTIVE_JOB.load(Ordering::Acquire).as_ref() }
}
fn publish(message: &str) {
    if let Some(job) = active() {
        if let Ok(binding) = job.progress.lock() {
            if let Some(callback) = binding.0 {
                if let Ok(text) = CString::new(message) {
                    unsafe {
                        callback(text.as_ptr(), binding.1 as *mut c_void);
                    }
                }
            }
        }
    }
}

#[derive(Default)]
struct Status {
    messages: Vec<String>,
}
impl StatusBackend for Status {
    fn report(&mut self, kind: MessageKind, args: Arguments, err: Option<&tectonic_errors::Error>) {
        if self.messages.len() < 4096 {
            let mut text = format!("{kind:?}: {args}");
            if let Some(e) = err {
                text.push_str(&format!(": {e:#}"));
            }
            text.truncate(text.floor_char_boundary(8192));
            publish(&text);
            self.messages.push(text);
        }
    }
    fn dump_error_logs(&mut self, output: &[u8]) {
        self.messages
            .push(String::from_utf8_lossy(&output[..output.len().min(262144)]).into_owned());
    }
}

/// Resource preparation uses its network timeout, separate from the TeX CPU budget.
struct ResourceBundle {
    inner: Box<dyn tectonic_bundles::Bundle>,
}
impl tectonic::io::IoProvider for ResourceBundle {
    fn input_open_name(
        &mut self,
        name: &str,
        status: &mut dyn StatusBackend,
    ) -> tectonic::io::OpenResult<tectonic::io::InputHandle> {
        let start = now();
        let result = self.inner.input_open_name(name, status);
        if let Some(job) = active() {
            if job.deadline.load(Ordering::Acquire) != 0 {
                job.deadline
                    .fetch_add(now().saturating_sub(start), Ordering::AcqRel);
            }
        }
        result
    }
}
impl tectonic_bundles::Bundle for ResourceBundle {
    fn get_digest(&mut self) -> Result<tectonic::io::digest::DigestData> {
        let start = now();
        let result = self.inner.get_digest();
        if let Some(job) = active() {
            if job.deadline.load(Ordering::Acquire) != 0 {
                job.deadline
                    .fetch_add(now().saturating_sub(start), Ordering::AcqRel);
            }
        }
        result
    }
    fn all_files(&self) -> Vec<String> {
        self.inner.all_files()
    }
}

fn open_bundle(request: &Request) -> Result<Box<dyn tectonic_bundles::Bundle>> {
    if let Some(path) = &request.bundle_path {
        Ok(Box::new(tectonic_bundles::dir::DirBundle::new(
            path.clone(),
        )))
    } else {
        let url = tectonic_bundles::get_fallback_bundle_url(tectonic_engine_xetex::FORMAT_SERIAL);
        let mut bundle = tectonic_bundles::detect_bundle(
            url,
            request.offline,
            Some(request.cache_root.join("Resources")),
        )?
        .ok_or_else(|| {
            tectonic_errors::Error::msg("The typesetting resource bundle is unavailable")
        })?;
        // Resolve only this document's engine/font requests, even when another
        // document left a learned prefetch manifest in the shared cache.
        bundle.disable_prefetch();
        Ok(bundle)
    }
}

fn compile(request: Request, status: &mut Status) -> Result<(PathBuf, PathBuf, String)> {
    use tectonic_errors::prelude::*;
    if !matches!(
        request.mode.as_deref(),
        None | Some("compile") | Some("prepare")
    ) {
        bail!("Invalid native typesetting mode")
    }
    let source = request.source_root.canonicalize()?;
    let relative = Path::new(&request.main_file);
    if relative.is_absolute()
        || relative
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        bail!("Invalid main file")
    }
    let main = source.join(relative).canonicalize()?;
    if !main.starts_with(&source) {
        bail!("Main file is outside this project")
    }
    if std::fs::metadata(&main)?.len() > 16 * 1024 * 1024 {
        bail!("Main source exceeds the document limit")
    }
    std::fs::create_dir_all(&request.output_root)?;
    std::fs::create_dir_all(&request.cache_root)?;
    let output_root = request.output_root.canonicalize()?;
    if output_root.starts_with(&source) || source.starts_with(&output_root) {
        bail!("Output must be independent of the immutable source snapshot")
    }
    if let Some(job) = active() {
        *job.output_root
            .lock()
            .map_err(|_| tectonic_errors::Error::msg("Native asset owner unavailable"))? =
            Some(output_root.clone());
    }
    publish("FLOE_TEX_RESOURCE_CHECK");
    let mut bundle = open_bundle(&request)?;
    let digest = bundle.get_digest()?.to_string();
    if let Some(expected) = &request.expected_bundle_digest {
        if expected != &digest {
            bail!("The typesetting resource version changed; use the pinned resource bundle")
        }
    }
    let mut builder = ProcessingSessionBuilder::new_with_security(SecuritySettings::new(
        SecurityStance::DisableInsecures,
    ));
    builder
        .primary_input_path(&main)
        .tex_input_name(&request.main_file)
        .filesystem_root(&source)
        .output_dir(&output_root)
        .format_cache_path(&request.cache_root)
        .format_name("latex")
        .bundle(Box::new(ResourceBundle { inner: bundle }))
        .keep_logs(true)
        .keep_intermediates(true)
        .output_format(tectonic::driver::OutputFormat::Xdv)
        .synctex(true)
        .print_stdout(false)
        .build_date(SystemTime::now())
        .shell_escape_disabled();
    if let Some(job) = active() {
        job.deadline.store(
            now().saturating_add(request.timeout_seconds.clamp(1, 600) * 1000),
            Ordering::Release,
        );
    }
    let mut session = builder.create(status)?;
    session.run(status)?;
    if floe_tex_checkpoint() != 0 {
        bail!("Native typesetting cancelled or exceeded its CPU budget")
    }
    let mut xdv = output_root.join(relative);
    xdv.set_extension("xdv");
    if !xdv.is_file() {
        bail!("The engine produced no XDV")
    }
    let mut resources: Box<dyn tectonic_bundles::Bundle> = Box::new(ResourceBundle {
        inner: open_bundle(&request)?,
    });
    if resources.get_digest()?.to_string() != digest {
        bail!("Resource bundle changed during native typesetting")
    }
    let list = display_list::write(&xdv, &output_root, &source, resources.as_mut(), status)?;
    if floe_tex_checkpoint() != 0 {
        bail!("Native typesetting cancelled or exceeded its CPU budget")
    }
    publish("FLOE_TEX_RESOURCE_READY");
    Ok((xdv, list, digest))
}

extern "C" {
    fn floe_tex_image_metadata(
        data: *const u8,
        length: usize,
        page: i32,
        kind: i32,
        rect: *mut f64,
        page_count: *mut i32,
    ) -> i32;
}
/// The image/PDF bytes were opened by TeX's existing scoped IoProvider.
/// Save the exact used data for the Apple renderer; never export an arbitrary host path.
#[no_mangle]
pub unsafe extern "C" fn floe_tex_measure_image(
    name: *const c_char,
    data: *const u8,
    length: usize,
    page: i32,
    kind: i32,
    rect: *mut f64,
    page_count: *mut i32,
) -> i32 {
    let work = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
        use tectonic_errors::prelude::*;
        if name.is_null()
            || data.is_null()
            || rect.is_null()
            || page_count.is_null()
            || length == 0
            || length > 64 * 1024 * 1024
        {
            bail!("Invalid native image metadata input")
        }
        let name = CStr::from_ptr(name).to_str()?;
        if name.len() > 4096 || name.chars().any(|c| c.is_control()) {
            bail!("Invalid native image name")
        }
        if floe_tex_image_metadata(data, length, page, kind, rect, page_count) != 0 {
            bail!("The protected Apple image/PDF reader could not inspect this resource")
        }
        let job = active()
            .ok_or_else(|| tectonic_errors::Error::msg("Native image has no owning job"))?;
        let root = job
            .output_root
            .lock()
            .map_err(|_| tectonic_errors::Error::msg("Native output lock failed"))?
            .clone()
            .ok_or_else(|| tectonic_errors::Error::msg("Native image has no output stage"))?;
        let mut assets = job
            .assets
            .lock()
            .map_err(|_| tectonic_errors::Error::msg("Native image asset lock failed"))?;
        let bytes = std::slice::from_raw_parts(data, length);
        if let Some(prior) = assets.get(name) {
            let path = prior["path"]
                .as_str()
                .ok_or_else(|| tectonic_errors::Error::msg("Invalid native image receipt"))?;
            if std::fs::read(path)? != bytes {
                bail!("Image source changed within the native build")
            }
            return Ok(());
        }
        let total: usize = assets
            .values()
            .map(|v| v["bytes"].as_u64().unwrap_or(0) as usize)
            .sum();
        if assets.len() >= 4096
            || total
                .checked_add(length)
                .filter(|v| *v <= 256 * 1024 * 1024)
                .is_none()
        {
            bail!("Native image asset limit exceeded")
        }
        let folder = root.join("NativeAssets/images");
        std::fs::create_dir_all(&folder)?;
        let path = folder.join(format!("image-{}.data", assets.len()));
        if path.exists() {
            bail!("Native image stage already exists")
        }
        std::fs::write(&path, bytes)?;
        assets.insert(name.to_owned(),serde_json::json!({"name":name,"path":path,"kind":if kind==0 {"image"}else{"pdf"},"bytes":length}));
        Ok(())
    }));
    match work {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            publish(&format!("Native image preparation failed: {error:#}"));
            -1
        }
        Err(_) => -2,
    }
}

/// Called from the token scanner; cooperative engine abort stays within TeX's
/// existing exception boundary rather than unwinding through Swift frames.
#[no_mangle]
pub extern "C" fn floe_tex_checkpoint() -> i32 {
    active()
        .map(|job| {
            i32::from(
                job.cancelled.load(Ordering::Acquire)
                    || (job.deadline.load(Ordering::Acquire) != 0
                        && now() >= job.deadline.load(Ordering::Relaxed)),
            )
        })
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn floe_tex_job_create() -> *mut Job {
    Box::into_raw(Box::new(Job {
        cancelled: AtomicBool::new(false),
        deadline: AtomicU64::new(0),
        progress: Mutex::new((None, 0)),
        output_root: Mutex::new(None),
        assets: Mutex::new(BTreeMap::new()),
    }))
}
#[no_mangle]
pub unsafe extern "C" fn floe_tex_job_cancel(job: *mut Job) {
    if let Some(job) = job.as_ref() {
        job.cancelled.store(true, Ordering::Release);
    }
}
#[no_mangle]
pub unsafe extern "C" fn floe_tex_job_progress(
    job: *mut Job,
    callback: Option<ProgressCallback>,
    context: *mut c_void,
) {
    if let Some(job) = job.as_ref() {
        if let Ok(mut binding) = job.progress.lock() {
            *binding = (callback, context as usize);
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn floe_tex_job_free(job: *mut Job) {
    if !job.is_null() {
        drop(Box::from_raw(job));
    }
}

/// The caller owns the returned UTF-8 JSON and releases it with `floe_tex_free`.
#[no_mangle]
pub unsafe extern "C" fn floe_tex_compile(request: *const c_char, job: *mut Job) -> *mut c_char {
    let mut status = Status::default();
    let mut prepared = false;
    let mut resource_metrics = None;
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        || -> Result<(PathBuf, PathBuf, String)> {
            let _guard = RUN
                .lock()
                .map_err(|_| tectonic_errors::Error::msg("Engine state is unavailable"))?;
            if job.is_null() {
                return Err(tectonic_errors::Error::msg(
                    "Missing build cancellation identity",
                ));
            }
            if (*job).cancelled.load(Ordering::Acquire) {
                return Err(tectonic_errors::Error::msg("Typesetting cancelled"));
            }
            ACTIVE_JOB.store(job, Ordering::Release);
            let _active_guard = ActiveGuard;
            (*job).deadline.store(0, Ordering::Release);
            if request.is_null() {
                return Err(tectonic_errors::Error::msg("Missing build request"));
            }
            let input = CStr::from_ptr(request).to_str()?;
            let request = serde_json::from_str::<Request>(input)?;
            prepared = request.mode.as_deref() == Some("prepare");
            let resources = tectonic_geturl::reqwest::ResourceScope::install(
                request.resource_timeout_seconds,
                request.resource_total_timeout_seconds,
                network_cancelled,
                network_started,
            )?;
            resource_metrics = Some(resources.metrics());
            let result = compile(request, &mut status);
            resource_metrics = Some(resources.metrics());
            result
        },
    ));
    let cancelled = job
        .as_ref()
        .map(|j| j.cancelled.load(Ordering::Acquire))
        .unwrap_or(false);
    let mut response = match result {
        Ok(Ok((path, list, digest))) => {
            serde_json::json!({"success":true,"prepared":prepared,"engine":"xetex-xdv","version":"floe-xetex-xdv-0.17.0-cg2","xdvPath":path,"displayListPath":list,"bundleDigest":digest,"messages":status.messages})
        }
        Ok(Err(error)) => {
            serde_json::json!({"success":false,"cancelled":cancelled,"error":format!("{error:#}"),"messages":status.messages})
        }
        Err(_) => {
            serde_json::json!({"success":false,"error":"The typesetting engine failed","messages":status.messages})
        }
    };
    if let Some(metrics) = resource_metrics {
        if let Some(fields) = response.as_object_mut() {
            let values = serde_json::json!({
                "resourceTimeoutSeconds":metrics.request_timeout_seconds,
                "resourceTotalTimeoutSeconds":metrics.total_timeout_seconds,
                "resourceRequestCount":metrics.request_count,
                "resourceReceivedBytes":metrics.received_bytes,
                "resourceElapsedMilliseconds":metrics.elapsed_milliseconds });
            fields.extend(values.as_object().unwrap().clone());
        }
    }
    CString::new(response.to_string())
        .unwrap_or_else(|_| CString::new("{\"success\":false}").unwrap())
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn floe_tex_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}
