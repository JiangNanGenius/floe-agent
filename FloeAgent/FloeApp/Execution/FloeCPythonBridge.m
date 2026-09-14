#import "FloeCPythonBridge.h"
#import "FloeTLSConfiguration.h"

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
static _Thread_local void *FloePythonCancellationContext;
static PyObject *FloePythonIsCancelled(PyObject *self, PyObject *args) {
    BOOL (^cancel)(void) = (__bridge BOOL (^)(void))FloePythonCancellationContext;
    return PyBool_FromLong(cancel && cancel());
}
static PyMethodDef FloePythonCancellationMethod = {"_floe_is_cancelled", FloePythonIsCancelled, METH_NOARGS, NULL};

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

@interface FloePythonServiceRecord : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *environmentID;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *failure;
@property(atomic, assign) BOOL cancelled;
@property(nonatomic, assign) NSUInteger limit;
@property(nonatomic, strong) NSMutableData *output;
@property(nonatomic, strong) NSMutableData *errors;
@property(nonatomic, assign) BOOL truncated;
- (BOOL)isActive;
- (NSDictionary *)snapshot;
- (void)append:(NSData *)data channel:(NSString *)channel;
@end

@implementation FloePythonServiceRecord
- (instancetype)init {
    if ((self = [super init])) {
        _identifier = NSUUID.UUID.UUIDString; _state = @"starting";
        _output = [NSMutableData new]; _errors = [NSMutableData new];
    }
    return self;
}
- (BOOL)isActive { @synchronized(self) { return [@[@"starting", @"running", @"stopping"] containsObject:_state]; } }
- (void)append:(NSData *)data channel:(NSString *)channel {
    @synchronized(self) {
        NSUInteger used = _output.length + _errors.length;
        NSUInteger count = MIN(data.length, used < _limit ? _limit - used : 0);
        if (count < data.length) _truncated = YES;
        NSMutableData *target = [channel isEqual:@"stderr"] ? _errors : _output;
        if (count) [target appendBytes:data.bytes length:count];
    }
}
- (NSDictionary *)snapshot {
    @synchronized(self) {
        return @{@"serviceID": _identifier, @"status": _state,
                 @"stdout": [_output base64EncodedStringWithOptions:0],
                 @"stderr": [_errors base64EncodedStringWithOptions:0],
                 @"encoding": @"base64", @"truncated": @(_truncated), @"error": _failure ?: @""};
    }
}
@end

static NSMutableDictionary<NSString *, FloePythonServiceRecord *> *FloePythonServices(void) {
    static NSMutableDictionary *records; static dispatch_once_t once;
    dispatch_once(&once, ^{ records = [NSMutableDictionary new]; });
    return records;
}

