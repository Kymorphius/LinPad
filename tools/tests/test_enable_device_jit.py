"""Stop-classification guards can be tested without Apple LLDB or a device.

Run with: python3 -m unittest discover -s tools/tests -p 'test_*.py'
"""

import importlib.util
from pathlib import Path
import signal
import sys
import types
import unittest
from unittest import mock


fake_lldb = types.ModuleType("lldb")
for name, value in {
    "eStopReasonInvalid": 0,
    "eStopReasonNone": 1,
    "eStopReasonBreakpoint": 3,
    "eStopReasonSignal": 5,
    "eStopReasonException": 6,
    "eStateStopped": 5,
    "eStateRunning": 6,
    "eStateStepping": 7,
    "eStateDetached": 9,
    "eLanguageTypeObjC_plus_plus": 17,
    "ePermissionsReadable": 4,
    "ePermissionsExecutable": 2,
    "LLDB_INVALID_ADDRESS": (1 << 64) - 1,
}.items():
    setattr(fake_lldb, name, value)


class FakeError:
    def __init__(self, failed=False):
        self.failed = failed

    def Fail(self):
        return self.failed

    def __str__(self):
        return "expression timed out" if self.failed else "success"


fake_lldb.SBError = FakeError
spec = importlib.util.spec_from_file_location(
    "enable_device_jit_under_test", Path(__file__).resolve().parents[1] / "enable_device_jit.py"
)
jit = importlib.util.module_from_spec(spec)
with mock.patch.dict(sys.modules, {"lldb": fake_lldb}):
    spec.loader.exec_module(jit)


class FakeLocation:
    def __init__(self, valid=True):
        self.valid = valid

    def IsValid(self):
        return self.valid


class FakeBreakpoint:
    def __init__(self, *, valid=True, internal=True, locations=(1,)):
        self.valid = valid
        self.internal = internal
        self.locations = locations

    def IsValid(self):
        return self.valid

    def IsInternal(self):
        return self.internal

    def FindLocationByID(self, location_id):
        return FakeLocation(location_id in self.locations)


class FakeModule:
    def IsValid(self):
        return True

    def GetUUIDString(self):
        return "LINPAD-TEST-MODULE"


class FakeTarget:
    def __init__(self, breakpoints=None):
        self.breakpoints = {-6: FakeBreakpoint()} if breakpoints is None else breakpoints
        self.lookups = []

    def FindBreakpointByID(self, breakpoint_id):
        self.lookups.append(breakpoint_id)
        return self.breakpoints.get(breakpoint_id, FakeBreakpoint(valid=False))

    def ResolveLoadAddress(self, pc):
        return types.SimpleNamespace(GetModule=lambda: FakeModule())


class FakeRegister:
    def IsValid(self):
        return True

    def GetValueAsUnsigned(self, error, default):
        return 1


class FakeFrame:
    def __init__(self, valid=False):
        self.valid = valid

    def IsValid(self):
        return self.valid

    def GetPC(self):
        return 0x100004000

    def FindRegister(self, name):
        return FakeRegister()


class FakeThread:
    next_id = 1

    def __init__(self, reason, description="", data=(), *, protocol=False):
        self.reason = reason
        self.description = description
        self.data = data
        self.frame = FakeFrame(valid=protocol)
        self.thread_id = FakeThread.next_id
        FakeThread.next_id += 1

    def IsValid(self):
        return True

    def GetThreadID(self):
        return self.thread_id

    def GetStopReason(self):
        return self.reason

    def GetStopDescription(self, length):
        return self.description

    def GetStopReasonDataCount(self):
        return len(self.data)

    def GetStopReasonDataAtIndex(self, index):
        return self.data[index]

    def GetFrameAtIndex(self, index):
        return self.frame


class FakeProcess:
    def __init__(self, *threads):
        self.threads = threads

    def GetSelectedThread(self):
        return self.threads[0]

    def GetNumThreads(self):
        return len(self.threads)

    def GetThreadAtIndex(self, index):
        return self.threads[index]

    def ReadUnsignedFromMemory(self, address, size, error):
        return jit.BRK_INSTRUCTION


UNSIGNED_MINUS_SIX = (1 << 64) - 6


def creation(*, reason=None, description="thread-creation", data=None):
    return FakeThread(
        fake_lldb.eStopReasonBreakpoint if reason is None else reason,
        description,
        (UNSIGNED_MINUS_SIX, 1) if data is None else data,
    )


