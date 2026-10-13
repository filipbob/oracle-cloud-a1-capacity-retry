"""Exercise the real retry loop with synthetic OCI replies and no real waits."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MOCK_OCI = """
import json
import os
from pathlib import Path
import sys

command = ' '.join(sys.argv[1:])
state = Path(os.environ['TEST_STATE'])
scenarios = json.loads(os.environ['TEST_SCENARIOS'])
if 'iam tenancy get' in command:
    print('synthetic-tenancy')
elif 'compute instance list' in command:
    print('[]')
elif 'compute compute-capacity-report create' in command:
    index = int(state.read_text()) if state.exists() else 0
    scenario = scenarios[min(index, len(scenarios) - 1)]
    state.write_text(str(index + 1))
    if scenario == 'capacity':
        print('OUT_OF_HOST_CAPACITY')
    elif scenario == 'rate_limit':
        print('TooManyRequests', file=sys.stderr)
        sys.exit(1)
    elif scenario == 'error':
        print('Temporary service error', file=sys.stderr)
        sys.exit(1)
    else:
        print('AVAILABLE')
elif 'compute instance launch' in command:
    index = int(state.read_text()) - 1
    scenario = scenarios[min(index, len(scenarios) - 1)]
    if scenario == 'success':
        print('ocid1.instance.mock.synthetic')
    elif scenario == 'uncertain':
        print('No instance identifier returned')
    elif scenario == 'network':
        print('ConnectionError', file=sys.stderr)
        sys.exit(1)
    elif scenario == 'launch_rate_limit':
        print('TooManyRequests', file=sys.stderr)
        sys.exit(1)
    else:
        sys.exit('Unexpected synthetic launch scenario')
else:
    sys.exit('Unexpected OCI command in test')
"""


class RetryJitterTests(unittest.TestCase):
    def run_retry(self, scenarios, jitter="30", cycles=4, ads="AD-1", ntp=False,
                  dry_run=False, bark=False, bark_settings=None):
        with tempfile.TemporaryDirectory(prefix="retry-jitter-test-") as directory:
            work = Path(directory)
            cli = work / "mock-oci"
            cli.write_text(f"#!{sys.executable}\n" + MOCK_OCI)
            cli.chmod(0o700)
            config = work / "synthetic-config"
            config.touch()
            key = work / "synthetic-public-key"
            key.touch()
            waits = work / "waits"
            settings = {
                "OCI_CONFIG_FILE": str(config), "SSH_KEY_FILE": str(key),
                "OCI_BIN": str(cli), "LOCK_FILE": str(work / "retry.lock"),
                "SUBNET_ID": "synthetic-subnet", "IMAGE_ID": "synthetic-image",
                "SLEEP_SECONDS": "10", "MAX_RETRY_DELAY_SECONDS": "40",
                "CAPACITY_REQUEST_DELAY_SECONDS": "2", "ADS": ads,
                "LOG_TO_FILE": "0", "NTP_CHECK_ENABLED": "1" if ntp else "0",
                "NTP_RETRY_DELAY_SECONDS": "3", "NETWORK_RECHECK_DELAYS": "1,2",
                "NTP_SERVERS": "synthetic-clock",
                "SNTP_BIN": "mock_sntp", "DRY_RUN": "1" if dry_run else "0",
            }
            if jitter is not None:
                settings["RETRY_JITTER_SECONDS"] = jitter
            if bark:
                # The default failure fixture never makes a network request.
                settings["BARK_KEY"] = "synthetic-device-key"
                settings["BARK_SERVER_URL"] = "invalid://synthetic-bark-server"
                if bark_settings:
                    settings.update(bark_settings)
            # Override the safe template in this temporary fixture only.
            env_file = work / "fixture.env"
            env_file.write_text((ROOT / ".env.example").read_text() + "\n" +
                                "\n".join(f"{k}={shlex.quote(v)}"
                                          for k, v in settings.items()) + "\n" +
                                ("unset RETRY_JITTER_SECONDS\n" if jitter is None else "") +
                                """
