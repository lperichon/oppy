import re
import unittest
from pathlib import Path


class PackagedLauncherReadinessTests(unittest.TestCase):
    def test_worker_readiness_probe_checks_soundfile_dependency(self):
        launcher_path = Path(__file__).resolve().parents[2] / "MacMenuBarApp/Sources/Oppy/WorkerLauncher.swift"
        source = launcher_path.read_text()

        match = re.search(r"readinessProbeScript\s*=\s*\"([^\"]+)\"", source)
        self.assertIsNotNone(match, "Could not find readinessProbeScript in WorkerLauncher.swift")

        probe_script = match.group(1)
        self.assertIn(
            "import soundfile",
            probe_script,
            "Readiness probe should validate soundfile so packaged builds fail early if dependency is missing",
        )

    def test_packaged_worker_path_is_preferred_over_cwd_worker(self):
        launcher_path = Path(__file__).resolve().parents[2] / "MacMenuBarApp/Sources/Oppy/WorkerLauncher.swift"
        source = launcher_path.read_text()

        cwd_check = source.find("let cwdPath = FileManager.default.currentDirectoryPath")
        bundle_check = source.find("if let resourceURL = Bundle.main.resourceURL")

        self.assertNotEqual(cwd_check, -1, "Could not find cwd worker path resolution block")
        self.assertNotEqual(bundle_check, -1, "Could not find bundled resource path resolution block")
        self.assertLess(
            bundle_check,
            cwd_check,
            "Bundled worker path should be resolved before cwd worker path to avoid using unprepared local Python env",
        )

    def test_unexpected_exit_message_includes_runtime_paths(self):
        launcher_path = Path(__file__).resolve().parents[2] / "MacMenuBarApp/Sources/Oppy/WorkerLauncher.swift"
        source = launcher_path.read_text()

        self.assertIn(
            "python executable",
            source,
            "Unexpected worker exit diagnostics should include python executable path",
        )
        self.assertIn(
            "worker script",
            source,
            "Unexpected worker exit diagnostics should include worker script path",
        )


if __name__ == "__main__":
    unittest.main()
