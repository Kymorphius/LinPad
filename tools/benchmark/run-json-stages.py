#!/usr/bin/env python3
"""Run matched, sequential JSON stage benchmarks without app maintenance."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import time


REPO = Path(__file__).resolve().parents[2]
SSH = REPO / "tools/ipad_ssh.sh"
SOURCE = REPO / "tools/benchmark/jsonstages/main.go"
CASES = ("decode_fresh", "encode", "gzip_compress_reuse",
         "gzip_decompress_fresh", "roundtrip", "crc32_ieee")
FIXTURE = "064b2c6387ef9f667a7ec90c0a76810720571906a80f26d3c3853439ff434655"


def validate_output(data, phase, compiler):
    """Require the complete matched experiment, not just a total row count."""
    def require(condition, message):
        if not condition:
            raise ValueError(phase + ": " + message)

    def integer(value, low, high):
        return type(value) is int and low <= value <= high

    rows = [json.loads(line) for line in data.splitlines()]
    require(all(isinstance(row, dict) for row in rows), "non-object row")
    require(all(row.get("type") in ("metadata", "calibration", "result") for row in rows), "unknown row type")
    metadata = [row for row in rows if row.get("type") == "metadata"]
    require(len(metadata) == 1, "expected exactly one metadata row")
    meta = metadata[0]
    target = "darwin" if phase.startswith("mac-") else "linux"
    require(meta.get("schema") == 1 and meta.get("compiler") == compiler,
            "compiler or metadata schema mismatch")
    require(meta.get("goos") == target and meta.get("goarch") == "arm64", "target mismatch")
    require(meta.get("gomaxprocs") == 1 and meta.get("workers") == 1, "worker count mismatch")
    require(meta.get("fixture_sha256") == FIXTURE and meta.get("fixture_bytes") == 15678,
            "fixture mismatch")
    require(meta.get("cases") == list(CASES) and meta.get("count") == 3
            and meta.get("target_ns") == 300000000, "experiment parameters mismatch")
    settings = meta.get("target_settings", {})
    require(all(settings.get(k) == v for k, v in {"GOOS": target, "GOARCH": "arm64",
                "GOARM64": "v8.0", "CGO_ENABLED": "0"}.items()), "build flags mismatch")
    require(meta.get("inherited_gc_env") == {"GOGC": "100", "GOMEMLIMIT": "off"}, "GC policy mismatch")
    calibrations = [row for row in rows if row.get("type") == "calibration"]
    require(len(calibrations) == len(CASES), "incomplete calibration set")
    iterations = {}
    for row in calibrations:
        case = row.get("case")
        require(case in CASES and case not in iterations, "duplicate or unknown calibration")
        require(row.get("excluded") is True and integer(row.get("iterations"), 1, 1 << 24)
                and integer(row.get("steps"), 1, 12) and integer(row.get("elapsed_ns"), 1, 10**15),
                "invalid calibration")
        iterations[case] = row["iterations"]
    measurements = [row for row in rows if row.get("type") == "result"]
    expected = {(case, repetition) for case in CASES for repetition in (1, 2, 3)}
    require(len(measurements) == len(expected), "incomplete measurement set")
    seen = set()
    for row in measurements:
        pair = (row.get("case"), row.get("repetition"))
        require(pair in expected and pair not in seen, "duplicate, missing, or unknown stage/repetition")
        seen.add(pair)
        require(row.get("iterations") == iterations[pair[0]], "iterations differ from calibration")
        require(row.get("workers") == 1 and row.get("gomaxprocs") == 1
                and row.get("checksum_ok") is True and row.get("warmup_excluded") is True,
                "invalid worker or correctness flags")
        require(integer(row.get("elapsed_ns"), 1, 10**15) and row.get("bytes_per_op") == 15678,
                "invalid elapsed time or payload")
        ns = row.get("ns_per_op")
        require(type(ns) in (int, float) and math.isfinite(ns) and ns > 0
                and math.isclose(ns, row["elapsed_ns"] / row["iterations"], rel_tol=1e-12),
                "inconsistent operation time")
        for field in ("total_alloc_bytes", "mallocs", "frees", "gc_count", "gc_pause_ns"):
            require(integer(row.get(field), 0, 1 << 64), "invalid memory counter: " + field)
        for field, total in (("allocated_bytes_per_op", "total_alloc_bytes"),
                             ("allocs_per_op", "mallocs"), ("frees_per_op", "frees"),
                             ("gc_pause_ns_per_op", "gc_pause_ns")):
            value = row.get(field)
            require(type(value) in (int, float) and math.isfinite(value) and value >= 0
                    and math.isclose(value, row[total] / row["iterations"], rel_tol=1e-12, abs_tol=1e-12),
                    "inconsistent memory metric: " + field)
        for field in ("checksum", "output_crc64_ecma"):
            value = row.get(field)
            require(isinstance(value, str) and len(value) == 16
                    and all(ch in "0123456789abcdef" for ch in value), "invalid checksum encoding")
    require(seen == expected, "missing stages or repetitions")
    return measurements


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def execute(args, *, timeout=90, input=None, env=None):
    result = subprocess.run(args, cwd=REPO, input=input, capture_output=True,
                            timeout=timeout, env=env)
    if result.returncode:
        raise RuntimeError(f"Command exited {result.returncode}: "
                           + result.stderr.decode(errors="replace")[-2000:])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--transport", choices=("usb", "wifi"), default="usb")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any(output.iterdir()):
        parser.error("Preserve existing files: select an empty output directory")
    os.chmod(output, 0o700)
    remote = "/tmp/linpad-json-stages-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
    remote_binary = remote + "/benchmark"
    shell = lambda command, **kw: execute([str(SSH), args.transport, command], **kw)
    q = shlex.quote
    binaries = {}
    runtime_env = dict(os.environ, GOGC="100", GOMEMLIMIT="off", GODEBUG="")
    environment = {
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source_sha256": sha(SOURCE),
        "compiler": execute(["go", "version"]).stdout.decode().strip(),
        "goarch": "arm64", "goarm64": "v8.0", "cgo_enabled": False,
        "flags": ["-duration", "300ms", "-count", "3"],
        "order": ["linux-1", "mac-1", "mac-2", "linux-2"],
        "transport": args.transport, "guest_directory": remote,
        "runtime_env": {"GOGC": "100", "GOMEMLIMIT": "off", "GODEBUG": ""},
    }
    for target in ("darwin", "linux"):
        binary = output / ("json-stages-" + target)
        env = dict(os.environ, CGO_ENABLED="0", GOARCH="arm64", GOARM64="v8.0", GOOS=target)
        execute(["go", "build", "-trimpath", "-buildvcs=false", "-o", str(binary), str(SOURCE)],
                timeout=120, env=env)
        binaries[target] = binary
    environment["binary_sha256"] = {target: sha(path) for target, path in binaries.items()}
    (output / "run-environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    # Capture only generic system counters and process names, never arguments.
    preflight = "uname -srmo; for p in / /root /home; do printf '%s=' \"$p\"; stat -c '%d:%i' \"$p\"; done; cat /proc/ish/memory; ps -o pid,ppid,comm"
    before_guest = shell(preflight, timeout=30).stdout
    (output / "guest-before.txt").write_bytes(before_guest)
    if any(name in before_guest.decode(errors="replace").lower()
           for name in ("benchmark", "json-stages", "linpad-bench")):
        raise RuntimeError("Another guest benchmark may be active; preserve it and coordinate first")
    created = False
    try:
        # The random private directory is owned by this run. No package install
        # or user configuration is needed, and no existing executable is replaced.
        shell("umask 077; mkdir " + q(remote), timeout=30)
        created = True
        shell("umask 077; cat > " + q(remote_binary) + " && chmod 700 " + q(remote_binary),
              input=binaries["linux"].read_bytes(), timeout=60)
        actual = shell("sha256sum " + q(remote_binary), timeout=30).stdout.decode().split()[0]
        if actual != environment["binary_sha256"]["linux"]:
            raise RuntimeError("Guest binary SHA-256 mismatch")
        for platform in ("mac", "linux"):
            command = ([str(binaries["darwin"]), "-selftest"] if platform == "mac"
                       else [str(SSH), args.transport, "GOGC=100 GOMEMLIMIT=off GODEBUG= timeout -s KILL 20 " + q(remote_binary) + " -selftest"])
            result = execute(command, timeout=40, env=runtime_env)
            (output / (platform + "-selftest.jsonl")).write_bytes(result.stdout)
            (output / (platform + "-selftest.stderr")).write_bytes(result.stderr)
            if not json.loads(result.stdout).get("checksum_ok"):
                raise RuntimeError(platform + " self-test failed")
        for phase in environment["order"]:
            print("START " + phase, flush=True)
            # These snapshots occur outside all benchmark timing. Do not stop
            # background user processes or deliberately run another CPU task.
            before = execute(["top", "-l", "1", "-n", "0"], timeout=15)
            (output / (phase + "-host-before.txt")).write_bytes(before.stdout)
            command = ([str(binaries["darwin"]), *environment["flags"]] if phase.startswith("mac")
                       else [str(SSH), args.transport, "GOGC=100 GOMEMLIMIT=off GODEBUG= timeout -s KILL 90 " + q(remote_binary)
                             + " -duration 300ms -count 3"])
            begin = time.monotonic()
            result = execute(command, timeout=110, env=runtime_env)
            (output / (phase + ".jsonl")).write_bytes(result.stdout)
            (output / (phase + ".stderr")).write_bytes(result.stderr)
            (output / (phase + "-wall.json")).write_text(json.dumps({"seconds": time.monotonic() - begin}) + "\n")
            measurements = validate_output(result.stdout, phase, environment["compiler"].split()[2])
            print("DONE " + phase + f" ({len(measurements)} valid measurements)", flush=True)
            after = execute(["top", "-l", "1", "-n", "0"], timeout=15)
            (output / (phase + "-host-after.txt")).write_bytes(after.stdout)
    finally:
        if created:
            # Delete only this run's binary; rmdir refuses an unexpected file.
            cleanup = shell("rm -f " + q(remote_binary) + " && rmdir " + q(remote), timeout=30)
            (output / "guest-cleanup.txt").write_bytes(cleanup.stdout)
    (output / "guest-after.txt").write_bytes(shell(preflight, timeout=30).stdout)
    print("Completed; guest benchmark removed. Results: " + str(output), flush=True)


if __name__ == "__main__":
    main()
