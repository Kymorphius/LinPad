#!/bin/sh
set -eu

# Runs the actual native bridge/delegate methods with a deterministic synchronous
# scroll-view model. This does not exercise UIKit or reproduce device animation.
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/linpad-scroll-sync.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

python3 - "$repo_dir" "$test_dir" <<'PY'
from pathlib import Path
import sys

repo, output = map(Path, sys.argv[1:])

def method(source, signature):
    start = source.rindex(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

terminal = (repo / 'app/TerminalView.m').read_text()
bridge = method(terminal, '- (void)userContentController:')
callback = method(terminal, '- (void)scrollViewDidScroll:')
guard = '    if (self.webScrollUpdateDepth != 0)\n        return;\n'
assert callback.count(guard) == 1, 'expected the production web-scroll guard'
(output / 'terminal-scroll-sync-methods.inc').write_text(bridge + '\n' + callback)
# Negative control: run the same production code with only callback suppression
# removed, so the test must observe the old stale A/B echo.
(output / 'terminal-scroll-sync-legacy-methods.inc').write_text(
    bridge + '\n' + callback.replace(guard, ''))
scrollbar = (repo / 'app/ScrollbarView.m').read_text()
(output / 'scrollbar-scroll-method.inc').write_text(
    method(scrollbar, '- (void)scrollViewDidScroll:'))
PY

for legacy in 0 1; do
    xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -Wno-unused-parameter -framework Foundation -I "$test_dir" \
        -DTEST_LEGACY_SCROLL_ECHO="$legacy" \
        "$repo_dir/tests/unit/terminal-scroll-sync-test.m" \
        -o "$test_dir/scroll-sync-$legacy"
    "$test_dir/scroll-sync-$legacy"
done
