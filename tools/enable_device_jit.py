"""Apple LLDB commands for LinPad's two TXM jitcalls.

    command script import /absolute/path/to/tools/enable_device_jit.py
    device select DEVICE
    device process attach -p PID
    linpad-jit --timeout 300
    linpad-jit --retry --timeout 300

Without --retry, tap Settings > Fast Mode > Retry in LinPad. --retry uses
bounded expressions on a verified main thread only at a clean attach stop.
The command handles only
LinPad's brk #0xf00d commands 1 (prepare RX memory) and 0 (resume and detach).
An error, Ctrl-C, or timeout preserves the stopped debugging session. Rerun
linpad-jit to resume a protocol stop; do not detach at an unhandled jitcall.
linpad-jit-status reads native globals while already attached and stopped.
"""

import argparse
import shlex
import signal
import threading
import time

import lldb


PAGE_SIZE = 16384
MIN_REGION_SIZE = 32 << 20
MAX_REGION_SIZE = 1 << 30
ADDRESS_LIMIT = 0x1000000000  # LinPad's acquire_txm requires an address < 64 GiB.
BRK_INSTRUCTION = 0xD4200000 | (0xF00D << 5)
EXECUTABLE = "iSH ARM64"
EXPRESSION_TIMEOUT_US = 2_000_000
_pending_allocations = {}


class JITError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise JITError(message)


def _emit(debugger, message):
    # Apple's bundled LLDB exposes SBFile rather than GetAsyncOutputStream.
    payload = ("[linpad-jit] " + message + "\n").encode("utf-8")
    error, written = debugger.GetOutputFile().Write(payload)
    if error.Fail() or written != len(payload):
        raise JITError("Cannot write progress output: %s" % error)


def _context(debugger):
    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        raise JITError("No selected target; attach to the LinPad process first.")
    triple = target.GetTriple() or ""
    if triple.split("-")[0] not in ("arm64", "arm64e"):
        raise JITError("Refusing non-arm64 target: " + triple)
    if target.GetExecutable().GetFilename() != EXECUTABLE:
        raise JITError("Refusing a target whose executable is not " + EXECUTABLE)
    main = target.FindModule(target.GetExecutable())
    if not main.IsValid():
        raise JITError("Cannot identify LinPad's main module.")
    process = target.GetProcess()
    if not process.IsValid() or process.GetProcessID() <= 0:
        raise JITError("Attach to the running LinPad process first.")
    if process.GetState() != lldb.eStateStopped:
        raise JITError("Process must already be stopped; no process state was changed.")
    return target, main, process


def _read_register(frame, name):
    value = frame.FindRegister(name)
    if not value.IsValid():
        raise JITError("Cannot read register " + name)
    error = lldb.SBError()
    number = value.GetValueAsUnsigned(error, lldb.LLDB_INVALID_ADDRESS)
    if error.Fail():
        raise JITError("Cannot read register %s: %s" % (name, error))
    return number


def _write_register(frame, name, number):
    error = lldb.SBError()
    register = frame.FindRegister(name)
    if not register.IsValid() or not register.SetValueFromCString(hex(number), error):
        raise JITError("Cannot write register %s: %s" % (name, error))
    if _read_register(frame, name) != number:
        raise JITError("Register %s did not retain its requested value." % name)


def _validate_region(address, size):
    if not MIN_REGION_SIZE <= size <= MAX_REGION_SIZE or size % PAGE_SIZE:
        raise JITError("Invalid LinPad region size %d; expected 32 MiB..1 GiB, 16 KiB aligned." % size)
    if address in (0, lldb.LLDB_INVALID_ADDRESS) or address % PAGE_SIZE:
        raise JITError("RX address must be nonzero and 16 KiB aligned: %#x" % address)
    if address >= ADDRESS_LIMIT or address + size > ADDRESS_LIMIT:
        raise JITError("RX region exceeds LinPad's 64 GiB address limit: %#x + %#x" % (address, size))


def _check_rx_region(process, address, size):
    """Reject an existing region unless every page belongs to readable RX maps."""
    end = address + size
    current = address
    while current < end:
        info = lldb.SBMemoryRegionInfo()
        error = process.GetMemoryRegionInfo(current, info)
        if error.Fail():
            raise JITError("Cannot inspect RX mapping at %#x: %s" % (current, error))
        if (not info.IsMapped() or not info.IsReadable() or not info.IsExecutable()
                or info.IsWritable() or info.GetRegionEnd() <= current):
            raise JITError("Refusing memory that is not mapped read/execute-only at %#x" % current)
        current = min(end, info.GetRegionEnd())


