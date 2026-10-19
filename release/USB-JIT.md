# Enable LinPad JIT over USB from a Mac

[`tools/enable_device_jit.py`](../tools/enable_device_jit.py) is an Apple LLDB
command extension for LinPad's TXM memory preparation protocol. It does not
modify the IPA or require an additional debugging app on the iPad. See
[jit/DESIGN.md](../jit/DESIGN.md#10-executable-memory-on-ios-txm-and-macos) for
the protocol design.

## Attach and enable JIT

Use a Mac with Xcode installed and selected. The iPad must have Developer Mode
enabled, trust the Mac, and run a development-signed LinPad build that permits
debugger attachment. Connect the iPad over USB, unlock it, and open LinPad.

Find the device identifier and the current LinPad process:

```sh
xcrun devicectl list devices
xcrun devicectl device info processes --device <device-identifier>
```

Look for `iSH ARM64.app/iSH ARM64`. The process ID can change whenever the app
restarts. Start a fresh LLDB session:

```sh
xcrun lldb --no-lldbinit
```

Select the device and attach to the current process:

```text
device select <device-identifier>
device process attach -p <current-process-id>
```

Wait for both `Process ... stopped` and `Target ... stopped`. Device attachment
is asynchronous: an early `(lldb)` prompt does not establish that the target
has stopped. Initial system-symbol loading can take time.

Import the helper using the absolute path to your checkout, then run it:

```text
command script import /absolute/path/LinPad-Revanced/tools/enable_device_jit.py
linpad-jit --timeout 300
```

Once the helper is waiting, select **Settings → Fast Mode → Retry** in LinPad.
The helper handles the main executable's `brk #0xf00d` protocol requests,
prepares the requested RX pages, returns their address, and waits for the app's
explicit detach request. The app determines the allocation size.

After `LinPad protocol completed and LLDB detached`, quit LLDB. Check Fast Mode
in the app and independently verify native state when symbols are available;
protocol completion alone does not establish the complete JIT state.

### Trigger Retry from LLDB

When the Fast Mode button is unavailable, use the explicit retry option:

```text
linpad-jit --retry --timeout 300
```

At a clean attachment stop, this option finds and verifies the main thread,
then invokes the app's existing `retryFastMode` method with a short Objective-C
expression. It does not invoke that method at a protocol BRK or another
exception stop.

If Fast Mode is already On, the helper verifies the initialized core's
`jitStatus == 1` and detaches normally without requesting another arena. If
initialization is in progress, it continues the in-flight TXM protocol. If the
expression is unavailable, the main thread cannot be verified, or state is
inconsistent, it reports an error and leaves the process stopped for inspection.
It never falls back to addresses from a previous binary.

Without `--retry`, the protocol command does not evaluate an expression.
The status command below also does not evaluate expressions.

## Verify native state

To inspect native state after protocol completion, start a fresh LLDB session,
select the device, attach to the current process, and wait for it to stop.
Import the helper and run:

```text
linpad-jit-status
process detach
quit
```

The status command only reads native globals. Missing symbols are reported as
`unavailable`; they do not count as verified state. Compare the available
native state with the app's Fast Mode setting. Finish debugging before testing
SSH or running guest programs.

## Scope and error handling

- JIT activation belongs to the current LinPad process. If the app terminates,
  iPadOS reclaims it, or the iPad restarts, repeat the USB activation procedure.
  The cable can be disconnected after successful debugger detachment.
- Linux programs that were already running when JIT was enabled retain their
  prior execution mode. Open a new Linux program or terminal to use JIT.
  Restarting the entire LinPad app also discards the activation.
- The helper has a total timeout and rejects user breakpoints, unknown traps,
  and invalid memory mappings. LLDB `thread-creation` events are continued only
  after its internal breakpoint and location are verified, at most 128 times.
- Errors, timeouts, and Ctrl-C leave the debugger attached and the process
  stopped for inspection. Inspect `thread backtrace all`, resolve the cause,
  and rerun `linpad-jit` if appropriate. Do not skip an unresolved protocol
  instruction or detach while its request is incomplete.
- If a later attachment fails, quit the previous LLDB and retry in a fresh
  session. Always use the current process ID and wait for the stopped event.

## Local regression checks

The helper's stop-event regression tests do not require a connected device:

```sh
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
```

An optional Apple Silicon Mac / Apple LLDB integration check uses a temporary
host test program without connecting to a device:

```sh
LINPAD_RUN_HOST_LLDB_SMOKE=1 python3 -m unittest discover \
    -s tools/tests -p 'test_jit_retry_host.py' -v
```
