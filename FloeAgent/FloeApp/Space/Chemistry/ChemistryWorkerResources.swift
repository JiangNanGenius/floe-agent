// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeWorkspace
import FloeChemistryEngine

/// Native configuration only. A tool argument, project or result cannot select
/// an interpreter, source file, executable or environment variable.
nonisolated struct ChemistryWorkerConfiguration: Sendable {
    let pythonExecutable: String
    let sources: [String: Data]

    init(pythonExecutable: String = "python3", sources: [String: Data]) throws {
        guard !pythonExecutable.isEmpty, pythonExecutable.utf8.count <= 4096,
              !pythonExecutable.contains("\n"), !pythonExecutable.contains("\0"),
              Set(ChemistryWorkerResources.workerNames).isSubset(of: Set(sources.keys)),
              Set(sources.keys).isSubset(of: Set(ChemistryWorkerResources.deploymentNames)),
              sources.values.allSatisfy({ !$0.isEmpty && $0.count <= 2 * 1024 * 1024 }) else {
            throw FloeError.validationFailed("The configured chemistry worker resources are unavailable")
        }
        self.pythonExecutable = pythonExecutable; self.sources = sources
    }

    static func bundled(pythonExecutable: String = "python3") throws -> Self {
        let sources = try ChemistryWorkerDeployment.files(), pinned = try ChemistryWorkerDeployment.digests()
        for name in ChemistryWorkerResources.workerNames {
            guard let data = sources[name], let digest = pinned[name], FloeDigest.sha256Hex(data) == digest else {
                throw FloeError.validationFailed("The bundled chemistry worker checksum does not match")
            }
        }
        for (name, digest) in pinned {
            guard ChemistryWorkerResources.deploymentNames.contains(name), let data = sources[name],
                  FloeDigest.sha256Hex(data) == digest else { throw FloeError.validationFailed("The chemistry deployment changed") }
        }
        return try Self(pythonExecutable: pythonExecutable, sources: sources)
    }

    var sourceDigests: [String: String] {
        var result = sources.mapValues(FloeDigest.sha256Hex)
        result["transport.py"] = FloeDigest.sha256Hex(Data(ChemistryWorkerResources.transport.utf8))
        return result
    }
    var fingerprint: String {
        // Fixed ordered data, independent of Dictionary iteration.
        FloeDigest.sha256Hex(Data(([pythonExecutable] + sourceDigests.keys.sorted().map {
            $0 + ":" + sourceDigests[$0]!
        }).joined(separator: "\n").utf8))
    }
}

/// Uses the existing workspace guard, then additionally refuses symlink files
/// and limits the actual read. Canonicalising both sides permits /var aliases.
nonisolated enum ChemistryWorkerFiles {
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func child(_ path: String, root: URL) throws -> URL {
        let guarder = WorkspacePathGuard(rootURL: root, maxReadBytes: 64 * 1024 * 1024,
                                         maxWriteBytes: 64 * 1024 * 1024)
        let url = try guarder.resolve(path)
        let lexical = canonical(root).appendingPathComponent(path).standardizedFileURL
        guard url == lexical else { throw FloeError.unauthorized }
        return url
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= limit else {
            throw FloeError.validationFailed("A chemistry artifact is missing, changed or exceeds its size limit")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == size, data.count <= limit,
              try handle.read(upToCount: 1)?.isEmpty != false else {
            throw FloeError.validationFailed("A chemistry artifact changed while being read")
        }
        let after = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard after.isRegularFile == true, after.isSymbolicLink != true, after.fileSize == size else {
            throw FloeError.validationFailed("A chemistry artifact changed while being read")
        }
        return data
    }
    static func write(_ data: Data, path: String, root: URL, limit: Int) throws {
        guard data.count <= limit else { throw FloeError.validationFailed("Chemistry artifact exceeds its size limit") }
        let url = try child(path, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try child(path, root: root) == url else { throw FloeError.unauthorized }
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FloeError.unauthorized }
        }
        try data.write(to: url, options: .atomic)
    }
}

