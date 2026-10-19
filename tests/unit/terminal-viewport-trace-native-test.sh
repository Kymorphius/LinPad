#!/bin/sh
# Foundation-only numeric boundary test; no device or guest access.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/linpad-native-viewport-test.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -framework Foundation -I"$project_dir/app" \
    "$project_dir/tests/unit/terminal-viewport-trace-native-test.m" -o "$task_dir/test"
"$task_dir/test"
