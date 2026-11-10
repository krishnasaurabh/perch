"""Exercise repository policy against staged blobs and reachable history."""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("check_repository.py")


class RepositoryPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.put("README.md", "# Example\n")
        self.put("LICENSE", "Test fixture\n")
        self.put(".gitignore", "*.log\nartifacts/\n")
        self.git("add", ".")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.STDOUT)

    def put(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def check(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.root,
                              capture_output=True, text=True)

    def stage(self, path, content):
        self.put(path, content)
        self.git("add", "-f", path)

    def test_product_source_is_allowed(self):
        self.stage("Sources/App.swift", 'print("Hello")\n')
        self.assertEqual(self.check().returncode, 0)

    def test_real_test_fixture_is_allowed(self):
        self.stage("Tests/Fixtures/sample.json", '{"title":"Sample"}')
        self.assertEqual(self.check().returncode, 0)

    def test_user_guide_is_allowed(self):
        self.stage("docs/usage.md", "# Usage\n")
        self.assertEqual(self.check().returncode, 0)

    def test_documentation_image_is_allowed(self):
        self.stage("docs/images/today.png", "png")
        self.assertEqual(self.check().returncode, 0)

    def test_documentation_images_stay_narrow(self):
        for name in ("docs/today.png", "docs/images/run/today.png", "docs/images/notes.txt", "docs/images/build.log"):
            with self.subTest(name=name):
                self.stage(name, "data")
                self.assertEqual(self.check().returncode, 1)
                self.git("rm", "-q", "-f", name)

    def test_oversized_documentation_image_is_blocked(self):
        self.stage("docs/images/today.png", "x" * (1024 * 1024 + 1))
        self.assertIn("exceeds 1 MiB", self.check().stderr)

    def test_swift_format_config_is_allowed(self):
        self.stage(".swift-format", '{"version": 1, "indentation": {"spaces": 4}}\n')
        self.assertEqual(self.check().returncode, 0)

    def test_swift_format_config_near_names_are_blocked(self):
        for name in (".swift-format.json", ".swift-format.local", ".swift-format-backup", ".swiftlint.yml"):
            with self.subTest(name=name):
                self.stage(name, "{}\n")
                self.assertEqual(self.check().returncode, 1)
                self.git("rm", "-f", name)

    def test_swift_format_config_still_obeys_ignore_rules(self):
        self.stage(".gitignore", ".swift-format\n")
        self.stage(".swift-format", "{}\n")
        self.assertIn("tracked despite ignore rule", self.check().stderr)

    def test_swift_format_config_still_obeys_content_rules(self):
        self.stage(".swift-format", '{"value": "' + "ghp_" + "a" * 36 + '"}\n')
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("access token", result.stderr)
        self.assertNotIn("a" * 36, result.stderr)

    def test_deleted_private_swift_format_config_in_history_still_fails(self):
        self.stage(".swift-format", '{"value": "' + "ghp_" + "a" * 36 + '"}\n')
        self.git("commit", "-qm", "Initial")
        self.git("rm", ".swift-format")
        self.git("commit", "-qm", "Remove config")
        result = self.check("--history", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("access token", result.stderr)
        self.assertNotIn("a" * 36, result.stderr)

    def test_unlisted_root_is_blocked(self):
        self.stage("notes.md", "Private notes")
        self.assertEqual(self.check().returncode, 1)

    def test_internal_folders_are_blocked(self):
        for folder in ("team", "research", "qa", "artifacts", "evidence", "test-results"):
            with self.subTest(folder=folder):
                name = "docs/" + folder + "/result.md"
                self.stage(name, "test")
                self.assertEqual(self.check().returncode, 1)
                self.git("rm", "-f", name)

    def test_force_added_output_is_blocked(self):
        self.stage("scripts/test.log", "output")
        self.assertEqual(self.check().returncode, 1)

    def test_arbitrary_ignore_rule_is_enforced(self):
        self.stage(".gitignore", "secret.swift\n")
        self.stage("Sources/secret.swift", "test")
        self.assertIn("tracked despite ignore rule", self.check().stderr)

    def test_staged_content_not_worktree_is_checked(self):
        self.stage("Sources/App.swift", "ghp_" + "a" * 36)
        self.put("Sources/App.swift", "safe working copy")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("a" * 36, result.stderr)

    def test_private_machine_path_is_blocked(self):
        self.stage("README.md", "/" + "home/" + "person/notes")
        self.assertEqual(self.check().returncode, 1)

    def test_private_host_is_blocked(self):
        self.stage("README.md", "host." + "ts.net")
        self.assertEqual(self.check().returncode, 1)

    def test_private_network_address_is_blocked(self):
        self.stage("README.md", "100." + "98.1.2")
        self.assertEqual(self.check().returncode, 1)

    def test_unsubstantiated_claim_is_blocked(self):
        self.stage("README.md", "Built from " + "scratch")
        self.assertEqual(self.check().returncode, 1)

    def test_deleted_output_in_history_still_fails(self):
        self.stage("scripts/result.log", "output")
        self.git("commit", "-qm", "Initial")
        self.git("rm", "scripts/result.log")
        self.git("commit", "-qm", "Remove output")
        self.assertEqual(self.check("--history", "HEAD").returncode, 1)

    def test_symlink_is_blocked(self):
        os.symlink("README.md", self.root / "Sources-link")
        self.git("add", "Sources-link")
        self.assertEqual(self.check().returncode, 1)

    def test_large_files_are_blocked(self):
        self.stage("Resources/large.txt", "x" * (1024 * 1024 + 1))
        self.assertEqual(self.check().returncode, 1)

    def test_guard_source_passes_its_own_content_checks(self):
        self.stage("scripts/check_repository.py", SCRIPT.read_text())
        self.stage("scripts/test_repository_policy.py", pathlib.Path(__file__).read_text())
        self.assertEqual(self.check().returncode, 0, self.check().stderr)


if __name__ == "__main__":
    unittest.main()
