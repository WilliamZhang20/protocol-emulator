"""Regression tests for analysis failures and the dead-code warning policy."""

import contextlib
import io
import subprocess
import unittest
from unittest.mock import patch

import dead_rtl_check as checker


class LintTests(unittest.TestCase):
    def test_warning_selection(self):
        for warning, expected in (
            ("", []),
            ("%Warning-WIDTH: top.v: unrelated", []),
            ("%Warning-UNUSEDSIGNAL: top.v: unused", ["%Warning-UNUSEDSIGNAL: top.v: unused"]),
        ):
            with self.subTest(warning=warning), patch.object(
                checker.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, "", warning),
            ) as run:
                self.assertEqual(checker.lint("verilator", "top", ["top.v"]), expected)
                self.assertIn("-Wno-fatal", run.call_args.args[0])

    def test_main_warning_policy(self):
        for path, expected in (("top.v", 1), ("test/models/ram.v", 0), ("ram_bm_bist.v", 0)):
            with self.subTest(path=path), patch.object(
                checker.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, "", f"%Warning-UNUSEDSIGNAL: {path}: unused"),
            ), patch.object(checker, "synth", return_value=[]), patch.object(
                checker.sys, "argv", ["checker", "verilator", "yosys", "top", "top.v"],
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(checker.main(), expected)

    def test_tool_failure_aborts_before_synthesis(self):
        for diagnostic in ("syntax error", "test/models/ram.v failed", "ram_bm_bist.v failed", ""):
            with self.subTest(diagnostic=diagnostic), patch.object(
                checker.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 1, "stdout detail", diagnostic),
            ), patch.object(checker, "synth") as synth, patch.object(
                checker.sys, "argv", ["checker", "verilator", "yosys", "top", "top.v"],
            ), contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaises(SystemExit) as failure:
                    checker.main()
                self.assertIn("verilator failed:", str(failure.exception))
                self.assertIn("stdout detail", str(failure.exception))
                self.assertIn(diagnostic, str(failure.exception))
                synth.assert_not_called()
                self.assertNotIn("0 findings", output.getvalue())


if __name__ == "__main__":
    unittest.main()
