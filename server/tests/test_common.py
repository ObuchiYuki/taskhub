import unittest

from taskhub.common import TaskHubError, canonical, normalized, text, timestamp


class CommonTests(unittest.TestCase):
    def test_timestamp_ascii_and_calendar_contract(self):
        self.assertEqual(timestamp("2024-02-29T23:59:59Z"), "2024-02-29T23:59:59Z")
        for value in ("２０２６-10-10T12:00:00Z", "٢٠٢٦-10-10T12:00:00Z", "2026-02-29T00:00:00Z",
                      "2026-10-10", "2026-10-10T00:00:00+00:00", "2026-10-10T24:00:00Z", None):
            with self.subTest(value=value), self.assertRaises(TaskHubError):
                timestamp(value)

    def test_text_bounds_and_controls(self):
        for value in (" ", "bad\x1bname", "bad\x00name", "\ud800"):
            with self.subTest(value=repr(value)), self.assertRaises(TaskHubError):
                text(value, "actor", limit=128, single_line=True)
        with self.assertRaises(TaskHubError):
            text("あ" * 43, "actor", limit=128)
        self.assertEqual(text("multi\nline", "body"), "multi\nline")
        self.assertEqual(normalized("ＡＢＣ"), "abc")

    def test_sync_keeps_linux_keyring_environment_and_drops_git_overrides(self):
        import os
        from unittest.mock import patch
        from taskhub.sync import _environment
        with patch.dict(os.environ, {"DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
                                    "XDG_RUNTIME_DIR": "/run/user/1000", "GIT_SSH_COMMAND": "unsafe"}):
            env = _environment()
        self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/user/1000/bus")
        self.assertEqual(env["XDG_RUNTIME_DIR"], "/run/user/1000")
        self.assertNotIn("GIT_SSH_COMMAND", env)

    def test_canonical_bytes_are_stable_utf8(self):
        self.assertEqual(canonical({"b": "日本語", "a": 1}), '{"a":1,"b":"日本語"}\n'.encode())
        self.assertEqual(canonical({"b": 2, "a": 1}), canonical({"a": 1, "b": 2}))


if __name__ == "__main__":
    unittest.main()