#if FLOE_HAS_CPYTHON
static FloePythonServiceRecord *FloePythonServiceFromCapsule(PyObject *self) {
    return (__bridge FloePythonServiceRecord *)PyCapsule_GetPointer(self, "floe.python.service");
}
static void FloePythonServiceCapsuleDestroyed(PyObject *capsule) {
    void *pointer = PyCapsule_GetPointer(capsule, "floe.python.service");
    if (pointer) CFRelease(pointer);
}
static PyObject *FloePythonServiceCancelled(PyObject *self, PyObject *args) {
    FloePythonServiceRecord *record = FloePythonServiceFromCapsule(self);
    if (!record) return NULL;
    return PyBool_FromLong(record.cancelled);
}
static PyObject *FloePythonServiceWrite(PyObject *self, PyObject *args) {
    PyObject *channel, *text;
    if (!PyArg_ParseTuple(args, "UU", &channel, &text)) return NULL;
    FloePythonServiceRecord *record = FloePythonServiceFromCapsule(self);
    if (!record) return NULL;
    Py_ssize_t count = 0;
    const char *bytes = PyUnicode_AsUTF8AndSize(text, &count);
    const char *name = PyUnicode_AsUTF8(channel);
    if (!bytes || !name) return NULL;
    [record append:[NSData dataWithBytes:bytes length:(NSUInteger)count] channel:[NSString stringWithUTF8String:name]];
    Py_RETURN_NONE;
}
static PyMethodDef FloePythonServiceCancelledMethod = {"_floe_cancelled", FloePythonServiceCancelled, METH_NOARGS, NULL};
static PyMethodDef FloePythonServiceWriteMethod = {"_floe_write", FloePythonServiceWrite, METH_VARARGS, NULL};
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

    // Managed packages are mutable user data and must never be placed under
    // the signed .app bundle. The old `python/../Documents` path still lived
    // inside FloeAgent.app on device, so every reviewed pip request failed
    // while creating its staging directory. Use the sandbox Application
    // Support container and share it across every private/project workspace.
    NSURL *applicationSupport = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:error];
    if (!applicationSupport) {
        [lock unlock];
        return NO;
    }
    NSString *packagesDir = [[applicationSupport
        URLByAppendingPathComponent:@"FloeAgent/PythonPackages" isDirectory:YES] path];
    NSError *packagesError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:packagesDir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                        error:&packagesError]) {
        if (error) *error = FloePythonError(
            5,
            [NSString stringWithFormat:@"Could not create managed package directory: %@",
                packagesError.localizedDescription ?: @"unknown error"]
        );
        [lock unlock];
        return NO;
    }

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

    // iOS has no /etc/ssl/cert.pem. Use the pinned Mozilla roots shipped
    // with the app, resolved anew on launch after the app bundle moves.
    NSString *caBundle = FloeTLSCertificateBundle();
    if (caBundle) {
        setenv("SSL_CERT_FILE", caBundle.fileSystemRepresentation, 1);
        setenv("REQUESTS_CA_BUNDLE", caBundle.fileSystemRepresentation, 1);
        setenv("PIP_CERT", caBundle.fileSystemRepresentation, 1);
    }

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
                                contextJSON:(NSString *)contextJSON
                                     timeout:(NSTimeInterval)timeout
                              maxOutputBytes:(NSInteger)maxOutputBytes
                       allowPackageInstaller:(BOOL)allowPackageInstaller
                                 shouldCancel:(BOOL (^)(void))shouldCancel {
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
    FloePythonCancellationContext = (__bridge void *)shouldCancel;
    PyObject *globals = PyDict_New();
    PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
    PyObject *isCancelled = PyCFunction_New(&FloePythonCancellationMethod, NULL);
    PyDict_SetItemString(globals, "_floe_is_cancelled", isCancelled);
    Py_DECREF(isCancelled);
    PyObject *source = PyUnicode_FromString(script.UTF8String);
    PyObject *input = PyUnicode_FromString((inputJSON ?: @"null").UTF8String);
    PyObject *context = PyUnicode_FromString((contextJSON ?: @"{}").UTF8String);
    PyDict_SetItemString(globals, "_floe_context_json", context);
    Py_DECREF(context);
    PyObject *seconds = PyFloat_FromDouble(MAX(0.05, MIN(timeout, 600.0)));
    PyObject *limit = PyLong_FromLongLong(MAX(1, MIN(maxOutputBytes, 262144)));
    PyDict_SetItemString(globals, "_floe_script", source);
    PyDict_SetItemString(globals, "_floe_input_json", input);
    PyDict_SetItemString(globals, "_floe_timeout", seconds);
    PyDict_SetItemString(globals, "_floe_cap", limit);
    Py_DECREF(source); Py_DECREF(input); Py_DECREF(seconds); Py_DECREF(limit);

    static const char *runner =
        "import io as _io, json as _json, sys as _sys, os as _os, time as _time, traceback as _tb\n"
        "class _FloeBudget:\n"
        " def __init__(self, cap): self.remaining=cap\n"
        "class _FloeSink:\n"
        " def __init__(self, budget): self.budget=budget; self.parts=[]; self.truncated=False\n"
        " def write(self, value):\n"
        "  text=str(value); raw=text.encode('utf-8', 'replace'); left=max(0,self.budget.remaining)\n"
        "  if len(raw)>left: raw=raw[:left]; self.truncated=True\n"
        "  decoded=raw.decode('utf-8','ignore'); self.budget.remaining-=len(raw)\n"
        "  if decoded: self.parts.append(decoded)\n"
        "  return len(text)\n"
        " def flush(self): pass\n"
        " def value(self): return ''.join(self.parts)\n"
        "_floe_budget=_FloeBudget(_floe_cap); _floe_out=_FloeSink(_floe_budget); _floe_err=_FloeSink(_floe_budget)\n"
        "_floe_old_out,_floe_old_err=_sys.stdout,_sys.stderr\n"
        "_floe_deadline=_time.monotonic()+_floe_timeout\n"
        "_floe_interrupted=False\n"
        "def _floe_trace(frame,event,arg):\n"
        " global _floe_interrupted\n"
        " if _floe_interrupted: return _floe_trace\n"
        " if _floe_is_cancelled():\n"
        "  _floe_interrupted=True; raise InterruptedError('Local Python cancelled')\n"
        " if _time.monotonic()>_floe_deadline:\n"
        "  _floe_interrupted=True; raise TimeoutError('Local Python time limit exceeded')\n"
        " return _floe_trace\n"
        "def _floe_profile(frame,event,arg):\n"
        " if event=='c_return': _floe_trace(frame,event,arg)\n"
        "_floe_status='ok'; _floe_error=''; _floe_printed=None\n"
        "def _floe_printJSON(value):\n"
        " global _floe_printed\n"
        " _floe_printed=_json.dumps(value,ensure_ascii=False)\n"
        "_floe_context=_json.loads(_floe_context_json)\n"
        "_floe_cwd=_os.getcwd(); _floe_env=dict(_os.environ); _floe_path=list(_sys.path); _floe_stdin=_sys.stdin; _floe_argv=_sys.argv\n"
        "_floe_search=[p for p in _floe_context.get('environment',{}).get('PYTHONPATH','').split(_os.pathsep) if p]\n"
        "try:\n"
        " _sys.stdout,_sys.stderr=_floe_out,_floe_err; _sys.settrace(_floe_trace); _sys.setprofile(_floe_profile)\n"
        " if _floe_context.get('workingDirectory'): _os.chdir(_floe_context['workingDirectory'])\n"
        " _os.environ.update(_floe_context.get('environment',{}))\n"
        " _sys.path[:]=_floe_search+_floe_path\n"
        " if _floe_context.get('workingDirectory'): _sys.path.insert(0,_floe_context['workingDirectory'])\n"
        // Package transactions replace directory generations. The persistent
        // interpreter may retain a negative finder for a previously absent root.
        " __import__('importlib').invalidate_caches()\n"
        " if 'standardInput' in _floe_context: _sys.stdin=_io.TextIOWrapper(_io.BytesIO(_floe_context['standardInput'].encode('utf-8')),encoding='utf-8')\n"
        " if 'arguments' in _floe_context: _sys.argv=_floe_context['arguments']\n"
        " _floe_globals={'__builtins__':__builtins__,'__name__':'__main__','printJSON':_floe_printJSON}\n"
        " if _floe_input_json!='null': _floe_globals['input']=_json.loads(_floe_input_json)\n"
        " exec(compile(_floe_script,'<floe-local-python>','exec'),_floe_globals,_floe_globals)\n"
        "except TimeoutError as exc: _floe_status='timedOut'; _floe_error=str(exc)\n"
        "except BaseException as exc: _floe_status='exception'; _floe_error=''.join(_tb.format_exception_only(type(exc),exc)).strip()\n"
        "finally:\n"
        " _sys.settrace(None); _sys.setprofile(None); _sys.stdout,_sys.stderr=_floe_old_out,_floe_old_err\n"
        " _sys.stdin=_floe_stdin; _sys.argv=_floe_argv; _sys.path[:]=_floe_path\n"
        " _os.environ.clear(); _os.environ.update(_floe_env); _os.chdir(_floe_cwd)\n"
        " _floe_roots=[_os.path.realpath(p)+_os.sep for p in _floe_search+[_floe_context.get('workingDirectory') or ''] if p]\n"
        " for _floe_name,_floe_module in list(_sys.modules.items()):\n"
        "  _floe_file=getattr(_floe_module,'__file__',None)\n"
        "  _floe_locations=([_floe_file] if isinstance(_floe_file,str) else [])+list(getattr(_floe_module,'__path__',[]) or [])\n"
        "  if any(isinstance(p,str) and any((_os.path.realpath(p)+_os.sep).startswith(r) for r in _floe_roots) for p in _floe_locations): _sys.modules.pop(_floe_name,None)\n"
        "_floe_result=_json.dumps({'status':_floe_status,'resultJSON':_floe_printed,'error':_floe_error,'stdout':_floe_out.value(),'stderr':_floe_err.value(),'truncated':_floe_out.truncated,'stderrTruncated':_floe_err.truncated},ensure_ascii=False)\n";

    PyObject *execution = PyRun_String(runner, Py_file_input, globals, globals);
    FloeAllowsPackageInstaller = 0;
    FloePythonCancellationContext = NULL;
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

+ (NSDictionary *)startService:(NSString *)script contextJSON:(NSString *)contextJSON
                 environmentID:(NSString *)environmentID maxOutputBytes:(NSInteger)maxOutputBytes {
#if !FLOE_HAS_CPYTHON
    return @{@"status": @"unavailable", @"error": @"Bundled CPython is unavailable"};
#else
    NSDictionary *context = [NSJSONSerialization JSONObjectWithData:[contextJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSString *directory = [context isKindOfClass:NSDictionary.class] ? context[@"workingDirectory"] : nil;
    if (![context isKindOfClass:NSDictionary.class] || !environmentID.length || ![context[@"environmentID"] isEqual:environmentID] ||
        ![directory isKindOfClass:NSString.class] || !directory.isAbsolutePath ||
        script.length == 0 || [script lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536) {
        return @{@"status": @"invalid", @"error": @"An explicit environment, working directory and bounded script are required"};
    }
    NSError *error = nil;
    if (!FloeEnsurePython(&error)) return @{@"status": @"unavailable", @"error": error.localizedDescription ?: @"CPython could not start"};
    NSString *bootstrapPath = [NSBundle.mainBundle pathForResource:@"PythonServiceBootstrap" ofType:@"py"];
    NSString *bootstrap = bootstrapPath ? [NSString stringWithContentsOfFile:bootstrapPath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!bootstrap.length) return @{@"status": @"unavailable", @"error": @"Python service bootstrap is not bundled"};
    FloePythonServiceRecord *record = [FloePythonServiceRecord new];
    record.environmentID = environmentID; record.limit = MIN(1048576, MAX(1, maxOutputBytes));
    NSMutableDictionary *records = FloePythonServices();
    @synchronized(records) {
        NSUInteger active = 0;
        for (FloePythonServiceRecord *other in records.allValues) if (other.isActive) active++;
        if (active >= 2) return @{@"status": @"busy", @"error": @"Two Python services are already active"};
        // Durable service history belongs to the Swift job store. Bound only
        // this native control cache; active records are never evicted.
        if (records.count >= 32) {
            for (NSString *key in records.allKeys) if (![records[key] isActive]) [records removeObjectForKey:key];
        }
        records[record.identifier] = record;
    }
    [NSThread detachNewThreadWithBlock:^{ @autoreleasepool {
        PyGILState_STATE originalGIL = PyGILState_Ensure();
        PyThreadState *originalState = PyThreadState_Get();
        if (record.cancelled) {
            PyGILState_Release(originalGIL);
            @synchronized(record) { record.state = @"stopped"; }
            return;
        }
        PyInterpreterConfig config = {
            .use_main_obmalloc = 0, .allow_fork = 0, .allow_exec = 0,
            .allow_threads = 1, .allow_daemon_threads = 0,
            .check_multi_interp_extensions = 1, .gil = PyInterpreterConfig_OWN_GIL
        };
        PyThreadState *serviceState = NULL;
        PyStatus created = Py_NewInterpreterFromConfig(&serviceState, &config);
        if (PyStatus_Exception(created)) {
            if (!PyThreadState_GetUnchecked()) PyEval_RestoreThread(originalState);
            PyGILState_Release(originalGIL);
            @synchronized(record) {
                record.failure = created.err_msg ? [NSString stringWithUTF8String:created.err_msg] : @"Python service interpreter initialization failed";
                record.state = @"failed";
            }
            return;
        }
        // No Python objects cross interpreter boundaries. The old GIL is
        // released by creation; this thread now owns the service interpreter.
        PyObject *globals = PyDict_New();
        PyObject *source = PyUnicode_FromStringAndSize(script.UTF8String, [script lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        PyObject *json = PyUnicode_FromString(contextJSON.UTF8String);
        void *retainedOwner = (__bridge_retained void *)record;
        PyObject *capsule = PyCapsule_New(retainedOwner, "floe.python.service", FloePythonServiceCapsuleDestroyed);
        if (!capsule) CFRelease(retainedOwner);
        PyObject *cancel = capsule ? PyCFunction_New(&FloePythonServiceCancelledMethod, capsule) : NULL;
        PyObject *write = capsule ? PyCFunction_New(&FloePythonServiceWriteMethod, capsule) : NULL;
        BOOL ready = globals && source && json && cancel && write;
        if (ready) {
            ready = PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins()) == 0
                && PyDict_SetItemString(globals, "_floe_source", source) == 0
                && PyDict_SetItemString(globals, "_floe_context_json", json) == 0
                && PyDict_SetItemString(globals, "_floe_cancelled", cancel) == 0
                && PyDict_SetItemString(globals, "_floe_write", write) == 0;
        }
        Py_XDECREF(source); Py_XDECREF(json); Py_XDECREF(cancel); Py_XDECREF(write); Py_XDECREF(capsule);
        @synchronized(record) { record.state = record.cancelled ? @"stopping" : @"running"; }
        NSString *program = [@"import json\n_floe_context=json.loads(_floe_context_json)\n" stringByAppendingString:bootstrap];
        PyObject *execution = ready ? PyRun_String(program.UTF8String, Py_file_input, globals, globals) : NULL;
        NSString *failure = nil;
        if (!execution) {
            PyObject *exception = PyErr_GetRaisedException();
            PyObject *description = exception ? PyObject_Str(exception) : NULL;
            const char *value = description ? PyUnicode_AsUTF8(description) : NULL;
            failure = value ? [NSString stringWithUTF8String:value] : @"Python service failed";
            Py_XDECREF(description); Py_XDECREF(exception); PyErr_Clear();
        }
        Py_XDECREF(execution); Py_XDECREF(globals);
        // Cleanup can wait for native operations or child threads. Keep the
        // record active until EndInterpreter returns; never free its owner early.
        Py_EndInterpreter(serviceState);
        PyEval_RestoreThread(originalState);
        PyGILState_Release(originalGIL);
        @synchronized(record) {
            record.failure = failure;
            record.state = record.cancelled ? @"stopped" : failure ? @"failed" : @"completed";
        }
    } }];
    return record.snapshot;
#endif
}

+ (NSDictionary *)serviceStatus:(NSString *)serviceID environmentID:(NSString *)environmentID {
    NSMutableDictionary *records = FloePythonServices();
    @synchronized(records) {
        FloePythonServiceRecord *record = records[serviceID];
        if (![record.environmentID isEqual:environmentID]) return @{@"status": @"notFound"};
        return record.snapshot;
    }
}

+ (NSDictionary *)stopService:(NSString *)serviceID environmentID:(NSString *)environmentID {
    NSMutableDictionary *records = FloePythonServices();
    FloePythonServiceRecord *record;
    @synchronized(records) { record = records[serviceID]; }
    if (![record.environmentID isEqual:environmentID]) return @{@"status": @"notFound"};
    @synchronized(record) {
        if (record.isActive) { record.cancelled = YES; record.state = @"stopping"; }
    }
    const NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 10;
    while (record.isActive && NSProcessInfo.processInfo.systemUptime < deadline) [NSThread sleepForTimeInterval:0.025];
    return record.snapshot;
}

+ (BOOL)hasActiveServices:(NSString *)environmentID {
    NSMutableDictionary *records = FloePythonServices();
    @synchronized(records) {
        for (FloePythonServiceRecord *record in records.allValues) {
            if ([record.environmentID isEqual:environmentID] && record.isActive) return YES;
        }
    }
    return NO;
}

+ (BOOL)stopServices:(NSString *)environmentID {
    NSMutableDictionary *records = FloePythonServices();
    NSArray<FloePythonServiceRecord *> *snapshot;
    @synchronized(records) { snapshot = records.allValues; }
    // Signal all first, so multiple services unwind concurrently.
    for (FloePythonServiceRecord *record in snapshot) {
        @synchronized(record) {
            if ([record.environmentID isEqual:environmentID] && record.isActive) {
                record.cancelled = YES; record.state = @"stopping";
            }
        }
    }
    const NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 10;
    while ([self hasActiveServices:environmentID] && NSProcessInfo.processInfo.systemUptime < deadline) [NSThread sleepForTimeInterval:0.025];
    return ![self hasActiveServices:environmentID];
}

@end
