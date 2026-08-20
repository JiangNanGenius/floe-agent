#import "FloeCPythonBridge.h"

#if __has_include(<Python/Python.h>)
#import <Python/Python.h>
#define FLOE_HAS_CPYTHON 1
#else
#define FLOE_HAS_CPYTHON 0
#endif

static NSString * const FloePythonErrorDomain = @"org.floeagent.python";

#if FLOE_HAS_CPYTHON
// The hook is registered in native code and cannot be removed by an
// agent-authored Python script. Only the bridge's private managed-install
// phase may import pip/ensurepip; installed application packages remain
// importable during ordinary runs.
static _Thread_local int FloeAllowsPackageInstaller = 0;
static int FloeAuditHookInstalled = 0;

static int FloePythonAuditHook(const char *event, PyObject *args, void *userData) {
    (void)userData;
    if (FloeAllowsPackageInstaller || strcmp(event, "import") != 0 || !PyTuple_Check(args)) {
        return 0;
    }
    PyObject *nameObject = PyTuple_GetItem(args, 0); // borrowed
    if (!nameObject || !PyUnicode_Check(nameObject)) { return 0; }
    const char *name = PyUnicode_AsUTF8(nameObject);
    if (!name) { return -1; }
    BOOL isPip = strcmp(name, "pip") == 0 || strncmp(name, "pip.", 4) == 0;
    BOOL isEnsurePip = strcmp(name, "ensurepip") == 0 || strncmp(name, "ensurepip.", 10) == 0;
    if (isPip || isEnsurePip) {
        PyErr_SetString(PyExc_PermissionError,
            "pip is available only through Floe's reviewed packages argument");
        return -1;
    }
    return 0;
}

static void FloeRemoveInstallerModules(void) {
    PyObject *modules = PyImport_GetModuleDict(); // borrowed
    if (!modules || !PyDict_Check(modules)) { return; }
    PyObject *keys = PyDict_Keys(modules);
    if (!keys) { PyErr_Clear(); return; }
    Py_ssize_t count = PyList_Size(keys);
    for (Py_ssize_t index = 0; index < count; index++) {
        PyObject *key = PyList_GetItem(keys, index); // borrowed
        if (!key || !PyUnicode_Check(key)) { continue; }
        const char *name = PyUnicode_AsUTF8(key);
        if (!name) { PyErr_Clear(); continue; }
        BOOL isPip = strcmp(name, "pip") == 0 || strncmp(name, "pip.", 4) == 0;
        BOOL isEnsurePip = strcmp(name, "ensurepip") == 0 || strncmp(name, "ensurepip.", 10) == 0;
        if ((isPip || isEnsurePip) && PyDict_DelItem(modules, key) < 0) {
            PyErr_Clear();
        }
    }
    Py_DECREF(keys);
}
#endif

@implementation FloeCPythonBridge

static NSError *FloePythonError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:FloePythonErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#if FLOE_HAS_CPYTHON
static NSLock *FloePythonInitLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

