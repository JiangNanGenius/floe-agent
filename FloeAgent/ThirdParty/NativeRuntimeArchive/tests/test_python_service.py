"""Real CPython 3.13 isolated-interpreter service qualification (desktop)."""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.request

try:
    import _interpreters
except ImportError:
    _interpreters = None

BOOTSTRAP = Path(__file__).resolve().parents[2] / "FloeApp/Resources/PythonServiceBootstrap.py"


@unittest.skipIf(_interpreters is None, "Requires CPython 3.13 isolated interpreters")
class PythonServiceTests(unittest.TestCase):
    def test_http_services_do_not_change_foreground_cwd_or_environment(self):
        original_cwd = os.getcwd()
        original_value = os.environ.get("FLOE_SERVICE_TEST")
        with tempfile.TemporaryDirectory(prefix="floe-python-services-") as temp:
            root = Path(temp)
            workers = []
            errors = []
            try:
                for number in range(2):
                    directory = root / str(number)
                    directory.mkdir()
                    (directory / "value.txt").write_text(f"response-{number}")
                    context = {"workingDirectory": str(directory), "environment": {"FLOE_SERVICE_TEST": str(number)}}
                    source = """
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import os
assert os.environ['FLOE_SERVICE_TEST'] == Path(os.getcwd()).name
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(Path('value.txt').read_bytes())
    def log_message(self, *args): pass
server = HTTPServer(('127.0.0.1', 0), Handler)
Path('port').write_text(str(server.server_address[1]))
try:
    server.serve_forever(poll_interval=0.05)
finally:
    server.server_close()
"""
                    interpreter = _interpreters.create("isolated")
                    setup = f"""
import json, os
_floe_context = json.loads({json.dumps(context)!r})
_floe_source = {source!r}
_cancel_path = {str(directory / 'cancel')!r}
_floe_cancelled = lambda: os.path.exists(_cancel_path)
_floe_write = lambda channel, text: None
exec({BOOTSTRAP.read_text()!r})
"""
                    def run(identifier=interpreter, code=setup):
                        try:
                            result = _interpreters.run_string(identifier, code)
                            if result is not None:
                                errors.append(str(result))
                        finally:
                            _interpreters.destroy(identifier)
                    thread = threading.Thread(target=run)
                    workers.append((directory, thread))
                    thread.start()
                for directory, thread in workers:
                    deadline = time.monotonic() + 8
                    while not (directory / "port").exists() and time.monotonic() < deadline and thread.is_alive():
                        time.sleep(0.02)
                    self.assertTrue((directory / "port").exists(), errors)
                    port = (directory / "port").read_text()
                    for _ in range(3):
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2) as response:
                            self.assertEqual(response.read().decode(), f"response-{directory.name}")
                self.assertEqual(os.getcwd(), original_cwd)
                self.assertEqual(os.environ.get("FLOE_SERVICE_TEST"), original_value)
                first, first_thread = workers[0]
                (first / "cancel").touch()
                first_thread.join(5)
                self.assertFalse(first_thread.is_alive(), "Stop must finish interpreter cleanup")
                second, second_thread = workers[1]
                self.assertTrue(second_thread.is_alive(), "Stopping one owner must preserve the other")
                with urllib.request.urlopen(f"http://127.0.0.1:{(second / 'port').read_text()}/", timeout=2) as response:
                    self.assertEqual(response.read(), b"response-1")
            finally:
                for directory, thread in workers:
                    (directory / "cancel").touch()
                for _, thread in workers:
                    thread.join(5)
            self.assertFalse(errors, errors)
            self.assertTrue(all(not thread.is_alive() for _, thread in workers))


if __name__ == "__main__":
    unittest.main()