def sigstop():
    return FakeThread(fake_lldb.eStopReasonSignal, "signal SIGSTOP", (signal.SIGSTOP,))


def user_breakpoint():
    return FakeThread(fake_lldb.eStopReasonBreakpoint, "breakpoint 7.1", (7, 1))


class ThreadCreationGuardTests(unittest.TestCase):
    def test_observed_unsigned_internal_id_resolves_to_negative_breakpoint(self):
        target = FakeTarget()
        self.assertTrue(jit._internal_thread_creation(target, creation()))
        self.assertEqual(target.lookups, [-6])

    def test_all_reported_locations_must_belong_to_valid_internal_breakpoints(self):
        target = FakeTarget({-6: FakeBreakpoint(locations=(1, 2)), -7: FakeBreakpoint()})
        self.assertTrue(jit._internal_thread_creation(
            target, creation(data=(UNSIGNED_MINUS_SIX, 2, (1 << 64) - 7, 1))
        ))

    def test_user_or_unresolvable_breakpoints_cannot_be_hidden_by_description(self):
        cases = {
            "positive user breakpoint": (FakeTarget({7: FakeBreakpoint()}), (7, 1)),
            "noninternal negative breakpoint": (
                FakeTarget({-6: FakeBreakpoint(internal=False)}), (UNSIGNED_MINUS_SIX, 1)
            ),
            "missing breakpoint": (FakeTarget({}), (UNSIGNED_MINUS_SIX, 1)),
            "invalid breakpoint": (
                FakeTarget({-6: FakeBreakpoint(valid=False)}), (UNSIGNED_MINUS_SIX, 1)
            ),
            "missing location": (FakeTarget(), (UNSIGNED_MINUS_SIX, 2)),
            "invalid location": (
                FakeTarget({-6: FakeBreakpoint(locations=())}), (UNSIGNED_MINUS_SIX, 1)
            ),
            "out of signed 32 bit range": (FakeTarget(), ((1 << 64) - (1 << 32), 1)),
        }
        for label, (target, data) in cases.items():
            with self.subTest(label=label):
                self.assertFalse(jit._internal_thread_creation(target, creation(data=data)))

    def test_description_and_reason_must_both_match(self):
        for thread in (
            creation(description="breakpoint -6.1"),
            creation(description="thread-creation extra"),
            creation(reason=fake_lldb.eStopReasonSignal),
            creation(reason=fake_lldb.eStopReasonException),
        ):
            with self.subTest(reason=thread.reason, description=thread.description):
                self.assertFalse(jit._internal_thread_creation(FakeTarget(), thread))

    def test_empty_odd_or_mixed_stop_data_is_not_an_internal_event(self):
        for data in ((), (UNSIGNED_MINUS_SIX,), (UNSIGNED_MINUS_SIX, 1, 7, 1)):
            with self.subTest(data=data):
                self.assertFalse(jit._internal_thread_creation(FakeTarget(), creation(data=data)))

    def test_initial_attach_accepts_sigstop_with_proven_internal_events(self):
        process = FakeProcess(sigstop(), creation(), FakeThread(fake_lldb.eStopReasonNone))
        self.assertTrue(jit._initial_attach_stop(FakeTarget(), process))

    def test_initial_attach_rejects_independent_user_stop(self):
        for thread in (
            user_breakpoint(),
            FakeThread(fake_lldb.eStopReasonSignal, "signal SIGTRAP", (signal.SIGTRAP,)),
            creation(data=(7, 1)),
        ):
            with self.subTest(reason=thread.reason, description=thread.description):
                self.assertFalse(jit._initial_attach_stop(FakeTarget(), FakeProcess(sigstop(), thread)))

    def test_only_internal_events_allows_idle_threads_but_requires_an_event(self):
        self.assertTrue(jit._only_internal_thread_creation(
            FakeTarget(), FakeProcess(creation(), FakeThread(fake_lldb.eStopReasonNone))
        ))
        self.assertFalse(jit._only_internal_thread_creation(
            FakeTarget(), FakeProcess(FakeThread(fake_lldb.eStopReasonNone))
        ))

    def test_subsequent_sigstop_or_user_breakpoint_is_never_auto_continued(self):
        for thread in (sigstop(), user_breakpoint(), creation(data=(7, 1))):
            with self.subTest(reason=thread.reason, description=thread.description):
                self.assertFalse(jit._only_internal_thread_creation(
                    FakeTarget(), FakeProcess(creation(), thread)
                ))

    def test_protocol_stop_can_coexist_with_proven_internal_events(self):
        protocol = FakeThread(fake_lldb.eStopReasonException, "EXC_BREAKPOINT", protocol=True)
        result = jit._protocol_stop(FakeTarget(), FakeModule(), FakeProcess(protocol, creation()))
        self.assertIs(result[0], protocol)
        self.assertEqual(result[3], 1)

    def test_protocol_stop_does_not_mask_an_independent_user_stop(self):
        protocol = FakeThread(fake_lldb.eStopReasonException, "EXC_BREAKPOINT", protocol=True)
        with self.assertRaisesRegex(jit.JITError, "independent stop"):
            jit._protocol_stop(
                FakeTarget(), FakeModule(), FakeProcess(protocol, creation(), user_breakpoint())
            )


