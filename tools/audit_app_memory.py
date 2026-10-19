#!/usr/bin/env python3
"""Read an iOS app's signed memory capabilities without running the app.

The JSON report contains only selected public app metadata and signing
capabilities. It never includes raw entitlements, provisioning profiles,
certificate data, account names, device identifiers, or command diagnostics.
This displays signing metadata, without verifying signature or profile trust.
An entitlement is not proof that iPadOS grants more memory at runtime.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
from xml.parsers.expat import ExpatError
import zipfile


MEMORY_ENTITLEMENTS = (
    "com.apple.developer.kernel.increased-memory-limit",
    "com.apple.developer.kernel.extended-virtual-addressing",
    "com.apple.developer.kernel.increased-debugging-memory-limit",
)
APP_GROUPS = "com.apple.security.application-groups"
MAX_INFO_SIZE = 1 << 20
MAX_PROFILE_SIZE = 16 << 20
MAX_EXECUTABLE_SIZE = 1 << 30
COMMAND_TIMEOUT = 30
ERROR_MESSAGES = {
    "invalid_input": "Input must be an existing .app directory or .ipa file.",
    "unsafe_path": "An input member has an unsafe path or file type.",
    "invalid_archive": "The IPA archive could not be read.",
    "ambiguous_main_app": "The IPA must contain exactly one main app in Payload.",
    "duplicate_zip_entry": "The IPA contains duplicate archive member names.",
    "archive_member_too_large": "A required app member exceeds the audit size limit.",
    "missing_info": "The app has no readable Info.plist.",
    "invalid_info_plist": "Info.plist is not a valid dictionary property list.",
    "invalid_bundle_executable": "Info.plist does not name a safe main executable.",
    "missing_executable": "The app has no readable main executable.",
    "codesign_unavailable": "The macOS codesign tool is unavailable.",
    "codesign_timeout": "The codesign inspection exceeded its time limit.",
    "codesign_failed": "The codesign inspection failed; diagnostics were suppressed.",
    "invalid_binary_entitlements": "The binary entitlements could not be fully interpreted.",
    "profile_unreadable": "The app provisioning profile could not be read.",
    "security_unavailable": "The macOS security tool is unavailable.",
    "security_timeout": "The profile decoding exceeded its time limit.",
    "security_failed": "The profile decoding failed; diagnostics were suppressed.",
    "invalid_profile": "The decoded profile is not a valid dictionary property list.",
    "invalid_profile_entitlements": "The profile entitlements could not be fully interpreted.",
    "input_unreadable": "The selected app files could not be read.",
}


class AuditError(Exception):
    """A fixed, privacy-safe error code, never an external command's output."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _error(report, code):
    entry = {"code": code, "message": ERROR_MESSAGES[code]}
    if entry not in report["errors"]:
        report["errors"].append(entry)


def _empty_report():
    return {
        "bundle_id": None,
        "version": None,
        "build": None,
        "signature_kind": "unknown",
        "binary": None,
        "profile": {
            "present": False,
            "entitlements": None,
            "expiration_date": "unknown",
            "app_id_matches": "unknown",
        },
        "runtime_memory_increase": "not_measured",
        "errors": [],
    }


def _load_dictionary(payload, error_code):
    try:
        value = plistlib.loads(payload)
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError, ExpatError):
        raise AuditError(error_code) from None
    if not isinstance(value, dict):
        raise AuditError(error_code)
    return value


def _read_limited(path, limit, missing_code):
    if path.is_symlink():
        raise AuditError("unsafe_path")
    try:
        if not path.is_file():
            raise AuditError(missing_code)
        with path.open("rb") as stream:
            payload = stream.read(limit + 1)
    except OSError:
        raise AuditError(missing_code) from None
    if len(payload) > limit:
        raise AuditError("archive_member_too_large")
    return payload


def _executable_name(info):
    name = info.get("CFBundleExecutable")
    if (not isinstance(name, str) or not name or name in (".", "..")
            or "/" in name or "\\" in name or "\0" in name):
        raise AuditError("invalid_bundle_executable")
    return name


