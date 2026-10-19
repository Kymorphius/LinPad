"""Privacy boundaries and signing evidence can be checked without an iPad.

Run: python3 -m unittest discover -s tools/tests -p 'test_audit_app_memory.py'
"""

from datetime import datetime
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


spec = importlib.util.spec_from_file_location(
    "audit_app_memory_under_test", Path(__file__).resolve().parents[1] / "audit_app_memory.py"
)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

INFO = {
    "CFBundleIdentifier": "com.example.LinPad",
    "CFBundleExecutable": "Linux for iPad",
    "CFBundleShortVersionString": "1.5.0",
    "CFBundleVersion": "42",
}
PRIVATE_SENTINEL = "DO-NOT-PRINT-PRIVATE-ACCOUNT-DEVICE-CERTIFICATE"


def completed(stdout=b"", stderr=b"", code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def app(self, profile=False):
        path = self.root / "Test.app"
        path.mkdir()
        (path / "Info.plist").write_bytes(plistlib.dumps(INFO))
        (path / INFO["CFBundleExecutable"]).write_bytes(b"Mach-O placeholder, never executed")
        if profile:
            (path / "embedded.mobileprovision").write_bytes(b"signed CMS placeholder")
        return path

    def ipa(self, extra=(), info=None):
        path = self.root / "test.ipa"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/Test.app/Info.plist", plistlib.dumps(INFO if info is None else info))
            archive.writestr("Payload/Test.app/" + INFO["CFBundleExecutable"], b"Mach-O placeholder")
            for name, payload in extra:
                archive.writestr(name, payload)
        return path

    def test_signed_app_reports_only_approved_fields(self):
        binary = {
            "get-task-allow": True,
            audit.APP_GROUPS: ["group.com.example.LinPad"],
            audit.MEMORY_ENTITLEMENTS[0]: True,
            "account-name": PRIVATE_SENTINEL,
        }
        profile = {
            "Name": PRIVATE_SENTINEL,
            "UUID": PRIVATE_SENTINEL,
            "ProvisionedDevices": [PRIVATE_SENTINEL],
            "DeveloperCertificates": [PRIVATE_SENTINEL.encode()],
            "ExpirationDate": datetime(2027, 4, 1, 12, 0),
            "Entitlements": {
                "application-identifier": "SECRETTEAM.com.example.*",
                audit.MEMORY_ENTITLEMENTS[0]: True,
            },
        }
        results = [
            completed(plistlib.dumps(binary), ("Executable=" + PRIVATE_SENTINEL + "\nSignature size=123\n").encode()),
            completed(plistlib.dumps(profile), PRIVATE_SENTINEL.encode()),
        ]
        with mock.patch.object(audit.subprocess, "run", side_effect=results) as run:
            report = audit.audit(self.app(profile=True))
        self.assertEqual(report["signature_kind"], "signed")
        self.assertTrue(report["binary"]["get-task-allow"])
        self.assertEqual(report["binary"]["AppGroups"], ["group.com.example.LinPad"])
        self.assertEqual(report["binary"][audit.MEMORY_ENTITLEMENTS[1]], "absent")
        self.assertEqual(report["profile"]["expiration_date"], "2027-04-01T12:00:00Z")
        self.assertIs(report["profile"]["app_id_matches"], True)
        self.assertEqual(report["runtime_memory_increase"], "not_measured")
        self.assertEqual(report["errors"], [])
        text = json.dumps(report)
        self.assertNotIn(PRIVATE_SENTINEL, text)
        self.assertNotIn("SECRETTEAM", text)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[0][0], "/usr/bin/codesign")
        self.assertEqual(commands[1][0:4], ["/usr/bin/security", "cms", "-D", "-i"])
        self.assertEqual(commands[1][4], str(self.root / "Test.app/embedded.mobileprovision"))

    def test_ad_hoc_and_missing_profile_do_not_claim_signed_permission(self):
        with mock.patch.object(audit.subprocess, "run", return_value=completed(stderr=b"Signature=adhoc\n")) as run:
            report = audit.audit(self.app())
        self.assertEqual(report["signature_kind"], "ad-hoc")
        self.assertEqual(report["binary"][audit.MEMORY_ENTITLEMENTS[0]], "absent")
        self.assertFalse(report["profile"]["present"])
        self.assertIsNone(report["profile"]["entitlements"])
        self.assertEqual(report["profile"]["app_id_matches"], "unknown")
        self.assertEqual(run.call_count, 1)

    def test_unsigned_is_an_observation_not_a_command_error(self):
        result = completed(stderr=(PRIVATE_SENTINEL + ": code object is not signed at all\n").encode(), code=1)
        with mock.patch.object(audit.subprocess, "run", return_value=result):
            report = audit.audit(self.app())
        self.assertEqual(report["signature_kind"], "unsigned")
        self.assertIsNone(report["binary"])
        self.assertEqual(report["errors"], [])
        self.assertNotIn(PRIVATE_SENTINEL, json.dumps(report))

    def test_command_errors_are_fixed_and_do_not_echo_diagnostics(self):
        results = [completed(stderr=PRIVATE_SENTINEL.encode(), code=7),
                   completed(stderr=PRIVATE_SENTINEL.encode(), code=8)]
        with mock.patch.object(audit.subprocess, "run", side_effect=results):
            report = audit.audit(self.app(profile=True))
        self.assertEqual([e["code"] for e in report["errors"]], ["codesign_failed", "security_failed"])
        self.assertEqual(report["signature_kind"], "unknown")
        self.assertIsNone(report["binary"])
        self.assertTrue(report["profile"]["present"])
        self.assertNotIn(PRIVATE_SENTINEL, json.dumps(report))

    def test_nonboolean_memory_entitlements_are_unknown_not_truthy(self):
        invalid = {audit.MEMORY_ENTITLEMENTS[0]: "true", "get-task-allow": 1,
                   audit.APP_GROUPS: ["group.ok", 42]}
        decoded = {"Entitlements": invalid}
        with mock.patch.object(audit.subprocess, "run", side_effect=[
            completed(plistlib.dumps(invalid), b"Signature=adhoc\n"),
            completed(plistlib.dumps(decoded)),
        ]):
            report = audit.audit(self.app(profile=True))
        for values in (report["binary"], report["profile"]["entitlements"]):
            self.assertEqual(values[audit.MEMORY_ENTITLEMENTS[0]], "unknown")
            self.assertEqual(values["get-task-allow"], "unknown")
            self.assertEqual(values["AppGroups"], "unknown")
        self.assertEqual({e["code"] for e in report["errors"]},
                         {"invalid_binary_entitlements", "invalid_profile_entitlements"})

    def test_profile_app_id_matching_exact_wildcard_mismatch_and_unknown(self):
        for pattern, expected in (
            ("TEAM.com.example.LinPad", True), ("TEAM.com.example.*", True),
            ("TEAM.*", True), ("TEAM.com.other.*", False),
            ("TEAM.com.example.LinPadOther", False), ("TEAM.com.ex*ample.*", "unknown"),
            (None, "unknown"),
        ):
            with self.subTest(pattern=pattern):
                self.assertEqual(audit._app_id_matches(INFO["CFBundleIdentifier"],
                                 {"application-identifier": pattern}), expected)

    def test_codesign_xml_on_stderr_and_binary_plist_on_stdout(self):
        entitlements = {audit.MEMORY_ENTITLEMENTS[2]: False}
        xml = plistlib.dumps(entitlements)
        self.assertEqual(audit._entitlement_plist(b"", b"Executable=private\n" + xml), entitlements)
        self.assertEqual(audit._entitlement_plist(plistlib.dumps(entitlements, fmt=plistlib.FMT_BINARY), b""), entitlements)

    def test_malformed_property_lists_are_reported_without_parser_details(self):
        path = self.app(profile=True)
        with mock.patch.object(audit.subprocess, "run", side_effect=[
            completed(b"<?xml version='1.0'?><plist><dict>" + PRIVATE_SENTINEL.encode() + b"</plist>"),
            completed(b"<?xml version='1.0'?><plist><dict>" + PRIVATE_SENTINEL.encode() + b"</plist>"),
        ]):
            report = audit.audit(path)
        self.assertEqual({error["code"] for error in report["errors"]},
                         {"invalid_binary_entitlements", "invalid_profile"})
        self.assertNotIn(PRIVATE_SENTINEL, json.dumps(report))
        (path / "Info.plist").write_bytes(b"<?xml version='1.0'?><plist><dict>unclosed")
        with mock.patch.object(audit.subprocess, "run") as run:
            report = audit.audit(path)
        run.assert_not_called()
        self.assertEqual(report["errors"][0]["code"], "invalid_info_plist")

    def test_ipa_extracts_only_main_executable_and_profile_then_cleans_up(self):
        path = self.ipa(extra=[
            ("Payload/Test.app/embedded.mobileprovision", b"profile"),
            ("Payload/Test.app/rootfs.ext4", b"must not be extracted"),
            ("Payload/Test.app/PlugIns/Extension.appex/Info.plist", plistlib.dumps(INFO)),
        ])
        paths = []

        def inspect(command, **kwargs):
            self.assertTrue(kwargs["capture_output"])
            selected = Path(command[-1])
            paths.append(selected)
            self.assertTrue(selected.is_file())
            self.assertEqual({p.name for p in selected.parent.iterdir()},
                             {"Info.plist", "main-executable", "embedded.mobileprovision"})
            if command[0].endswith("codesign"):
                self.assertEqual(selected.read_bytes(), b"Mach-O placeholder")
                return completed(stderr=b"Signature=adhoc\n")
            return completed(plistlib.dumps({"Entitlements": {"application-identifier": "TEAM.*"}}))

        with mock.patch.object(audit.subprocess, "run", side_effect=inspect):
            report = audit.audit(path)
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["bundle_id"], INFO["CFBundleIdentifier"])
        self.assertEqual(len(paths), 2)
        self.assertTrue(all(not path.exists() for path in paths))

    def test_multiple_main_apps_are_rejected_before_external_commands(self):
        path = self.ipa(extra=[("Payload/Second.app/Info.plist", plistlib.dumps(INFO))])
        with mock.patch.object(audit.subprocess, "run") as run:
            report = audit.audit(path)
        run.assert_not_called()
        self.assertEqual(report["errors"][0]["code"], "ambiguous_main_app")

    def test_traversal_absolute_and_windows_paths_are_rejected_even_if_unused(self):
        for name in ("../escape", "Payload/Test.app/../../../escape", "/absolute",
                     "Payload\\Test.app\\secret", "C:/private", "Payload/./Test.app/extra"):
            with self.subTest(name=name):
                path = self.ipa(extra=[(name, b"unused")])
                with mock.patch.object(audit.subprocess, "run") as run:
                    report = audit.audit(path)
                run.assert_not_called()
                self.assertEqual(report["errors"][0]["code"], "unsafe_path")

    def test_duplicate_entries_are_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            path = self.ipa(extra=[("Payload/Test.app/Info.plist", plistlib.dumps(INFO))])
        with mock.patch.object(audit.subprocess, "run") as run:
            report = audit.audit(path)
        run.assert_not_called()
        self.assertEqual(report["errors"][0]["code"], "duplicate_zip_entry")

    def test_ipa_symlink_executable_is_rejected(self):
        path = self.root / "symlink.ipa"
        link = zipfile.ZipInfo("Payload/Test.app/" + INFO["CFBundleExecutable"])
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/Test.app/Info.plist", plistlib.dumps(INFO))
            archive.writestr(link, "../../elsewhere")
        with mock.patch.object(audit.subprocess, "run") as run:
            report = audit.audit(path)
        run.assert_not_called()
        self.assertEqual(report["errors"][0]["code"], "unsafe_path")

    def test_bundle_executable_traversal_is_rejected(self):
        path = self.ipa(info={**INFO, "CFBundleExecutable": "../outside"})
        with mock.patch.object(audit.subprocess, "run") as run:
            report = audit.audit(path)
        run.assert_not_called()
        self.assertEqual(report["errors"][0]["code"], "invalid_bundle_executable")

    def test_oversized_required_member_is_rejected(self):
        path = self.ipa()
        with mock.patch.object(audit, "MAX_EXECUTABLE_SIZE", 4), mock.patch.object(audit.subprocess, "run") as run:
            report = audit.audit(path)
        run.assert_not_called()
        self.assertEqual(report["errors"][0]["code"], "archive_member_too_large")

    def test_missing_tools_and_timeout_do_not_include_command_or_output(self):
        for exception, code in ((FileNotFoundError(PRIVATE_SENTINEL), "codesign_unavailable"),
                                (subprocess.TimeoutExpired(PRIVATE_SENTINEL, 30, output=PRIVATE_SENTINEL), "codesign_timeout")):
            with self.subTest(code=code), mock.patch.object(audit.subprocess, "run", side_effect=exception):
                report = audit.audit(self.app())
            self.assertEqual(report["errors"][0]["code"], code)
            self.assertNotIn(PRIVATE_SENTINEL, json.dumps(report))
            # Each subtest gets a new bundle directory.
            for child in (self.root / "Test.app").iterdir():
                child.unlink()
            (self.root / "Test.app").rmdir()

    def test_cli_emits_json_and_nonzero_for_fixed_errors(self):
        with mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            status = audit.main([str(self.root / "missing.app")])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output.getvalue())["errors"][0]["code"], "invalid_input")


if __name__ == "__main__":
    unittest.main()
