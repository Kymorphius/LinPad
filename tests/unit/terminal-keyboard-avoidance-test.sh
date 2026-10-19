#!/bin/sh
set -eu

# Compiles production desktop geometry and native padding decisions on macOS.
# The deterministic Will/Did schedule models viewport sizes, not UIKit animation.
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/linpad-keyboard-avoidance.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

python3 - "$repo_dir" "$test_dir" <<'PY'
from pathlib import Path
import sys

repo, output = map(Path, sys.argv[1:])

def declaration(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

source = (repo / 'desktop/DesktopKit/Sources/DesktopKit/Core/WindowManager.swift').read_text()
display = declaration(source, '    func displayFrame(for window: DesktopWindow) -> CGRect')
placement = declaration(source, '    private func tiledOrFloatingFrame(for window: DesktopWindow) -> CGRect')
app_id = declaration((repo / 'desktop/DesktopKit/Sources/DesktopKit/API/API.swift').read_text(), 'public enum AppID')
terminal_branch = '''        if window.appID == AppID.terminal {
            return WindowGeometry.liftingAboveKeyboard(frame, availableHeight: availableHeight)
        }
'''
assert display.count(terminal_branch) == 1, 'expected the terminal-only production dispatch'

# Only UIKit/Perception-owned state is replaced by plain storage. Both routing
# methods and every geometry/padding decision run the actual production code.
storage = '''import CoreGraphics
import Foundation
final class DesktopWindow {
    let id = UUID()
    let appID: String
    var frame: CGRect
    var isMaximized = false
    var snap: SnapZone?
    var tileDragOffset: CGSize = .zero
    init(appID: String, frame: CGRect) { self.appID = appID; self.frame = frame }
}
'''
manager = '''
final class WindowManager {
    static let minimumSize = CGSize(width: 320, height: 200)
    var desktopSize = CGSize(width: 1180, height: 760)
    var focusedWindowID: UUID?
    var keyboard = KeyboardAvoidance()
    var keyboardOverlap: CGFloat { keyboard.overlap }
    var tileFrames: [UUID: CGRect] = [:]
'''
for legacy in [False, True]:
    method = display.replace(terminal_branch, '') if legacy else display
    (output / ('legacy-routing.swift' if legacy else 'routing.swift')).write_text(
        storage + app_id + manager + method + '\n' + placement + '\n}\n')
PY

for variant in current legacy; do
    if [ "$variant" = legacy ]; then
        routing="$test_dir/legacy-routing.swift"
        define="-DTEST_LEGACY_HEIGHT"
    else
        routing="$test_dir/routing.swift"
        define=""
    fi
    # Intentional splitting: define is either empty or one compiler argument.
    # shellcheck disable=SC2086
    xcrun swiftc -warnings-as-errors $define \
        -import-objc-header "$repo_dir/app/TerminalKeyboardGeometry.h" \
        "$repo_dir/desktop/DesktopKit/Sources/DesktopKit/Core/WindowGeometry.swift" \
        "$repo_dir/desktop/DesktopKit/Sources/DesktopKit/Core/KeyboardAvoidance.swift" \
        "$routing" "$repo_dir/tests/unit/terminal-keyboard-avoidance-test.swift" \
        -o "$test_dir/keyboard-avoidance-$variant"
    "$test_dir/keyboard-avoidance-$variant"
done
