#!/usr/bin/env python3
"""Offline checks: temp files/canaries only, no node, daemon or credentials."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare-secrets.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PrepareTests(unittest.TestCase):
    def test_protected_literal_env_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / 'source.env'
            env.write_text('COMMANDER_VEHICLES=\'{"1":"5YJ3E1EA0XF000001"}\'\nUNCHANGED="literal"\n')
            env.chmod(0o600)
            values = prepare.read_env(env)
            self.assertEqual(json.loads(values['COMMANDER_VEHICLES']), {'1': '5YJ3E1EA0XF000001'})
            self.assertEqual(values['UNCHANGED'], 'literal')
            link = Path(directory) / 'link.env'
            link.symlink_to(env)
            with self.assertRaises(ValueError):
                prepare.read_env(link)
            env.chmod(0o644)
            with self.assertRaises(ValueError):
                prepare.read_env(env)

    def test_exclusive_file_never_rotates_saved_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'canary'
            with patch.object(prepare.os, 'chown'):
                prepare.exclusive(file, 'FIRST-CANARY', 0o400)
                with self.assertRaises(FileExistsError):
                    prepare.exclusive(file, 'REPLACEMENT-CANARY', 0o400)
            self.assertEqual(file.read_text(), 'FIRST-CANARY')
            self.assertEqual(file.stat().st_mode & 0o777, 0o400)

    def test_env_update_preserves_unrelated_lines_and_removes_duplicate_budget_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'commander.env'
            untouched = '# private comment\nSAVED_KEY=CANARY\n'
            file.write_text(untouched + 'COMMANDER_MONTHLY_BUDGET_USD=10\nCOMMANDER_MONTHLY_BUDGET_USD=20\n')
            file.chmod(0o600)
            with patch.object(prepare.os, 'chown'):
                prepare.update_env(file, {'COMMANDER_MONTHLY_BUDGET_USD': '5', 'COMMANDER_TELEMETRY_ENABLED': 'true'})
            text = file.read_text()
            self.assertTrue(text.startswith(untouched))
            self.assertEqual(text.count('COMMANDER_MONTHLY_BUDGET_USD='), 1)
            self.assertIn('COMMANDER_MONTHLY_BUDGET_USD=5\n', text)
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