def _validate_zip_name(name):
    # Never pass archive names to extract()/extractall(). Check even unused
    # entries so a traversal archive cannot appear to be a normal audited IPA.
    path = PurePosixPath(name)
    if (not name or name.startswith("/") or "\\" in name or "\0" in name
            or ".." in path.parts or any(part == "." for part in name.split("/"))
            or re.match(r"^[A-Za-z]:", name)):
        raise AuditError("unsafe_path")


def _copy_member(archive, member, destination, limit):
    mode = member.external_attr >> 16
    if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG)):
        raise AuditError("unsafe_path")
    if member.file_size > limit:
        raise AuditError("archive_member_too_large")
    copied = 0
    with archive.open(member) as source, destination.open("wb") as target:
        while True:
            chunk = source.read(min(1 << 20, limit + 1 - copied))
            if not chunk:
                break
            copied += len(chunk)
            if copied > limit:
                raise AuditError("archive_member_too_large")
            target.write(chunk)


@contextmanager
def _app_files(path):
    """Yield main app metadata, Mach-O, and its own optional profile only."""
    if path.is_dir() and path.suffix.lower() == ".app":
        info = _load_dictionary(
            _read_limited(path / "Info.plist", MAX_INFO_SIZE, "missing_info"),
            "invalid_info_plist",
        )
        executable = path / _executable_name(info)
        if executable.is_symlink():
            raise AuditError("unsafe_path")
        if not executable.is_file():
            raise AuditError("missing_executable")
        profile = path / "embedded.mobileprovision"
        if profile.is_symlink():
            raise AuditError("unsafe_path")
        yield info, executable, profile if profile.exists() else None
        return
    if not path.is_file() or path.suffix.lower() != ".ipa":
        raise AuditError("invalid_input")
    try:
        with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory(prefix="linpad-memory-audit-") as temp:
            members = {}
            for member in archive.infolist():
                # ZipInfo truncates filename at NUL but retains orig_filename.
                _validate_zip_name(member.orig_filename)
                _validate_zip_name(member.filename)
                if member.filename in members:
                    raise AuditError("duplicate_zip_entry")
                members[member.filename] = member
            mains = [name for name in members if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
            if len(mains) != 1:
                raise AuditError("ambiguous_main_app")
            root = mains[0].rsplit("/", 1)[0] + "/"
            destination = Path(temp)
            info_path = destination / "Info.plist"
            _copy_member(archive, members[mains[0]], info_path, MAX_INFO_SIZE)
            info = _load_dictionary(info_path.read_bytes(), "invalid_info_plist")
            name = _executable_name(info)
            if root + name not in members:
                raise AuditError("missing_executable")
            executable = destination / "main-executable"
            _copy_member(archive, members[root + name], executable, MAX_EXECUTABLE_SIZE)
            profile_name = root + "embedded.mobileprovision"
            profile = None
            if profile_name in members:
                profile = destination / "embedded.mobileprovision"
                _copy_member(archive, members[profile_name], profile, MAX_PROFILE_SIZE)
            # codesign -d reads the selected Mach-O signature directly. No
            # resources, rootfs, nested apps, or executable code are extracted.
            yield info, executable, profile
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError, EOFError, UnicodeError):
        raise AuditError("invalid_archive") from None


def _run_command(command, tool):
    try:
        return subprocess.run(command, capture_output=True, timeout=COMMAND_TIMEOUT, check=False)
    except FileNotFoundError:
        raise AuditError(tool + "_unavailable") from None
    except subprocess.TimeoutExpired:
        raise AuditError(tool + "_timeout") from None
    except OSError:
        raise AuditError(tool + "_failed") from None


def _entitlement_plist(stdout, stderr):
    # Older codesign versions may put XML beside their summary on stderr.
    for output in (stdout, stderr):
        if output.startswith(b"bplist00"):
            return _load_dictionary(output, "invalid_binary_entitlements")
        start = output.find(b"<?xml")
        if start < 0:
            start = output.find(b"<plist")
        if start >= 0:
            end = output.find(b"</plist>", start)
            if end < 0:
                raise AuditError("invalid_binary_entitlements")
            return _load_dictionary(output[start:end + len(b"</plist>")], "invalid_binary_entitlements")
    if stdout.strip():
        raise AuditError("invalid_binary_entitlements")
    return {}


