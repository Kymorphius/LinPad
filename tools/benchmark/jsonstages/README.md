# JSON and gzip stage benchmark

This standalone Go program separates the composite `json_gzip1` workload in
`../bench.go`. It uses the identical 15,678-byte synthetic fixture and no
external dependencies, user files, or network access.

```sh
go test tools/benchmark/jsonstages/main.go tools/benchmark/jsonstages/main_test.go
python3 tools/benchmark/test_json_stage_runner.py
python3 tools/benchmark/run-json-stages.py \
  --output release/out/json-stages-new-run --transport usb
```

The output directory must be empty. The host runner builds `darwin/arm64` and
`linux/arm64` with the same installed Go compiler, `GOARM64=v8.0`, `CGO_ENABLED=0`,
`-trimpath`, and `-buildvcs=false`. It verifies the transferred Linux binary's
SHA-256, checks both self-tests, then measures Linux → Mac → Mac → Linux.
Builds and host-load snapshots are outside the measured intervals. Each phase
uses three repetitions with a 300 ms calibration target. Both measured
processes use `GOGC=100`, `GOMEMLIMIT=off`, and an empty `GODEBUG`; these settings
are process-local. No user process or application setting is changed.

The guest program is placed in a new private temporary directory, bounded by
an external 90-second timeout, and removed after the run. Cleanup removes only
the owned binary and uses `rmdir`, which refuses unexpected additional files.
The program also has its own 120-second watchdog. Do not run another benchmark
or full app build alongside a measurement. Keep LinPad in the foreground and
coordinate application updates or debugger maintenance separately.

| Case | Timed operation |
| --- | --- |
| `decode_fresh` | Unmarshal into a fresh nil record slice |
| `encode` | Marshal prepared records into a fresh output |
| `gzip_compress_reuse` | Reset the warmed Writer/buffer, write the fixture once, then Close |
| `gzip_decompress_fresh` | NewReader, ReadAll to EOF, then Close on a prepared gzip member |
| `roundtrip` | The original decode → encode → compress → decompress hot pipeline |
| `crc32_ieee` | ChecksumIEEE on the uncompressed fixture |

All cases run one worker with `GOMAXPROCS=1`. Each repetition uses an independently
prepared runner and excluded warmup. Calibration is monotonic-wall-clock based,
with at most 12 steps, fourfold growth, and `2^24` operations. The original
roundtrip pipeline is retained, but this harness's runner, warmup, and timer
boundaries differ from `bench.go`; compare platforms within this experiment.

Every operation contributes an observable length/CRC checksum. Complete final
output validation and a diagnostic CRC64 happen outside timing. The host
validator requires all six cases × three distinct repetitions, six matching
calibrations, target/compiler/build/GC settings, iteration consistency, and
finite timing and memory metrics. Raw output is retained in the ignored run
directory, along with load snapshots, binaries, and environment metadata.

`ReadMemStats` brackets the timed work but executes outside its wall-clock
interval. Allocation counts and bytes, completed GC counts, and pause deltas
are process-global diagnostic snapshots. A GC can straddle the boundaries;
pause time excludes concurrent marking, assists, and write-barrier costs.
One forced GC occurs before each case, with no per-repetition forced GC.

Independent stage medians are not additive shares of the roundtrip. Heap,
allocator, cache, pool, and reuse state differ between cases. Do not interpret
the difference between their sum and the roundtrip as execution-layer overhead.
An allocation-free compression result can test whether allocation alone explains
the slowdown, but it cannot establish a specific JIT cause.