nonisolated enum ChemistryWorkerResources {
    static let workerNames = ["chemistry_worker.py", "science_worker.py", "quantum_worker.py"]
    static let deploymentNames = workerNames + ["requirements-rdkit.txt", "requirements-science.txt", "WorkerManifest.json"]

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// Executed only by exec.shell in the task's verified resolved environment.
    /// The bootstrap verifies native resources before any of them is imported.
    static func command(configuration: ChemistryWorkerConfiguration, relativeDirectory: String,
                        manifestDigest: String) -> String {
        let bootstrap = "import hashlib,pathlib,sys; p=pathlib.Path(sys.argv[1]); b=p.read_bytes(); assert hashlib.sha256(b).hexdigest()==sys.argv[2], 'Chemistry transport checksum mismatch'; sys.argv=[str(p)]+sys.argv[3:]; exec(compile(b,str(p),'exec'),{'__name__':'__main__','__file__':str(p)})"
        return "exec " + quote(configuration.pythonExecutable) + " -I -c " + quote(bootstrap) + " "
            + quote(relativeDirectory + "/transport.py") + " "
            + quote(configuration.sourceDigests["transport.py"]!) + " " + quote(manifestDigest)
    }

    /// Bounded file transport, not a chemistry engine. It runs only the bundled
    /// worker with its exact staged stdin. No shell, package install or network.
    static let transport = #"""
import hashlib, json, os, pathlib, signal, subprocess, sys, threading, time

MAX_REQUEST = 16 * 1024 * 1024
MAX_RESPONSE = 64 * 1024 * 1024
MAX_STDERR = 64 * 1024
WORKERS = ('chemistry_worker.py', 'science_worker.py', 'quantum_worker.py')
root = pathlib.Path(__file__).resolve().parent
child = None
cancelled = threading.Event()
overflow = threading.Event()

def read_regular(path, limit):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError('Invalid or oversized transport file: ' + path.name)
    with path.open('rb') as f:
        data = f.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Transport file exceeds its limit: ' + path.name)
    return data

def atomic(path, data):
    temporary = path.with_name(path.name + '.partial')
    with temporary.open('xb') as f:
        f.write(data); f.flush(); os.fsync(f.fileno())
    os.replace(temporary, path)

def stop(signum, frame):
    cancelled.set()
    if child is not None and child.poll() is None:
        try: os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError: pass

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, stop)

