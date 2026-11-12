#!/usr/bin/env python3
"""Exercise release selection with real Git histories and simulated GitHub responses."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from release_plan import checked_plan, plan_release


class ReleaseChangesTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.tmp = tempfile.TemporaryDirectory(prefix="mouse herdr release ")
        self.addCleanup(self.tmp.cleanup)
        previous = Path.cwd()
        os.chdir(self.tmp.name)
        self.addCleanup(os.chdir, previous)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        self.write("VERSION", "1.0\n")
        self.write("Sources/MouseHerdr/App.swift", "// original app\n")
        self.write("Resources/AppIcon.png", "original icon")
        self.commit()
        self.git("tag", "v1.0.1")

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.PIPE).strip()

    def write(self, path, content):
        file = Path(path)
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "test change")
        return self.git("rev-parse", "HEAD")

    def test_first_release_includes_the_app(self):
        plan = plan_release("HEAD")
        self.assertEqual(plan["publish"], "true")
        self.assertEqual(plan["version"], "1.0.1")

    def test_docs_tests_and_workflows_do_not_publish(self):
        for path in ["README.md", "docs/ring.png", "Sources/README.md",
                     "CONTRIBUTING.md", "Tests/AppTests.swift", "scripts/test_setup.py",
                     ".github/workflows/release.yml", "LICENSE"]:
            self.write(path, "documentation or maintenance")
        head = self.commit()
        self.assertEqual(plan_release(head, "v1.0.1")["publish"], "false")

    def test_docs_after_unreleased_code_still_include_the_code(self):
        self.write("Sources/MouseHerdr/App.swift", "// new behavior\n")
        self.commit()
        self.write("README.md", "updated instructions")
        head = self.commit()
        plan = plan_release(head, "v1.0.1")
        self.assertEqual(plan["publish"], "true")
        self.assertEqual(plan["version"], "1.0.3")

    def test_docs_after_published_code_do_not_publish_again(self):
        self.write("Sources/MouseHerdr/App.swift", "// new behavior\n")
        self.commit()
        self.git("tag", "v1.0.2")
        self.write("README.md", "updated instructions")
        head = self.commit()
        self.assertEqual(plan_release(head, "v1.0.2")["publish"], "false")

    def test_resource_and_build_changes_publish(self):
        for path in ["Resources/AppIcon.png", "Package.swift", "Package.resolved", "build.sh", "VERSION"]:
            with self.subTest(path=path):
                self.git("reset", "--hard", "v1.0.1")
                self.write(path, "1.1\n" if path == "VERSION" else "new build input\n")
                head = self.commit()
                self.assertEqual(plan_release(head, "v1.0.1")["publish"], "true")

    def test_removing_or_moving_source_to_docs_publishes(self):
        for move in [False, True]:
            with self.subTest(move=move):
                self.git("reset", "--hard", "v1.0.1")
                source = Path("Sources/MouseHerdr/App.swift")
                if move:
                    Path("docs").mkdir(exist_ok=True)
                    source.rename("docs/example.swift")
                else:
                    source.unlink()
                head = self.commit()
                self.assertEqual(plan_release(head, "v1.0.1")["publish"], "true")

    def test_reverted_code_with_only_docs_left_does_not_publish(self):
        self.write("Sources/MouseHerdr/App.swift", "// temporary change\n")
        self.commit()
        self.write("Sources/MouseHerdr/App.swift", "// original app\n")
        self.write("README.md", "documentation")
        head = self.commit()
        self.assertEqual(plan_release(head, "v1.0.1")["publish"], "false")

    def test_three_part_version_file_is_rejected_before_building(self):
        self.write("VERSION", "1.0.7\n")
        head = self.commit()
        with self.assertRaisesRegex(ValueError, "major.minor"):
            plan_release(head, "v1.0.1")

    def test_latest_release_must_be_in_main_history(self):
        self.write("Sources/MouseHerdr/App.swift", "// future release\n")
        self.commit()
        self.git("tag", "v1.0.2")
        with self.assertRaises(subprocess.CalledProcessError):
            plan_release("v1.0.1", "v1.0.2")


class ReleaseGateTests(unittest.TestCase):
    SHA = "a" * 40

    def run_plan(self, *, current=None, conclusion="success", latest=None, existing=None):
        ci = {"head_sha": self.SHA, "head_branch": "main", "event": "push",
              "status": "completed", "conclusion": conclusion}
        responses = [{"object": {"sha": current or self.SHA}},
                     {"workflow_runs": [ci]}, latest, existing]
        with patch("release_plan.github_api", side_effect=responses), patch(
            "release_plan.plan_release",
            return_value={"publish": "true", "version": "1.0.5", "build": "5"},
        ):
            return checked_plan(self.SHA)

    def test_stale_main_commit_cannot_replace_latest(self):
        self.assertEqual(self.run_plan(current="b" * 40)["publish"], "false")

    def test_manual_release_cannot_bypass_failed_or_incomplete_ci(self):
        for conclusion in ["failure", "cancelled", None]:
            with self.subTest(conclusion=conclusion):
                self.assertEqual(self.run_plan(conclusion=conclusion)["publish"], "false")

    def test_first_tested_release_can_publish(self):
        plan = self.run_plan()
        self.assertEqual(plan["publish"], "true")
        self.assertEqual(plan["resume_draft"], "false")

    def test_published_versions_are_not_overwritten(self):
        self.assertEqual(self.run_plan(existing={"draft": False})["publish"], "false")

    def test_interrupted_upload_can_resume_the_same_commit(self):
        plan = self.run_plan(existing={"draft": True, "target_commitish": self.SHA})
        self.assertEqual(plan["resume_draft"], "true")

    def test_draft_for_another_commit_cannot_be_reused(self):
        with self.assertRaisesRegex(ValueError, "different commit"):
            self.run_plan(existing={"draft": True, "target_commitish": "b" * 40})


if __name__ == "__main__":
    unittest.main(verbosity=2)
