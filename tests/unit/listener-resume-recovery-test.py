#!/usr/bin/env python3
"""Exercise the whole one-shot guard with private fake /proc and commands.

The test copy replaces fixed paths and both kill callsites. It never invokes
kill against a real process or opens a network connection.
"""
import os
from pathlib import Path
import subprocess
import tempfile


SOURCE = Path(__file__).resolve().parents[2] / "tools/probes/listener-resume-recovery.sh"


def executable(path, text):
    path.write_text(text)
    path.chmod(0o700)


def run_case(mode, expected_code, expected_events):
    with tempfile.TemporaryDirectory(prefix="listener-recovery-fixture-") as tmp:
        root = Path(tmp)
        proc = root / "proc"
        master = proc / "42"
        master.mkdir(parents=True)
        (proc / "uptime").write_text("1000.00 0.00\n")
        fields = ["0"] * 50
        fields[0], fields[1], fields[19] = "S", "1", "123"
        if mode == "one-tick-jitter":
            fields[19] = "124"
        elif mode == "negative-one-tick-jitter":
            fields[19] = "122"
        elif mode == "two-tick-change":
            fields[19] = "125"
        (master / "stat").write_text("42 (dropbear) " + " ".join(fields) + "\n")
        (master / "status").write_text(
            "Name:\tdropbear\nTgid:\t42\nPid:\t42\nPPid:\t"
            + ("2" if mode == "identity-mismatch" else "1")
            + "\nUid:\t0\t0\t0\t0\n"
        )
        (master / "exe").symlink_to("/usr/sbin/dropbear")
        pidfile, events = root / "server.pid", root / "events"
        pidfile.write_text("42\n")
        events.write_text("")
        mockbin = root / "bin"
        mockbin.mkdir()
        executable(mockbin / "id", "#!/bin/sh\nprintf '0\\n'\n")
        executable(mockbin / "timeout", '#!/bin/sh\nshift\nexec "$@"\n')
        executable(mockbin / "sleep", '''#!/bin/sh
[ "$1" = 3 ] && exit 0
IFS=' ' read -r t rest < "$FIXTURE/proc/uptime"
t=${t%%.*}
printf '%s.00 0.00\n' "$((t + $1))" > "$FIXTURE/proc/uptime"
''')
        executable(mockbin / "nc", '''#!/bin/sh
n=0
[ ! -f "$FIXTURE/calls" ] || read -r n < "$FIXTURE/calls"
n=$((n + 1))
printf '%s\n' "$n" > "$FIXTURE/calls"
if [ "$MODE" = healthy ] || [ "$MODE" = one-tick-jitter ] || [ "$MODE" = negative-one-tick-jitter ] || [ -f "$FIXTURE/restarted" ] || { [ "$n" = 1 ] && [ "$MODE" != initial-bad ]; }; then
    printf 'SSH-2.0-dropbear_fixture\r\n'
else
    [ "$MODE" != pidfile-changed ] || printf '999\n' > "$FIXTURE/server.pid"
fi
''')
        executable(mockbin / "kill", '''#!/bin/sh
case "$1" in
 -0) [ -d "$FIXTURE/proc/$2" ] ;;
 -TERM)
    printf 'TERM %s\n' "$2" >> "$FIXTURE/events"
    case "$MODE" in
      pid-reused) sed 's/ 123 / 1123 /' "$FIXTURE/proc/$2/stat" > "$FIXTURE/stat.new"; mv "$FIXTURE/stat.new" "$FIXTURE/proc/$2/stat" ;;
      master-stays) : ;;
      *) rm -r "$FIXTURE/proc/$2" ;;
    esac ;;
 *) exit 99 ;;
esac
''')
        helper = root / "linpad-ssh-start"
        executable(helper, '''#!/bin/sh
# LinPad SSH helper
printf 'START\n' >> "$FIXTURE/events"
printf '999\n' > "$FIXTURE/server.pid"
: > "$FIXTURE/restarted"
''')
        script = SOURCE.read_text()
        replacements = {
            "proc_root=/proc": f"proc_root='{proc}'",
            "pid_file=/run/linpad-ssh/server.pid": f"pid_file='{pidfile}'",
            "helper=/usr/local/bin/linpad-ssh-start": f"helper='{helper}'",
            "nc=/usr/bin/nc": f"nc='{mockbin / 'nc'}'",
            "timeout=/usr/bin/timeout": f"timeout='{mockbin / 'timeout'}'",
            'kill -0 "$expected_pid"': f'"{mockbin / "kill"}" -0 "$expected_pid"',
            'kill -TERM "$expected_pid"': f'"{mockbin / "kill"}" -TERM "$expected_pid"',
        }
        for old, new in replacements.items():
            assert script.count(old) == 1, old
            script = script.replace(old, new)
        tested = root / "guard.sh"
        executable(tested, script)
        log = root / "guard.log"
        if mode == "existing-log":
            log.write_text("keep me\n")
        env = dict(os.environ, FIXTURE=str(root), MODE=mode,
                   PATH=str(mockbin) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["/bin/sh", str(tested), str(log), "42", "123", "60"],
                                env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == expected_code, (mode, result.returncode, result.stderr, log.read_text())
        assert events.read_text() == expected_events, (mode, events.read_text())
        if mode == "existing-log":
            assert log.read_text() == "keep me\n"
        else:
            assert log.stat().st_mode & 0o777 == 0o600
        print(f"PASS {mode}")


if __name__ == "__main__":
    subprocess.run(["/bin/sh", "-n", str(SOURCE)], check=True)
    for case in (
        ("healthy", 0, ""),
        ("one-tick-jitter", 0, ""),
        ("negative-one-tick-jitter", 0, ""),
        ("two-tick-change", 1, ""),
        ("identity-mismatch", 1, ""),
        ("initial-bad", 1, ""),
        ("recovery", 0, "TERM 42\nSTART\n"),
        ("pid-reused", 1, "TERM 42\n"),
        ("master-stays", 1, "TERM 42\n"),
        ("pidfile-changed", 1, ""),
        ("existing-log", 1, ""),
    ):
        run_case(*case)
