#!/bin/sh
# Compile and execute production Darwin memory calculations with host API mocks.
# Additional arguments are passed to the compiler (e.g. -fsanitize=undefined).
set -eu
case $(uname -s) in
    Darwin) ;;
    *) echo 'darwin-memory-test requires the macOS SDK' >&2; exit 1 ;;
esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/linpad-darwin-memory-test.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -I"$root" "$@" \
    "-DDARWIN_MEMORY_TEST_SOURCE=\"${DARWIN_MEMORY_TEST_SOURCE:-$root/platform/darwin.c}\"" \
    "$root/tests/unit/darwin-memory-test.c" -o "$build/darwin-memory-test"
for fixture in quota-5g quota-12g-small quota-12g-large tiny-headroom \
        host-fallback host-clamp overflow live-footprint; do
    "$build/darwin-memory-test" "$fixture"
done