def _threads(process):
    selected = process.GetSelectedThread()
    threads = [process.GetThreadAtIndex(i) for i in range(process.GetNumThreads())]
    if selected.IsValid():
        threads.sort(key=lambda thread: thread.GetThreadID() != selected.GetThreadID())
    return threads


def _internal_thread_creation(target, thread):
    """Identify LLDB's synthetic thread events without ignoring user breakpoints."""
    if (thread.GetStopReason() != lldb.eStopReasonBreakpoint
            or thread.GetStopDescription(256) != "thread-creation"):
        return False
    count = thread.GetStopReasonDataCount()
    if not count or count % 2:
        return False
    for index in range(0, count, 2):
        breakpoint_id = thread.GetStopReasonDataAtIndex(index)
        if breakpoint_id >= (1 << 63):
            breakpoint_id -= 1 << 64
        if not -(1 << 31) <= breakpoint_id < 0:
            return False
        breakpoint = target.FindBreakpointByID(breakpoint_id)
        if not breakpoint.IsValid() or not breakpoint.IsInternal():
            return False
        location = breakpoint.FindLocationByID(thread.GetStopReasonDataAtIndex(index + 1))
        if not location.IsValid():
            return False
    return True


def _only_internal_thread_creation(target, process):
    found = False
    for thread in _threads(process):
        if thread.GetStopReason() in (lldb.eStopReasonInvalid, lldb.eStopReasonNone):
            continue
        if not _internal_thread_creation(target, thread):
            return False
        found = True
    return found


def _protocol_stop(target, main, process):
    """Return a proven LinPad protocol stop, never infer one from SIGTRAP alone."""
    candidates = []
    for thread in _threads(process):
        reason = thread.GetStopReason()
        if reason not in (lldb.eStopReasonException, lldb.eStopReasonBreakpoint,
                          lldb.eStopReasonSignal):
            continue
        if reason == lldb.eStopReasonSignal:
            if not thread.GetStopReasonDataCount() or thread.GetStopReasonDataAtIndex(0) != signal.SIGTRAP:
                continue
        frame = thread.GetFrameAtIndex(0)
        if not frame.IsValid():
            continue
        pc = frame.GetPC()
        address = target.ResolveLoadAddress(pc)
        module = address.GetModule()
        if not module.IsValid() or module.GetUUIDString() != main.GetUUIDString():
            continue
        error = lldb.SBError()
        instruction = process.ReadUnsignedFromMemory(pc, 4, error)
        if error.Fail() or instruction != BRK_INSTRUCTION:
            continue
        command = _read_register(frame, "x16")
        if command not in (0, 1):
            raise JITError("LinPad stopped at brk #0xf00d with unsupported command %d; untouched." % command)
        candidates.append((thread, frame, pc, command))
    if len(candidates) > 1:
        raise JITError("Multiple protocol threads stopped together; refusing to choose one.")
    if candidates:
        chosen = candidates[0]
        for other in _threads(process):
            if other.GetThreadID() == chosen[0].GetThreadID():
                continue
            if _internal_thread_creation(target, other):
                continue
            if other.GetStopReason() not in (lldb.eStopReasonInvalid, lldb.eStopReasonNone):
                raise JITError("A second thread has an independent stop; preserving all stops.")
        return chosen
    return None


def _initial_attach_stop(target, process):
    for thread in _threads(process):
        reason = thread.GetStopReason()
        if reason in (lldb.eStopReasonInvalid, lldb.eStopReasonNone):
            continue
        if _internal_thread_creation(target, thread):
            continue
        if (reason == lldb.eStopReasonSignal and thread.GetStopReasonDataCount()
                and thread.GetStopReasonDataAtIndex(0) == signal.SIGSTOP):
            continue
        return False
    return True


def _describe_stop(process):
    items = []
    for thread in _threads(process):
        if thread.GetStopReason() not in (lldb.eStopReasonInvalid, lldb.eStopReasonNone):
            items.append("thread %d: %s" % (thread.GetThreadID(), thread.GetStopDescription(256)))
    return "; ".join(items) or "no recognized stopping thread"


