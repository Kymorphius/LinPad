"""Reject incomplete or mismatched experiments before publishing a comparison."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("run-json-stages.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def experiment():
    rows = [{"type": "metadata", "schema": 1, "compiler": "go1.25.5", "goos": "linux",
             "goarch": "arm64", "gomaxprocs": 1, "workers": 1,
             "fixture_sha256": runner.FIXTURE, "fixture_bytes": 15678,
             "cases": list(runner.CASES), "count": 3, "target_ns": 300000000,
             "target_settings": {"GOOS": "linux", "GOARCH": "arm64", "GOARM64": "v8.0", "CGO_ENABLED": "0"},
             "inherited_gc_env": {"GOGC": "100", "GOMEMLIMIT": "off"}}]
    for case in runner.CASES:
        rows.append({"type": "calibration", "case": case, "iterations": 10,
                     "steps": 3, "elapsed_ns": 300000000, "excluded": True})
        for repetition in (1, 2, 3):
            rows.append({"type": "result", "case": case, "repetition": repetition,
                         "workers": 1, "gomaxprocs": 1, "iterations": 10,
                         "elapsed_ns": 300000000, "ns_per_op": 30000000,
                         "bytes_per_op": 15678, "checksum_ok": True, "warmup_excluded": True,
                         "total_alloc_bytes": 100, "mallocs": 10, "frees": 0,
                         "gc_count": 0, "gc_pause_ns": 0, "allocated_bytes_per_op": 10,
                         "allocs_per_op": 1, "frees_per_op": 0, "gc_pause_ns_per_op": 0,
                         "checksum": "0000000000000000", "output_crc64_ecma": "1111111111111111"})
    return rows


class ExperimentValidation(unittest.TestCase):
    def validate(self, rows, phase="linux-1"):
        return runner.validate_output("\n".join(json.dumps(row) for row in rows), phase, "go1.25.5")

    def test_complete_experiment(self):
        self.assertEqual(len(self.validate(experiment())), 18)

    def test_duplicate_replaces_missing_row_with_same_total(self):
        rows = experiment()
        rows[-1] = copy.deepcopy(rows[-2])
        with self.assertRaisesRegex(ValueError, "stage/repetition"):
            self.validate(rows)

    def test_duplicate_calibration_with_same_total(self):
        rows = experiment()
        calibrations = [i for i, row in enumerate(rows) if row["type"] == "calibration"]
        rows[calibrations[-1]] = copy.deepcopy(rows[calibrations[0]])
        with self.assertRaisesRegex(ValueError, "calibration"):
            self.validate(rows)

    def test_wrong_platform_and_parameters(self):
        for field, value in (("goos", "darwin"), ("goarch", "amd64"), ("count", 2),
                             ("target_ns", 500000000), ("workers", 4), ("fixture_sha256", "bad")):
            with self.subTest(field=field):
                rows = experiment()
                rows[0][field] = value
                with self.assertRaises(ValueError):
                    self.validate(rows)
        with self.assertRaisesRegex(ValueError, "target"):
            self.validate(experiment(), "mac-1")

    def test_bad_measurement_or_memory_metrics(self):
        for field, value in (("iterations", 11), ("checksum_ok", False), ("ns_per_op", float("nan")),
                             ("mallocs", -1), ("allocated_bytes_per_op", 99),
                             ("output_crc64_ecma", "wrong")):
            with self.subTest(field=field):
                rows = experiment()
                rows[-1][field] = value
                with self.assertRaises(ValueError):
                    self.validate(rows)


if __name__ == "__main__":
    unittest.main()
