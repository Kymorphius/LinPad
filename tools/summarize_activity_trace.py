#!/usr/bin/env python3
"""Summarize one PID from an offline xctrace sysmon-process XML export.

Only native cumulative CPU counter deltas and physical footprint are reported.
The first cpu-percent cell may be a sentinel; it is deliberately unused. Times
and duration-on-core counters in this schema are nanoseconds, footprint is
bytes, and 100 percent means one fully occupied CPU core, not the whole chip.
No process names, other process metadata, or source XML appear in the report.
"""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import statistics
import sys
import xml.etree.ElementTree as ET


MAX_XML_SIZE = 32 * 1024 * 1024
MAX_ELEMENTS = 500_000
UINT64_MAX = (1 << 64) - 1
REQUIRED_COLUMNS = {
    "time": "start-time",
    "process": "process",
    "pid": "pid",
    "cpu-total-system": "duration-on-core",
    "cpu-total-user": "duration-on-core",
    "memory-physical-footprint": "size-in-bytes",
}
ERROR_MESSAGES = {
    "invalid_input": "Input must be a readable regular .xml file of at most 32 MiB.",
    "invalid_pid": "An explicit positive integer PID is required.",
    "invalid_xml": "Input is not a supported XML document; parser diagnostics were suppressed.",
    "invalid_references": "XML contains ambiguous, missing, cyclic, or incompatible references.",
    "invalid_schema": "Exactly one complete, unambiguous sysmon-process schema is required.",
    "invalid_row": "A process row is incomplete or has ambiguous identity or metrics.",
    "insufficient_samples": "At least two valid samples for the requested PID are required.",
    "nonmonotonic_time": "Requested PID sample timestamps must increase strictly in document order.",
    "counter_reset": "Requested PID cumulative CPU counters must not decrease.",
}


