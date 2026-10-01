"""Exercise actual curl transport recovery without fetching large fonts."""
import http.server
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import fetch_fonts


class DownloadTests(unittest.TestCase):
    def test_real_connection_drop_recovers_in_same_curl_batch(self):
        calls = []
        requests = []
        payload = b'complete-font-transport-fixture'

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                requests.append(self.path)
                if len(requests) == 1:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        real_run = subprocess.run

        def run(cmd, **kwargs):
            calls.append(list(cmd))
            self.assertIn('--retry-all-errors', cmd)
            self.assertEqual(cmd[cmd.index('--retry-max-time') + 1], '120')
            self.assertEqual(cmd[cmd.index('--max-time') + 1], '300')
            # Only test timing/proxy isolation changes; execute real curl.
            cmd = list(cmd)
            cmd[cmd.index('--retry-delay') + 1] = '0'
            return real_run(cmd + ['--noproxy', '*'], **kwargs)

        try:
            with tempfile.TemporaryDirectory() as tmp:
                dest = Path(tmp) / 'font.otf'
                with patch.object(fetch_fonts.subprocess, 'run', run):
                    fetch_fonts.download(f'http://127.0.0.1:{server.server_port}/font', dest)
                self.assertEqual(dest.read_bytes(), payload)
                self.assertFalse(Path(str(dest) + '.part').exists())
            self.assertEqual(len(calls), 1)
            self.assertEqual(len(requests), 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_permanent_failure_preserves_partial_without_promotion(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / 'font.otf'
            partial = Path(str(dest) + '.part')
            partial.write_bytes(b'incomplete')
            error = subprocess.CompletedProcess([], 56, '', 'transport failed')
            with patch.object(fetch_fonts.subprocess, 'run', return_value=error) as run:
                with self.assertRaisesRegex(RuntimeError, 'curl failed \\(56\\)'):
                    fetch_fonts.download('https://example.test/font.otf', dest)
                self.assertEqual(run.call_count, 2)
                self.assertIn('-C', run.call_args_list[0].args[0])
                self.assertNotIn('-C', run.call_args_list[1].args[0])
            self.assertFalse(dest.exists())
            self.assertEqual(partial.read_bytes(), b'incomplete')

    def test_existing_cache_is_not_downloaded_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / 'font.otf'
            dest.write_bytes(b'existing')
            with patch.object(fetch_fonts.subprocess, 'run') as run:
                fetch_fonts.download('https://example.test/font.otf', dest)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
