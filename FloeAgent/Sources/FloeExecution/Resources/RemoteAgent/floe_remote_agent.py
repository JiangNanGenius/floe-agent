#!/usr/bin/env python3
"""Floe durable remote task and cloud-workspace agent.

SSH is only the loopback enrollment/recovery route. Enrolled Apple devices use
mutual TLS with one independently revocable client certificate per device.
Jobs survive client disconnects and resume by id. Hard safety boundaries are
enforced here instead of relying on model prompts.
"""
import base64, hashlib, hmac, ipaddress, json, os, pathlib, re, secrets, signal, socket, ssl
import subprocess, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "1.2.0"
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

def launch_task(body, device_id):
    command, target = body.get("command", ""), body.get("target") or {"kind": "container"}
    validate_command(command); kind = target.get("kind", "container")
    if kind == "container": argv = ["docker", "exec", valid_id(target.get("container", ""), "container"), "sh", "-lc", command]
    elif kind == "host" and body.get("explicit_host_authority") is True: argv = ["sh", "-lc", command]
    else: raise ValueError("target must be a container, or explicitly authorized host execution")
    task_id, directory = str(uuid.uuid4()), None
    directory = task_dir(task_id); directory.mkdir(mode=0o700)
    runner = directory / "runner.py"
    runner.write_text("import json,os,subprocess,sys,time\nargv=json.loads(sys.argv[1]); started=time.time()\nwith open(sys.argv[2],'ab',buffering=0) as out:\n p=subprocess.Popen(argv,stdout=out,stderr=subprocess.STDOUT,start_new_session=True); open(sys.argv[4],'w').write(str(p.pid)); code=p.wait()\n tmp=sys.argv[3]+'.tmp'; open(tmp,'w').write(json.dumps({'state':'succeeded' if code==0 else 'failed','exit_code':code,'ended_at':time.time(),'duration':time.time()-started})); os.replace(tmp,sys.argv[3])\n")
    wrapper = subprocess.Popen(["python3", str(runner), json.dumps(argv), str(directory/"events.log"), str(directory/"result.json"), str(directory/"child.pid")], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    record = {"id":task_id,"state":"running","target":target,"command_sha256":hashlib.sha256(command.encode()).hexdigest(),"device_id":device_id or "ssh-recovery","created_at":time.time(),"pid":wrapper.pid}
    atomic_json(directory / "task.json", record); return record

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
                return self._send(200,{"version":VERSION,"docker":available("docker"),"nginx":available("nginx"),"certbot":available("certbot"),"ufw":available("ufw"),"network_scope":scope,"detected_address":address,"certificate_maintenance":certificate})
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
            if self.path=="/v1/tasks": return self._send(202,launch_task(body,self._device()))
            if self.path=="/v1/workspaces/create": return self._send(201,create_workspace(body,self._device()))
            if self.path=="/v1/shares/plan":
                address,scope=public_address(); domain=safe_domain(body.get("domain"))
                return self._send(200,{"network_scope":scope,"detected_address":address,"domain":domain,"scheme":"https" if domain else "http","requires_forwarded_private_authority":scope=="private","dependencies":{"nginx":available("nginx"),"certbot":available("certbot") if domain else None,"ufw":available("ufw")}})
            if self.path=="/v1/shares": return self._send(201,create_share(body,self._device()))
            if self.path.startswith("/v1/shares/") and self.path.endswith("/stop"):
                share_id=self.path.strip("/").split("/")[2]; return self._send(200,stop_share(share_id))
            if self.path.startswith("/v1/tasks/") and self.path.endswith("/cancel"):
                task_id=self.path.strip("/").split("/")[2]; record=task_record(task_id); pid_path=task_dir(task_id)/"child.pid"; pid=int(pid_path.read_text()) if pid_path.exists() else int(record.get("pid",0))
                if pid>1: os.killpg(pid,signal.SIGTERM)
                atomic_json(task_dir(task_id)/"result.json",{"state":"cancelled","ended_at":time.time()}); return self._send(200,{"ok":True,"id":task_id})
            if self.path=="/v1/workspaces/delete":
                return self._send(200,delete_workspace(body.get("workspace_id","")))
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
    threading.Thread(target=certificate_maintainer,daemon=True).start()
    loopback=ThreadingHTTPServer(("127.0.0.1",PORT),Handler); ca,certificate,key=PKI/"ca.crt",PKI/"server.crt",PKI/"server.key"
    if ca.exists() and certificate.exists() and key.exists():
        context=ssl.create_default_context(ssl.Purpose.CLIENT_AUTH); context.verify_mode=ssl.CERT_REQUIRED; context.load_verify_locations(cafile=str(ca)); context.load_cert_chain(certfile=str(certificate),keyfile=str(key))
        tls=ThreadingHTTPServer((os.environ.get("FLOE_AGENT_TLS_BIND","0.0.0.0"),TLS_PORT),Handler); tls.socket=context.wrap_socket(tls.socket,server_side=True); threading.Thread(target=tls.serve_forever,daemon=True).start()
    loopback.serve_forever()
if __name__=="__main__": serve()
