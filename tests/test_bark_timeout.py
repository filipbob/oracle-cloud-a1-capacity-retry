"""Exercise the helper's overall time budget and retry-loop recovery."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest

import test_retry_jitter


ROOT = Path(__file__).resolve().parents[1]


class SlowReplyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.received.append((self.path, json.loads(data)))
        reply = b'{"code":200}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        try:
            if self.server.slow_reply:
                for byte in reply:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    if self.server.stop_reply.wait(0.4):
                        break
            else:
                self.wfile.write(reply)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        pass


class BarkTimeoutTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), SlowReplyHandler)
        self.server.daemon_threads = False
        self.server.received = []
        self.server.slow_reply = True
        self.server.stop_reply = threading.Event()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.settings = {
            "BARK_KEY": "synthetic-device-key",
            "BARK_SERVER_URL": f"http://127.0.0.1:{self.server.server_port}/bark",
            "BARK_TIMEOUT_SECONDS": "1",
        }

    def tearDown(self):
        self.server.stop_reply.set()
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def run_helper(self, overrides=None):
        environ = os.environ.copy()
        environ.update(self.settings)
        if overrides:
            environ.update(overrides)
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, str(ROOT / "bark_push.py"), "Title", "Unicode: \u2713"],
            env=environ, capture_output=True, text=True, timeout=5,
        )
        return result, time.monotonic() - started

    def test_slow_response_has_an_overall_timeout(self):
        result, elapsed = self.run_helper()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Bark notification timed out", result.stderr)
        self.assertLess(elapsed, 2.5)
        self.assertEqual(len(self.server.received), 1)
        self.assertNotIn(self.settings["BARK_KEY"], result.stdout + result.stderr)
        self.assertNotIn(self.settings["BARK_SERVER_URL"], result.stdout + result.stderr)

    def test_fast_response_still_delivers_unicode(self):
        self.server.slow_reply = False
        result, _ = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.server.received, [("/bark/push", {
            "device_key": "synthetic-device-key", "title": "Title", "body": "Unicode: \u2713",
        })])

    def test_empty_key_skips_the_worker_even_with_an_invalid_timeout(self):
        result, _ = self.run_helper({"BARK_KEY": "", "BARK_TIMEOUT_SECONDS": "invalid"})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.server.received, [])

    def test_invalid_timeout_is_rejected_before_sending(self):
        result, _ = self.run_helper({"BARK_TIMEOUT_SECONDS": "invalid"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Invalid Bark", result.stderr)
        self.assertEqual(self.server.received, [])

    def test_retry_loop_continues_after_notification_timeouts(self):
        fixture = test_retry_jitter.RetryJitterTests()
        result, delays = fixture.run_retry(
            ["success", "capacity"], jitter="0", cycles=2,
            bark=True, bark_settings=self.settings,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(delays, [10, 10])
        self.assertEqual(len(self.server.received), 1)
        self.assertIn("Bark notification timed out", result.stderr)
        self.assertIn("no capacity according to the capacity report", result.stdout)
        self.assertNotIn(self.settings["BARK_KEY"], result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
