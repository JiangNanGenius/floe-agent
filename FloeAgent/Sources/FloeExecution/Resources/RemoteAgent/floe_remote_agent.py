#!/usr/bin/env python3
"""Floe durable remote task and cloud-workspace agent.

SSH is only the loopback enrollment/recovery route. Enrolled Apple devices use
mutual TLS with one independently revocable client certificate per device.
Jobs survive client disconnects and resume by id. Hard safety boundaries are
enforced here instead of relying on model prompts.
"""
import base64, fcntl, hashlib, hmac, ipaddress, json, os, pathlib, re, secrets, signal, socket, ssl
import subprocess, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "1.5.0"
ROOT = pathlib.Path(os.environ.get("FLOE_CLOUD_ROOT", "~/.floe/cloud-workspaces")).expanduser().resolve()
STATE = pathlib.Path(os.environ.get("FLOE_STATE_ROOT", "~/.local/state/floe-agent")).expanduser().resolve()
CONFIG = pathlib.Path(os.environ.get("FLOE_CONFIG_ROOT", "~/.config/floe-agent")).expanduser().resolve()
TOKEN_FILE, PKI = CONFIG / "token", CONFIG / "pki"
PORT, TLS_PORT = int(os.environ.get("FLOE_AGENT_PORT", "43187")), int(os.environ.get("FLOE_AGENT_TLS_PORT", "43188"))
MAX_BYTES, MAX_LOG_BYTES = 10 * 1024 * 1024, 32 * 1024 * 1024
SHARES = STATE / "shares"
WORKSPACE_MARKER = ".floe-owned.json"
for directory in (ROOT, STATE / "tasks", SHARES, PKI): directory.mkdir(parents=True, exist_ok=True)
if not TOKEN_FILE.exists():
    TOKEN_FILE.write_text(secrets.token_urlsafe(48), encoding="utf-8"); os.chmod(TOKEN_FILE, 0o600)
TOKEN, REVOCATIONS = TOKEN_FILE.read_text(encoding="utf-8").strip(), PKI / "revoked-devices.json"

def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".floe-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream: json.dump(value, stream, separators=(",", ":"))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def valid_id(value, label="identifier"):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value):
        raise ValueError(label + " is invalid")
    return value

def resolve(relative):
    if not isinstance(relative, str) or relative.startswith(("/", "~")): raise ValueError("path must be relative")
    candidate = (ROOT / relative).resolve()
    if candidate != ROOT and ROOT not in candidate.parents: raise ValueError("path escapes cloud workspace")
    return candidate

def truth(value): return value is True or (isinstance(value, str) and value.lower() in ("1", "true", "yes", "on"))

def public_address():
    candidates=[]
    try:
        output=subprocess.check_output(["ip","route","get","1.1.1.1"],text=True,timeout=3)
        match=re.search(r"\bsrc\s+(\S+)",output)
        if match: candidates.append(match.group(1))
    except (OSError,subprocess.SubprocessError): pass
    try: candidates.extend(socket.gethostbyname_ex(socket.gethostname())[2])
    except OSError: pass
    for value in candidates:
        try:
            address=ipaddress.ip_address(value)
            if address.is_global: return value, "public"
        except ValueError: pass
    return (candidates[0] if candidates else None), "private"

def safe_domain(value):
    if not value: return None
    value=str(value).strip().lower().rstrip(".")
    if len(value)>253 or not re.fullmatch(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}",value):
        raise ValueError("domain is invalid")
    return value

def available(command):
    from shutil import which
    return which(command) is not None

def share_record(share_id):
    path=SHARES/valid_id(share_id,"share id")/"share.json"
    if not path.exists(): raise ValueError("share not found")
    return json.loads(path.read_text())

