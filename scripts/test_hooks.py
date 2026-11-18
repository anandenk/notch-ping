import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("hooks", Path(__file__).with_name("hooks.py"))
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)


class HookSettingsTests(unittest.TestCase):
    @unittest.skipIf(__import__("sys").version_info < (3, 11), "Optional setup requires Python 3.11")
    def test_runtime_trust_accepts_only_documented_session_end_exception(self):
        from codex_hook_setup import valid_runtime_settings
        hook = {"eventName": "sessionEnd", "async": False, "timeoutSec": 1, "isManaged": False}
        self.assertTrue(valid_runtime_settings(hook))
        self.assertFalse(valid_runtime_settings(dict(hook, eventName="stop")))
        self.assertFalse(valid_runtime_settings(dict(hook, timeoutSec=10)))
        self.assertFalse(valid_runtime_settings(dict(hook, isManaged=True)))
        self.assertTrue(valid_runtime_settings(dict(hook, eventName="stop", **{"async": True})))

    def test_install_is_idempotent_and_uninstall_preserves_other_hooks(self):
        helper = Path("/tmp/space in path/notch-relay")
        original = {"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "existing"}]}]}}
        installed = hooks.amend(original, "claude", helper, True)
        self.assertEqual(installed, hooks.amend(installed, "claude", helper, True))
        self.assertEqual(original, hooks.amend(installed, "claude", helper, False))
        for groups in installed["hooks"].values():
            for group in groups:
                for handler in group["hooks"]:
                    if handler["command"] != "existing":
                        self.assertTrue(handler["async"])

    def test_invalid_settings_are_not_silently_replaced(self):
        with self.assertRaises(ValueError):
            hooks.amend({"hooks": "unexpected"}, "codex", Path("/tmp/notch-relay"), True)

    def test_agy_install_and_uninstall_preserves_other_hooks(self):
        helper = Path("/tmp/notch-relay")
        original = {"cmux": {"Stop": [{"command": "cmux stop", "timeout": 10, "type": "command"}]}}
        installed = hooks.amend(original, "agy", helper, True)
        self.assertIn("notch-ping", installed)
        self.assertIn("cmux", installed)
        self.assertEqual(installed, hooks.amend(installed, "agy", helper, True))
        self.assertEqual(original, hooks.amend(installed, "agy", helper, False))

    def test_agy_mentions_prefixes_and_wrappers_are_not_owned(self):
        helper = Path("/tmp/space in path/notch-relay")
        base = hooks.command(helper, "agy")
        commands = ["echo " + repr(base), base + "-extra audit", base + " Stop --custom",
                    "logger " + base + " Stop", "/another/notch-relay hook agy Stop"]
        original = {"diagnostics": {
            "Stop": [{"type": "command", "command": cmd} for cmd in commands],
            "PreToolUse": [{"matcher": ".*", "hooks": [
                {"type": "command", "command": cmd} for cmd in commands]}]}}
        for install in (False, True):
            with self.subTest(install=install):
                changed = hooks.amend_agy(original, helper, install)
                self.assertEqual(changed["diagnostics"], original["diagnostics"])
        self.assertEqual(hooks.amend_agy(original, helper, False), original)

    def test_agy_preserves_unrelated_handlers_and_metadata_in_owned_namespace(self):
        helper = Path("/tmp/notch-relay")
        original = {"notch-ping": {"enabled": False, "description": "my settings",
                    "Stop": [{"command": "echo unrelated"}],
                    "PreToolUse": [{"matcher": "ask_question", "hooks": [
                        {"command": "echo unrelated nested"}]}]}}
        installed = hooks.amend_agy(original, helper, True)
        self.assertFalse(installed["notch-ping"]["enabled"])
        self.assertEqual(installed, hooks.amend_agy(installed, helper, True))
        self.assertEqual(original, hooks.amend_agy(installed, helper, False))

    def test_agy_upgrades_legacy_matcher_without_duplicating_owned_handlers(self):
        helper = Path("/tmp/notch-relay")
        base = hooks.command(helper, "agy")
        legacy = {"notch-ping": {
            "Stop": [{"type": "command", "command": base + " Stop", "timeout": 1}],
            "PreToolUse": [{"matcher": "ask_question", "hooks": [
                {"type": "command", "command": base + " PreToolUse", "timeout": 1}]}]
        }}
        upgraded = hooks.amend_agy(legacy, helper, True)
        self.assertEqual(len(upgraded["notch-ping"]["PreToolUse"]), 1)
        self.assertIn("PostToolUse", upgraded["notch-ping"])
        self.assertEqual(upgraded, hooks.amend_agy(upgraded, helper, True))
        self.assertEqual({}, hooks.amend_agy(upgraded, helper, False))

    def test_agy_removes_only_exact_owned_handlers_in_mixed_groups(self):
        helper = Path("/tmp/notch-relay")
        original = {"legacy": {"Stop": [{"command": "echo keep"}],
                    "PreToolUse": [{"matcher": "ask_question", "hooks": [{"command": "echo keep"}]}]}}
        mixed = copy.deepcopy(original)
        mixed["legacy"]["Stop"].extend([{"command": hooks.command(helper, "agy")},
                                        {"command": hooks.command(helper, "agy") + " Stop"}])
        mixed["legacy"]["PreToolUse"][0]["hooks"].append(
            {"command": hooks.command(helper, "agy") + " PreToolUse"})
        self.assertEqual(original, hooks.amend_agy(mixed, helper, False))

    def test_agy_namespace_collision_does_not_overwrite_user_data(self):
        with self.assertRaises(ValueError):
            hooks.amend_agy({"notch-ping": "unexpected"}, Path("/tmp/notch-relay"), True)

    def test_file_round_trip_preserves_unrelated_settings_and_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            settings = home / ".claude/settings.json"
            settings.parent.mkdir()
            original = b'{"permissions":{"allow":["Read"]},"theme":"dark"}\n'
            settings.write_bytes(original)
            relay = home / "built-relay"
            relay.write_bytes(b"fixture executable")
            hooks.update(home, True, relay)
            backups = list((home / "Library/Application Support/NotchPing/backups").glob("*/claude-settings.json"))
            self.assertEqual(backups[0].read_bytes(), original)
            hooks.update(home, False, relay)
            import json
            self.assertEqual(json.loads(settings.read_bytes()), json.loads(original))

    def test_symlinked_settings_or_parent_directory_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            elsewhere = home / "elsewhere"
            elsewhere.mkdir()
            (home / ".codex").symlink_to(elsewhere)
            relay = home / "built-relay"
            relay.write_bytes(b"fixture executable")
            with self.assertRaises(ValueError):
                hooks.update(home, True, relay)


if __name__ == "__main__":
    unittest.main()
