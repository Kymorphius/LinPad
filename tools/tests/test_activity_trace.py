"""Offline xctrace parsing, native-counter math, and privacy boundaries.

Run: python3 -m unittest discover -s tools/tests -p 'test_activity_trace.py'
"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "activity_trace_under_test", Path(__file__).resolve().parents[1] / "summarize_activity_trace.py"
)
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)

PRIVATE = "PRIVATE-PROCESS-NAME-AND-TRACE-METADATA"
PID = 42
MIB = 1 << 20
NS = 1_000_000_000
# Deliberately unlike the ordering of both the actual export and the report.
COLUMNS = (
    ("memory-physical-footprint", "size-in-bytes"),
    ("cpu-total-user", "duration-on-core"),
    ("ppid", "pid"),
    ("process", "process"),
    ("time", "start-time"),
    ("cpu-percent", "system-cpu-percent"),
    ("pid", "pid"),
    ("cpu-total-system", "duration-on-core"),
)


def row(time=0, system=10 * NS, user=20 * NS, memory=MIB, pid=PID, overrides=None):
    cells = {
        "time": f"<start-time>{time}</start-time>",
        "cpu-total-system": f"<duration-on-core>{system}</duration-on-core>",
        "cpu-total-user": f"<duration-on-core>{user}</duration-on-core>",
        "memory-physical-footprint": f"<size-in-bytes>{memory}</size-in-bytes>",
        "pid": f"<pid>{pid}</pid>",
        "ppid": "<pid>1</pid>",
        "process": f'<process fmt="{PRIVATE}"><pid>{pid}</pid><device-session>{PRIVATE}</device-session></process>',
        "cpu-percent": "<sentinel/>",
    }
    cells.update(overrides or {})
    return "<row>" + "".join(cells[name] for name, _ in COLUMNS) + "</row>"


def document(rows, columns=COLUMNS, definitions=""):
    schema = '<schema name="sysmon-process">' + "".join(
        f"<col><mnemonic>{name}</mnemonic><engineering-type>{kind}</engineering-type></col>"
        for name, kind in columns
    ) + "</schema>"
    return '<trace-query-result><node>' + schema + "".join(rows) + definitions + "</node></trace-query-result>"


class ActivityTraceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "process.xml"

    def summarize(self, xml, pid=PID):
        self.path.write_text(xml, encoding="utf-8")
        return trace.summarize_trace(self.path, pid)

    def assert_error(self, code, xml, pid=PID):
        with self.assertRaises(trace.TraceError) as raised:
            self.summarize(xml, pid)
        self.assertEqual(raised.exception.code, code)

    def two_rows(self):
        return [row(), row(time=2 * NS, system=10 * NS + NS // 4, user=21 * NS + NS // 4)]

    def test_native_counter_deltas_mib_and_one_core_ratio(self):
        report = self.summarize(document([
            row(memory=3 * MIB),
            # Unselected process metrics are irrelevant and are not disclosed.
            row(time=NS, pid=99, overrides={"cpu-total-user": "<sentinel/>"}),
            row(time=2 * NS, user=22 * NS, system=10 * NS + NS // 2, memory=MIB),
            row(time=4 * NS, user=25 * NS, system=11 * NS, memory=2 * MIB,
                overrides={"cpu-percent": "<system-cpu-percent>999999</system-cpu-percent>"}),
        ]))
        self.assertEqual(report, {
            "pid": PID,
            "sample_count": 3,
            "interval_seconds": 4.0,
            "cpu_user_seconds": 5.0,
            "cpu_system_seconds": 1.0,
            "cpu_total_seconds": 6.0,
            "cpu_percent_one_core": 150.0,
            "footprint_mib": {"min": 1.0, "median": 2.0, "max": 3.0},
        })
        self.assertNotIn(PRIVATE, json.dumps(report))
        self.assertNotIn("99", json.dumps(report))

    def test_global_forward_chained_process_pid_and_metric_references(self):
        rows = [
            row(overrides={"process": '<process ref="process-chain"/>',
                           "pid": '<pid ref="pid-chain"/>',
                           "memory-physical-footprint": '<size-in-bytes ref="memory"/>'}),
            row(time=2 * NS, user=21 * NS, overrides={
                "process": '<process ref="process"/>', "pid": '<pid ref="pid"/>',
                "memory-physical-footprint": '<size-in-bytes id="memory">2097152</size-in-bytes>',
            }),
        ]
        definitions = ('<definitions><process id="process-chain" ref="process"/>'
                       f'<process id="process" fmt="{PRIVATE}"><pid ref="pid-chain"/></process>'
                       '<pid id="pid-chain" ref="pid"/><pid id="pid">42</pid></definitions>')
        report = self.summarize(document(rows, definitions=definitions))
        self.assertEqual(report["sample_count"], 2)
        self.assertEqual(report["cpu_percent_one_core"], 50.0)
        self.assertEqual(report["footprint_mib"], {"min": 2.0, "median": 2.0, "max": 2.0})

    def test_even_footprint_median_and_fractional_times(self):
        rows = self.two_rows()
        rows[1] = rows[1].replace(f"<size-in-bytes>{MIB}</size-in-bytes>", f"<size-in-bytes>{2 * MIB}</size-in-bytes>")
        report = self.summarize(document(rows))
        self.assertEqual(report["footprint_mib"]["median"], 1.5)
        self.assertEqual(report["cpu_user_seconds"], 1.25)
        self.assertEqual(report["cpu_system_seconds"], 0.25)
        self.assertEqual(report["cpu_percent_one_core"], 75.0)

    def test_wrong_pid_and_one_sample_fail_without_process_list(self):
        for rows, pid in ((self.two_rows(), 999), ([row()], PID)):
            with self.subTest(pid=pid, count=len(rows)):
                self.assert_error("insufficient_samples", document(rows), pid)

    def test_timestamp_order_and_each_cpu_counter_are_checked(self):
        cases = [
            ("nonmonotonic_time", row()),
            ("counter_reset", row(time=NS, user=19 * NS, system=12 * NS)),
            ("counter_reset", row(time=NS, user=22 * NS, system=9 * NS)),
        ]
        for code, second in cases:
            with self.subTest(code=code, second=second):
                self.assert_error(code, document([row(), second]))
        self.assert_error("nonmonotonic_time", document([row(time=NS), row(time=0)]))
        # A reset in an interior sample cannot be hidden by a higher last value.
        self.assert_error("counter_reset", document([
            row(), row(time=NS, user=19 * NS), row(time=2 * NS, user=22 * NS),
        ]))

    def test_missing_or_invalid_selected_metrics_fail(self):
        cases = [
            {"cpu-total-user": "<sentinel/>"},
            {"cpu-total-system": "<duration-on-core>-1</duration-on-core>"},
            {"time": "<start-time>NaN</start-time>"},
            {"memory-physical-footprint": "<size-in-bytes>1.5</size-in-bytes>"},
            {"memory-physical-footprint": f"<size-in-bytes>{1 << 64}</size-in-bytes>"},
            {"pid": "<pid>1</pid>"},
            {"process": "<process><pid>42</pid><pid>42</pid></process>"},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.assert_error("invalid_row", document([row(), row(time=NS, overrides=overrides)]))
        self.assert_error("invalid_row", document(self.two_rows()).replace("<sentinel/>", "", 1))

    def test_schema_must_be_complete_unique_and_have_native_units(self):
        xml = document(self.two_rows())
        cases = [
            xml.replace('name="sysmon-process"', 'name="other"'),
            document(self.two_rows(), columns=COLUMNS[:-1]),
            document(self.two_rows(), columns=COLUMNS + (COLUMNS[0],)),
            xml.replace("<engineering-type>start-time</engineering-type>", "<engineering-type>seconds</engineering-type>"),
            xml.replace("</node>", '<schema name="sysmon-process"/></node>'),
        ]
        for case in cases:
            with self.subTest(xml=case[:100]):
                self.assert_error("invalid_schema", case)

    def test_bad_references_never_fall_back_to_formatted_values(self):
        references = [
            ('<pid ref="missing" fmt="42"/>', ""),
            ('<pid ref="cycle-a"/>', '<pid id="cycle-a" ref="cycle-b"/><pid id="cycle-b" ref="cycle-a"/>'),
            ('<pid ref="duplicate"/>', '<pid id="duplicate">42</pid><pid id="duplicate">42</pid>'),
            ('<pid ref="wrong-type"/>', '<event-count id="wrong-type">42</event-count>'),
            ('<pid ref="value">42</pid>', '<pid id="value">42</pid>'),
        ]
        for reference, definitions in references:
            with self.subTest(reference=reference):
                self.assert_error("invalid_references", document([
                    row(overrides={"pid": reference}), row(time=NS),
                ], definitions=definitions))

    def test_regular_xml_size_and_safe_parser_errors(self):
        self.path.write_text(document(self.two_rows()), encoding="utf-8")
        with mock.patch.object(trace, "MAX_XML_SIZE", 8):
            with self.assertRaises(trace.TraceError) as raised:
                trace.summarize_trace(self.path, PID)
            self.assertEqual(raised.exception.code, "invalid_input")
        for xml in (f"<{PRIVATE}", f'<!DOCTYPE x [<!ENTITY secret "{PRIVATE}">]><x>&secret;</x>'):
            self.path.write_text(xml, encoding="utf-8")
            output, diagnostics = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(diagnostics):
                self.assertEqual(trace.main([str(self.path), "--pid", str(PID)]), 1)
            self.assertEqual(output.getvalue(), "")
            report = json.loads(diagnostics.getvalue())
            self.assertEqual(report["error"]["code"], "invalid_xml")
            self.assertNotIn(PRIVATE, diagnostics.getvalue())
            self.assertNotIn(str(self.path), diagnostics.getvalue())
        with self.assertRaises(trace.TraceError) as raised:
            trace.summarize_trace(self.path.parent, PID)
        self.assertEqual(raised.exception.code, "invalid_input")

    def test_cli_success_is_only_whitelisted_json_and_pid_is_required(self):
        self.path.write_text(document(self.two_rows()), encoding="utf-8")
        output, diagnostics = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(diagnostics):
            self.assertEqual(trace.main([str(self.path), "--pid", str(PID)]), 0)
        self.assertEqual(diagnostics.getvalue(), "")
        self.assertEqual(json.loads(output.getvalue())["pid"], PID)
        self.assertNotIn(PRIVATE, output.getvalue())
        for arguments in ([str(self.path)], [str(self.path), "--pid", PRIVATE]):
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    trace.main(arguments)
            self.assertEqual(raised.exception.code, 2)
        for pid in (0, -1, True, "42", 1 << 31):
            with self.subTest(pid=pid):
                with self.assertRaises(trace.TraceError) as raised:
                    trace.summarize_trace(self.path, pid)
                self.assertEqual(raised.exception.code, "invalid_pid")


if __name__ == "__main__":
    unittest.main()
