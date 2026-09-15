# SPDX-License-Identifier: MPL-2.0
"""Real TLS RDP traffic through xrdp. No mocked native callbacks or inputs."""
import ctypes as C
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import ssl
import sys
import threading
import time

root = Path(sys.argv[1])
lib = C.CDLL(str(root / 'libFloeRDP.so'))
U16, U32, U8, P = C.c_uint16, C.c_uint32, C.c_uint8, C.c_void_p
class Options(C.Structure):
    _fields_ = [('host', C.c_char_p), ('port', U16), ('username', C.c_char_p), ('password', C.c_char_p), ('domain', C.c_char_p), ('width', U32), ('height', U32)]
class Input(C.Structure):
    _fields_ = [(name, U16) for name in ('kind', 'flags', 'code', 'x', 'y')]
State = C.CFUNCTYPE(None, P, C.c_int, U32)
Frame = C.CFUNCTYPE(None, P, C.POINTER(U8), U32, U32, U32)
Certificate = C.CFUNCTYPE(C.c_int, P, C.POINTER(U8), C.c_size_t, C.c_char_p, U16)
class Callbacks(C.Structure):
    _fields_ = [('user', P), ('state', State), ('frame', Frame), ('certificate', Certificate)]
lib.floe_rdp_create.argtypes = [C.POINTER(Options), Callbacks]
lib.floe_rdp_create.restype = P
lib.floe_rdp_start.argtypes = [P]
lib.floe_rdp_stop.argtypes = [P]
lib.floe_rdp_stop.restype = None
lib.floe_rdp_destroy.argtypes = [P]
lib.floe_rdp_input.argtypes = [P, C.POINTER(Input), C.c_size_t]
lib.floe_rdp_version.restype = C.c_char_p
expected = ssl.PEM_cert_to_DER_cert((root / 'certificate.pem').read_text())
records = []
def wait(predicate, seconds=20):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError('RDP fixture condition timed out')

class Session:
    def __init__(self, accept=True):
        self.states, self.frames, self.certificates = [], deque(maxlen=200), 0
        self.last = None
        self.guard = threading.Lock()
        @State
        def state(_, value, error):
            with self.guard: self.states.append((value, error))
        @Frame
        def frame(_, data, width, height, stride):
            if not (0 < width <= 4096 and 0 < height <= 4096 and width*4 <= stride and stride*height <= 32*1024*1024):
                return
            payload = C.string_at(data, stride*height)
            # A fixed full-screen fixture color proves this is the remote desktop,
            # not merely xrdp's login frame or an allocated zeroed framebuffer.
            pixel = payload[(height-10)*stride + 10*4: (height-10)*stride + 10*4+3]
            with self.guard:
                self.last = (payload, width, height, stride)
                self.frames.append((hashlib.sha256(payload).hexdigest(), pixel.hex()))
            if pixel == bytes.fromhex('563412') and not (root / 'desktop.ppm').exists():
                rgb = bytearray()
                for y in range(height):
                    row = payload[y*stride:y*stride+width*4]
                    for x in range(0, len(row), 4): rgb.extend(row[x:x+3][::-1])
                (root/'desktop.ppm').write_bytes(f'P6\n{width} {height}\n255\n'.encode()+rgb)
        @Certificate
        def certificate(_, data, count, host, port):
            with self.guard: self.certificates += 1
            try:
                pem = C.string_at(data, count).decode('ascii')
                first = pem[:pem.index('-----END CERTIFICATE-----')+25]
                return int(accept and host == b'127.0.0.1' and port == 3390 and ssl.PEM_cert_to_DER_cert(first) == expected)
            except (ValueError, UnicodeError): return 0
        self.callbacks = Callbacks(None, state, frame, certificate)
        self.options = Options(b'127.0.0.1',3390,b'fixture',os.environ['FLOE_RDP_FIXTURE_PASSWORD'].encode(),b'',800,600)
        self.pointer = lib.floe_rdp_create(C.byref(self.options), self.callbacks)
        assert self.pointer
    def start(self): assert lib.floe_rdp_start(self.pointer) == 1
    def connected(self):
        with self.guard: return any(v == 2 for v, _ in self.states)
    def desktop(self):
        with self.guard: return any(pixel == '563412' for _, pixel in self.frames)
    def close(self):
        started = time.monotonic()
        lib.floe_rdp_stop(self.pointer)
        assert lib.floe_rdp_destroy(self.pointer) == 1
        self.pointer = None
        elapsed = time.monotonic()-started
        assert elapsed < 5, elapsed
        records.append({'states':self.states,'frames':len(self.frames),'samplePixels':[pixel for _,pixel in list(self.frames)[-10:]],'certificateCallbacks':self.certificates,'shutdownSeconds':round(elapsed,3)})
        if self.last:
            payload,width,height,stride = self.last
            rgb = bytearray()
            for y in range(height):
                row=payload[y*stride:y*stride+width*4]
                for x in range(0,len(row),4):rgb.extend(row[x:x+3][::-1])
            (root/'last-desktop.ppm').write_bytes(f'P6\n{width} {height}\n255\n'.encode()+rgb)
        (root/'sessions.json').write_text(json.dumps(records,indent=2)+'\n')
        print(json.dumps(records[-1]))

# Reject an untrusted certificate; no accepted frame or input.
s = Session(accept=False)
try:
    s.start()
    wait(lambda: any(v == 3 for v, _ in s.states))
    assert s.certificates > 0 and not s.connected() and not s.frames
finally: s.close()
# Repeated real sessions verify callbacks can be disposed then recreated safely.
for index in range(3):
    s = Session()
    try:
        s.start(); wait(s.connected); wait(s.desktop)
        path = Path(os.environ['FLOE_RDP_FIXTURE_EVENTS'])
        before = path.read_text() if path.exists() else ''
        events = (Input * 7)(Input(0,0x0800,0,200,150),Input(0,0x9000,0,200,150),Input(0,0x1000,0,200,150),
            Input(1,0x4000,0x1e,0,0),Input(1,0x8000,0x1e,0,0),Input(1,0x4000,0x1c,0,0),Input(1,0x8000,0x1c,0,0))
        assert lib.floe_rdp_input(s.pointer,events,len(events)) == 1
        wait(lambda: path.exists() and 'a\nReturn\n' in path.read_text()[len(before):])
        oversized = (Input * 16385)()
        assert lib.floe_rdp_input(s.pointer,oversized,len(oversized)) == 0
    finally: s.close()
# Cancel while connecting; native destroy must join, no freed callback context.
s = Session()
s.start(); s.close()
(root/'result.json').write_text(json.dumps({'source':os.environ.get('GITHUB_SHA'),'runtime':lib.floe_rdp_version().decode(),
    'coverage':'Linux real TLS RDP bridge, xrdp VNC backend; not Apple App or Windows NLA acceptance',
    'passed':['certificate rejection','three connect/frame/input/close cycles','atomic oversized batch rejection','connecting cancellation'], 'sessions':records},indent=2)+'\n')
print((root/'result.json').read_text())
