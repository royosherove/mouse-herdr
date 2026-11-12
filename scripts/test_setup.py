#!/usr/bin/env python3
"""Check build failure handling and, optionally, the packaged app's Herdr diagnostics."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("MOUSEHERDR_TEST_BINARY")


@unittest.skipUnless(sys.platform == "darwin", "MouseHerdr builds on macOS")
class BuildScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mouse herdr build ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy2(ROOT / "build.sh", self.root / "build.sh")
        tools = self.root / "tools"
        tools.mkdir()
        swift = tools / "swift"
        swift.write_text(
            '#!/bin/sh\n'
            'touch "$COMPILER_MARKER"\n'
            'echo "intentional compiler failure" >&2\n'
            'exit 23\n'
        )
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                        BUNDLE_ID="dev.mouseherdr.test", SIGNING="adhoc",
                        COMPILER_MARKER=str(self.root / "compiler-called"))

    def run_build(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.root / "build.sh"), *args],
            cwd=self.root.parent, env=self.env, capture_output=True, text=True, timeout=10,
        )

    def test_failed_compilation_cannot_package_an_old_binary(self):
        stale = self.root / ".build/release/MouseHerdr"
        stale.parent.mkdir(parents=True)
        stale.write_text('#!/bin/sh\ntouch "$STALE_MARKER"\nexit 0\n')
        stale.chmod(0o755)
        self.env["STALE_MARKER"] = str(self.root / "stale-used")
        previous = self.root / "dist/MouseHerdr.app/previous-build"
        previous.parent.mkdir(parents=True)
        previous.write_text("previous successful build")

        result = self.run_build()

        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertIn("intentional compiler failure", result.stderr)
        self.assertFalse((self.root / "stale-used").exists())
        self.assertEqual(previous.read_text(), "previous successful build")

    def test_invalid_bundle_id_is_rejected_before_building(self):
        self.env["BUNDLE_ID"] = "invalid<&identifier"
        result = self.run_build()
        self.assertEqual(result.returncode, 2)
        self.assertIn("BUNDLE_ID", result.stderr)
        self.assertFalse((self.root / "compiler-called").exists())

    def test_unknown_argument_is_rejected_before_building(self):
        result = self.run_build("instal")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)
        self.assertFalse((self.root / "compiler-called").exists())

    def test_help_does_not_build_or_change_keychains(self):
        result = self.run_build("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        self.assertFalse((self.root / "compiler-called").exists())
        self.assertFalse((self.root / "signing").exists())


@unittest.skipUnless(BINARY, "Set MOUSEHERDR_TEST_BINARY to test a packaged app")
class HerdrSetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mouse herdr hc ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.hc = self.root / "hc"
        self.env = dict(os.environ, MOUSEHERDR_HC=str(self.hc),
                        MOUSEHERDR_HERDR_APP=str(self.root / "missing-herdr-app"))

    def status(self, script=None):
        if script is not None:
            self.hc.write_text("#!/bin/sh\n" + script + "\n")
            self.hc.chmod(0o755)
        result = subprocess.run(
            [str(Path(BINARY).resolve()), "--herdr-status"],
            env=self.env, capture_output=True, text=True, timeout=12,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Herdr app: not installed", result.stdout)
        return result.stdout

    def test_missing_optional_dependency(self):
        self.assertIn("herdr-core: not installed", self.status())

    def test_failed_and_invalid_listing(self):
        for script in ["exit 1", "printf 'invalid json'"]:
            with self.subTest(script=script):
                self.assertIn("installed, but not running", self.status(script))

    def test_empty_and_populated_listing(self):
        self.assertIn("running, no agents", self.status("""printf '%s' '{"terminals":[]}'"""))
        self.assertIn("running, 1 agent", self.status(
            """printf '%s' '{"terminals":[{"address":"t1","agent":"claude-code","status":"working","where":"demo / 1"}]}'"""
        ))

    def test_unresponsive_service_has_a_bounded_wait(self):
        started = time.monotonic()
        self.assertIn("installed, but not running", self.status("exec /bin/sleep 30"))
        self.assertLess(time.monotonic() - started, 10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
