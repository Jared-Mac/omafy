import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
HELPER = str(REPO / "bin/omafy-player")
BUNDLED_UNIT = REPO / "systemd/omafy-player.service"


class PlayerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="omafy-player-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.cache = self.base / 'cache space%"\\$literal'
        self.credentials = self.cache / "omafy/librespot/credentials.json"
        self.credentials.parent.mkdir(parents=True)
        self.credentials.write_text("{}")
        self.config = self.base / "config space"
        self.unit = self.config / "systemd/user/omafy-player.service"
        self.unit.parent.mkdir(parents=True)
        self.dropin = self.unit.parent / "omafy-player.service.d/10-omafy-cache.conf"
        self.log = self.base / "calls.jsonl"
        fakebin = self.base / "bin"
        fakebin.mkdir()
        mock = fakebin / "systemctl"
        mock.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[1] == "show":
    if os.environ.get("TEST_SHOW_FAIL"):
        sys.exit(1)
    if "TEST_PROPERTIES" in os.environ:
        print(os.environ["TEST_PROPERTIES"])
    else:
        unit = Path(os.environ["XDG_CONFIG_HOME"]) / "systemd/user/omafy-player.service"
        dropin = unit.parent / "omafy-player.service.d/10-omafy-cache.conf"
        print("LoadState=" + ("loaded" if unit.exists() else "not-found"))
        print("FragmentPath=" + (str(unit) if unit.exists() else ""))
        print("DropInPaths=" + (str(dropin) if dropin.exists() else ""))
        print("Transient=no")
elif args[1] == os.environ.get("TEST_FAIL_ACTION"):
    sys.exit(1)
''')
        mock.chmod(0o755)
        # A conflicting setup must never launch OAuth. The marker catches it
        # without invoking the real receiver or accessing Spotify.
        receiver = fakebin / "librespot"
        receiver.write_text('''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
Path(os.environ["TEST_OAUTH_MARKER"]).touch()
if not os.environ.get("TEST_OAUTH_SUCCESS"):
    sys.exit(1)