def certificate_maintainer():
    """Server-owned renewal loop; it never depends on an attached iPad."""
    while True:
        time.sleep(6*60*60)
        domain_shares=[]
        for path in SHARES.glob("*/share.json"):
            try:
                item=json.loads(path.read_text())
                if item.get("domain") and item.get("state")=="running": domain_shares.append(item)
            except (OSError,ValueError): pass
        if not domain_shares or not available("certbot"): continue
        command=["certbot","renew","--quiet"]
        if available("sudo"): command=["sudo","-n"]+command
        try:
            result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=600)
            atomic_json(STATE/"certificate-status.json",{"checked_at":time.time(),"ok":result.returncode==0,"output":result.stdout[-2048:]})
            if result.returncode==0:
                for item in domain_shares:
                    prefix=SHARES/item["id"]
                    subprocess.run(["nginx","-p",str(prefix)+"/","-c","nginx.conf","-s","reload"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        except (OSError,subprocess.SubprocessError) as error:
            atomic_json(STATE/"certificate-status.json",{"checked_at":time.time(),"ok":False,"error":str(error)})

def create_share(body, device_id):
    if not truth(body.get("explicit_share_authority")): raise ValueError("explicit sharing authority is required")
    source=resolve(body.get("path",""))
    if not source.is_dir(): raise ValueError("share path must be an existing directory")
    if not available("nginx"): raise ValueError("nginx is not installed; ask the model to prepare the host first")
    port=int(body.get("port") or 8080)
    if port<1024 or port>65535 or port in (PORT,TLS_PORT): raise ValueError("share port must be an unreserved, unused Floe port")
    address,scope=public_address(); allow_forwarded=truth(body.get("allow_forwarded_private"))
    if scope=="private" and not allow_forwarded: raise ValueError("host appears private; sharing needs explicit forwarded-private authorization")
    domain=safe_domain(body.get("domain")); share_id=str(uuid.uuid4()); prefix=SHARES/share_id; prefix.mkdir(mode=0o700)
    certificate=None
    if domain:
        if not available("certbot"): raise ValueError("certbot is required for domain HTTPS")
        method=str(body.get("acme_method") or "standalone").strip().lower()
        if method not in ("standalone","nginx","webroot"): raise ValueError("acme_method must be standalone, nginx, or webroot")
        command=["certbot","certonly","--non-interactive","--agree-tos"]
        if method=="webroot": command += ["--webroot","-w",str(source)]
        else: command += ["--"+method]
        command += ["-d",domain]
        email=str(body.get("acme_email") or "").strip()
        command += (["--email",email] if email else ["--register-unsafely-without-email"])
        if available("sudo"): command=["sudo","-n"]+command
        result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=600)
        if result.returncode!=0: raise ValueError("ACME certificate request failed: "+result.stdout[-1024:])
        certificate=f"/etc/letsencrypt/live/{domain}"
    listen=f"{port} ssl" if domain else str(port)
    tls=(f"ssl_certificate {certificate}/fullchain.pem;\nssl_certificate_key {certificate}/privkey.pem;" if domain else "")
    config=f"""pid nginx.pid; error_log error.log; events {{ worker_connections 256; }} http {{ access_log access.log; server {{ listen {listen}; server_name {domain or '_'}; {tls} location / {{ alias {str(source)}/; index index.html; try_files $uri $uri/ =404; }} }} }}"""
    (prefix/"nginx.conf").write_text(config); result=subprocess.run(["nginx","-p",str(prefix)+"/","-c","nginx.conf"],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=15)
    if result.returncode!=0: raise ValueError("nginx failed: "+result.stdout[-1024:])
    firewall=False
    if truth(body.get("manage_firewall")) and available("ufw"):
        command=["ufw","allow",f"{port}/tcp","comment",f"Floe:{share_id}"]
        if available("sudo"): command=["sudo","-n"]+command
        firewall=subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    record={"id":share_id,"state":"running","path":body.get("path"),"port":port,"domain":domain,"scheme":"https" if domain else "http","scope":scope,"detected_address":address,"firewall_managed":firewall,"device_id":device_id or "ssh-recovery","created_at":time.time()}
    atomic_json(prefix/"share.json",record); return record

def create_workspace(body, device_id):
    requested=body.get("workspace_id")
    workspace_id=valid_id(requested,"workspace id") if requested else str(uuid.uuid4())
    target=resolve(workspace_id)
    if target.exists():
        marker=target/WORKSPACE_MARKER
        if not marker.exists(): raise ValueError("workspace path already exists and is not Floe-owned")
        return {"ok":True,"workspace_id":workspace_id,"already_existed":True}
    target.mkdir(mode=0o700,parents=False)
    atomic_json(target/WORKSPACE_MARKER,{"workspace_id":workspace_id,"created_at":time.time(),"device_id":device_id or "ssh-recovery"})
    return {"ok":True,"workspace_id":workspace_id,"already_existed":False}

def list_workspaces():
    rows=[]
    for target in sorted(ROOT.iterdir(),key=lambda path:path.name.casefold()):
        marker=target/WORKSPACE_MARKER
        if not target.is_dir() or not marker.is_file(): continue
        try:
            metadata=json.loads(marker.read_text())
            workspace_id=valid_id(metadata.get("workspace_id"),"workspace id")
            if workspace_id!=target.name: continue
            rows.append({"workspace_id":workspace_id,"created_at":metadata.get("created_at")})
        except (OSError,ValueError,TypeError,json.JSONDecodeError): pass
    return {"workspaces":rows[:500]}

def delete_workspace(workspace_id):
    workspace_id=valid_id(workspace_id,"workspace id"); target=resolve(workspace_id)
    if not target.exists(): return {"ok":True,"workspace_id":workspace_id,"already_absent":True}
    marker=target/WORKSPACE_MARKER
    if not marker.is_file(): raise ValueError("refusing to delete a workspace not created by Floe")
    try:
        metadata=json.loads(marker.read_text())
        if metadata.get("workspace_id")!=workspace_id: raise ValueError("workspace ownership marker mismatch")
    except (OSError,ValueError,TypeError): raise ValueError("workspace ownership marker is invalid")
    import shutil; shutil.rmtree(target)
    return {"ok":True,"workspace_id":workspace_id,"already_absent":False}

def owned_workspace(workspace_id):
    workspace_id=valid_id(workspace_id,"workspace id"); target=resolve(workspace_id)
    marker=target/WORKSPACE_MARKER
    if not target.is_dir() or not marker.is_file(): raise ValueError("Floe-owned cloud workspace not found")
    try: metadata=json.loads(marker.read_text())
    except (OSError,ValueError,TypeError): raise ValueError("workspace ownership marker is invalid")
    if metadata.get("workspace_id")!=workspace_id: raise ValueError("workspace ownership marker mismatch")
    return target

def git_path(value):
    if not isinstance(value,str) or not value or value.startswith(("/","~")): raise ValueError("git path must be workspace-relative")
    normalized=pathlib.PurePosixPath(value)
    if ".." in normalized.parts or normalized.parts[0]==".git": raise ValueError("git path escapes workspace or targets repository metadata")
    return normalized.as_posix()

def git_branch(value):
    if not isinstance(value,str) or not re.fullmatch(r"(?![.-])(?!.*\.\.)(?!.*//)[A-Za-z0-9._/-]{1,200}",value) or value.endswith((".","/")) or "@{" in value:
        raise ValueError("git branch name is invalid")
    return value

def run_git(workspace,args,timeout=60):
    if not available("git"): raise ValueError("git is not installed on the cloud host")
    environment=os.environ.copy(); environment["GIT_TERMINAL_PROMPT"]="0"; environment["GIT_OPTIONAL_LOCKS"]="0"
    try:
        result=subprocess.run(["git","-C",str(workspace)]+args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout,env=environment)
    except subprocess.TimeoutExpired: raise ValueError("git operation timed out")
    output=result.stdout[-512*1024:]
    if result.returncode!=0: raise ValueError("git operation failed: "+output[-4096:])
    return {"ok":True,"exit_code":result.returncode,"output":output}

def git_action(body):
    workspace=owned_workspace(body.get("workspace_id","")); action=str(body.get("action") or "")
    repository=(workspace/".git").exists()
    if action=="initialize":
        if repository: return {"ok":True,"already_initialized":True}
        result=run_git(workspace,["init","-b","main"])
        info=workspace/".git"/"info"; info.mkdir(parents=True,exist_ok=True)
        with (info/"exclude").open("a",encoding="utf-8") as stream: stream.write("\n"+WORKSPACE_MARKER+"\n")
        return result
    if not repository: raise ValueError("cloud workspace is not a Git repository")
    if action=="status": return run_git(workspace,["status","--short","--branch","--untracked-files=all"])
    if action=="diff":
        args=["diff","--no-ext-diff","--"]
        if body.get("path"): args.append(git_path(body["path"]))
        return run_git(workspace,args)
    if action=="log": return run_git(workspace,["log","--max-count=30","--date=iso-strict","--pretty=format:%h%x09%aI%x09%an%x09%s"])
    if action=="stage":
        path=body.get("path"); return run_git(workspace,["add","--",git_path(path)] if path else ["add","--all"])
    if action=="commit":
        message=str(body.get("message") or "").strip()
        if not message or len(message.encode())>8192: raise ValueError("commit message must contain 1 to 8192 bytes")
        return run_git(workspace,["commit","-m",message])
    if action=="fetch": return run_git(workspace,["fetch","--prune"],120)
    if action=="pull": return run_git(workspace,["pull","--ff-only"],120)
    if action=="push": return run_git(workspace,["push"],120)
    if action in ("switch_branch","create_branch"):
        if run_git(workspace,["status","--porcelain"])["output"].strip(): raise ValueError("commit workspace changes before switching branches")
        name=git_branch(body.get("name")); return run_git(workspace,["switch","-c",name] if action=="create_branch" else ["switch",name])
    raise ValueError("unsupported safe git action")

# --- Host-shared Skill library ------------------------------------------------
# Root holds an atomic index.json plus immutable packages/<id>/<digest>
# directories. Task containers mount this root read-only at /opt/floe/skills
# (created by SSHCommandService.runRouted launches); active tasks pin the exact
# digest path, never a movable alias. Published bytes are immutable: a listed
# id+semver can never be replaced by different content.
SHARED_SKILLS = pathlib.Path(os.environ.get("FLOE_SHARED_SKILLS_ROOT", "~/.floe/shared/skills")).expanduser().resolve()
SKILL_PACKAGES, SKILL_STAGING = SHARED_SKILLS / "packages", SHARED_SKILLS / ".staging"
SKILL_INDEX, SKILL_LOCK = SHARED_SKILLS / "index.json", SHARED_SKILLS / ".index.lock"
SKILL_MAX_FILES, SKILL_MAX_TOTAL_BYTES = 256, 8 * 1024 * 1024
SKILL_MAX_FILE_BYTES, SKILL_MAX_MARKDOWN_BYTES, SKILL_MAX_MANIFEST_BYTES = 2 * 1024 * 1024, 256 * 1024, 64 * 1024
SKILL_READ_MAX_BYTES, SKILL_STAGING_TTL = 1048576, 2 * 60 * 60
SKILL_SEMVER = re.compile(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?")
SKILL_GIT = None  # test seam only: callable(arguments, cwd, timeout) -> result(returncode, stdout, stderr)

def run_skill_git(arguments, cwd, timeout=120):
    runner = SKILL_GIT
    if runner is not None: return runner(list(arguments), str(cwd), timeout)
    if not available("git"): raise ValueError("git is not installed on the remote host")
    environment = os.environ.copy(); environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        return subprocess.run(["git"] + list(arguments), cwd=str(cwd), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout, env=environment)
    except subprocess.TimeoutExpired: raise ValueError("git skill operation timed out")

def skill_git_output(result, action):
    if getattr(result, "returncode", 1) != 0:
        stderr = getattr(result, "stderr", b"") or b""
        detail = stderr.decode("utf-8", "replace")[-512:] if isinstance(stderr, (bytes, bytearray)) else str(stderr)[-512:]
        raise ValueError(f"{action} failed: {detail}")
    stdout = getattr(result, "stdout", b"")
    return stdout if isinstance(stdout, (bytes, bytearray)) else str(stdout).encode("utf-8", "replace")

def skill_repository(value):
    if not isinstance(value, str) or not 0 < len(value) <= 512 or value.startswith("-") or any(character.isspace() for character in value):
        raise ValueError("skill repository is invalid")
    patterns = (r"https?://[A-Za-z0-9._-]+(?::\d{1,5})?/[A-Za-z0-9._~%()+/@-]+",
                r"git@[A-Za-z0-9._-]+:[A-Za-z0-9._~/-]+",
                r"ssh://(?:[A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+(?::\d{1,5})?/[A-Za-z0-9._~/-]+")
    if not any(re.fullmatch(pattern, value) for pattern in patterns):
        raise ValueError("skill repository must be an http(s), ssh:// or user@host Git URL")
    scheme = "https://" if value.startswith("https://") else ("http://" if value.startswith("http://") else None)
    if scheme and "@" in value[len(scheme):].split("/", 1)[0]: raise ValueError("skill repository URLs must not embed credentials")
    return value

def skill_subdirectory(value):
    if value is None or value == "": return ""
    if isinstance(value, str) and "\\" in value: raise ValueError("skill subdirectory is invalid")
    return git_path(value)

def skill_frontmatter(data):
    lines = bytes(data).decode("utf-8", "replace").splitlines()[:200]
    if not lines or lines[0].strip() != "---": return {}
    fields = {}
    for line in lines[1:]:
        if line.strip() == "---": break
        match = re.fullmatch(r"([A-Za-z0-9_.-]+):[ \t]*(.*)", line)
        if match: fields[match.group(1).lower()] = match.group(2).strip().strip("\"'")
    return fields

def skill_identity(markdown, manifest, skill_id):
    fields = skill_frontmatter(markdown)
    name = re.sub(r"[\x00-\x1f\x7f]", "", str(fields.get("display_name") or fields.get("name") or ""))[:120] or skill_id
    version = None
    candidate = str(fields.get("version") or "")
    if candidate and SKILL_SEMVER.fullmatch(candidate): version = candidate
    if version is None and manifest:
        try: metadata = json.loads(bytes(manifest).decode("utf-8", "replace"))
        except ValueError: metadata = None
        if isinstance(metadata, dict):
            candidate = str(metadata.get("version") or "")
            if candidate and SKILL_SEMVER.fullmatch(candidate): version = candidate
    return name, version

def skill_tree_digest(entries):
    manifest = "\n".join(f"{path}:{digest}:{mode}" for path, digest, mode in sorted(entries))
    return hashlib.sha256(manifest.encode("utf-8")).hexdigest()

def valid_skill_entry(entry):
    if not isinstance(entry, dict): return False
    try: skill_id = valid_id(entry.get("id"), "skill id")
    except ValueError: return False
    digest = entry.get("digest")
    return (isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
            and entry.get("relative_path") == f"packages/{skill_id}/{digest}"
            and isinstance(entry.get("name"), str) and entry.get("name") != ""
            and isinstance(entry.get("revision"), str) and entry.get("revision") != ""
            and isinstance(entry.get("repository"), str) and entry.get("repository") != ""
            and isinstance(entry.get("ref"), str) and entry.get("ref") != ""
            and isinstance(entry.get("subdirectory"), str)
            and isinstance(entry.get("updated_at"), (int, float))
            and (entry.get("version") is None or isinstance(entry.get("version"), str)))

def skills_index():
    try: value = json.loads(SKILL_INDEX.read_text(encoding="utf-8"))
    except FileNotFoundError: return {"schema_version": 1, "skills": {}, "published": {}}
    except (OSError, ValueError): raise ValueError("shared skills index is unreadable; repair it through authorized host access")
    if not isinstance(value, dict) or value.get("schema_version") != 1: raise ValueError("shared skills index schema is unsupported")
    if not isinstance(value.get("skills"), dict) or not isinstance(value.get("published"), dict): raise ValueError("shared skills index is malformed")
    return value

def skills_locked(action):
    SHARED_SKILLS.mkdir(parents=True, exist_ok=True)
    with open(SKILL_LOCK, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try: return action()
        finally: fcntl.flock(handle, fcntl.LOCK_UN)

def reap_skill_staging():
    import shutil
    if not SKILL_STAGING.is_dir(): return
    for entry in SKILL_STAGING.iterdir():
        try:
            if entry.is_dir() and not entry.is_symlink() and time.time() - entry.stat().st_mtime > SKILL_STAGING_TTL:
                shutil.rmtree(entry, ignore_errors=True)
        except OSError: pass

def verify_skill_package(target, digest):
    import hashlib
    entries = []
    for path in sorted(target.rglob("*")):
        if path.is_symlink(): raise ValueError("symbolic links are not allowed inside skill packages")
        if not path.is_file(): continue
        mode = "100755" if os.access(path, os.X_OK) else "100644"
        entries.append((path.relative_to(target).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest(), mode))
    if skill_tree_digest(entries) != digest: raise ValueError("existing skill package bytes do not match its digest")

def list_skills():
    index = skills_index()
    rows = [index["skills"][key] for key in sorted(index["skills"]) if valid_skill_entry(index["skills"][key])]
    return {"schema_version": 1, "skills": rows}

def read_skill(skill_id, digest, relative):
    skill_id = valid_id(skill_id, "skill id")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest): raise ValueError("skill digest is invalid")
    if not isinstance(relative, str) or not relative or relative.startswith(("/", "~")) or "\0" in relative or "\\" in relative:
        raise ValueError("skill path must be relative")
    parts = pathlib.PurePosixPath(relative).parts
    if not parts or ".." in parts or "." in parts or ".git" in parts: raise ValueError("skill path is invalid")
    base = SKILL_PACKAGES / skill_id / digest
    if os.path.islink(SKILL_PACKAGES / skill_id) or os.path.islink(base): raise ValueError("skill version directory is invalid")
    if not base.is_dir(): raise ValueError("skill version is not published")
    target = base
    for part in parts:
        target = target / part
        if os.path.islink(target): raise ValueError("symbolic links are not allowed inside skill packages")
    if not target.is_file(): raise ValueError("skill file not found")
    data = target.read_bytes()
    if len(data) > SKILL_READ_MAX_BYTES: raise ValueError("skill file is too large to read as text")
    try: content = data.decode("utf-8")
    except UnicodeDecodeError: raise ValueError("skill file is not UTF-8 text")
    return {"skill_id": skill_id, "digest": digest, "path": relative, "content": content, "byte_count": len(data)}

def pull_skill(body):
    import shutil
    skill_id = valid_id(body.get("id", ""), "skill id")
    repository = skill_repository(body.get("repository", ""))
    ref = git_branch(body.get("ref", ""))
    subdirectory = skill_subdirectory(body.get("subdirectory", ""))
    SKILL_STAGING.mkdir(parents=True, exist_ok=True)
    reap_skill_staging()
    staging = SKILL_STAGING / str(uuid.uuid4()); staging.mkdir(mode=0o700)
    try:
        repository_dir = staging / "repository.git"; package = staging / "package"
        skill_git_output(run_skill_git(["init", "-q", "--bare", str(repository_dir)], staging, 30), "git init")
        skill_git_output(run_skill_git(["-C", str(repository_dir), "remote", "add", "origin", repository], staging, 30), "git remote")
        fetched = False
        for arguments in ([["-C", str(repository_dir), "fetch", "-q", "--no-tags", "--depth", "1", "origin", ref],
                           ["-C", str(repository_dir), "fetch", "-q", "--no-tags", "origin", ref]]):
            if run_skill_git(arguments, staging, 180).returncode == 0: fetched = True; break
        if not fetched: raise ValueError("git fetch failed; verify the repository URL, ref and host network access")
        revision = skill_git_output(
            run_skill_git(["-C", str(repository_dir), "rev-parse", "--verify", "FETCH_HEAD^{commit}"], staging, 30),
            "git rev-parse").decode("utf-8", "replace").strip()
        if not re.fullmatch(r"[0-9a-f]{40}", revision): raise ValueError("skill revision is not a Git commit hash")
        arguments = ["-C", str(repository_dir), "ls-tree", "-r", "-l", "--full-tree", revision, "-z"]
        if subdirectory: arguments += ["--", subdirectory]
        listing = skill_git_output(run_skill_git(arguments, staging, 60), "git ls-tree")
        prefix = (subdirectory + "/") if subdirectory else ""
        wanted = []
        for chunk in listing.split(b"\0"):
            if not chunk: continue
            head, tab, raw_path = chunk.partition(b"\t")
            pieces = head.decode("ascii", "replace").split(" ")
            if not tab or len(pieces) != 4: raise ValueError("skill listing is malformed")
            mode, kind, _, size = pieces
            path = raw_path.decode("utf-8", "surrogateescape")
            if kind == "commit": raise ValueError("nested git repositories (submodules) are not supported in skill packages")
            if kind != "blob": continue
            if mode == "120000": raise ValueError("symbolic links are not supported in skill packages")
            if mode not in ("100644", "100755"): raise ValueError("unsupported file mode in skill package")
            parts = pathlib.PurePosixPath(path).parts
            if not path or path.startswith("/") or ".." in parts or "." in parts or ".git" in parts:
                raise ValueError("skill file path is invalid")
            if prefix and not path.startswith(prefix): raise ValueError("skill listing escaped the requested subdirectory")
            relative = path[len(prefix):] if prefix else path
            relative_parts = pathlib.PurePosixPath(relative).parts
            if not relative_parts or ".." in relative_parts or len(relative.encode("utf-8", "surrogateescape")) > 512:
                raise ValueError("skill file path is invalid")
            if size.isdigit() and int(size) > SKILL_MAX_FILE_BYTES: raise ValueError(f"skill file {relative} exceeds the per-file limit")
            wanted.append((relative, path, mode))
        if not wanted: raise ValueError("no files found for the requested skill repository path")
        if len(wanted) > SKILL_MAX_FILES: raise ValueError("skill package exceeds the file-count limit")
        blobs = {}; entries = []; total = 0; package.mkdir(parents=True)
        for relative, path, mode in wanted:
            blob = skill_git_output(
                run_skill_git(["-C", str(repository_dir), "cat-file", "blob", f"{revision}:{path}"], staging, 60),
                "git cat-file")
            if len(blob) > SKILL_MAX_FILE_BYTES: raise ValueError(f"skill file {relative} exceeds the per-file limit")
            if relative == "SKILL.md" and len(blob) > SKILL_MAX_MARKDOWN_BYTES: raise ValueError("SKILL.md exceeds the markdown size limit")
            if relative == "floe.json" and len(blob) > SKILL_MAX_MANIFEST_BYTES: raise ValueError("floe.json exceeds the manifest size limit")
            total += len(blob)
            if total > SKILL_MAX_TOTAL_BYTES: raise ValueError("skill package exceeds the total size limit")
            destination = package.joinpath(*pathlib.PurePosixPath(relative).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(str(destination), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o755 if mode == "100755" else 0o644)
            with os.fdopen(descriptor, "wb") as stream: stream.write(blob)
            blobs[relative] = blob; entries.append((relative, hashlib.sha256(blob).hexdigest(), mode))
        if "SKILL.md" not in blobs: raise ValueError("skill package is missing SKILL.md")
        digest = skill_tree_digest(entries)
        name, version = skill_identity(blobs["SKILL.md"], blobs.get("floe.json"), skill_id)
        def commit():
            index = skills_index()
            current = index["skills"].get(skill_id)
            if current and current.get("digest") == digest: return current
            published = index["published"].setdefault(skill_id, {})
            if digest not in published and version:
                for other, record in published.items():
                    if other != digest and record.get("version") == version:
                        raise ValueError(f"published skill version {skill_id}@{version} already exists with different bytes; publish a new version")
            target = SKILL_PACKAGES / skill_id / digest
            if target.exists():
                if digest not in published: verify_skill_package(target, digest)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(str(package), str(target))
            entry = {"id": skill_id, "name": name, "version": version, "repository": repository, "ref": ref,
                     "subdirectory": subdirectory, "revision": revision, "digest": digest,
                     "relative_path": f"packages/{skill_id}/{digest}", "updated_at": time.time()}
            index["skills"][skill_id] = entry
            published[digest] = {"version": version, "name": name, "revision": revision, "committed_at": entry["updated_at"]}
            atomic_json(SKILL_INDEX, index)
            return entry
        return skills_locked(commit)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

def stop_share(share_id):
    record=share_record(share_id); prefix=SHARES/share_id
    subprocess.run(["nginx","-p",str(prefix)+"/","-c","nginx.conf","-s","quit"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if record.get("firewall_managed") and available("ufw"):
        command=["ufw","delete","allow",f"{record['port']}/tcp"]
        if available("sudo"): command=["sudo","-n"]+command
        subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    record["state"]="stopped"; record["stopped_at"]=time.time(); atomic_json(prefix/"share.json",record); return record

def revoked():
    try:
        value = json.loads(REVOCATIONS.read_text()); return set(value if isinstance(value, list) else [])
    except (FileNotFoundError, ValueError): return set()

def peer_device(connection):
    try: certificate = connection.getpeercert()
    except (AttributeError, ssl.SSLError): return None
    for group in certificate.get("subject", ()):
        for key, value in group:
            if key == "commonName" and value.startswith("floe-device-"): return value[12:]
    return None

HARD_DENY = (
    re.compile(r"(^|[;&|]\s*)rm\s+(-[^\n]*\s+)*(--no-preserve-root\s+)?/(\s|$)"),
    re.compile(r"\b(mkfs(?:\.[a-z0-9]+)?|wipefs|fdisk|parted)\b", re.I),
    re.compile(r"\bdd\b[^\n]*\bof=/dev/(sd|nvme|mmcblk|vd)", re.I),
    re.compile(r"\b(shutdown|poweroff|halt|reboot)\b", re.I),
    re.compile(r">\s*/dev/(sd|nvme|mmcblk|vd)", re.I),
    re.compile(r"\biptables\s+(-F|--flush)\b|\bnft\s+flush\s+ruleset\b", re.I),
)
def validate_command(command):
    if not isinstance(command, str) or not command.strip() or len(command) > 32768: raise ValueError("command is empty or too large")
    if any(pattern.search(command) for pattern in HARD_DENY): raise ValueError("non-bypassable destructive-action boundary")

def task_dir(task_id): return STATE / "tasks" / valid_id(task_id, "task id")
def task_record(task_id):
    directory, path = task_dir(task_id), task_dir(task_id) / "task.json"
    if not path.exists(): raise ValueError("task not found")
    record = json.loads(path.read_text()); result = directory / "result.json"
    if result.exists(): record.update(json.loads(result.read_text()))
    elif record.get("pid"):
        try: os.kill(int(record["pid"]), 0); record["state"] = "running"
        except (ProcessLookupError, PermissionError, ValueError): record["state"] = "interrupted"
    return record

def cancel_task(task_id, device_id=None):
    record = task_record(task_id)
    if device_id and record.get("device_id") != device_id:
        raise ValueError("task belongs to another device")
    if record["state"] in ("succeeded", "failed", "cancelled", "interrupted"):
        return record
    if record.get("cancellation_protocol") != 1:
        raise ValueError("legacy task cannot be safely cancelled; inspect its process through authorized SSH")
    # Never signal a PID read from disk: it may have been reused. The runner
    # that owns the unreaped Popen child handles this idempotent request.
    atomic_json(task_dir(task_id) / "cancel.request", {"requested_at": time.time()})
    record["state"] = "cancelRequested"
    return record

TASK_RUNNER = '''import json,os,signal,subprocess,sys,time
argv=json.loads(sys.argv[1]); started=time.time(); cancelled=False
with open(sys.argv[2],'ab',buffering=0) as out:
 p=subprocess.Popen(argv,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 open(sys.argv[4],'w').write(str(p.pid))
 while p.poll() is None:
  if os.path.exists(sys.argv[5]):
   cancelled=True
   try: os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError: pass
   try: p.wait(timeout=3)
   except subprocess.TimeoutExpired:
    try: os.killpg(p.pid,signal.SIGKILL)
    except ProcessLookupError: pass
    p.wait()
   break
  time.sleep(0.05)
 code=p.wait()
 tmp=sys.argv[3]+'.tmp'
 with open(tmp,'w') as result:
  json.dump({'state':'cancelled' if cancelled else ('succeeded' if code==0 else 'failed'),'exit_code':code,'ended_at':time.time(),'duration':time.time()-started},result)
 os.replace(tmp,sys.argv[3])
'''

def launch_task(body, device_id):
    command, target = body.get("command", ""), body.get("target") or {"kind": "container"}
    validate_command(command); kind = target.get("kind", "container")
    if kind == "container": argv = ["docker", "exec", valid_id(target.get("container", ""), "container"), "sh", "-lc", command]
    elif kind == "host" and body.get("explicit_host_authority") is True: argv = ["sh", "-lc", command]
    else: raise ValueError("target must be a container, or explicitly authorized host execution")
    requested_id=body.get("task_id")
    task_id=valid_id(requested_id,"task id") if requested_id else str(uuid.uuid4())
    directory = task_dir(task_id)
    if directory.exists():
        record=task_record(task_id)
        expected=hashlib.sha256(command.encode()).hexdigest()
        if record.get("command_sha256")!=expected: raise ValueError("task id already belongs to another command")
        return record
    directory.mkdir(mode=0o700)
    runner = directory / "runner.py"
    runner.write_text(TASK_RUNNER)
    wrapper = subprocess.Popen(["python3", str(runner), json.dumps(argv), str(directory/"events.log"), str(directory/"result.json"), str(directory/"child.pid"), str(directory/"cancel.request")], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    record = {"id":task_id,"state":"running","target":target,"command_sha256":hashlib.sha256(command.encode()).hexdigest(),"device_id":device_id or "ssh-recovery","created_at":time.time(),"pid":wrapper.pid,"cancellation_protocol":1}
    atomic_json(directory / "task.json", record)
    threading.Thread(target=wrapper.wait, daemon=True).start()
    return record

SHELLS = {}
SHELLS_LOCK = threading.RLock()
SHELL_MAX_AGE = 30 * 60
SHELL_MAX_SESSIONS = 16
SHELL_MAX_PER_DEVICE = 4

def _shell_entry(shell_id, device_id):
    with SHELLS_LOCK:
        entry = SHELLS.get(shell_id)
        if entry and entry["device_id"] != (device_id or "ssh-recovery"):
            raise ValueError("shell belongs to another device")
        return entry

def _shell_reap(entry):
    if entry["alive"]:
        try:
            pid, _ = os.waitpid(entry["pid"], os.WNOHANG)
            if pid: entry["alive"] = False
        except ChildProcessError:
            entry["alive"] = False
    return not entry["alive"]

def shell_cleanup():
    with SHELLS_LOCK:
        expired = [(key, entry["device_id"]) for key, entry in SHELLS.items()
                   if time.monotonic() - entry["created"] > SHELL_MAX_AGE]
    for key, owner in expired:
        shell_close(key, owner)

def shell_maintainer():
    while True:
        time.sleep(10)
        shell_cleanup()

def _shell_drain(fd, wait, max_bytes):
    import select as _select
    chunks, total, deadline = [], 0, time.monotonic() + wait
    while total < max_bytes:
        remaining = deadline - time.monotonic()
        if remaining <= 0: break
        ready, _, _ = _select.select([fd], [], [], remaining)
        if not ready: break
        try: chunk = os.read(fd, min(65536, max_bytes - total))
        except OSError: break
        if not chunk: break
        chunks.append(chunk); total += len(chunk)
    return b"".join(chunks)

def shell_open(body, device_id=None):
    import pty, fcntl, termios, struct
    shell_cleanup()
    owner = device_id or "ssh-recovery"
    term = re.sub(r"[^A-Za-z0-9._-]", "", str(body.get("term", "xterm-256color")))[:32] or "xterm-256color"
    cols = min(max(int(body.get("cols", 80)), 20), 500); rows = min(max(int(body.get("rows", 24)), 5), 200)
    with SHELLS_LOCK:
        if len(SHELLS) >= SHELL_MAX_SESSIONS or sum(e["device_id"] == owner for e in SHELLS.values()) >= SHELL_MAX_PER_DEVICE:
            raise ValueError("shell session limit reached; close an existing session")
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = term
            shell = os.environ.get("SHELL") or "/bin/sh"
            try: os.execvp(shell, [shell, "-i"])
            except Exception: os._exit(127)
        shell_id = str(uuid.uuid4())
        entry = {"pid": pid, "fd": fd, "created": time.monotonic(), "alive": True,
                 "device_id": owner, "lock": threading.RLock(), "closed": False}
        SHELLS[shell_id] = entry
    try:
        with entry["lock"]:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            os.set_blocking(fd, False)
            data = _shell_drain(fd, 0.4, 65536)
    except Exception:
        shell_close(shell_id, owner)
        raise
    return {"shell_id": shell_id, "alive": True, "data_base64": base64.b64encode(data).decode()}

def shell_io(shell_id, body, device_id=None):
    entry = _shell_entry(shell_id, device_id)
    if not entry: raise ValueError("shell not found")
    if time.monotonic() - entry["created"] > SHELL_MAX_AGE:
        shell_close(shell_id, device_id); raise ValueError("shell expired")
    with entry["lock"]:
        if entry["closed"]: raise ValueError("shell closed")
        return _shell_exchange(shell_id, entry, body)

def _shell_exchange(shell_id, entry, body):
    raw = body.get("input_base64") or ""
    if raw:
        data_in = base64.b64decode(raw, validate=True)
        if len(data_in) > 65536: raise ValueError("input too large")
        if not entry["alive"]: raise ValueError("shell exited")
        import select
        offset, deadline = 0, time.monotonic() + 2
        while offset < len(data_in):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [entry["fd"]], [], remaining)[1]:
                raise ValueError(f"shell input timed out after {offset} of {len(data_in)} bytes; do not replay blindly")
            try: offset += os.write(entry["fd"], data_in[offset:])
            except BlockingIOError: continue
    wait = min(max(float(body.get("wait_ms", 200)) / 1000.0, 0.05), 2)
    max_bytes = min(max(int(body.get("max_bytes", 65536)), 1), 262144)
    data = _shell_drain(entry["fd"], wait, max_bytes)
    _shell_reap(entry)
    if not entry["alive"]:
        data += _shell_drain(entry["fd"], 0.1, max(0, max_bytes - len(data)))
    return {"shell_id": shell_id, "alive": entry["alive"], "data_base64": base64.b64encode(data).decode()}

def shell_close(shell_id, device_id=None):
    entry = _shell_entry(shell_id, device_id)
    if not entry: return {"ok": True}
    with entry["lock"]:
        if entry["closed"]: return {"ok": True}
        # Never signal a PID after reaping it: the OS may have reused it.
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGKILL):
            if _shell_reap(entry): break
            try: os.killpg(entry["pid"], sig)
            except ProcessLookupError: pass
            deadline = time.monotonic() + 0.3
            while time.monotonic() < deadline and not _shell_reap(entry): time.sleep(0.01)
        try: os.close(entry["fd"])
        except OSError: pass
        entry["closed"] = True
        with SHELLS_LOCK:
            SHELLS.pop(shell_id, None)
        if entry["alive"]:
            # A kernel-stalled child must not block the HTTP request thread.
            threading.Thread(target=lambda: os.waitpid(entry["pid"], 0), daemon=True).start()
    return {"ok": True}

class Handler(BaseHTTPRequestHandler):
    server_version = "FloeRemoteAgent/" + VERSION
    def log_message(self, fmt, *args): pass
    def _bearer(self):
        raw=self.headers.get("Authorization",""); return raw.startswith("Bearer ") and hmac.compare_digest(raw[7:],TOKEN)
    def _device(self):
        value=peer_device(self.connection); return value if value and value not in revoked() else None
    def _send(self,status,body):
        data=json.dumps(body,separators=(",",":"),ensure_ascii=False).encode(); self.send_response(status); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def _guard(self):
        if self._bearer() or self._device(): return True
        self._send(401,{"error":"unauthorized"}); return False
    def _body(self):
        size=int(self.headers.get("Content-Length","0"))
        if size<0 or size>MAX_BYTES*2: raise ValueError("request too large")
        value=json.loads(self.rfile.read(size) or b"{}")
        if not isinstance(value,dict): raise ValueError("JSON object required")
        return value
    def do_GET(self):
        if not self._guard(): return
        try:
            parsed=urlparse(self.path); query=parse_qs(parsed.query); relative=query.get("path",[""])[0]
            if parsed.path=="/v1/health": return self._send(200,{"ok":True,"version":VERSION,"transport":"mtls" if self._device() else "ssh-tunnel"})
            if parsed.path=="/v1/tasks":
                rows=[]
                for path in sorted((STATE/"tasks").iterdir(),reverse=True):
                    try: rows.append(task_record(path.name))
                    except (ValueError,OSError): pass
                return self._send(200,{"tasks":rows[:200]})
            if parsed.path=="/v1/capabilities":
                address,scope=public_address()
                certificate={}
                try: certificate=json.loads((STATE/"certificate-status.json").read_text())
                except (OSError,ValueError): pass
                return self._send(200,{"version":VERSION,"docker":available("docker"),"nginx":available("nginx"),"certbot":available("certbot"),"ufw":available("ufw"),"network_scope":scope,"detected_address":address,"certificate_maintenance":certificate,"interactive_shell":True,"shared_skills":True})
            if parsed.path=="/v1/skills": return self._send(200,list_skills())
            if parsed.path.startswith("/v1/skills/"):
                pieces=parsed.path.strip("/").split("/")
                if len(pieces)==6 and pieces[3]=="versions" and pieces[5]=="read": return self._send(200,read_skill(pieces[2],pieces[4],relative))
                return self._send(404,{"error":"not_found"})
            if parsed.path=="/v1/workspaces": return self._send(200,list_workspaces())
            if parsed.path=="/v1/shares":
                rows=[]
                for path in SHARES.glob("*/share.json"):
                    try: rows.append(json.loads(path.read_text()))
                    except (OSError,ValueError): pass
                return self._send(200,{"shares":sorted(rows,key=lambda item:item.get("created_at",0),reverse=True)})
            if parsed.path.startswith("/v1/tasks/"):
                pieces=parsed.path.strip("/").split("/"); record=task_record(pieces[2])
                if len(pieces)==3: return self._send(200,record)
                if len(pieces)==4 and pieces[3]=="events":
                    offset=max(0,int(query.get("offset",["0"])[0])); log=task_dir(pieces[2])/"events.log"; data=b""
                    if log.exists():
                        with log.open("rb") as stream: stream.seek(offset); data=stream.read(min(MAX_BYTES,max(0,MAX_LOG_BYTES-offset)))
                    return self._send(200,{"id":pieces[2],"offset":offset,"next_offset":offset+len(data),"data_base64":base64.b64encode(data).decode(),"state":record.get("state")})
            target=resolve(relative)
            if parsed.path=="/v1/files/list":
                rows=[]
                for item in sorted(target.iterdir(),key=lambda p:p.name.casefold()):
                    stat=item.stat(); rows.append({"name":item.name,"directory":item.is_dir(),"bytes":stat.st_size,"mtime":stat.st_mtime})
                return self._send(200,{"path":relative,"entries":rows})
            if parsed.path=="/v1/files/read":
                data=target.read_bytes()
                if len(data)>MAX_BYTES: raise ValueError("file too large")
                return self._send(200,{"path":relative,"sha256":hashlib.sha256(data).hexdigest(),"data_base64":base64.b64encode(data).decode()})
            self._send(404,{"error":"not_found"})
        except Exception as error: self._send(400,{"error":str(error)})
    def do_POST(self):
        if not self._guard(): return
        try:
            body=self._body()
            if self.path=="/v1/shell": return self._send(202,shell_open(body,self._device()))
            if self.path.startswith("/v1/shell/"):
                pieces=self.path.strip("/").split("/")
                if len(pieces)==4 and pieces[3]=="io": return self._send(200,shell_io(pieces[2],body,self._device()))
                if len(pieces)==4 and pieces[3]=="close": return self._send(200,shell_close(pieces[2],self._device()))
                return self._send(404,{"error":"not_found"})
            if self.path=="/v1/tasks": return self._send(202,launch_task(body,self._device()))
            if self.path=="/v1/skills/pull": return self._send(200,pull_skill(body))
            if self.path=="/v1/workspaces/create": return self._send(201,create_workspace(body,self._device()))
            if self.path=="/v1/shares/plan":
                address,scope=public_address(); domain=safe_domain(body.get("domain"))
                return self._send(200,{"network_scope":scope,"detected_address":address,"domain":domain,"scheme":"https" if domain else "http","requires_forwarded_private_authority":scope=="private","dependencies":{"nginx":available("nginx"),"certbot":available("certbot") if domain else None,"ufw":available("ufw")}})
            if self.path=="/v1/shares": return self._send(201,create_share(body,self._device()))
            if self.path.startswith("/v1/shares/") and self.path.endswith("/stop"):
                share_id=self.path.strip("/").split("/")[2]; return self._send(200,stop_share(share_id))
            if self.path.startswith("/v1/tasks/") and self.path.endswith("/cancel"):
                task_id=self.path.strip("/").split("/")[2]
                return self._send(200,cancel_task(task_id,None if self._bearer() else self._device()))
            if self.path=="/v1/workspaces/delete":
                return self._send(200,delete_workspace(body.get("workspace_id","")))
            if self.path=="/v1/git": return self._send(200,git_action(body))
            target=resolve(body.get("path",""))
            if self.path=="/v1/files/mkdir": target.mkdir(parents=True,exist_ok=True); return self._send(200,{"ok":True})
            if self.path=="/v1/files/write":
                data=base64.b64decode(body.get("data_base64",""),validate=True)
                if len(data)>MAX_BYTES: raise ValueError("file too large")
                target.parent.mkdir(parents=True,exist_ok=True); fd,temporary=tempfile.mkstemp(prefix=".floe-",dir=str(target.parent))
                try:
                    with os.fdopen(fd,"wb") as stream: stream.write(data)
                    os.replace(temporary,target)
                finally:
                    if os.path.exists(temporary): os.unlink(temporary)
                return self._send(200,{"ok":True,"sha256":hashlib.sha256(data).hexdigest()})
            if self.path=="/v1/devices/revoke":
                if not self._bearer(): return self._send(403,{"error":"recovery credential required"})
                device_id=valid_id(body.get("device_id",""),"device id"); values=revoked(); values.add(device_id); atomic_json(REVOCATIONS,sorted(values)); return self._send(200,{"ok":True,"device_id":device_id})
            self._send(404,{"error":"not_found"})
        except Exception as error: self._send(400,{"error":str(error)})

def serve():
    threading.Thread(target=shell_maintainer,daemon=True).start()
    threading.Thread(target=certificate_maintainer,daemon=True).start()
    loopback=ThreadingHTTPServer(("127.0.0.1",PORT),Handler); ca,certificate,key=PKI/"ca.crt",PKI/"server.crt",PKI/"server.key"
    if ca.exists() and certificate.exists() and key.exists():
        context=ssl.create_default_context(ssl.Purpose.CLIENT_AUTH); context.verify_mode=ssl.CERT_REQUIRED; context.load_verify_locations(cafile=str(ca)); context.load_cert_chain(certfile=str(certificate),keyfile=str(key))
        tls=ThreadingHTTPServer((os.environ.get("FLOE_AGENT_TLS_BIND","0.0.0.0"),TLS_PORT),Handler); tls.socket=context.wrap_socket(tls.socket,server_side=True); threading.Thread(target=tls.serve_forever,daemon=True).start()
    loopback.serve_forever()
if __name__=="__main__": serve()
