import unittest
from pathlib import Path


class PackagingScriptTests(unittest.TestCase):
    def test_bundle_venv_builds_portable_virtualenv_with_dependencies(self):
        script_path = Path(__file__).resolve().parents[2] / "scripts/package_macos.sh"
        script = script_path.read_text()

        self.assertIn(
            "python3 -m venv --copies \"$WORKER_DST_DIR/.venv\"",
            script,
            "Bundled app should create a relocatable venv instead of copying host-machine symlinks",
        )
        self.assertIn(
            "\"$WORKER_DST_DIR/.venv/bin/python3\" -m pip install -r \"$WORKER_DST_DIR/requirements.txt\"",
            script,
            "Bundled venv should install worker requirements so runtime imports are available",
        )


if __name__ == "__main__":
    unittest.main()
