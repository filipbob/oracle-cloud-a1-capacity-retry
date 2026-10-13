from contextlib import redirect_stderr
import io
import json
import unittest
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError, URLError

import bark_push


class BarkPushTests(unittest.TestCase):
    def send(self, environ=None, response=b'{"code":200}', error=None):
        settings = {"BARK_KEY": "synthetic-device-key"}
        if environ:
            settings.update(environ)
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value.read.return_value = response
        if error:
            opener.open.side_effect = error
        stderr = io.StringIO()
        with patch.object(bark_push, "build_opener", return_value=opener) as factory:
            with redirect_stderr(stderr):
                success = bark_push.send_notification("Synthetic title", "Unicode body: \u2713", settings)
        return success, opener, factory, stderr.getvalue()

    def test_missing_key_disables_network_access(self):
        success, opener, factory, stderr = self.send({"BARK_KEY": ""})
        self.assertTrue(success)
        factory.assert_not_called()
        opener.open.assert_not_called()
        self.assertEqual(stderr, "")

    def test_json_post_keeps_key_out_of_url_and_headers(self):
        success, opener, factory, stderr = self.send()
        self.assertTrue(success)
        self.assertEqual(stderr, "")
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.day.app/push")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(json.loads(request.data), {
            "device_key": "synthetic-device-key", "title": "Synthetic title",
            "body": "Unicode body: \u2713"})
        self.assertNotIn("synthetic-device-key", request.full_url)
        self.assertNotIn("synthetic-device-key", repr(request.headers))
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 5)
        self.assertIsInstance(factory.call_args.args[0], bark_push.NoRedirects)

    def test_self_hosted_server_and_optional_fields(self):
        success, opener, _, _ = self.send({
            "BARK_SERVER_URL": "https://bark.example.test/notifications/",
            "BARK_TIMEOUT_SECONDS": "8", "BARK_SOUND": "minuet", "BARK_GROUP": "OCI"})
        self.assertTrue(success)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://bark.example.test/notifications/push")
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 8)
        self.assertEqual(json.loads(request.data)["sound"], "minuet")
        self.assertEqual(json.loads(request.data)["group"], "OCI")

    def test_http_self_hosting_is_supported(self):
        success, opener, _, _ = self.send({"BARK_SERVER_URL": "http://bark.example.test"})
        self.assertTrue(success)
        self.assertEqual(opener.open.call_args.args[0].full_url, "http://bark.example.test/push")

    def test_empty_optional_settings_use_defaults(self):
        success, opener, _, _ = self.send({"BARK_SERVER_URL": "", "BARK_TIMEOUT_SECONDS": ""})
        self.assertTrue(success)
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 5)

    def test_invalid_urls_are_rejected_without_echoing_them(self):
        for server in ("file:///synthetic-device-key", "https://", "not-a-url",
                       "https://synthetic-device-key@bark.example.test",
                       "https://bark.example.test/synthetic-device-key",
                       "https://bark.example.test/%73ynthetic-device-key",
                       "https://bark.example.test?key=synthetic-device-key",
                       "https://bark.example.test#synthetic-device-key",
                       "https://bark.example.test:invalid", "https://bark.example.test:99999",
                       "https://bark.example.test\nsynthetic-device-key"):
            with self.subTest(server=server):
                success, opener, factory, stderr = self.send({"BARK_SERVER_URL": server})
                self.assertFalse(success)
                factory.assert_not_called()
                opener.open.assert_not_called()
                self.assertNotIn("synthetic-device-key", stderr)
                self.assertNotIn("bark.example.test", stderr)

    def test_invalid_timeouts_are_rejected(self):
        for timeout in ("0", "-1", "1.5", "nan", "inf", "61", "9999999999999999999"):
            with self.subTest(timeout=timeout):
                success, opener, _, stderr = self.send({"BARK_TIMEOUT_SECONDS": timeout})
                self.assertFalse(success)
                opener.open.assert_not_called()
                self.assertIn("Invalid Bark", stderr)

    def test_all_redirects_are_blocked(self):
        handler = bark_push.NoRedirects()
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status):
                self.assertIsNone(handler.redirect_request(None, None, status, "", {},
                                                          "https://redirect.example.test/push"))

    def test_failure_details_and_credentials_are_never_logged(self):
        errors = [HTTPError("https://bark.example.test/synthetic-device-key", 403,
                            "synthetic-device-key", {}, io.BytesIO(b"synthetic-device-key")),
                  URLError("synthetic-device-key"), TimeoutError("synthetic-device-key")]
        for error in errors:
            with self.subTest(error=type(error).__name__):
                success, _, _, stderr = self.send(error=error)
                self.assertFalse(success)
                self.assertIn("WARNING:", stderr)
                self.assertNotIn("synthetic-device-key", stderr)
                self.assertNotIn("bark.example.test", stderr)

    def test_rejected_or_malformed_responses_are_sanitized(self):
        for response in (b'{"code":400,"message":"synthetic-device-key"}',
                         b'{"message":"synthetic-device-key"}', b'[]', b'null',
                         b'synthetic-device-key', b'\xff', b'x' * 65537):
            with self.subTest(response=response[:30]):
                success, _, _, stderr = self.send(response=response)
                self.assertFalse(success)
                self.assertNotIn("synthetic-device-key", stderr)


if __name__ == "__main__":
    unittest.main()
