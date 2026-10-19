#!/bin/sh
# Bounded semantic fixture, independent of Alpine/libc/a guest compiler.
# Apple Silicon host only. Does not access an iPad or any existing Linux root.
#
# LLVM_CLANG=/path/to/clang LLD=/path/to/ld.lld OUT=/tmp/fb \
#   sh tests/arm64-insn/forward-branches.sh build
# OUT=/tmp/fb sh tests/arm64-insn/forward-branches.sh prepare
# ISH_JIT_FORWARD_FALLTHROUGH=0 ISH=/path/to/ish OUT=/tmp/fb LABEL=baseline \
#   sh tests/arm64-insn/forward-branches.sh run
# ISH_JIT_FORWARD_FALLTHROUGH=1 ISH=/path/to/candidate/ish OUT=/tmp/fb LABEL=candidate \
#   sh tests/arm64-insn/forward-branches.sh run
#
# build only compiles fixtures; prepare refuses to replace an existing fakefs.
# run executes the native fixture and that one ELF through the selected CLI,
# requires an active native JIT, disables persistent caching, and compares both
# outputs with a fixed oracle. This is a correctness check, not a benchmark.
# The experimental fallthrough policy defaults off. The runner preserves the
# caller's ISH_JIT_FORWARD_FALLTHROUGH setting; opt in explicitly for a candidate.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
OUT=${OUT:?set OUT to a private fixture-output directory}
MODE=${1:-build}
mkdir -p "$OUT"

case "$MODE" in
    build)
        NATIVE_CC=${NATIVE_CC:-/usr/bin/clang}
        LLVM_CLANG=${LLVM_CLANG:-clang}
        LLD=${LLD:-ld.lld}
        "$NATIVE_CC" -arch arm64 -O0 -Wall -Wextra -Werror \
            -o "$OUT/forward-branches-native" \
            "$HERE/forward-branches.c" "$HERE/forward-branches.S"
        "$LLVM_CLANG" --target=aarch64-linux-gnu -O0 -Wall -Wextra -Werror \
            -ffreestanding -fno-builtin -fno-stack-protector \
            -fno-unwind-tables -fno-asynchronous-unwind-tables \
            -nostdlib -static --ld-path="$LLD" -Wl,-e,_start \
            -Wl,-z,max-page-size=4096 -o "$OUT/forward-branches-guest" \
            "$HERE/forward-branches.c" "$HERE/forward-branches.S"
        echo "forward-branches: fixtures built in $OUT"
        ;;
    prepare)
        if [ -e "$OUT/fakefs" ]; then
            echo "Refusing to replace $OUT/fakefs; choose a fresh OUT directory" >&2
            exit 1
        fi
        test -f "$OUT/forward-branches-guest"
        mkdir -p "$OUT/fakefs/data"
        cp "$OUT/forward-branches-guest" "$OUT/fakefs/data/forward-branches"
        chmod 755 "$OUT/fakefs/data/forward-branches"
        python3 "$ROOT/benchmark/create_fakefs.py" "$OUT/fakefs/data" "$OUT/fakefs"
        ;;
    run)
        : "${ISH:?set ISH to the native Mac ish CLI to test}"
        LABEL=${LABEL:-run}
        case "$LABEL" in *[!A-Za-z0-9_-]*|'') echo "Invalid LABEL" >&2; exit 1;; esac
        export ISH OUT LABEL
        python3 - <<'PY'
import os
from pathlib import Path
import subprocess

out = Path(os.environ["OUT"]).resolve()
label = os.environ["LABEL"]
expected = (
    "conditional families, spilled registers, nested paths ok\n"
    "NZCV across memory and TLB paths ok\n"
    "backward/self/unconditional branches ok\n"
    "4 KiB fetch boundary and instruction limit ok\n"
    "overlapping interior entry points ok\n"
    "fallthrough and interior code invalidation ok\n"
    "forward-branches: all passed\n"
)
if not (out / "fakefs/meta.db").is_file():
    raise SystemExit("Run prepare first to create the isolated fixture fakefs")
env = os.environ.copy()
env.update(ISH_JIT="1", ISH_JIT_PCACHE="0", ISH_JIT_STATS="1")
commands = {
    "native": [str(out / "forward-branches-native")],
    "guest": [str(Path(os.environ["ISH"]).resolve()), "-f", str(out / "fakefs"),
              "/forward-branches"],
}
for name, command in commands.items():
    try:
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired as error:
        raise SystemExit(f"{label} {name}: exceeded the 60-second semantic-test limit") from error
    (out / f"{label}-{name}.txt").write_text(result.stdout)
    (out / f"{label}-{name}.stderr").write_text(result.stderr)
    if result.returncode or result.stdout != expected:
        raise SystemExit(f"{label} {name}: failed; see {out / (label + '-' + name + '.txt')}")
    if name == "guest" and "ish: native JIT on:" not in result.stderr:
        raise SystemExit(f"{label} guest: native JIT was not confirmed in stderr")
print(f"{label}: native and JIT match the exact oracle (six groups)")
PY
        ;;
    *)
        echo "Usage: $0 build|prepare|run" >&2
        exit 2
        ;;
esac