static BOOL FloeEnsurePython(NSError **error) {
    if (Py_IsInitialized()) {
        if (!FloeAuditHookInstalled && error) {
            *error = FloePythonError(4, @"Managed-package audit hook is unavailable");
        }
        return FloeAuditHookInstalled != 0;
    }
    NSLock *lock = FloePythonInitLock();
    [lock lock];
    if (Py_IsInitialized()) {
        BOOL ready = FloeAuditHookInstalled != 0;
        if (!ready && error) {
            *error = FloePythonError(4, @"Managed-package audit hook is unavailable");
        }
        [lock unlock];
        return ready;
    }

    NSString *home = [[[NSBundle mainBundle] resourceURL]
        URLByAppendingPathComponent:@"python" isDirectory:YES].path;
    NSString *standardLibrary = [home stringByAppendingPathComponent:@"lib/python3.13"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:standardLibrary]) {
        if (error) *error = FloePythonError(1, @"Bundled Python standard library is missing");
        [lock unlock];
        return NO;
    }

    // Workspace packages directory: pip --target installs go here so the
    // agent can install and import pure-Python packages. Created on first use.
    NSString *packagesDir = [home stringByAppendingPathComponent:@"../Documents/PythonPackages"];
    [[NSFileManager defaultManager] createDirectoryAtPath:packagesDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    PyPreConfig preconfig;
    PyConfig config;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    PyConfig_InitIsolatedConfig(&config);
    preconfig.utf8_mode = 1;
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    config.site_import = 1;  // Allow site-packages so pip --target works
    config.user_site_directory = 0;
    config.use_environment = 0;

    NSString *stage = @"Py_PreInitialize";
    PyStatus status = Py_PreInitialize(&preconfig);
    if (!PyStatus_Exception(status)) {
        stage = @"PyConfig_SetString(home)";
        wchar_t *wideHome = Py_DecodeLocale(home.UTF8String, NULL);
        status = PyConfig_SetString(&config, &config.home, wideHome);
        PyMem_RawFree(wideHome);
    }
    if (!PyStatus_Exception(status)) {
        stage = @"PyConfig_Read";
        status = PyConfig_Read(&config);
    }
    if (!PyStatus_Exception(status)) {
        stage = @"PyConfig_SetBytesArgv";
        const char *argv[] = {"FloeAgent"};
        status = PyConfig_SetBytesArgv(&config, 1, (char **)argv);
    }
    if (!PyStatus_Exception(status)) {
        stage = @"Py_InitializeFromConfig";
        status = Py_InitializeFromConfig(&config);
    }
    if (PyStatus_Exception(status)) {
        NSString *detail = status.err_msg
            ? [NSString stringWithUTF8String:status.err_msg]
            : @"Unknown CPython initialization failure";
        if (error) *error = FloePythonError(2, [NSString stringWithFormat:@"%@: %@", stage, detail]);
        PyConfig_Clear(&config);
        [lock unlock];
        return NO;
    }
    PyConfig_Clear(&config);

    if (PySys_AddAuditHook(FloePythonAuditHook, NULL) < 0) {
        if (error) *error = FloePythonError(4, @"Could not install the managed-package audit hook");
        PyErr_Clear();
        [lock unlock];
        return NO;
    }
    FloeAuditHookInstalled = 1;

    // Add the workspace packages directory to sys.path so pip --target
    // installs are importable.
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *sysPath = PySys_GetObject("path");
    if (sysPath && PyList_Check(sysPath)) {
        PyObject *packagesPath = PyUnicode_FromString(packagesDir.UTF8String);
        if (packagesPath) {
            PyList_Append(sysPath, packagesPath);
            Py_DECREF(packagesPath);
        }
    }
    PyGILState_Release(gil);
    // Initialization owns the GIL. Release it so later actor hops may safely
    // enter through PyGILState_Ensure on any cooperative thread.
    PyEval_SaveThread();
    [lock unlock];
    return YES;
}
#endif

+ (NSString *)runtimeVersionWithError:(NSError **)error {
#if FLOE_HAS_CPYTHON
    if (!FloeEnsurePython(error)) { return nil; }
    return [NSString stringWithUTF8String:Py_GetVersion()];
#else
    if (error) *error = FloePythonError(3, @"Python.xcframework is not linked");
    return nil;
#endif
}

