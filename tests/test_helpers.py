import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="omafy-auth-test-")
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / "omafy"
        self.tokens = self.state / "token.json"
        self.auth = runpy.run_path(str(REPO / "bin/omafy-auth"))["cmd_token"].__globals__
        self.auth.update(STATE_DIR=str(self.state), TOKEN_PATH=str(self.tokens))
        self.original = {
            "client_id": "dummy-client", "access_token": "cached-token",
            "refresh_token": "refresh-token", "expires_at": int(time.time()) + 3600,
            "scope": "user-library-read", "cache_key": "original-cache-key",
        }
        self.auth["save_tokens"](self.original)

    def command(self, name, args=None, expected_exit=0):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as raised:
            self.auth[name](args)
        self.assertEqual(raised.exception.code, expected_exit)
        return json.loads(output.getvalue())

    def test_save_ignores_legacy_temporary_symlink(self):
        victim = Path(self.temp.name) / "unrelated.txt"
        victim.write_text("keep this")
        legacy = self.state / "token.json.tmp"
        legacy.symlink_to(victim)
        replacement = {**self.original, "access_token": "replacement"}
        self.auth["save_tokens"](replacement)
        self.assertEqual(victim.read_text(), "keep this")
        self.assertEqual(legacy.readlink(), victim)
        self.assertFalse(self.tokens.is_symlink())
        self.assertEqual(json.loads(self.tokens.read_text()), replacement)
        self.assertEqual(self.tokens.stat().st_mode & 0o777, 0o600)

    def test_save_ignores_permissive_legacy_temporary_file(self):
        legacy = self.state / "token.json.tmp"
        legacy.write_text("keep this")
        legacy.chmod(0o666)
        self.tokens.chmod(0o666)
        self.auth["save_tokens"](self.original)
        self.assertEqual(legacy.read_text(), "keep this")
        self.assertEqual(legacy.stat().st_mode & 0o777, 0o666)
        self.assertEqual(self.tokens.stat().st_mode & 0o777, 0o600)

    def test_save_is_private_before_writing_and_atomic_until_replace(self):
        replacement = {**self.original, "access_token": "replacement"}
        dump = json.dump
        observed_modes = []

        def observe_write(data, stream):
            observed_modes.append(os.fstat(stream.fileno()).st_mode & 0o777)
            self.assertEqual(json.loads(self.tokens.read_text()), self.original)
            dump(data, stream)

        # Privacy must not depend on a caller's umask. A restrictive umask must
        # also yield a readable 0600 token file after the descriptor chmod.
        for mask in (0, 0o777):
            with self.subTest(umask=mask):
                old_mask = os.umask(mask)
                try:
                    with patch.object(json, "dump", observe_write):
                        self.auth["save_tokens"](replacement)
                finally:
                    os.umask(old_mask)
                self.assertEqual(json.loads(self.tokens.read_text()), replacement)
                self.assertEqual(self.tokens.stat().st_mode & 0o777, 0o600)
                self.assertEqual(list(self.state.glob(".token-*.tmp")), [])
                self.auth["save_tokens"](self.original)
        self.assertEqual(observed_modes, [0o600, 0o600])

    def test_save_replaces_destination_symlink_without_touching_target(self):
        victim = Path(self.temp.name) / "unrelated.txt"
        victim.write_text("keep this")
        self.tokens.unlink()
        self.tokens.symlink_to(victim)
        self.auth["save_tokens"](self.original)
        self.assertEqual(victim.read_text(), "keep this")
        self.assertFalse(self.tokens.is_symlink())
        self.assertEqual(json.loads(self.tokens.read_text()), self.original)

    def test_failed_serialization_preserves_saved_tokens_and_removes_partial_file(self):
        with self.assertRaises(TypeError):
            self.auth["save_tokens"]({"access_token": "partial-token", "invalid": object()})
        self.assertEqual(json.loads(self.tokens.read_text()), self.original)
        self.assertEqual(list(self.state.iterdir()), [self.tokens])

    def test_failed_permission_change_writes_no_tokens_and_cleans_up(self):
        with patch.object(os, "fchmod", side_effect=OSError("chmod failed")):
            with patch.object(json, "dump", side_effect=AssertionError("must not write tokens")):
                with self.assertRaisesRegex(OSError, "chmod failed"):
                    self.auth["save_tokens"]({**self.original, "access_token": "replacement"})
        self.assertEqual(json.loads(self.tokens.read_text()), self.original)
        self.assertEqual(list(self.state.iterdir()), [self.tokens])

    def test_failed_atomic_replace_preserves_saved_tokens_and_cleans_up(self):
        with patch.object(os, "replace", side_effect=OSError("replace failed")):
            with self.assertRaisesRegex(OSError, "replace failed"):
                self.auth["save_tokens"]({**self.original, "access_token": "replacement"})
        self.assertEqual(json.loads(self.tokens.read_text()), self.original)
        self.assertEqual(list(self.state.iterdir()), [self.tokens])

    def test_cached_token_does_not_refresh(self):
        with patch.dict(self.auth, token_request=lambda _: self.fail("unexpected network request")):
            output = self.command("cmd_token", argparse.Namespace(force_refresh=False))
        self.assertEqual(output["access_token"], "cached-token")
        self.assertEqual(output["cache_key"], "original-cache-key")

    def test_forced_refresh_preserves_grant_identity_scope_and_refresh_token(self):
        calls = []

        def request(params):
            calls.append(params)
            return {"access_token": "replacement-token", "expires_in": 3600}, None

        with patch.dict(self.auth, token_request=request):
            output = self.command("cmd_token", argparse.Namespace(force_refresh=True))
        saved = json.loads(self.tokens.read_text())
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["grant_type"], "refresh_token")
        self.assertEqual(output["access_token"], "replacement-token")
        self.assertEqual(output["cache_key"], "original-cache-key")
        self.assertEqual(saved["refresh_token"], "refresh-token")
        self.assertEqual(output["scope"], "user-library-read")

    def test_expired_token_refreshes_and_preserves_rotated_credentials(self):
        self.auth["save_tokens"]({**self.original, "expires_at": 0})
        with patch.dict(self.auth, token_request=lambda _: ({"access_token": "fresh", "refresh_token": "rotated"}, None)):
            output = self.command("cmd_token", argparse.Namespace(force_refresh=False))
        self.assertEqual(output["access_token"], "fresh")
        self.assertEqual(json.loads(self.tokens.read_text())["refresh_token"], "rotated")

    def test_legacy_tokens_gain_a_stable_cache_key(self):
        legacy = dict(self.original)
        del legacy["cache_key"]
        self.auth["save_tokens"](legacy)
        output = self.command("cmd_token", argparse.Namespace(force_refresh=False))
        again = self.command("cmd_token", argparse.Namespace(force_refresh=False))
        self.assertTrue(output["cache_key"])
        self.assertEqual(output["cache_key"], again["cache_key"])
        self.assertEqual(self.tokens.stat().st_mode & 0o777, 0o600)

    def test_each_sign_in_has_a_new_cache_key(self):
        first = self.auth["store_grant"]({"access_token": "first", "refresh_token": "r1"}, "client")
        second = self.auth["store_grant"]({"access_token": "second", "refresh_token": "r2"}, "client")
        self.assertNotEqual(first["cache_key"], second["cache_key"])

    def test_revoked_refresh_token_removes_saved_credentials(self):
        with patch.dict(self.auth, token_request=lambda _: (None, "invalid_grant")):
            output = self.command("cmd_token", argparse.Namespace(force_refresh=True), expected_exit=2)
        self.assertEqual(output["error"], "not_logged_in")
        self.assertFalse(self.tokens.exists())

    def test_refresh_network_failure_preserves_credentials(self):
        with patch.dict(self.auth, token_request=lambda _: (None, "network: unavailable")):
            output = self.command("cmd_token", argparse.Namespace(force_refresh=True), expected_exit=3)
        self.assertIn("network", output["error"])
        self.assertEqual(json.loads(self.tokens.read_text()), self.original)

    def test_logout_waits_for_a_concurrent_writer_then_removes_its_result(self):
        with self.auth["token_lock"]():
            process = subprocess.Popen(
                [sys.executable, str(REPO / "bin/omafy-auth"), "logout"],
                env={**os.environ, "XDG_STATE_HOME": self.temp.name},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.wait(timeout=0.2)
                self.auth["save_tokens"]({**self.original, "access_token": "late-writer"})
            except BaseException:
                process.kill()
                process.communicate()
                raise
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(json.loads(stdout), {"logged_in": False})
        self.assertFalse(self.tokens.exists())


if __name__ == "__main__":
    unittest.main()