class FakeExpressionOptions:
    def __init__(self):
        self.settings = {}

    def __getattr__(self, name):
        if name.startswith("Set"):
            return lambda value: self.settings.__setitem__(name, value)
        raise AttributeError(name)


class FakeExpressionValue:
    def __init__(self, number=0, *, valid=True, failed=False, parse_failed=False):
        self.number = number
        self.valid = valid
        self.failed = failed
        self.parse_failed = parse_failed

    def IsValid(self):
        return self.valid

    def GetError(self):
        return FakeError(self.failed)

    def GetValueAsSigned(self, error, default):
        error.failed = self.parse_failed
        return default if self.parse_failed else self.number


class MutableRegister:
    def __init__(self, number):
        self.number = number

    def IsValid(self):
        return True

    def GetValueAsUnsigned(self, error, default):
        return self.number

    def SetValueFromCString(self, value, error):
        self.number = int(value, 0)
        return True


class RetryFrame(FakeFrame):
    def __init__(self, values=(), *, command=0):
        super().__init__(valid=True)
        self.values = list(values)
        self.expressions = []
        self.on_expression = None
        self.registers = {
            "pc": MutableRegister(0x100004000),
            "x16": MutableRegister(command),
            "x0": MutableRegister(0x300000000),
            "x1": MutableRegister(jit.MIN_REGION_SIZE),
        }

    def GetPC(self):
        return self.registers["pc"].number

    def FindRegister(self, name):
        return self.registers[name]

    def EvaluateExpression(self, expression, options):
        self.expressions.append((expression, options.settings))
        if self.on_expression is not None:
            self.on_expression()
        if not self.values:
            raise AssertionError("Unexpected target expression")
        value = self.values.pop(0)
        return value if isinstance(value, FakeExpressionValue) else FakeExpressionValue(value)


class RetryThread(FakeThread):
    def __init__(self, frame, *, queue="com.apple.main-thread", index=1):
        super().__init__(fake_lldb.eStopReasonSignal, "signal SIGSTOP", (signal.SIGSTOP,))
        self.frame = frame
        self.queue = queue
        self.index = index

    def GetQueueName(self):
        return self.queue

    def GetIndexID(self):
        return self.index


class LifecycleProcess(FakeProcess):
    def __init__(self, *threads):
        super().__init__(*threads)
        self.selected = threads[0]
        self.state = fake_lldb.eStateStopped
        self.continues = 0
        self.detaches = []
        self.allocations = 0
        self.writes = 0

    def GetSelectedThread(self):
        return self.selected

    def SetSelectedThread(self, thread):
        self.selected = thread
        return True

    def GetProcessID(self):
        return 123

    def GetUniqueID(self):
        return 456

    def GetState(self):
        return self.state

    def Continue(self):
        self.continues += 1
        return FakeError()

    def Detach(self, keep_stopped):
        self.detaches.append(keep_stopped)
        self.state = fake_lldb.eStateDetached
        return FakeError()

    def AllocateMemory(self, size, permissions, error):
        self.allocations += 1
        raise AssertionError("Unexpected RX allocation")

    def WriteMemory(self, address, data, error):
        self.writes += 1
        return len(data)


class FakeDebugger:
    def __init__(self):
        self.asynchronous = True

    def GetAsync(self):
        return self.asynchronous

    def SetAsync(self, value):
        self.asynchronous = value