+ (NSDictionary<NSString *,id> *)runScript:(NSString *)script
                                  inputJSON:(NSString *)inputJSON
                                     timeout:(NSTimeInterval)timeout
                              maxOutputBytes:(NSInteger)maxOutputBytes
                       allowPackageInstaller:(BOOL)allowPackageInstaller {
#if !FLOE_HAS_CPYTHON
    return @{ @"status": @"exception", @"error": @"Python.xcframework is not linked", @"stdout": @"" };
#else
    NSError *initializationError = nil;
    if (!FloeEnsurePython(&initializationError)) {
        return @{ @"status": @"exception",
                  @"error": initializationError.localizedDescription ?: @"CPython unavailable",
                  @"stdout": @"" };
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    PyGILState_STATE gil = PyGILState_Ensure();
    FloeAllowsPackageInstaller = allowPackageInstaller ? 1 : 0;
    PyObject *globals = PyDict_New();
    PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
    PyObject *source = PyUnicode_FromString(script.UTF8String);
    PyObject *input = PyUnicode_FromString((inputJSON ?: @"null").UTF8String);
    PyObject *seconds = PyFloat_FromDouble(MAX(0.05, MIN(timeout, 30.0)));
    PyObject *limit = PyLong_FromLongLong(MAX(1, MIN(maxOutputBytes, 262144)));
    PyDict_SetItemString(globals, "_floe_script", source);
    PyDict_SetItemString(globals, "_floe_input_json", input);
    PyDict_SetItemString(globals, "_floe_timeout", seconds);
    PyDict_SetItemString(globals, "_floe_cap", limit);
    Py_DECREF(source); Py_DECREF(input); Py_DECREF(seconds); Py_DECREF(limit);

    static const char *runner =
        "import io as _io, json as _json, sys as _sys, time as _time, traceback as _tb\n"
        "class _FloeBudget:\n"
        " def __init__(self, cap): self.remaining=cap\n"
        "class _FloeSink:\n"
        " def __init__(self, budget): self.budget=budget; self.parts=[]; self.truncated=False\n"
        " def write(self, value):\n"
        "  text=str(value); raw=text.encode('utf-8', 'replace'); left=max(0,self.budget.remaining)\n"
        "  if len(raw)>left: raw=raw[:left]; self.truncated=True\n"
        "  decoded=raw.decode('utf-8','ignore'); self.parts.append(decoded); self.budget.remaining-=len(raw); return len(text)\n"
        " def flush(self): pass\n"
        " def value(self): return ''.join(self.parts)\n"
        "_floe_budget=_FloeBudget(_floe_cap); _floe_out=_FloeSink(_floe_budget); _floe_err=_FloeSink(_floe_budget)\n"
        "_floe_old_out,_floe_old_err=_sys.stdout,_sys.stderr\n"
        "_floe_deadline=_time.monotonic()+_floe_timeout\n"
        "def _floe_trace(frame,event,arg):\n"
        " if _time.monotonic()>_floe_deadline: raise TimeoutError('Local Python time limit exceeded')\n"
        " return _floe_trace\n"
        "_floe_status='ok'; _floe_error=''\n"
        "try:\n"
        " _sys.stdout,_sys.stderr=_floe_out,_floe_err; _sys.settrace(_floe_trace)\n"
        " _floe_globals={'__builtins__':__builtins__,'input':_json.loads(_floe_input_json)}\n"
        " exec(compile(_floe_script,'<floe-local-python>','exec'),_floe_globals,_floe_globals)\n"
        "except TimeoutError as exc: _floe_status='timedOut'; _floe_error=str(exc)\n"
        "except BaseException as exc: _floe_status='exception'; _floe_error=''.join(_tb.format_exception_only(type(exc),exc)).strip()\n"
        "finally: _sys.settrace(None); _sys.stdout,_sys.stderr=_floe_old_out,_floe_old_err\n"
        "_floe_result=_json.dumps({'status':_floe_status,'error':_floe_error,'stdout':_floe_out.value(),'stderr':_floe_err.value(),'truncated':_floe_out.truncated,'stderrTruncated':_floe_err.truncated},ensure_ascii=False)\n";

    PyObject *execution = PyRun_String(runner, Py_file_input, globals, globals);
    FloeAllowsPackageInstaller = 0;
    FloeRemoveInstallerModules();
    NSDictionary *result = nil;
    if (execution) {
        Py_DECREF(execution);
        PyObject *value = PyDict_GetItemString(globals, "_floe_result");
        if (value) {
            const char *utf8 = PyUnicode_AsUTF8(value);
            if (utf8) {
                NSData *data = [[NSString stringWithUTF8String:utf8] dataUsingEncoding:NSUTF8StringEncoding];
                result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
        }
    } else {
        PyErr_Clear();
    }
    Py_DECREF(globals);
    PyGILState_Release(gil);

    NSInteger durationMs = (NSInteger)((CFAbsoluteTimeGetCurrent() - started) * 1000.0);
    if (!result) {
        return @{ @"status": @"exception", @"error": @"CPython runner failed", @"stdout": @"", @"durationMs": @(durationMs) };
    }
    NSMutableDictionary *withDuration = [result mutableCopy];
    withDuration[@"durationMs"] = @(durationMs);
    return withDuration;
#endif
}

@end