def _preserve_stopped(process):
    if process.GetState() in (lldb.eStateRunning, lldb.eStateStepping):
        error = process.Stop()
        if error.Fail():
            return "Interrupt failed (%s); state=%d; keep LLDB open and stop the process." % (error, process.GetState())
    if process.GetState() == lldb.eStateStopped:
        return "Process remains stopped and attached. Keep LLDB open. Inspect with thread backtrace all; rerun linpad-jit only after resolving the error. Do not detach at an unhandled jitcall."
    return "Process state=%d. No automatic detach was attempted." % process.GetState()


def _retry_frame(process):
    """Find a main-thread candidate; the expression must independently verify it."""
    threads = _threads(process)
    candidates = [thread for thread in threads if thread.GetQueueName() == "com.apple.main-thread"]
    if not candidates:
        # LLDB's first thread normally is UIKit's main thread. This index is only
        # a fallback candidate: NSThread.isMainThread below is the actual proof.
        candidates = [thread for thread in threads if thread.GetIndexID() == 1]
    if len(candidates) != 1:
        raise JITError("Cannot identify one main-thread candidate; retry manually in LinPad.")
    thread = candidates[0]
    frame = thread.GetFrameAtIndex(0)
    if not frame.IsValid() or not process.SetSelectedThread(thread):
        raise JITError("Cannot select a valid main-thread frame; retry manually in LinPad.")
    return frame


def _retry_expression(body):
    # A statement expression, not a compiled block: no target code escapes the
    # LLDB expression's lifetime. Verify the main thread before any app method.
    return """(long)({
        id threadClass = (id)objc_getClass("NSThread");
        id appClass = (id)objc_getClass("AppDelegate");
        !threadClass || !(BOOL)[threadClass isMainThread] ? -10L :
        !appClass ? -11L :
        !(BOOL)[appClass respondsToSelector:@selector(fastModeState)] ||
        !(BOOL)[appClass respondsToSelector:@selector(retryFastMode)] ||
        !(BOOL)[appClass respondsToSelector:@selector(jitStatus)] ? -12L :
        (%s);
    })""" % body


def _evaluate_retry_integer(target, process, frame, body, check_deadline):
    if not _initial_attach_stop(target, process):
        raise JITError("Retry expression requires a clean attach stop: " + _describe_stop(process))
    check_deadline()
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetTimeoutInMicroSeconds(EXPRESSION_TIMEOUT_US)
    options.SetOneThreadTimeoutInMicroSeconds(EXPRESSION_TIMEOUT_US)
    options.SetTryAllThreads(False)
    options.SetStopOthers(True)
    options.SetIgnoreBreakpoints(False)
    options.SetUnwindOnError(True)
    value = frame.EvaluateExpression(_retry_expression(body), options)
    check_deadline()
    if not value.IsValid() or value.GetError().Fail():
        detail = value.GetError() if value.IsValid() else "invalid expression result"
        raise JITError("Retry expression failed or timed out: %s" % detail)
    if process.GetState() != lldb.eStateStopped or not _initial_attach_stop(target, process):
        raise JITError("Retry expression left an unexpected stop; preserving it: " + _describe_stop(process))
    error = lldb.SBError()
    number = value.GetValueAsSigned(error, -(1 << 63))
    if error.Fail() or number == -(1 << 63):
        raise JITError("Cannot parse retry expression result: %s" % error)
    failures = {
        -10: "Selected thread is not the main thread; retry manually in LinPad.",
        -11: "AppDelegate class is unavailable; no retry was requested.",
        -12: "Required AppDelegate selectors are unavailable; no retry was requested.",
        -13: "Fast mode changed unexpectedly; no further expression was attempted.",
    }
    if number in failures:
        raise JITError(failures[number])
    return number


def _request_retry(target, process, check_deadline):
    """Return True only when already-On has a verified, initialized JIT core."""
    frame = _retry_frame(process)
    state = _evaluate_retry_integer(target, process, frame, "(long)[appClass fastModeState]", check_deadline)
    if state == 2:
        # jitStatus calls jit_enabled(), which can initialize an untried core.
        # Call it only after On proves initialization has already completed.
        core = _evaluate_retry_integer(
            target, process, frame,
            "(long)[appClass fastModeState] == 2 ? (long)[appClass jitStatus] : -13L",
            check_deadline,
        )
        if core != 1:
            raise JITError("Fast mode reports On but native JIT core is not On (%d); preserving the session." % core)
        return True
    if state == 1:
        return False  # An in-flight request must be serviced, never restarted.
    if state not in (0, 3):
        raise JITError("Unknown fast-mode state %d; no retry was requested." % state)
    requested = _evaluate_retry_integer(
        target, process, frame,
        "((long)[appClass fastModeState] == 0 || (long)[appClass fastModeState] == 3) "
        "? ((void)[appClass retryFastMode], 1L) : -13L",
        check_deadline,
    )
    if requested != 1:
        raise JITError("Retry did not return the expected acknowledgement; preserving the session.")
    return False