cache = Path(sys.argv[sys.argv.index("--cache") + 1])
(cache / "credentials.json").write_text("{}")
print("Authenticated as test", flush=True)
time.sleep(30)
''')
        receiver.chmod(0o755)
        self.oauth_marker = self.base / "oauth-started"
        self.env = {**os.environ, "XDG_CACHE_HOME": str(self.cache), "XDG_CONFIG_HOME": str(self.config),
                    "PATH": str(fakebin) + os.pathsep + os.environ["PATH"],
                    "TEST_LOG": str(self.log), "TEST_OAUTH_MARKER": str(self.oauth_marker)}

    def run_helper(self, command, success=True, **env):
        result = subprocess.run([HELPER, command], env={**self.env, **env},
                                capture_output=True, text=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def mutations(self):
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [call[1:] for call in calls if call[1] not in ("show", "is-active")]

    def clear_log(self):
        self.log.unlink(missing_ok=True)

    def write_dropin(self, contents):
        self.dropin.parent.mkdir(parents=True, exist_ok=True)
        self.dropin.write_text(contents)

    def assert_conflict_preserved(self):
        # Exercise both cached and first-time sign-in paths. Neither may stop
        # a service, reload systemd, start OAuth, or remove credentials.
        for command in ("setup", "start", "stop", "restart", "logout", "uninstall"):
            with self.subTest(command=command):
                self.assertIn("Refusing", self.run_helper(command, success=False).stderr)
                self.assertEqual(self.credentials.read_text(), "{}")
                self.assertEqual(self.mutations(), [])
        self.credentials.unlink()
        self.run_helper("setup", success=False)
        self.assertEqual(self.mutations(), [])
        self.assertFalse(self.oauth_marker.exists())

    def test_setup_reuses_owned_files_without_rewriting_and_logout_uses_custom_cache(self):
        self.run_helper("setup")
        self.assertEqual(self.unit.resolve(), BUNDLED_UNIT)
        escaped = str(self.credentials.parent).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
        self.assertEqual(self.dropin.read_text(), f'[Service]\nEnvironment="OMAFY_CACHE_DIR={escaped}"\n')
        before = [(p.lstat().st_ino, p.lstat().st_mtime_ns) for p in (self.unit, self.dropin)]
        self.run_helper("setup")
        self.assertEqual(before, [(p.lstat().st_ino, p.lstat().st_mtime_ns) for p in (self.unit, self.dropin)])
        self.assertIn(["enable", "--now", self.unit.name], self.mutations())
        self.run_helper("logout")
        self.assertFalse(self.credentials.exists())
        self.assertIn(["disable", "--now", self.unit.name], self.mutations())

    def test_regular_user_unit_is_preserved(self):
        original = "[Service]\nExecStart=/usr/bin/sleep infinity\n"
        self.unit.write_text(original)
        self.assert_conflict_preserved()
        self.assertEqual(self.unit.read_text(), original)
        self.assertFalse(self.dropin.exists())

    def test_first_signin_does_not_stop_any_service(self):
        self.credentials.unlink()
        self.run_helper("setup", TEST_OAUTH_SUCCESS="1")
        self.assertTrue(self.oauth_marker.exists())
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)
        self.assertFalse(any(call[0] == "stop" for call in self.mutations()))

    def test_signin_stops_only_owned_service_and_aborts_if_stop_fails(self):
        self.run_helper("setup")
        self.credentials.unlink()
        self.clear_log()
        self.run_helper("setup", success=False, TEST_FAIL_ACTION="stop", TEST_OAUTH_SUCCESS="1")
        self.assertFalse(self.oauth_marker.exists())
        self.assertEqual(self.mutations(), [["stop", self.unit.name]])
        self.clear_log()
        self.run_helper("setup", TEST_OAUTH_SUCCESS="1")
        self.assertEqual(self.mutations()[0], ["stop", self.unit.name])
        self.assertTrue(self.oauth_marker.exists())

    def test_foreign_unit_symlink_is_preserved(self):
        foreign = self.base / "unrelated.service"
        foreign.write_text("unrelated")
        self.unit.symlink_to(foreign)
        self.assert_conflict_preserved()
        self.assertEqual(self.unit.readlink(), foreign)
        self.assertEqual(foreign.read_text(), "unrelated")

    def test_dangling_unit_symlink_is_preserved(self):
        target = self.base / "missing.service"
        self.unit.symlink_to(target)
        self.assert_conflict_preserved()
        self.assertEqual(self.unit.readlink(), target)

    def test_unit_directory_is_preserved(self):
        self.unit.mkdir()
        self.assert_conflict_preserved()
        self.assertEqual(list(self.unit.iterdir()), [])

    def test_modified_generated_dropin_is_preserved(self):
        self.run_helper("setup")
        self.clear_log()
        original = self.dropin.read_text() + 'Environment="USER_SETTING=keep"\n'
        self.dropin.write_text(original)
        self.assert_conflict_preserved()
        self.assertEqual(self.dropin.read_text(), original)

    def test_foreign_dropin_without_unit_is_preserved(self):
        self.write_dropin("[Service]\nExecStart=/usr/bin/sleep infinity\n")
        original = self.dropin.read_bytes()
        self.assert_conflict_preserved()
        self.assertEqual(self.dropin.read_bytes(), original)
        self.assertFalse(self.unit.exists())

    def test_dropin_symlink_is_never_followed_even_if_content_matches(self):
        self.run_helper("setup")
        self.clear_log()
        foreign = self.base / "user.conf"
        self.dropin.rename(foreign)
        original = foreign.read_bytes()
        self.dropin.symlink_to(foreign)
        self.assert_conflict_preserved()
        self.assertEqual(foreign.read_bytes(), original)
        self.assertEqual(self.dropin.readlink(), foreign)

    def test_dangling_dropin_symlink_is_preserved(self):
        self.dropin.parent.mkdir()
        target = self.base / "missing.conf"
        self.dropin.symlink_to(target)
        self.assert_conflict_preserved()
        self.assertFalse(target.exists())
        self.assertEqual(self.dropin.readlink(), target)

    def test_symlinked_dropin_directory_is_preserved(self):
        target = self.base / "user-dropins"
        target.mkdir()
        self.dropin.parent.symlink_to(target)
        self.assert_conflict_preserved()
        self.assertEqual(list(target.iterdir()), [])

    def test_additional_custom_dropin_blocks_service_changes(self):
        self.run_helper("setup")
        self.clear_log()
        custom = self.dropin.with_name("90-custom.conf")
        custom.write_text("[Service]\nExecStart=/usr/bin/sleep infinity\n")
        self.assert_conflict_preserved()
        self.assertIn("sleep", custom.read_text())

    def test_different_cache_path_requires_explicit_resolution(self):
        self.run_helper("setup")
        self.clear_log()
        original = self.dropin.read_bytes()
        self.run_helper("setup", success=False, XDG_CACHE_HOME=str(self.base / "other-cache"))
        self.assertEqual(self.dropin.read_bytes(), original)
        self.assertEqual(self.mutations(), [])
        self.assertFalse(self.oauth_marker.exists())

    def test_shadowing_runtime_or_global_service_blocks_setup(self):
        for fragment in ("/run/user/1000/systemd/user/omafy-player.service", "/usr/lib/systemd/user/omafy-player.service"):
            with self.subTest(fragment=fragment):
                properties = f"LoadState=loaded\nFragmentPath={fragment}\nDropInPaths=\nTransient=no"
                self.run_helper("setup", success=False, TEST_PROPERTIES=properties)
                self.assertEqual(self.mutations(), [])
                self.assertFalse(self.unit.exists())

    def test_effective_global_dropin_blocks_service_changes(self):
        self.run_helper("setup")
        self.clear_log()
        properties = f"LoadState=loaded\nFragmentPath={self.unit}\nDropInPaths=/etc/systemd/user/service.d/custom.conf\nTransient=no"
        self.run_helper("restart", success=False, TEST_PROPERTIES=properties)
        self.assertEqual(self.mutations(), [])

    def test_manager_inspection_failure_is_fail_closed(self):
        self.run_helper("setup", success=False, TEST_SHOW_FAIL="1")
        self.run_helper("setup", success=False, TEST_PROPERTIES="")
        self.assertEqual(self.mutations(), [])
        self.assertFalse(self.unit.exists())

    def test_start_requires_setup_and_manages_only_owned_installation(self):
        self.run_helper("start", success=False)
        self.assertEqual(self.mutations(), [])
        self.run_helper("setup")
        self.clear_log()
        for command in ("start", "stop", "restart"):
            self.run_helper(command)
        self.assertEqual(self.mutations(), [[command, self.unit.name] for command in ("start", "stop", "restart")])

    def test_disable_failure_preserves_credentials_and_installation(self):
        self.run_helper("setup")
        self.run_helper("uninstall", success=False, TEST_FAIL_ACTION="disable")
        self.assertTrue(self.credentials.exists())
        self.assertTrue(self.unit.is_symlink())
        self.assertTrue(self.dropin.exists())

    def test_uninstall_removes_only_owned_files_and_keeps_other_directory_contents(self):
        self.run_helper("setup")
        notes = self.dropin.with_name("notes.txt")
        notes.write_text("keep this")
        self.run_helper("uninstall")
        self.assertFalse(self.credentials.exists())
        self.assertFalse(self.unit.is_symlink())
        self.assertFalse(self.dropin.exists())
        self.assertEqual(notes.read_text(), "keep this")
        self.run_helper("uninstall")  # Safe to repeat after removal.


if __name__ == "__main__":
    unittest.main()
