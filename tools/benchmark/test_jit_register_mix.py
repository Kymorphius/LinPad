"""Static instruction counts must not become operand counts or dynamic claims."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("mix", Path(__file__).with_name("jit-register-mix.py"))
mix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mix)

FIXTURE = """TEXT encoding/json.first(SB) encoding/json/decode.go
  decode.go:1 0x1000 8b01016b ADD R1, R11, R11
  decode.go:2 0x1004 f9400bec MOVD 16(RSP), R12
  decode.go:3 0x1008 a90033eb STP (R11, R12), 0(RSP)
  decode.go:4 0x100c eb0f001f CMP R15, R0
  decode.go:5 0x1010 54000040 BEQ 2(PC)
  decode.go:6 0x1014 94000004 CALL main.R18helper(SB)

TEXT main.second(SB) main.go
  main.go:1 0x2000 aa1203f2 MOVD R18, R18
  main.go:2 0x2004 a900304b STP (R11, R12), 0(R2)
  main.go:3 0x2008 d65f03c0 RET
  main.go:4 0x200c 00000000 ?
  main.go:5 0x2010 00000000 WORD $0
  unrecognized source line
"""


class StaticRegisterMix(unittest.TestCase):
    def test_counts_distinct_mentions_and_address_proxy(self):
        parsed = mix.parse_objdump(FIXTURE)
        first, second = parsed["functions"].values()
        self.assertEqual(first["instructions"], 6)
        self.assertEqual(first["gpr_instruction_mentions"]["R1"], 1)
        self.assertEqual(first["gpr_instruction_mentions"]["R11"], 2)
        self.assertEqual(first["gpr_instruction_mentions"]["R18"], 0)
        self.assertEqual(first["rsp_instruction_mentions"], 2)
        self.assertEqual(first["gpr_instruction_mentions"]["R15"], 1)
        self.assertEqual(first["spilled_gpr_instructions"], 4)
        self.assertEqual(first["memory_operand_instructions"], 2)
        self.assertEqual(first["branch_or_call_instructions"], 2)
        self.assertEqual(second["unsupported_lines"], 3)
        self.assertEqual(parsed["totals"]["instructions"], 9)
        self.assertEqual(parsed["totals"]["spilled_gpr_instruction_fraction"], 6 / 9)
        # A register tuple is not itself an address expression.
        self.assertFalse(mix.ADDRESS.search("(R11, R12), symbol(SB), 2(PC)"))

    def test_custom_map_and_invalid_instruction_fields(self):
        parsed = mix.parse_objdump(FIXTURE, frozenset((1,)))
        self.assertEqual(parsed["totals"]["spilled_gpr_instructions"], 1)
        for old, new, message in (("0x1000", "0x1001", "PC"),
                                  ("0x1000", "bad_pc", "PC"),
                                  ("8b01016b", "8b01016", "opcode"),
                                  ("8b01016b", "nothex!!", "opcode")):
            with self.subTest(new=new), self.assertRaisesRegex(ValueError, message):
                mix.parse_objdump(FIXTURE.replace(old, new, 1))
        for text in ("", "TEXT empty(SB) empty.go\n", "TEXT empty(SB) x\n  x:1 0x1000 00000000 ?"):
            with self.assertRaisesRegex(ValueError, "no ARM64 instructions"):
                mix.parse_objdump(text)
        with self.assertRaisesRegex(ValueError, "before TEXT"):
            mix.parse_objdump("unexpected output")

    def test_local_command_limits_and_failure(self):
        self.assertEqual(mix.command([sys.executable, "-c", "print('ok')"]), "ok\n")
        for code, kwargs, message in (("print('x' * 1000)", {"limit": 10}, "output limit"),
                                      ("import time; time.sleep(5)", {"timeout": 0.05}, "timeout"),
                                      ("raise SystemExit(7)", {}, "failed")):
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, message):
                mix.command([sys.executable, "-c", code], **kwargs)

    def test_analyze_uses_objdump_and_binary_compiler_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "benchmark"
            binary.write_bytes(b"\x7fELF\x02\x01\x01" + bytes(11) + b"\xb7\x00")
            build = "benchmark: go1.25.5\n\tbuild\tGOOS=linux\n\tbuild\tGOARCH=arm64\n"
            with patch.object(mix, "command", side_effect=[build, FIXTURE, "go version go1.25.5 darwin/arm64\n"]) as command:
                result = mix.analyze(binary, "first|second", mix.DEFAULT_SPILLED)
            self.assertEqual(command.call_args_list[1].args[0],
                             ["go", "tool", "objdump", "-s", "first|second", str(binary)])
            self.assertEqual(result["compiler"], "go1.25.5")
            self.assertEqual(result["analysis"], "unweighted_static_instruction_counts")
            self.assertEqual(len(result["binary_sha256"]), 64)
            with patch.object(mix, "command", return_value=build.replace("GOOS=linux", "GOOS=darwin")):
                with self.assertRaisesRegex(ValueError, "GOOS=linux"):
                    mix.analyze(binary, "main", mix.DEFAULT_SPILLED)
            binary.write_bytes(b"not ELF")
            with self.assertRaisesRegex(ValueError, "ELF64"):
                mix.analyze(binary, "main", mix.DEFAULT_SPILLED)

    def test_output_never_overwrites_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            with patch.object(mix, "analyze", return_value={"static": True}):
                mix.main(["unused", "--symbol", "main", "--output", str(output)])
                self.assertEqual(json.loads(output.read_text()), {"static": True})
                with self.assertRaises(SystemExit) as failure, contextlib.redirect_stderr(io.StringIO()):
                    mix.main(["unused", "--symbol", "main", "--output", str(output)])
                self.assertEqual(failure.exception.code, 1)
            self.assertEqual(json.loads(output.read_text()), {"static": True})


if __name__ == "__main__":
    unittest.main()
