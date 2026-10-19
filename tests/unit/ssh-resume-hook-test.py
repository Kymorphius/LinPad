#!/usr/bin/env python3
"""Prove the generated resume hook detaches and installer preflight preserves data."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "tools/setup_guest_ssh.sh"
TIMEOUT = shutil.which("timeout")
NOHUP = shutil.which("nohup")
assert TIMEOUT and NOHUP, "native timeout/nohup are required for the detached-hook fixture"


def executable(path, text):
    path.write_text(text)
    path.chmod(0o700)


def hook_source():
    setup = SOURCE.read_text()
    marker = "    cat > \"$resume_tmp\" <<'RESUME_HOOK'\n"
    assert setup.count(marker) == 1
    hook = setup.split(marker, 1)[1].split("\nRESUME_HOOK\n", 1)[0] + "\n"
    assert "/usr/bin/timeout 40 /usr/local/bin/linpad-ssh-start --recover-existing" in hook
    return hook


def run_event(event):
    with tempfile.TemporaryDirectory(prefix="linpad-ssh-resume-fixture-") as tmp:
        root = Path(tmp)
        helper, hook = root / "helper", root / "hook"
        calls, done = root / "calls", root / "done"
        executable(helper, f'''#!/bin/sh
printf '%s\\n' "$*" >> '{calls}'
sleep 1
: > '{done}'
''')
        script = hook_source().replace("/usr/bin/nohup", NOHUP).replace("/usr/bin/timeout", TIMEOUT)
        script = script.replace("/usr/local/bin/linpad-ssh-start", str(helper))
        executable(hook, script)
        subprocess.run(["/bin/sh", "-n", str(hook)], check=True)
        before = time.monotonic()
        result = subprocess.run([TIMEOUT, "5", str(hook), *event],
                                capture_output=True, text=True, timeout=6)
        elapsed = time.monotonic() - before
        assert result.returncode == 0, result
        assert elapsed < 0.8, (event, elapsed, "hook waited for helper")
        assert not done.exists(), "helper must still be running when the hook returns"
        if event == ["resume"]:
            deadline = time.monotonic() + 4
            while not done.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            assert done.exists(), "owned transient helper did not finish"
            assert calls.read_text() == "--recover-existing\n"
        else:
            time.sleep(0.05)
            assert not calls.exists(), (event, "unexpected helper launch")
        print(f"PASS event={event!r} returned={elapsed:.3f}s")


def preflight_case(mode):
    with tempfile.TemporaryDirectory(prefix="linpad-ssh-install-fixture-") as tmp:
        root = Path(tmp)
        etc, home, mockbin = root / "etc", root / "root", root / "bin"
        hooks = etc / "linpad/lifecycle.d"
        hooks.mkdir(parents=True)
        (home / ".ssh").mkdir(parents=True)
        (etc / "linpad-ssh").mkdir()
        mockbin.mkdir()
        auth, key = home / ".ssh/authorized_keys", etc / "linpad-ssh/dropbear_ed25519_host_key"
        auth.write_text("preserved-auth-fixture\n")
        key.write_text("preserved-key-fixture-never-read\n")
        custom = hooks / "10-custom"
        custom.write_text("preserved user hook\n")
        target = root / "custom-target"
        target.write_text("preserved symlink target\n")
        destination = hooks / "50-linpad-ssh"
        if mode == "unknown-hook":
            destination.write_text("#!/bin/sh\n# User custom hook\n")
        elif mode == "symlink-hook":
            destination.symlink_to(target)
        elif mode == "symlink-directory":
            hooks.rename(etc / "saved-hooks")
            hooks.symlink_to(etc / "saved-hooks", target_is_directory=True)
        elif mode == "symlink-parent":
            (etc / "linpad").rename(etc / "saved-linpad")
            (etc / "linpad").symlink_to(etc / "saved-linpad", target_is_directory=True)
        executable(mockbin / "id", "#!/bin/sh\nprintf '0\\n'\n")
        executable(mockbin / "stat", "#!/bin/sh\nprintf '0\\n'\n")
        script = SOURCE.read_text().replace("/etc", str(etc)).replace("/root/.ssh", str(home / ".ssh"))
        script = script.replace("/usr/local/bin", str(root / "local-bin"))
        tested = root / "setup.sh"
        executable(tested, script)
        env = dict(os.environ, PATH=str(mockbin) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["/bin/sh", str(tested)], input="ssh-ed25519 AAAA fixture\n",
                                capture_output=True, text=True, timeout=5, env=env)
        assert result.returncode == 1, (mode, result)
        assert "refusing" in result.stderr, (mode, result.stderr)
        assert auth.read_text() == "preserved-auth-fixture\n"
        assert key.read_text() == "preserved-key-fixture-never-read\n"
        assert custom.read_text() == "preserved user hook\n"
        assert target.read_text() == "preserved symlink target\n"
        if mode == "unknown-hook":
            assert destination.read_text() == "#!/bin/sh\n# User custom hook\n"
        print(f"PASS preflight={mode} authentication and hooks preserved")


if __name__ == "__main__":
    for event in (["resume"], ["suspend"], ["other"], []):
        run_event(event)
    for mode in ("unknown-hook", "symlink-hook", "symlink-directory", "symlink-parent"):
        preflight_case(mode)
