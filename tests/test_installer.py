"""Contract tests for the Windows bootstrapper; no downloads or installs."""

import json
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class InstallerContractTests(unittest.TestCase):
    def test_manifest_covers_every_sentinel_repository_at_a_commit(self):
        manifest = json.loads((ROOT / "suite-manifest.json").read_text(encoding="utf-8"))
        expected = {
            "Sentinel-Pulse", "Sentinel-Edge", "Sentinel-Echo", "Sentinel-Flare",
            "Sentinel-Core", "Sentinel-Archive", "Sentinel-Chain", "Sentinel-Link",
            "Sentinel-Nexus", "Sentinel-Iron",
        }
        self.assertEqual(expected, set(manifest["repositories"]))
        for commit in manifest["repositories"].values():
            self.assertRegex(commit, r"^[0-9a-f]{40}$")

    def test_plan_mode_is_read_only_and_lists_install_steps(self):
        script = ROOT / "Install-Sentinel-Suite.ps1"
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), "-PlanOnly"],
            cwd=ROOT, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(10, len(plan["repositories"]))
        self.assertIn("MongoDB", plan["runtimes"])
        self.assertIn("Sentinel-Core", plan["desktopBots"])

    def test_launcher_rejects_unknown_component_before_starting_services(self):
        script = ROOT / "Start-Sentinel-Suite.ps1"
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), "-Component", "Unknown"],
            cwd=ROOT, text=True, capture_output=True, timeout=30,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Unknown component", result.stderr + result.stdout)

    def test_core_launch_plan_starts_mongo_pulse_edge_then_core(self):
        script = ROOT / "Start-Sentinel-Suite.ps1"
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
             "-Component", "Sentinel-Core", "-PlanOnly"],
            cwd=ROOT, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        plan = json.loads(result.stdout)
        self.assertTrue(plan["startsMongoDB"])
        self.assertEqual(["Sentinel-Pulse", "Sentinel-Edge", "Sentinel-Core"], plan["startupOrder"])

    def test_stop_plan_does_not_start_any_service(self):
        script = ROOT / "Start-Sentinel-Suite.ps1"
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
             "-Component", "Stop", "-PlanOnly"],
            cwd=ROOT, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual([], plan["startupOrder"])
        self.assertFalse(plan["startsMongoDB"])


if __name__ == "__main__":
    unittest.main()
