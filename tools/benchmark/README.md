# Same-source LinPad / macOS benchmark

`bench.go` is a standalone, standard-library-only Go program. Build the same
source with the same installed Go compiler for `darwin/arm64` and `linux/arm64`.
It does not install packages, access user files, or change LinPad settings.

```sh
CGO_ENABLED=0 GOARCH=arm64 GOARM64=v8.0 GOOS=darwin \
  go build -trimpath -buildvcs=false -o /tmp/linpad-bench-mac tools/benchmark/bench.go
CGO_ENABLED=0 GOARCH=arm64 GOARM64=v8.0 GOOS=linux \
  go build -trimpath -buildvcs=false -o /tmp/linpad-bench-linux tools/benchmark/bench.go
/tmp/linpad-bench-mac -selftest
/tmp/linpad-bench-mac -duration 500ms -count 3
```

Transfer the Linux binary to an owned, private guest temporary directory, verify
its SHA-256, and run the same flags using `tools/ipad_ssh.sh`. Keep the app in the
foreground. Run the two machines sequentially, with no compiler or other heavy
workload deliberately running alongside the measured process. Preserve existing
user sessions. Remove only the owned guest binary and temporary directory after
the run. A shell `timeout` around the guest process is recommended: calibration
is bounded, but the requested duration is a target rather than a hard deadline.

The program emits JSON Lines metadata, excluded calibration records, and one
result per measured repetition. `-case integer1` selects one exact case; the
metadata lists all supported case names. Durations must be 100 ms through 2 s,
and repeat counts must be 1 through 5.

| Case | Work per reported operation | Workers / GOMAXPROCS |
| --- | --- | --- |
| `integer1` | One dependent uint64 mix, 4096 rounds | 1 |
| `integer4` | Four independent copies of that mix | 4 |
| `float1` | One float64 arithmetic kernel, 4096 rounds | 1 |
| `json_gzip1` | Parse, encode, gzip, decompress fixed JSON input | 1 |
| `memcpy1` | Copy 16 MiB, with 32 MiB source/destination payload | 1 |
| `memcpy4` | Copy 4 × 8 MiB, with 64 MiB aggregate payload | 4 |

Preparation, calibration, warmup and complete result validation are excluded
from measured wall time. Every repetition has its own warmup. The integer and
float kernels cannot be inlined, and outputs are consumed and checked. The copy
destination is checked byte-for-byte outside timing. Goroutine unblock/wait
overhead remains included. JSON/gzip includes allocations and any resulting GC;
its byte throughput is logical input bytes, not compressed output bytes.

Compare the same case using the median of three repetitions. Throughput ratio
is `LinPad / Mac`; equivalently, use `Mac ns_per_op / LinPad ns_per_op`. For
integer worker scaling, account for four kernels per `integer4` operation:
`4 * integer1_ns_per_op / integer4_ns_per_op`. The copy cases also change total
working-set size, so their difference is not pure parallel scaling or peak DRAM
bandwidth. Do not combine these unrelated cases into a single score.

This measures these Go workloads on these two running systems. OS scheduling,
Go runtime/assembly paths, LinPad's execution layer, JIT warmup, temperature and
background activity all contribute. It does not isolate the device CPU's native
potential. Use wall time: LinPad's guest process CPU-time clock has a known
current-thread accounting boundary in `kernel/time.c`.

Keep raw output, binaries, and environment notes in an ignored run directory
such as `release/out/benchmark-<UTC timestamp>/`.