def _binary_entitlements(executable):
    result = _run_command([
        "/usr/bin/codesign", "-d", "--entitlements", ":-", "--verbose=2", str(executable),
    ], "codesign")
    if result.returncode:
        if b"code object is not signed at all" in result.stderr:
            return "unsigned", None
        raise AuditError("codesign_failed")
    if re.search(rb"(?m)^Signature=adhoc\s*$", result.stderr):
        kind = "ad-hoc"
    elif re.search(rb"(?m)^(Signature size=\d+|Authority=)", result.stderr):
        kind = "signed"
    else:
        kind = "unknown"
    return kind, _entitlement_plist(result.stdout, result.stderr)


def _summarize_entitlements(entitlements):
    values = {}
    invalid = False
    for key in ("get-task-allow",) + MEMORY_ENTITLEMENTS:
        value = entitlements.get(key, "absent")
        if key in entitlements and type(value) is not bool:
            value = "unknown"
            invalid = True
        values[key] = value
    groups = entitlements.get(APP_GROUPS, [])
    if not isinstance(groups, list) or any(not isinstance(group, str) for group in groups):
        groups = "unknown"
        invalid = True
    values["AppGroups"] = groups
    return values, invalid


def _app_id_matches(bundle_id, profile_entitlements):
    app_id = profile_entitlements.get("application-identifier")
    if not isinstance(bundle_id, str) or not isinstance(app_id, str) or "." not in app_id:
        return "unknown"
    prefix, pattern = app_id.split(".", 1)
    if not prefix or not pattern:
        return "unknown"
    if pattern == "*":
        return True
    if pattern.endswith(".*") and pattern.count("*") == 1:
        return bundle_id.startswith(pattern[:-1])
    if "*" in pattern:
        return "unknown"
    return bundle_id == pattern


def _expiration_date(value):
    if not isinstance(value, datetime):
        return "unknown"
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def audit(path):
    """Return a privacy-filtered report; uncertainty never means unlocked."""
    report = _empty_report()
    try:
        with _app_files(Path(path)) as (info, executable, profile):
            for source, target in (("CFBundleIdentifier", "bundle_id"),
                                   ("CFBundleShortVersionString", "version"),
                                   ("CFBundleVersion", "build")):
                value = info.get(source)
                report[target] = value if isinstance(value, str) else None
            try:
                kind, entitlements = _binary_entitlements(executable)
                report["signature_kind"] = kind
                if entitlements is not None:
                    report["binary"], invalid = _summarize_entitlements(entitlements)
                    if invalid:
                        _error(report, "invalid_binary_entitlements")
            except AuditError as error:
                _error(report, error.code)
            if profile is not None:
                report["profile"]["present"] = True
                try:
                    _read_limited(profile, MAX_PROFILE_SIZE, "profile_unreadable")
                    result = _run_command(["/usr/bin/security", "cms", "-D", "-i", str(profile)], "security")
                    if result.returncode:
                        raise AuditError("security_failed")
                    decoded = _load_dictionary(result.stdout, "invalid_profile")
                    entitlements = decoded.get("Entitlements")
                    if not isinstance(entitlements, dict):
                        raise AuditError("invalid_profile_entitlements")
                    report["profile"]["entitlements"], invalid = _summarize_entitlements(entitlements)
                    if invalid:
                        _error(report, "invalid_profile_entitlements")
                    report["profile"]["expiration_date"] = _expiration_date(decoded.get("ExpirationDate"))
                    report["profile"]["app_id_matches"] = _app_id_matches(report["bundle_id"], entitlements)
                except AuditError as error:
                    _error(report, error.code)
    except AuditError as error:
        _error(report, error.code)
    except OSError:
        _error(report, "input_unreadable")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", help="A local .app directory or .ipa file; its binary is never executed.")
    args = parser.parse_args(argv)
    report = audit(args.app)
    print(json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
