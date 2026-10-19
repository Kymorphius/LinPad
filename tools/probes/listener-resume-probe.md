# Listener suspend/resume probe

This small diagnostic observes one listener that it creates itself. It does not
connect to SSH, inspect other processes, send signals, change app state, rebind a
failed listener, or repair a service. A controller must arrange any device lock
and resume separately. Its result is evidence about this listener, not proof
that a separate Dropbear listener failed for the same reason.

The executable requires exactly `NEW_LOGPATH DURATION_SECONDS`, where duration
is an integer from 15 through 300. It creates that one log with `O_EXCL` and mode
`0600`; an existing file is never truncated or replaced. It owns one IPv4 TCP
listener bound to `127.0.0.1` and an ephemeral port, with nonblocking and
close-on-exec flags. Any connection accepted on that listener is closed without
reading or writing application data.

Every approximately one second it appends a compact JSON sample with monotonic
time, port, immediate poll result/revents, nonblocking accept result, and
`getsockname`, `SO_TYPE`, optional `SO_ACCEPTCONN`, and `F_GETFL` observations.
Negative syscall results are represented as result `-1` and a positive errno;
the other errno fields also use positive values. A successful accept result is
the owned descriptor number. Flag values and errno numbers are platform values.
`SO_ACCEPTCONN` may be unsupported and is never required for success.

The original listener descriptor remains open after an observed error so later
samples can show its state. There is no automatic replacement or retrying bind.
The log contains only these numeric observations and fixed metadata, never
terminal contents, credentials, or other process data. Writes occur once per
sample without `fsync`; a hard process kill can omit the final record.

The monotonic deadline is duration seconds. An independent maximum of
`duration + 5` loop iterations bounds work even if the emulated clock stops
advancing. Each iteration sleeps one second, with at most eight `EINTR` retries;
other sleep or log errors stop the probe. A suspended process cannot run its
cleanup until it resumes, so use a separate controller timeout with a small
margin when measuring wall time. Initial socket, bind, listen, or clock failure
produces start/end records and exits nonzero; subsequent socket errors are
observations and do not by themselves cause a nonzero exit.

## Build Linux AArch64 on macOS

The Linux build uses raw AArch64 syscalls, with no libc, dynamic loader, guest
compiler, or Linux rootfs dependency. Build into a fresh private directory:

```sh
task_probe_out=$(mktemp -d /tmp/linpad-listener-probe.XXXXXX)
/opt/homebrew/opt/llvm/bin/clang \
  --target=aarch64-linux-gnu -O2 -Wall -Wextra -Werror \
  -ffreestanding -fno-builtin -fno-stack-protector -nostdlib -static \
  --ld-path=/tmp/linpad-power-toolchain/bin/ld.lld \
  -Wl,-e,_start,-z,max-page-size=4096 \
  tools/probes/listener-resume-probe.c \
  -o "$task_probe_out/listener-resume-probe-linux"
/opt/homebrew/opt/llvm/bin/llvm-readelf -l \
  "$task_probe_out/listener-resume-probe-linux"
```

The compile-time checks cover 64-bit pointers, 16-byte Linux `timespec`, 8-byte
`pollfd`, and 16-byte `sockaddr_in` with address at offset 4. The Linux build
requires little endian AArch64. `_start` obtains argc/argv from the initial
stack and exits with raw syscall 93. It keeps an initialized nonzero eight-byte
RW datum so the ELF has a file-backed RW `PT_LOAD`, avoiding a known standalone
LinPad loader limitation with BSS-only segments.

Linux AArch64 syscall numbers used: `fcntl=25`, `openat=56`, `close=57`,
`write=64`, `ppoll=73`, `exit=93`, `nanosleep=101`, `clock_gettime=113`,
`socket=198`, `bind=200`, `listen=201`, `accept=202`, `getsockname=204`, and
`getsockopt=209`. No timer is armed and no signal handler is installed.

## Optional native format/lifetime smoke

On Apple Silicon the same C file uses POSIX calls and `poll(..., 0)` instead of
Linux `ppoll(..., zero_timeout, ...)`; the start record identifies that variant.
This checks argument handling, log format, ordinary listener behavior, cleanup,
and collision protection. It does not test Linux emulation or iPad suspension.

```sh
/opt/homebrew/opt/llvm/bin/clang -O2 -Wall -Wextra -Werror \
  tools/probes/listener-resume-probe.c \
  -o "$task_probe_out/listener-resume-probe-darwin"
"$task_probe_out/listener-resume-probe-darwin" \
  "$task_probe_out/native-smoke.jsonl" 15
```

Exit codes: `0` completed with successful initial setup and cleanup, `2` invalid
arguments, `3` unable to create a new log, `4` setup/clock/sleep/log/cleanup
failure. The final record reports sample count and listener-close errno. As
with any write-only log, an error closing the log itself can only be represented
by the process exit code.

## Optional one-shot SSH recovery guard

`listener-resume-recovery.sh NEW_LOG EXPECTED_PID EXPECTED_STARTTIME SECONDS`
is a separate, explicitly launched diagnostic controller for the guest. Use a
private experiment directory and freshly verify the intended SSH master first.
It requires guest root, the existing LinPad SSH helper, and BusyBox `nc` and
`timeout` at their fixed `/usr/bin` paths. It does not install a service or edit
configuration. Duration is 35 through 300 seconds; 300 provides room for a
controlled one-minute display lock and subsequent checks.

An initial healthy local SSH-2.0 banner is required before arming. Thereafter
checks are separated by five-second sleeps, with each banner operation bounded
by four seconds. Two consecutive missing banners can trigger at most one TERM
to the expected master. Every identity marker must still match: PID file,
executable, name, PID/Tgid, parent PID 1, all root UIDs and starttime. LinPad's
derived starttime can vary by one 100-Hz tick, so only a +/-1 tick tolerance is
accepted. This does not exclude PID reuse within that 10 ms margin by itself.

The existing start helper is called only after the old `/proc/PID` entry is
gone and the PID file has not been replaced. A changed identity, unsupported
helper header, unreadable state, insufficient time or failed recovery ends the
guard without further signals. It never uses SIGKILL or signals process groups.
The log records uptime, master CPU ticks and fixed status messages. An existing
log is refused and new logs have mode 0600.

This is a bounded experiment aid, not a permanent lifecycle repair. A suspended
app cannot execute the guard; resuming after its deadline leaves the server
untouched. A real device controller must arrange lock/unlock within the window,
collect the probe and guard logs, and independently verify SSH afterward.

`python3 tests/unit/listener-resume-recovery-test.py` exercises the full guard
against private fake proc files and mocked commands, including healthy,
identity-change, rounding, recovery, PID-reuse and existing-log cases. No real
process is signaled or network connection opened by that fixture.