def linpad_jit(debugger, command, result, internal_dict):
    """Service TXM until detach, or verify already-On before a --retry detach."""
    process = None
    finished = threading.Event()
    expired = threading.Event()
    watchdog = None
    old_async = debugger.GetAsync()
    try:
        parser = _Parser(prog="linpad-jit", add_help=False)
        parser.add_argument("--timeout", type=int, default=300)
        parser.add_argument("--retry", action="store_true")
        options = parser.parse_args(shlex.split(command))
        if not 5 <= options.timeout <= 1800:
            raise JITError("--timeout must be between 5 and 1800 seconds.")
        target, main, process = _context(debugger)
        pid = process.GetProcessID()
        identity = (process.GetUniqueID(), pid)
        deadline = time.monotonic() + options.timeout

        def check_deadline():
            if expired.is_set() or time.monotonic() >= deadline:
                raise JITError("Timed out after %d seconds." % options.timeout)

        def interrupt_at_deadline():
            if not finished.wait(options.timeout):
                expired.set()
                if process.GetState() in (lldb.eStateRunning, lldb.eStateStepping):
                    process.SendAsyncInterrupt()

        debugger.SetAsync(False)
        watchdog = threading.Thread(target=interrupt_at_deadline, daemon=True)
        watchdog.start()
        stop = _protocol_stop(target, main, process)
        if stop is None and not _initial_attach_stop(target, process):
            raise JITError("Initial stop is not an attach SIGSTOP or protocol request: " + _describe_stop(process))
        if options.retry and stop is None:
            if _request_retry(target, process, check_deadline):
                check_deadline()
                error = process.Detach(False)
                if error.Fail():
                    raise JITError("Detach failed: %s" % error)
                finished.set()
                _pending_allocations.pop(identity, None)
                result.AppendMessage("Fast mode and initialized native JIT core are already On; LLDB detached with resume. No RX allocation was requested.")
                return
            _emit(debugger, "PID %d: retry requested or already enabling; servicing TXM requests. Timeout %ds; Ctrl-C preserves the session." % (pid, options.timeout))
        elif options.retry:
            _emit(debugger, "PID %d already has a TXM request; servicing it without expressions or another retry." % pid)
        else:
            _emit(debugger, "PID %d attached. Tap LinPad Settings > Fast Mode > Retry. Timeout %ds; Ctrl-C preserves the session." % (pid, options.timeout))
        handled = 0
        internal_stops = 0
        while True:
            check_deadline()
            if stop is None:
                error = process.Continue()
                check_deadline()
                if error.Fail():
                    raise JITError("Continue failed: %s" % error)
                if process.GetState() != lldb.eStateStopped:
                    raise JITError("Process stopped responding or exited; state=%d" % process.GetState())
                stop = _protocol_stop(target, main, process)
                if stop is None:
                    if _only_internal_thread_creation(target, process):
                        internal_stops += 1
                        if internal_stops > 128:
                            raise JITError("Too many internal thread-creation stops; preserving the current stop.")
                        continue
                    raise JITError("Unexpected stop; no PC or registers were changed: " + _describe_stop(process))
            thread, frame, pc, jit_command = stop
            handled += 1
            if handled > 16:
                raise JITError("Too many protocol requests; preserving the current stop.")
            if jit_command == 0:
                _emit(debugger, "Received LinPad detach request; advancing its BRK and detaching with resume.")
                _write_register(frame, "pc", pc + 4)
                error = process.Detach(False)
                if error.Fail():
                    raise JITError("Detach failed: %s" % error)
                finished.set()
                _pending_allocations.pop(identity, None)
                result.AppendMessage("LinPad protocol completed and LLDB detached. JIT state still requires independent native readback (linpad-jit-status after reattach).")
                return

            requested_address = _read_register(frame, "x0")
            size = _read_register(frame, "x1")
            # Validate size before asking debugserver to allocate anything.
            _validate_region(PAGE_SIZE if requested_address == 0 else requested_address, size)
            key = (pc, thread.GetThreadID(), size)
            pending = _pending_allocations.get(identity)
            address = requested_address
            if address == 0 and pending is not None and pending[:3] == key:
                address = pending[3]
                _emit(debugger, "Reusing RX allocation from the interrupted preparation.")
            if address == 0:
                error = lldb.SBError()
                address = process.AllocateMemory(size, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, error)
                if error.Fail():
                    raise JITError("RX allocation failed: %s" % error)
                _pending_allocations[identity] = key + (address,)
            _validate_region(address, size)
            _check_rx_region(process, address, size)
            pages = size // PAGE_SIZE
            _emit(debugger, "Preparing %d MiB RX at %#x: writing one byte per 16 KiB page (%d pages)." % (size >> 20, address, pages))
            for page in range(pages):
                check_deadline()
                error = lldb.SBError()
                written = process.WriteMemory(address + page * PAGE_SIZE, b"\x69", error)
                if error.Fail() or written != 1:
                    raise JITError("RX preparation failed at page %d/%d: wrote %d byte(s), %s" % (page + 1, pages, written, error))
                if (page + 1) % 1024 == 0 or page + 1 == pages:
                    _emit(debugger, "Prepared %d/%d pages." % (page + 1, pages))
            check_deadline()
            _write_register(frame, "x0", address)
            _write_register(frame, "pc", pc + 4)
            _pending_allocations.pop(identity, None)
            _emit(debugger, "RX region returned to LinPad; waiting for its explicit detach request.")
            stop = None
    except (JITError, KeyboardInterrupt) as error:
        finished.set()
        detail = str(error) or "Cancelled by operator."
        if process is not None:
            detail += " " + _preserve_stopped(process)
        result.SetError(detail)
    except Exception as error:
        finished.set()
        detail = "%s: %s" % (type(error).__name__, error)
        if process is not None:
            detail += " " + _preserve_stopped(process)
        result.SetError(detail)
    finally:
        finished.set()
        if watchdog is not None:
            watchdog.join(timeout=1)
        debugger.SetAsync(old_async)