test_cycles=0
sleep() {
  printf '%s\n' "$1" >> "$TEST_WAITS"
  if (( $1 >= 10 )); then
    test_cycles=$((test_cycles + 1))
    if (( test_cycles >= TEST_CYCLES )); then
      exit 0
    fi
  fi
}
mock_sntp() {
  # File state survives the command substitution used by the NTP check.
  if [[ ! -f "$TEST_NTP_STATE" ]]; then
    touch "$TEST_NTP_STATE"
    return 1
  fi
  echo '0.001 synthetic clock offset'
}
osascript() { :; }
""")
            env = os.environ.copy()
            env.update({"ENV_FILE": str(env_file), "DRY_RUN": settings["DRY_RUN"],
                        "TEST_STATE": str(work / "state"),
                        "TEST_NTP_STATE": str(work / "ntp-state"),
                        "TEST_SCENARIOS": json.dumps(scenarios),
                        "TEST_WAITS": str(waits), "TEST_CYCLES": str(cycles)})
            env.pop("RETRY_JITTER_SECONDS", None)
            result = subprocess.run(["bash", str(ROOT / "oci_capacity_retry.sh")],
                                    env=env, capture_output=True, text=True, timeout=15)
            delays = [int(value) for value in waits.read_text().splitlines()] if waits.exists() else []
            return result, delays

    def assert_delays(self, scenarios, bases, jitter="30", **kwargs):
        result, delays = self.run_retry(scenarios, jitter, len(bases), **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cycle_delays = [delay for delay in delays if delay >= 10]
        self.assertEqual(len(cycle_delays), len(bases))
        for delay, base in zip(cycle_delays, bases):
            self.assertGreaterEqual(delay, base)
            self.assertLessEqual(delay, base + int(jitter or 0))
        logged = [int(value) for value in
                  re.findall(r'(?:[Ww]aiting |retrying in )(\d+)s', result.stdout)]
        self.assertEqual(logged, delays if kwargs.get("ntp") else cycle_delays)
        return delays

    def test_disabled_and_missing_setting_preserve_backoff(self):
        for jitter in ("0", None):
            with self.subTest(jitter=jitter):
                self.assertEqual(self.assert_delays(["capacity"], [10, 20, 40, 40], jitter),
                                 [10, 20, 40, 40])

    def test_capacity_backoff_is_capped_without_accumulating_jitter(self):
        self.assert_delays(["capacity"], [10, 20, 40, 40, 40, 40])

    def test_rate_limit_backoff(self):
        self.assert_delays(["rate_limit"], [20, 40, 40, 40])

    def test_launch_rate_limit_backoff(self):
        self.assert_delays(["launch_rate_limit"], [20, 40, 40, 40])

    def test_temporary_error_resets_base(self):
        self.assert_delays(["capacity", "error", "capacity", "capacity"],
                           [10, 10, 10, 20])

    def test_success_resets_base(self):
        self.assert_delays(["capacity", "success", "capacity", "capacity"],
                           [10, 10, 10, 20])

    def test_uncertain_launch_resets_base(self):
        self.assert_delays(["capacity", "uncertain", "capacity", "capacity"],
                           [10, 10, 10, 20])

    def test_capacity_call_spacing_is_unchanged(self):
        delays = self.assert_delays(["capacity"], [10, 20], ads="AD-1,AD-2,AD-3")
        self.assertEqual([delay for delay in delays if delay < 10], [2, 2, 2, 2])

    def test_network_rechecks_are_unchanged(self):
        delays = self.assert_delays(["network"], [10, 10])
        self.assertEqual([delay for delay in delays if delay < 10], [1, 2, 1, 2])

    def test_ntp_recovery_wait_is_unchanged(self):
        delays = self.assert_delays(["capacity"], [10, 20], ntp=True)
        self.assertEqual([delay for delay in delays if delay < 10], [3])

    def test_invalid_jitter_fails_even_in_dry_run(self):
        for jitter in ("-1", "1.5", "abc", "01", "32768", "999999999999999999999", "1+2"):
            with self.subTest(jitter=jitter):
                result, delays = self.run_retry(["capacity"], jitter, dry_run=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("RETRY_JITTER_SECONDS must be an integer", result.stdout)
                self.assertEqual(delays, [])

    def test_maximum_supported_jitter(self):
        self.assert_delays(["capacity"], [10, 20, 40], jitter="32767")

    def test_failed_bark_notification_does_not_interrupt_retry(self):
        result, delays = self.run_retry(["success"], cycles=2, bark=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(delays), 2)
        self.assertIn("Invalid Bark", result.stderr)
        self.assertEqual(result.stdout.count("[NOTIFICATION]"), 2)
        self.assertNotIn("synthetic-device-key", result.stdout + result.stderr)

    def test_dry_run_never_sends_bark_notifications(self):
        result, delays = self.run_retry(["success"], dry_run=True, bark=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(delays, [])
        self.assertNotIn("Bark", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
