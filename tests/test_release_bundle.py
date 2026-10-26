import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "build-release-bundle.py"
SPEC = importlib.util.spec_from_file_location("build_release_bundle", MODULE_PATH)
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def repository_source(self):
        source = self.root / "source"
        for directory in ("agent", "config", "daemon", "tools"):
            (source / directory).mkdir(parents=True)
            (source / directory / f"{directory}.txt").write_text(directory)
        installer = source / "install.sh"
        installer.write_text("#!/bin/bash\nexit 0\n")
        installer.chmod(0o755)
        return source

    def test_repository_bundle_contains_fixed_installer_and_selected_tree(self):
        source = self.repository_source()
        cache = source / "tools" / "__pycache__"
        cache.mkdir()
        (cache / "generated.pyc").write_bytes(b"generated")
        output = self.root / "bundle"

        BUILDER.build("repository", source, output)

        self.assertTrue(os.access(output / "install.sh", os.X_OK))
        self.assertIn('"$REPOSITORY/install.sh" --local', (output / "install.sh").read_text())
        self.assertTrue((output / "repository/agent/agent.txt").is_file())
        self.assertTrue((output / "repository/install.sh").is_file())
        self.assertFalse((output / "repository/tools/__pycache__").exists())

    def test_repository_bundle_rejects_source_symlink(self):
        source = self.repository_source()
        (source / "agent/link").symlink_to(source / "install.sh")

        with self.assertRaisesRegex(BUILDER.BundleError, "links are forbidden"):
            BUILDER.build("repository", source, self.root / "bundle")

    def test_rules_bundle_copies_only_supported_files(self):
        source = self.root / "staged"
        (source / "extensions").mkdir(parents=True)
        (source / "leechblockng-managed-storage.json").write_text("{}\n")
        (source / "extensions/page_keyword_filter.xpi").write_bytes(b"xpi")
        (source / "not-supported.txt").write_text("do not deploy")
        output = self.root / "bundle"

        BUILDER.build("rules", source, output)

        self.assertTrue(os.access(output / "install.sh", os.X_OK))
        self.assertTrue((output / "rules/leechblockng-managed-storage.json").is_file())
        self.assertTrue((output / "rules/extensions/page_keyword_filter.xpi").is_file())
        self.assertFalse((output / "rules/not-supported.txt").exists())

    def test_rules_bundle_requires_supported_content(self):
        source = self.root / "empty"
        source.mkdir()

        with self.assertRaisesRegex(BUILDER.BundleError, "no supported"):
            BUILDER.build("rules", source, self.root / "bundle")


if __name__ == "__main__":
    unittest.main()
