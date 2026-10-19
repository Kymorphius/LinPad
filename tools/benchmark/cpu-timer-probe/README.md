# CPU timer capability probe

Build a standalone Linux/ARM64 child with the same Go toolchain as the workload:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=v8.0 \
  go build -trimpath -buildvcs=false -o /tmp/cpu-timer-probe \
  tools/benchmark/cpu-timer-probe/main.go
```

Transfer it to an owned private guest temporary directory, verify its SHA-256,
run it with an external timeout, and remove only that file and the empty owned
directory afterwards. The JSON records syscall errno values; zero means success.
A successful monotonic timer is a control for the CPU timer probes.

The probe never arms a timer or sends a signal. It disables ITIMER_PROF only in
its own child process, attempts SIGEV_NONE timers for CLOCK_MONOTONIC,
CLOCK_PROCESS_CPUTIME_ID, and CLOCK_THREAD_CPUTIME_ID, and immediately deletes
each successfully created timer. Failed cleanup makes the process exit nonzero.

This tests kernel capability, not CPU performance. A Go CPU profile can be empty
when both CPU timer mechanisms are unsupported, even if StartCPUProfile returns
success. Do not interpret that empty profile as an absence of CPU work. Manually
sending signals is not a replacement for unbiased periodic CPU sampling.