class FakeResult:
    def __init__(self):
        self.messages = []
        self.error = None

    def AppendMessage(self, message):
        self.messages.append(message)

    def SetError(self, message):
        self.error = message


class RetryLifecycleTests(unittest.TestCase):
    def run_command(self, values=(), *, command="--retry --timeout 5", initial_stop=None,
                    unknown_stop=False, queue="com.apple.main-thread", index=1, on_expression=None):
        frame = RetryFrame(values)
        thread = RetryThread(frame, queue=queue, index=index)
        if unknown_stop:
            thread.reason = fake_lldb.eStopReasonBreakpoint
            thread.description = "breakpoint 7.1"
            thread.data = (7, 1)
        process = LifecycleProcess(thread)
        if on_expression is not None:
            frame.on_expression = lambda: on_expression(process, thread)
        target = FakeTarget()
        terminal = (thread, frame, frame.GetPC(), 0)
        stops = [initial_stop, terminal]
        debugger = FakeDebugger()
        result = FakeResult()
        with mock.patch.object(jit, "_context", return_value=(target, FakeModule(), process)), \
                mock.patch.object(jit, "_protocol_stop", side_effect=stops), \
                mock.patch.object(jit, "_emit"), \
                mock.patch.object(jit, "_check_rx_region"), \
                mock.patch.object(fake_lldb, "SBExpressionOptions", FakeExpressionOptions, create=True):
            jit.linpad_jit(debugger, command, result, {})
        self.assertTrue(debugger.asynchronous, "The original async setting must be restored")
        return frame, process, result

    def test_idle_and_failed_request_retry_once_then_service_protocol(self):
        for state in (0, 3):
            with self.subTest(state=state):
                frame, process, result = self.run_command((state, 1))
                self.assertIsNone(result.error)
                self.assertEqual(len(frame.expressions), 2)
                self.assertEqual(sum("[appClass retryFastMode]" in expression
                                     for expression, _ in frame.expressions), 1)
                self.assertFalse(any("[appClass jitStatus]" in expression
                                     for expression, _ in frame.expressions))
                self.assertEqual(process.continues, 1)
                self.assertEqual(process.detaches, [False])

    def test_already_on_verifies_core_and_detaches_without_wait_or_allocation(self):
        frame, process, result = self.run_command((2, 1))
        self.assertIsNone(result.error)
        self.assertIn("[appClass jitStatus]", frame.expressions[1][0])
        self.assertFalse(any("[appClass retryFastMode]" in expression
                             for expression, _ in frame.expressions))
        self.assertEqual(process.continues, 0)
        self.assertEqual(process.allocations, 0)
        self.assertEqual(process.detaches, [False])
        self.assertIn("already On", result.messages[-1])

    def test_already_on_with_disabled_or_missing_core_stays_attached(self):
        for core in (0, -1):
            with self.subTest(core=core):
                frame, process, result = self.run_command((2, core))
                self.assertIn("core is not On", result.error)
                self.assertEqual(process.continues, 0)
                self.assertEqual(process.detaches, [])
                self.assertEqual(process.state, fake_lldb.eStateStopped)
                self.assertEqual(frame.GetPC(), 0x100004000)

    def test_expression_that_leaves_an_exception_never_enters_txm_handling(self):
        def unexpected_stop(process, thread):
            thread.reason = fake_lldb.eStopReasonException
            thread.description = "EXC_BREAKPOINT"
            # Even a BRK-looking PC must not be consumed after an expression.

        frame, process, result = self.run_command((0,), on_expression=unexpected_stop)
        self.assertIn("Retry expression left an unexpected stop", result.error)
        self.assertEqual(len(frame.expressions), 1)
        self.assertEqual(process.continues, 0)
        self.assertEqual(process.detaches, [])
        self.assertEqual(process.writes, 0)
        self.assertEqual(frame.GetPC(), 0x100004000)

    def test_total_deadline_after_expression_preserves_stop_without_retry(self):
        with mock.patch.object(jit.time, "monotonic", side_effect=(0, 0, 5)):
            frame, process, result = self.run_command((0,))
        self.assertIn("Timed out after 5 seconds", result.error)
        self.assertEqual(len(frame.expressions), 1)
        self.assertEqual(process.detaches, [])
        self.assertEqual(process.continues, 0)
        self.assertEqual(frame.GetPC(), 0x100004000)

    def test_enabling_only_reads_state_and_services_in_flight_request(self):
        frame, process, result = self.run_command((1,))
        self.assertIsNone(result.error)
        self.assertEqual(len(frame.expressions), 1)
        self.assertEqual(process.continues, 1)
        self.assertEqual(process.detaches, [False])

    def test_txm_cmd_zero_and_one_never_execute_expressions_or_retry(self):
        for command in (0, 1):
            with self.subTest(command=command):
                protocol_frame = RetryFrame(command=command)
                protocol_thread = RetryThread(protocol_frame)
                stop = (protocol_thread, protocol_frame, protocol_frame.GetPC(), command)
                frame, process, result = self.run_command(initial_stop=stop)
                self.assertIsNone(result.error)
                self.assertEqual(frame.expressions, [])
                self.assertEqual(protocol_frame.expressions, [])
                self.assertEqual(process.detaches, [False])
                self.assertEqual(process.writes, jit.MIN_REGION_SIZE // jit.PAGE_SIZE if command else 0)

    def test_expression_failure_or_unparseable_result_preserves_stopped_session(self):
        for value in (FakeExpressionValue(failed=True), FakeExpressionValue(valid=False),
                      FakeExpressionValue(parse_failed=True)):
            with self.subTest(value=value.__dict__):
                frame, process, result = self.run_command((value,))
                self.assertIsNotNone(result.error)
                self.assertIn("stopped and attached", result.error)
                self.assertEqual(len(frame.expressions), 1)
                self.assertEqual(process.continues, 0)
                self.assertEqual(process.detaches, [])
                self.assertEqual(process.state, fake_lldb.eStateStopped)

    def test_unknown_initial_stop_is_rejected_before_any_expression(self):
        frame, process, result = self.run_command(unknown_stop=True)
        self.assertIn("Initial stop is not", result.error)
        self.assertEqual(frame.expressions, [])
        self.assertEqual(process.continues, 0)
        self.assertEqual(process.detaches, [])

    def test_main_thread_runtime_check_class_selectors_and_state_fail_closed(self):
        for value, fragment in ((-10, "not the main thread"), (-11, "class is unavailable"),
                                (-12, "selectors are unavailable"), (-13, "changed unexpectedly"),
                                (4, "Unknown fast-mode state")):
            with self.subTest(value=value):
                frame, process, result = self.run_command((value,))
                self.assertIn(fragment, result.error)
                self.assertEqual(len(frame.expressions), 1)
                self.assertEqual(process.detaches, [])
                self.assertEqual(process.continues, 0)

    def test_missing_main_thread_candidate_refuses_without_expression(self):
        frame, process, result = self.run_command(queue="worker", index=2)
        self.assertIn("main-thread candidate", result.error)
        self.assertEqual(frame.expressions, [])
        self.assertEqual(process.detaches, [])

    def test_index_one_is_only_candidate_and_still_gets_runtime_verification(self):
        frame, process, result = self.run_command((-10,), queue=None, index=1)
        self.assertIn("not the main thread", result.error)
        self.assertIn("[threadClass isMainThread]", frame.expressions[0][0])
        self.assertEqual(process.detaches, [])

    def test_expression_settings_are_bounded_single_thread_and_keep_breakpoints(self):
        frame, _, result = self.run_command((2, 1))
        self.assertIsNone(result.error)
        for expression, settings in frame.expressions:
            self.assertEqual(settings, {
                "SetLanguage": fake_lldb.eLanguageTypeObjC_plus_plus,
                "SetTimeoutInMicroSeconds": jit.EXPRESSION_TIMEOUT_US,
                "SetOneThreadTimeoutInMicroSeconds": jit.EXPRESSION_TIMEOUT_US,
                "SetTryAllThreads": False,
                "SetStopOthers": True,
                "SetIgnoreBreakpoints": False,
                "SetUnwindOnError": True,
            })
            self.assertNotIn("^", expression, "No LLDB-compiled block may escape")
            self.assertLess(expression.index("respondsToSelector"), expression.index("(long)[appClass"))

    def test_manual_mode_keeps_the_expression_free_workflow(self):
        frame, process, result = self.run_command(command="--timeout 5")
        self.assertIsNone(result.error)
        self.assertEqual(frame.expressions, [])
        self.assertEqual(process.continues, 1)
        self.assertEqual(process.detaches, [False])


if __name__ == "__main__":
    unittest.main()
