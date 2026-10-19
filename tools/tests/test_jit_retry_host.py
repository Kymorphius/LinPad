"""Opt-in Apple LLDB integration tests using only self-owned macOS processes.

    LINPAD_RUN_HOST_LLDB_SMOKE=1 python3 -m unittest discover \
        -s tools/tests -p 'test_jit_retry_host.py' -v

These tests compile and attach to a temporary macOS fixture named iSH ARM64.
They never select a device or attach to an existing app. They exercise real
LLDB expression compilation and the simulated TXM protocol, not iPad JIT.
"""

import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time
import unittest


TEST_DIRECTORY = Path(__file__).resolve().parent
HELPER = TEST_DIRECTORY.parent / "enable_device_jit.py"
FIXTURE = TEST_DIRECTORY / "fixtures" / "jit_retry_host.m"


@unittest.skipUnless(
    os.environ.get("LINPAD_RUN_HOST_LLDB_SMOKE") == "1",
    "Set LINPAD_RUN_HOST_LLDB_SMOKE=1 to run the self-owned Apple LLDB fixture",
)
class HostLLDBRetryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise unittest.SkipTest("The host fixture requires Darwin arm64")
        cls.lldb = cls._find_apple_tool("lldb")
        clang = cls._find_apple_tool("clang")
        sdk = subprocess.run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
            capture_output=True, text=True, timeout=10,
        )
        if sdk.returncode:
            raise RuntimeError("Cannot locate the macOS Foundation SDK:\n" + sdk.stdout + sdk.stderr)
        version = subprocess.run(
            [cls.lldb, "--version"], capture_output=True, text=True, timeout=10,
        )
        if version.returncode:
            raise RuntimeError("Cannot run Apple LLDB:\n" + version.stdout + version.stderr)
        if not version.stdout.lstrip().startswith("lldb-") or "Apple" not in version.stdout:
            raise unittest.SkipTest("The host fixture requires Apple's bundled LLDB")

        cls.directory = tempfile.TemporaryDirectory(prefix="linpad-host-lldb-smoke-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.binary = Path(cls.directory.name) / "iSH ARM64"
        # Do not emit Objective-C debug declarations. The real release helper
        # must compile scalar/void message sends through id without relying on
        # the AppDelegate interface being available to LLDB's expression parser.
        compiled = subprocess.run(
            [clang, "-isysroot", sdk.stdout.strip(), "-arch", "arm64", "-O0", "-fblocks", "-framework", "Foundation",
             str(FIXTURE), "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=30,
        )
        if compiled.returncode:
            raise RuntimeError("Cannot compile the Foundation LLDB fixture:\n"
                               + compiled.stdout + compiled.stderr)

    @classmethod
    def _find_apple_tool(cls, name):
        try:
            found = subprocess.run(
                ["xcrun", "--find", name], capture_output=True, text=True, timeout=10,
            )
        except FileNotFoundError as error:
            raise unittest.SkipTest("Apple developer tools are unavailable: xcrun not found") from error
        if found.returncode:
            raise unittest.SkipTest("Apple developer tool %s is unavailable:\n%s" % (name, found.stderr))
        return found.stdout.strip()

    def _await_marker(self, process, log, marker, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            contents = log.read_text(errors="replace")
            if marker in contents:
                return contents
            if process.poll() is not None:
                self.fail("Host fixture exited with %s before %s:\n%s"
                          % (process.returncode, marker, contents))
            time.sleep(0.05)
        self.fail("Host fixture did not emit %s within %ss:\n%s"
                  % (marker, timeout, log.read_text(errors="replace")))

    def _exercise(self, mode, expected_output, expected_fixture_marker):
        log = Path(self.directory.name) / (mode + ".log")
        commands = Path(self.directory.name) / (mode + ".lldb")
        with log.open("wb") as output:
            process = subprocess.Popen(
                [str(self.binary), mode], stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT,
            )
            try:
                self._await_marker(process, log, "LINPAD_HOST_READY")
                commands.write_text(
                    "settings set auto-confirm true\n"
                    "process attach --pid %d\n" % process.pid
                    + "command script import %s\n" % json.dumps(str(HELPER))
                    + "linpad-jit --retry --timeout 20\n"
                    + "quit\n"
                )
                try:
                    completed = subprocess.run(
                        [self.lldb, "--no-lldbinit", "--batch", "--source", str(commands)],
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=45,
                    )
                except subprocess.TimeoutExpired as error:
                    self.fail("Apple LLDB exceeded 45s while attaching only to fixture PID %d. "
                              "Check Developer Tools debugging permissions.\nstdout: %r\nstderr: %r"
                              % (process.pid, error.stdout, error.stderr))
                diagnostics = ("Apple LLDB fixture run failed. Developer Tools debugging "
                               "permission errors are test failures, not successful skips.\n"
                               + completed.stdout + completed.stderr)
                self.assertEqual(completed.returncode, 0, diagnostics)
                self.assertIn(expected_output, completed.stdout, diagnostics)
                self.assertIsNone(process.poll(), diagnostics + "\nFixture:\n" + log.read_text())
                contents = self._await_marker(process, log, expected_fixture_marker)
                self.assertIsNone(process.poll(), "Fixture must survive helper detach:\n" + contents)
                return completed.stdout
            finally:
                # Only this exact Popen child is terminated, never a device app,
                # another fixture, or any process found by its executable name.
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                else:
                    process.wait(timeout=5)

    def test_idle_compiles_retry_and_completes_txm_protocol(self):
        output = self._exercise(
            "idle", "LinPad protocol completed and LLDB detached.", "LINPAD_HOST_PROTOCOL_ON",
        )
        self.assertIn("Preparing 32 MiB RX", output)
        self.assertIn("Prepared 2048/2048 pages.", output)

    def test_already_on_verifies_core_and_does_not_request_retry(self):
        output = self._exercise(
            "on", "initialized native JIT core are already On", "LINPAD_HOST_CORE_ON",
        )
        self.assertNotIn("Preparing ", output)
        self.assertIn("No RX allocation was requested.", output)


if __name__ == "__main__":
    unittest.main()
