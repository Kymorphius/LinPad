#!/usr/bin/env python3
"""Unweighted static register mentions in a local Go Linux/ARM64 ELF.

The default spilled set mirrors jit/translate.c:jit_g2h. This is an operand
syntax survey, not a runtime profile or a count of emitted JIT spill cycles.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time

DEFAULT_SPILLED = frozenset((11, 12, 13, 14, 15, 18))
REGISTER = re.compile(r"(?<![\w.$/])R([0-9]|[12][0-9]|30)\b")
STACK = re.compile(r"(?<![\w.$/])RSP\b")
ADDRESS = re.compile(r"\((?:R(?:[0-9]|[12][0-9]|30)|RSP)\)")
HEADER = re.compile(r"^TEXT (.+?)\(SB\)(?:\s+.*)?$")
LINE = re.compile(r"^\s*\S+:\d+\s+(\S+)\s+(\S+)(?:\s+(.*))?$")
BRANCHES = set("B BL BR BLR JMP CALL RET CBZ CBNZ TBZ TBNZ BEQ BNE BHS BLO "
               "BMI BPL BVS BVC BHI BLS BGE BLT BGT BLE BAL BNV BCS BCC".split())
DATA = {"BYTE", "WORD", "DWORD", "LONG", "QUAD"}


def command(argv, limit=64 * 1024 * 1024, timeout=30):
    """Drain output incrementally; kill on time/output limits and command errors."""
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("command exceeded timeout")
                for key, _ in selector.select(remaining):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif len(output) + len(chunk) > limit:
                        raise ValueError("command exceeded output limit")
                    else:
                        output.extend(chunk)
        status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        decoded = output.decode("utf-8", errors="strict")
        if status:
            raise ValueError(f"command failed ({status}): {decoded[:1000]}")
        return decoded
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def counters():
    return {"instructions": 0, "gpr_instruction_mentions": {f"R{i}": 0 for i in range(31)},
            "rsp_instruction_mentions": 0, "spilled_gpr_instructions": 0,
            "memory_operand_instructions": 0, "branch_or_call_instructions": 0,
            "unsupported_lines": 0}


def parse_objdump(text, spilled=DEFAULT_SPILLED):
    functions, total, current = {}, counters(), None
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        header = HEADER.fullmatch(line)
        if header:
            name = header.group(1)
            if name in functions:
                raise ValueError(f"duplicate TEXT header at line {number}")
            current = functions[name] = counters()
            continue
        if current is None:
            raise ValueError(f"output before TEXT header at line {number}")
        instruction = LINE.fullmatch(line)
        if not instruction:
            current["unsupported_lines"] += 1
            total["unsupported_lines"] += 1
            continue
        pc, word, assembly = instruction.groups()
        if not re.fullmatch(r"0x[0-9a-fA-F]{1,16}", pc) or int(pc, 16) % 4:
            raise ValueError(f"invalid ARM64 PC at line {number}")
        if not re.fullmatch(r"[0-9a-fA-F]{8}", word):
            raise ValueError(f"invalid ARM64 opcode at line {number}")
        parts = (assembly or "").split(None, 1)
        if not parts or not re.fullmatch(r"[A-Z][A-Z0-9.]*", parts[0]) or parts[0] in DATA:
            current["unsupported_lines"] += 1
            total["unsupported_lines"] += 1
            continue
        mnemonic, operands = parts[0], parts[1] if len(parts) > 1 else ""
        registers = {int(value) for value in REGISTER.findall(operands)}
        for counts in (current, total):
            counts["instructions"] += 1
            for register in registers:
                counts["gpr_instruction_mentions"][f"R{register}"] += 1
            counts["rsp_instruction_mentions"] += bool(STACK.search(operands))
            counts["spilled_gpr_instructions"] += bool(registers & spilled)
            counts["memory_operand_instructions"] += bool(ADDRESS.search(operands))
            counts["branch_or_call_instructions"] += mnemonic in BRANCHES
    if not total["instructions"]:
        raise ValueError("no ARM64 instructions parsed; check symbol expression and objdump format")
    for counts in (*functions.values(), total):
        counts["spilled_gpr_instruction_fraction"] = (
            counts["spilled_gpr_instructions"] / counts["instructions"]
            if counts["instructions"] else None)
    return {"totals": total, "functions": functions}


def spilled_csv(value):
    if not re.fullmatch(r"(?:[0-9]|[12][0-9]|30)(?:,(?:[0-9]|[12][0-9]|30))*", value):
        raise argparse.ArgumentTypeError("expected comma-separated GPR indices from 0 to 30")
    return frozenset(map(int, value.split(",")))


def analyze(binary, symbol, spilled):
    with binary.open("rb") as source:
        header = source.read(20)
        if (len(header) != 20 or header[:7] != b"\x7fELF\x02\x01\x01"
                or int.from_bytes(header[18:20], "little") != 183):
            raise ValueError("binary must be an ELF64 little-endian AArch64 file")
        source.seek(0)
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    build = command(["go", "version", "-m", str(binary)], limit=1024 * 1024)
    settings = dict(re.findall(r"^\s*build\s+([\w-]+)=([^\r\n]+)$", build, re.MULTILINE))
    if settings.get("GOOS") != "linux" or settings.get("GOARCH") != "arm64":
        raise ValueError("Go build metadata must report GOOS=linux and GOARCH=arm64")
    compiler = re.search(r": (go\S+)\s*$", build.splitlines()[0]) if build else None
    if not compiler:
        raise ValueError("missing Go compiler version in binary metadata")
    result = parse_objdump(command(["go", "tool", "objdump", "-s", symbol, str(binary)]), spilled)
    return {"schema": 1, "analysis": "unweighted_static_instruction_counts",
            "binary_name": binary.name, "binary_sha256": digest,
            "binary_target": {"GOOS": "linux", "GOARCH": "arm64"},
            "compiler": compiler.group(1), "compiler_version_source": "go version -m binary",
            "objdump_toolchain": command(["go", "version"], limit=16384).strip(),
            "symbol_regex": symbol, "spilled_gprs": sorted(spilled),
            "spill_map_source": "jit/translate.c:jit_g2h; fixed default, CLI override allowed",
            "limitations": ["Static counts are not execution frequencies or runtime hotness.",
                            "Register mentions are distinct per instruction, not operand counts.",
                            "Spilled-register membership does not measure actual JIT spill cycles.",
                            "Memory metric is a (Rn)/(RSP) operand syntax proxy, not a memory decoder.",
                            "Unsupported lines are excluded and counted explicitly."], **result}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--symbol", required=True, help="Go objdump symbol regular expression")
    parser.add_argument("--spilled", type=spilled_csv, default=DEFAULT_SPILLED,
                        help="guest GPR indices (default: 11,12,13,14,15,18)")
    parser.add_argument("--output", type=Path, help="create a new JSON file; never overwrite")
    args = parser.parse_args(argv)
    try:
        if not args.symbol:
            raise ValueError("symbol expression must not be empty")
        serialized = json.dumps(analyze(args.binary, args.symbol, args.spilled), indent=2) + "\n"
        if args.output:
            descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
                destination.write(serialized)
        else:
            sys.stdout.write(serialized)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