class TraceError(Exception):
    """A fixed error code that cannot include trace contents or paths."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


class _References:
    def __init__(self, root):
        self.ids = {}
        self.cache = {}
        for count, element in enumerate(root.iter(), 1):
            if count > MAX_ELEMENTS:
                raise TraceError("invalid_xml")
            identity = element.get("id")
            if identity is not None:
                if not identity or identity in self.ids:
                    raise TraceError("invalid_references")
                self.ids[identity] = element

    def resolve(self, element):
        chain = []
        seen = set()
        current = element
        while current not in self.cache and current.get("ref") is not None:
            if current in seen or len(current) or (current.text or "").strip():
                raise TraceError("invalid_references")
            seen.add(current)
            chain.append(current)
            target = self.ids.get(current.get("ref"))
            if target is None or target.tag != current.tag:
                raise TraceError("invalid_references")
            current = target
        resolved = self.cache.get(current, current)
        self.cache[element] = resolved
        for reference in chain:
            self.cache[reference] = resolved
        return resolved


def _read_xml(path):
    path = Path(path)
    try:
        if path.suffix.lower() != ".xml" or not stat.S_ISREG(path.stat().st_mode):
            raise TraceError("invalid_input")
        with path.open("rb") as source:
            # Check the opened file too, and bound the read if it grows.
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_XML_SIZE:
                raise TraceError("invalid_input")
            payload = source.read(MAX_XML_SIZE + 1)
        if len(payload) > MAX_XML_SIZE:
            raise TraceError("invalid_input")
    except (OSError, ValueError):
        raise TraceError("invalid_input") from None
    try:
        document = payload.decode("utf-8-sig")
        # Reject DTDs/entities explicitly, including external declarations. The
        # supported export is UTF-8 and requires neither feature nor a network.
        if "<!DOCTYPE" in document.upper() or "<!ENTITY" in document.upper():
            raise TraceError("invalid_xml")
        return ET.fromstring(document)
    except (ET.ParseError, UnicodeError, ValueError):
        raise TraceError("invalid_xml") from None


def _schema(root):
    schemas = [element for element in root.iter("schema")
               if element.get("name") == "sysmon-process"]
    if len(schemas) != 1:
        raise TraceError("invalid_schema")
    schema = schemas[0]
    parents = {child: parent for parent in root.iter() for child in parent}
    container = parents.get(schema)
    if container is None:
        raise TraceError("invalid_schema")
    positions = {}
    types = {}
    columns = list(schema)
    for position, column in enumerate(columns):
        mnemonics = column.findall("mnemonic")
        engineering_types = column.findall("engineering-type")
        if column.tag != "col" or len(mnemonics) != 1 or len(engineering_types) != 1:
            raise TraceError("invalid_schema")
        mnemonic = (mnemonics[0].text or "").strip()
        if not mnemonic or mnemonic in positions:
            raise TraceError("invalid_schema")
        positions[mnemonic] = position
        types[mnemonic] = (engineering_types[0].text or "").strip()
    if any(types.get(name) != expected for name, expected in REQUIRED_COLUMNS.items()):
        raise TraceError("invalid_schema")
    # Rows use the schema immediately alongside them. Multiple schemas in that
    # container would make their positional interpretation ambiguous.
    if len(container.findall("schema")) != 1:
        raise TraceError("invalid_schema")
    return positions, len(columns), container.findall("row")


def _integer(element, expected_type, refs):
    element = refs.resolve(element)
    text = (element.text or "").strip()
    if (element.tag != expected_type or len(element) or len(text) > 20
            or re.fullmatch(r"[0-9]+", text) is None):
        raise TraceError("invalid_row")
    value = int(text)
    if value > UINT64_MAX:
        raise TraceError("invalid_row")
    return value


def summarize_trace(path, pid):
    """Return a small whitelist report, or raise a privacy-safe TraceError."""
    if isinstance(pid, bool) or not isinstance(pid, int) or not 0 < pid <= 0x7FFFFFFF:
        raise TraceError("invalid_pid")
    root = _read_xml(path)
    refs = _References(root)
    positions, column_count, rows = _schema(root)
    samples = []
    for row in rows:
        cells = list(row)
        if len(cells) != column_count:
            raise TraceError("invalid_row")
        row_pid = _integer(cells[positions["pid"]], "pid", refs)
        process = refs.resolve(cells[positions["process"]])
        process_pids = process.findall("pid")
        if (process.tag != "process" or len(process_pids) != 1
                or _integer(process_pids[0], "pid", refs) != row_pid):
            raise TraceError("invalid_row")
        if row_pid != pid:
            continue
        sample = tuple(_integer(cells[positions[name]], expected_type, refs)
                       for name, expected_type in REQUIRED_COLUMNS.items()
                       if name not in ("process", "pid"))
        # The required-column order above is time, system CPU, user CPU, bytes.
        if samples:
            if sample[0] <= samples[-1][0]:
                raise TraceError("nonmonotonic_time")
            if sample[1] < samples[-1][1] or sample[2] < samples[-1][2]:
                raise TraceError("counter_reset")
        samples.append(sample)
    if len(samples) < 2:
        raise TraceError("insufficient_samples")
    interval = samples[-1][0] - samples[0][0]
    system = samples[-1][1] - samples[0][1]
    user = samples[-1][2] - samples[0][2]
    footprints = [sample[3] for sample in samples]
    return {
        "pid": pid,
        "sample_count": len(samples),
        "interval_seconds": round(interval / 1e9, 9),
        "cpu_user_seconds": round(user / 1e9, 9),
        "cpu_system_seconds": round(system / 1e9, 9),
        "cpu_total_seconds": round((user + system) / 1e9, 9),
        "cpu_percent_one_core": round(100 * (user + system) / interval, 9),
        "footprint_mib": {
            "min": round(min(footprints) / (1 << 20), 9),
            "median": round(statistics.median(footprints) / (1 << 20), 9),
            "max": round(max(footprints) / (1 << 20), 9),
        },
    }


def _pid_argument(value):
    if re.fullmatch(r"[0-9]{1,10}", value) is None or not 0 < int(value) <= 0x7FFFFFFF:
        raise argparse.ArgumentTypeError(ERROR_MESSAGES["invalid_pid"])
    return int(value)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export_xml", type=Path, help="Offline xctrace sysmon-process XML export")
    parser.add_argument("--pid", type=_pid_argument, required=True, help="Only summarize this PID")
    args = parser.parse_args(argv)
    try:
        report = summarize_trace(args.export_xml, args.pid)
    except TraceError as error:
        # Never echo parser diagnostics, source paths, process names, or rows.
        print(json.dumps({"error": {"code": error.code,
                                    "message": ERROR_MESSAGES[error.code]}}), file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
