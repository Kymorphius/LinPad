# Idle CPU regressions

## Observed problem

A 15.73-second Time Profiler recording of LinPad 1.5.0 (4428) on an iPad
at rest attributed 15.447 seconds of sampled CPU time to the guest
`pipe-source` thread: approximately one CPU core. The hot stack was
`realfs_poll -> poll_wait -> sys_poll -> sys_ppoll`; the desktop main thread
accounted for only 0.130 seconds of sampled CPU time. These are CPU samples,
not measurements of device watts or temperature.

PulseAudio suspends its microphone source by polling its FIFO without read
interest. The host microphone bridge leaves a small silence probe in that FIFO.
`kernel/poll.c` still requests hangup/error notifications, so `fs/poll.c` watches
the host read filter with `NOTE_LOWAT(INT_MAX)`. Darwin named FIFOs ignore this
low-water setting: buffered bytes repeatedly wake the host filter, but the
guest correctly rejects ordinary read readiness. The wait therefore spins.

Hangup-only host read watches now clear each notification after collection.
The guest readiness scan still reports persistent hangups. Recreating the read
filter when interests change also resets Darwin's sticky `EV_CLEAR` and
`NOTE_LOWAT` settings, so ordinary level-triggered reads resume normally.

A second regression involved nested epoll sets with at least 16 ready host
filters. Repeatedly draining a full batch never finishes for level-triggered
descriptors. Collection now takes one bounded snapshot sized for the set's
registered host filters, including edge bookkeeping beyond the small buffer.

## Regression checks

Run from the repository root:

```sh
tests/unit/poll-test.sh
```

The native test links the production `fs/poll.c` and `fs/real.c`; no guest
filesystem, JIT or simulator is needed. It checks:

- A buffered named FIFO with read interest disabled waits for its timeout with
  low CPU use, and restoring read interest exposes the existing data.
- Empty and buffered anonymous pipes still wake promptly when the writer closes.
- Read-watch mode changes preserve host level-triggered notifications.
- Nested sets with 20 ready sockets return promptly; edge-triggered events rearm
  without duplicate or stale readiness.

Darwin's raw named-FIFO close behavior differs from anonymous pipes, so the
hangup checks use anonymous pipes rather than asserting unsupported host FIFO
semantics. A watchdog catches an unbounded wait.

DesktopKit also combines its CPU/memory samples into one guest command and
releases panel, widget, folder and optional FPS sampling while backgrounded,
locked or covered by the screensaver. Folder scans also stop when desktop
icons are hidden. `PanelMonitorSharingTests` covers shared sampling and late
replies from a cancelled sampling session.

## Device acceptance

Source tests do not update the installed iPad app. After installing a signed
build containing these changes, repeat an idle Time Profiler recording with the
same windows, fast-mode setting and desktop settings. Confirm that the
`pipe-source` thread blocks rather than consuming a core, then check playback,
microphone capture, lock/unlock and background/foreground transitions. Compare
temperature or battery use only after a matched device run and cooling period.