def _symbol_address(target, main, name):
    addresses = set()
    for spelling in (name, "_" + name):
        matches = main.FindSymbols(spelling, lldb.eSymbolTypeData)
        for index in range(matches.GetSize()):
            symbol = matches.GetContextAtIndex(index).GetSymbol()
            if symbol.IsValid():
                address = symbol.GetStartAddress().GetLoadAddress(target)
                if address != lldb.LLDB_INVALID_ADDRESS:
                    addresses.add(address)
    if len(addresses) != 1:
        raise JITError("Expected one loaded main-module data symbol %s; found %d." % (name, len(addresses)))
    return addresses.pop()


def linpad_jit_status(debugger, command, result, internal_dict):
    """Read native LinPad JIT state without executing any target expression."""
    try:
        if command.strip():
            raise JITError("linpad-jit-status takes no arguments.")
        target, main, process = _context(debugger)
        fields = (("jit_state", 4), ("fastModeState", 8),
                  ("fastModeNewProgramsOnly", 1), ("arena_size", 8),
                  ("arena_rx", 8), ("txm_arena", 1), ("bootPhase", 8))
        values = {}
        for name, width in fields:
            try:
                address = _symbol_address(target, main, name)
                error = lldb.SBError()
                value = process.ReadUnsignedFromMemory(address, width, error)
                if error.Fail():
                    raise JITError("Cannot read at %#x: %s" % (address, error))
                if name == "jit_state" and value & (1 << 31):
                    value -= 1 << 32
                values[name] = value
                result.AppendMessage("%s = %s (at %#x)" % (name, hex(value) if name == "arena_rx" else value, address))
            except JITError as error:
                result.AppendMessage("%s = unavailable (%s)" % (name, error))
        if all(name in values for name in ("jit_state", "fastModeState", "txm_arena")):
            result.AppendMessage("Native JIT On: %s" % (values["jit_state"] == 1 and values["fastModeState"] == 2 and values["txm_arena"] == 1))
        else:
            result.AppendMessage("Native JIT On: unconfirmed; one or more required symbols are unavailable.")
        result.AppendMessage("Fast mode: Idle=0, Enabling=1, On=2, Failed=3. Boot: Unpacking=0, Configuring=1, Running=2, Failed=3. Process remains stopped and attached.")
    except Exception as error:
        result.SetError(str(error))


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -o -f %s.linpad_jit linpad-jit" % __name__)
    debugger.HandleCommand("command script add -o -f %s.linpad_jit_status linpad-jit-status" % __name__)
    print("Loaded linpad-jit [--retry] [--timeout 300] and linpad-jit-status. Both require an attached, stopped iSH ARM64 target.")
