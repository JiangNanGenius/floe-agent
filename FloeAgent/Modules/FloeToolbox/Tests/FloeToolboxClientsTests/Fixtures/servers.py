"""Loopback-only protocol fixtures. No external network, accounts or user files."""
import base64
import hashlib
import http.server
import json
import socketserver
import struct
import sys
import threading


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            midpoint = max(1, len(data) // 2)
            self.request.sendall(data[:midpoint])
            self.request.sendall(data[midpoint:])


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, connection = self.request
        connection.sendto(data, self.client_address)


class HTTPHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        print("fixture request method=%s upgrade=%s" % (self.command, bool(self.headers.get("Upgrade"))), file=sys.stderr, flush=True)
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.websocket()
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:%d/other" % self.server.foreign_port)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(8):
                    block = b"a" * 4096
                    self.wfile.write(b"1000\r\n" + block + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > 16 * 1024 * 1024:
            self.send_error(413)
            return
        body = self.rfile.read(length) if length else b"response"
        self.send_response(201 if self.command == "POST" else 200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Set-Cookie", "synthetic-cookie=value")
        self.end_headers()
        self.wfile.write(body)

    def websocket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.connection.settimeout(5)
        print("fixture WebSocket handshake sent", file=sys.stderr, flush=True)
        try:
            while True:
                head = self.rfile.read(2)
                if len(head) != 2:
                    return
                opcode, masked, size = head[0] & 15, head[1] & 128, head[1] & 127
                if size == 126:
                    size = struct.unpack("!H", self.rfile.read(2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", self.rfile.read(8))[0]
                if size > 1024 * 1024 or not masked:
                    return
                mask = self.rfile.read(4)
                data = self.rfile.read(size)
                if len(mask) != 4 or len(data) != size:
                    return
                data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
                if opcode == 8:
                    self.frame(8, data[:125])
                    return
                if opcode == 9:
                    self.frame(10, data)
                elif opcode in (1, 2):
                    self.frame(opcode, data)
        except (OSError, ValueError):
            return

    def frame(self, opcode, data):
        if len(data) < 126:
            header = bytes([128 | opcode, len(data)])
        elif len(data) < 65536:
            header = bytes([128 | opcode, 126]) + struct.pack("!H", len(data))
        else:
            header = bytes([128 | opcode, 127]) + struct.pack("!Q", len(data))
        self.wfile.write(header + data)
        self.wfile.flush()


tcp = socketserver.ThreadingTCPServer(("127.0.0.1", 0), TCPHandler)
udp = socketserver.ThreadingUDPServer(("127.0.0.1", 0), UDPHandler)
http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
http.foreign_port = tcp.server_address[1]
for server in (tcp, udp, http):
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
print(json.dumps({"tcp": tcp.server_address[1], "udp": udp.server_address[1], "http": http.server_address[1]}), flush=True)
threading.Event().wait()
