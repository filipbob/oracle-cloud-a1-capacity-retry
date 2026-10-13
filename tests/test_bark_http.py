"""Verify the actual HTTP transport against a local server with synthetic keys."""

from contextlib import redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import threading
import unittest

import bark_push


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.received.append((self.path, json.loads(data)))
        self.send_response(self.server.status)
        self.send_header("Content-Type", "application/json")
        if self.server.status in (301, 302, 303, 307, 308):
            self.send_header("Location", "/redirect-destination")
        self.end_headers()
        self.wfile.write(json.dumps(self.server.reply).encode())

    def do_GET(self):
        self.server.received.append((self.path, None))
        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        pass


class BarkHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def setUp(self):
        self.server.received = []
        self.server.status = 200
        self.server.reply = {"code": 200}
        self.settings = {
            "BARK_KEY": "synthetic-device-key",
            "BARK_SERVER_URL": f"http://127.0.0.1:{self.server.server_port}/bark",
            "BARK_TIMEOUT_SECONDS": "2",
        }

    def test_real_json_post_and_unicode(self):
        self.assertTrue(bark_push.send_notification("Synthetic title", "Unicode: \u2713", self.settings))
        self.assertEqual(self.server.received, [("/bark/push", {
            "device_key": "synthetic-device-key", "title": "Synthetic title", "body": "Unicode: \u2713"})])

    def test_redirect_never_receives_credentials_or_a_second_request(self):
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status):
                self.server.status = status
                self.server.received = []
                with redirect_stderr(io.StringIO()):
                    self.assertFalse(bark_push.send_notification("Title", "Body", self.settings))
                self.assertEqual(len(self.server.received), 1)
                self.assertEqual(self.server.received[0][0], "/bark/push")

    def test_real_server_failure_is_sanitized(self):
        for status, code in ((403, 403), (200, 500)):
            with self.subTest(status=status, code=code):
                self.server.status = status
                self.server.reply = {"code": code, "message": "synthetic-device-key"}
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    self.assertFalse(bark_push.send_notification("Title", "Body", self.settings))
                self.assertNotIn("synthetic-device-key", stderr.getvalue())
                self.assertNotIn(self.settings["BARK_SERVER_URL"], stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