try:
    manifest_data = read_regular(root / 'manifest.json', 64 * 1024)
    if hashlib.sha256(manifest_data).hexdigest() != sys.argv[1]:
        raise ValueError('Transport manifest checksum mismatch')
    manifest = json.loads(manifest_data)
    if manifest['schema'] != 'floe.chemistry.transport.v1':
        raise ValueError('Unsupported transport manifest')
    for name in manifest['sourceDigests']:
        if name == 'transport.py': continue
        if name not in WORKERS + ('requirements-rdkit.txt', 'requirements-science.txt', 'WorkerManifest.json'):
            raise ValueError('Unknown deployment resource')
        source = read_regular(root / name, 2 * 1024 * 1024)
        if hashlib.sha256(source).hexdigest() != manifest['sourceDigests'][name]:
            raise ValueError('Worker source checksum mismatch: ' + name)
    request = read_regular(root / 'request.json', MAX_REQUEST)
    if hashlib.sha256(request).hexdigest() != manifest['inputSHA256']:
        raise ValueError('Frozen request checksum mismatch')
    output = root / 'response.json'
    receipt_path = root / 'transportReceipt.json'
    if output.exists() or receipt_path.exists() or (root / 'response.json.partial').exists():
        raise ValueError('This attempt already has output; reconcile it instead of replaying')

    # Isolated Python still uses this configured environment's site packages.
    # Only the three verified native workers enter its import path.
    loader = "import pathlib,runpy,sys; p=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(p.parent)); sys.argv=[str(p)]; runpy.run_path(str(p),run_name='__main__')"
    engine_jobs = root / 'engine-jobs'
    if engine_jobs.is_symlink(): raise ValueError('Invalid engine job directory')
    engine_jobs.mkdir(mode=0o700, exist_ok=True)
    worker_environment = dict(os.environ)
    worker_environment['CHEMISTRY_JOB_DIRECTORY'] = str(engine_jobs)
    child = subprocess.Popen([sys.executable, '-I', '-c', loader, str(root / WORKERS[0])],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True, env=worker_environment)
    counts = {'stdout': 0, 'stderr': 0}
    capture_errors = []

    def drain(pipe, path, key, cap):
        try:
            with path.open('xb') as f:
                while True:
                    block = pipe.read(65536)
                    if not block: break
                    counts[key] += len(block)
                    if counts[key] > cap:
                        overflow.set()
                        # Drain boundedly until the supervising loop reaps it.
                    else: f.write(block)
                f.flush(); os.fsync(f.fileno())
        except BaseException as exc:
            capture_errors.append(str(exc)); overflow.set()
        finally: pipe.close()

    stdout_thread = threading.Thread(target=drain, args=(child.stdout, root / 'response.json.partial', 'stdout', MAX_RESPONSE))
    stderr_thread = threading.Thread(target=drain, args=(child.stderr, root / 'stderr.txt', 'stderr', MAX_STDERR))
    stdout_thread.start(); stderr_thread.start()
    try:
        child.stdin.write(request); child.stdin.close()
    except BrokenPipeError:
        pass
    stop_started = None
    while child.poll() is None:
        if cancelled.is_set() or overflow.is_set():
            if stop_started is None:
                stop_started = time.monotonic()
                try: os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError: pass
            elif time.monotonic() - stop_started > 5:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
        time.sleep(0.05)
    stdout_thread.join(); stderr_thread.join()
    if cancelled.is_set(): raise RuntimeError('Worker stopped after cancellation')
    if overflow.is_set() or capture_errors: raise ValueError('Worker output exceeded a capture bound or could not be fully saved')
    response = read_regular(root / 'response.json.partial', MAX_RESPONSE)
    value = json.loads(response)
    if not isinstance(value, dict) or not isinstance(value.get('ok'), bool):
        raise ValueError('Worker did not return a complete JSON envelope')
    if manifest['kind'] == 'calculation':
        request_envelope = json.loads(request)
        if value.get('protocol') != 'floe.chemistry.worker' or value.get('version') != 1 or value.get('identity') != request_envelope['identity'] or value.get('requestDigest') != request_envelope['requestDigest']:
            raise ValueError('Worker response has a different frozen input identity')
    elif child.returncode != 0:
        raise RuntimeError('Capability worker exited with code ' + str(child.returncode))
    os.replace(root / 'response.json.partial', output)
    receipt = dict(schema='floe.chemistry.transport-receipt.v1', attemptID=manifest['attemptID'],
        projectID=manifest['projectID'], taskID=manifest['taskID'], hostRunID=manifest['hostRunID'],
        environmentID=manifest['environmentID'], inputSHA256=manifest['inputSHA256'],
        configurationDigest=manifest['configurationDigest'], manifestSHA256=sys.argv[1],
        responseSHA256=hashlib.sha256(response).hexdigest(), responseBytes=len(response),
        workerExitCode=child.returncode, complete=True)
    receipt_data = json.dumps(receipt, sort_keys=True, separators=(',', ':')).encode()
    atomic(receipt_path, receipt_data)
    print(json.dumps({'chemistryTransport':'complete', 'attemptID':manifest['attemptID'],
        'receiptSHA256':hashlib.sha256(receipt_data).hexdigest()}), flush=True)
except BaseException as exc:
    if child is not None and child.poll() is None:
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        child.wait()
    print(json.dumps({'chemistryTransport':'failed', 'errorType':type(exc).__name__,
        'error':str(exc)[:4096]}), file=sys.stderr, flush=True)
    sys.exit(1)
"""#
}
#endif
