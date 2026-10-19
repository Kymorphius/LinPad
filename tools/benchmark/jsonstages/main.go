// jsonstages separates the JSON/gzip pipeline in ../bench.go without external
// dependencies. Build this file directly with the same Go toolchain and target
// flags on both systems. It never reads files, starts subprocesses, or connects
// to a network. Its only output is JSONL on stdout and bounded errors on stderr.
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"hash/crc32"
	"hash/crc64"
	"io"
	"os"
	"runtime"
	"runtime/debug"
	"slices"
	"time"
)

const (
	fixtureSHA256 = "064b2c6387ef9f667a7ec90c0a76810720571906a80f26d3c3853439ff434655"
	fixtureBytes  = 15678
	fixtureCRC32  = uint32(0x5ed2d536)
	maxIterations = 1 << 24
	maxCalibrates = 12
)

var caseNames = []string{
	"decode_fresh", "encode", "gzip_compress_reuse", "gzip_decompress_fresh",
	"roundtrip", "crc32_ieee",
}

var crc64Table = crc64.MakeTable(crc64.ECMA)

// The fixture and record field order match ../bench.go exactly.
type fixtureRecord struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Payload string `json:"payload"`
}

type fixtureData struct {
	input      []byte
	records    []fixtureRecord
	compressed []byte
}

func fixture() (*fixtureData, error) {
	records := make([]fixtureRecord, 128)
	for i := range records {
		records[i] = fixtureRecord{
			ID: i, Name: fmt.Sprintf("record-%03d", i), Enabled: i%3 != 0,
			Payload: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		}
	}
	input, err := json.Marshal(records)
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256(input)
	if len(input) != fixtureBytes || hex.EncodeToString(hash[:]) != fixtureSHA256 || crc32.ChecksumIEEE(input) != fixtureCRC32 {
		return nil, fmt.Errorf("fixture differs from the original benchmark")
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed) // gzip.DefaultCompression, as in bench.go.
	if _, err := writer.Write(input); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return &fixtureData{input: input, records: records, compressed: compressed.Bytes()}, nil
}

type options struct {
	duration time.Duration
	count    int
	selected string
	selftest bool
	maxWall  time.Duration
}

func parseOptions(args []string) (options, error) {
	var o options
	f := flag.NewFlagSet("jsonstages", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	f.DurationVar(&o.duration, "duration", 300*time.Millisecond, "per-repetition calibration target: 100ms through 1s")
	f.IntVar(&o.count, "count", 3, "measured repetitions per case: 1 through 5")
	f.StringVar(&o.selected, "case", "all", "all, decode_fresh, encode, gzip_compress_reuse, gzip_decompress_fresh, roundtrip, or crc32_ieee")
	f.BoolVar(&o.selftest, "selftest", false, "validate every case without benchmark results")
	f.DurationVar(&o.maxWall, "max-wall", 120*time.Second, "process watchdog: 5s through 5m; exits 124 if exceeded")
	if err := f.Parse(args); err != nil {
		return o, err
	}
	if f.NArg() != 0 {
		return o, fmt.Errorf("unexpected positional arguments")
	}
	if o.duration < 100*time.Millisecond || o.duration > time.Second {
		return o, fmt.Errorf("duration must be 100ms through 1s")
	}
	if o.count < 1 || o.count > 5 {
		return o, fmt.Errorf("count must be 1 through 5")
	}
	if o.maxWall < 5*time.Second || o.maxWall > 5*time.Minute {
		return o, fmt.Errorf("max-wall must be 5s through 5m")
	}
	if o.selected != "all" && !slices.Contains(caseNames, o.selected) {
		return o, fmt.Errorf("unknown case %q", o.selected)
	}
	return o, nil
}

type runner struct {
	name       string
	fixture    *fixtureData
	compressed bytes.Buffer
	writer     *gzip.Writer
	last       []byte
	records    []fixtureRecord
	crc        uint32
	checksum   uint64
	err        error
}

func newRunner(name string, data *fixtureData) (*runner, error) {
	if !slices.Contains(caseNames, name) {
		return nil, fmt.Errorf("unknown case %q", name)
	}
	r := &runner{name: name, fixture: data}
	if name == "gzip_compress_reuse" || name == "roundtrip" {
		r.compressed.Grow(len(data.input))
		r.writer = gzip.NewWriter(&r.compressed)
	}
	// This also allocates the compressor's lazy working storage before timing.
	r.work(1)
	if _, err := r.validate(1); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *runner) compress(input []byte) error {
	r.compressed.Reset()
	r.writer.Reset(&r.compressed)
	if _, err := r.writer.Write(input); err != nil {
		return err
	}
	return r.writer.Close()
}

func (r *runner) decompress(input []byte) error {
	reader, err := gzip.NewReader(bytes.NewReader(input))
	if err != nil {
		return err
	}
	r.last, err = io.ReadAll(reader)
	closeErr := reader.Close()
	if err != nil {
		return err
	}
	return closeErr
}

// roundtripOperation is the original jsonWorker.operation hot pipeline. It
// intentionally retains fresh JSON decoding/encoding and fresh gzip reading,
// while reusing only the compressor and its output buffer.
func (r *runner) roundtripOperation() error {
	var records []fixtureRecord
	if err := json.Unmarshal(r.fixture.input, &records); err != nil {
		return err
	}
	encoded, err := json.Marshal(records)
	if err != nil {
		return err
	}
	if err := r.compress(encoded); err != nil {
		return err
	}
	return r.decompress(r.compressed.Bytes())
}

// A single worker runs on the calling goroutine. There is no goroutine/channel
// setup inside the timed loop and no extra checksum traversal over the payload.
// The output-length checksum is accumulated per operation, as in bench.go;
// complete output validation and the diagnostic CRC64 happen after timing.
func (r *runner) work(iterations int) {
	r.checksum, r.err = 0, nil
	switch r.name {
	case "decode_fresh":
		for i := 0; i < iterations; i++ {
			var records []fixtureRecord
			if r.err = json.Unmarshal(r.fixture.input, &records); r.err != nil {
				return
			}
			r.records = records
			r.checksum += uint64(len(records))
		}
	case "encode":
		for i := 0; i < iterations; i++ {
			r.last, r.err = json.Marshal(r.fixture.records)
			if r.err != nil {
				return
			}
			r.checksum += uint64(len(r.last))
		}
	case "gzip_compress_reuse":
		for i := 0; i < iterations; i++ {
			if r.err = r.compress(r.fixture.input); r.err != nil {
				return
			}
			r.checksum += uint64(r.compressed.Len())
		}
	case "gzip_decompress_fresh":
		for i := 0; i < iterations; i++ {
			if r.err = r.decompress(r.fixture.compressed); r.err != nil {
				return
			}
			r.checksum += uint64(len(r.last))
		}
	case "roundtrip":
		for i := 0; i < iterations; i++ {
			if r.err = r.roundtripOperation(); r.err != nil {
				return
			}
			r.checksum += uint64(len(r.last))
		}
	case "crc32_ieee":
		for i := 0; i < iterations; i++ {
			r.crc = crc32.ChecksumIEEE(r.fixture.input)
			r.checksum += uint64(r.crc)
		}
	}
}

func (r *runner) validate(iterations int) (string, error) {
	if r.err != nil {
		return "", r.err
	}
	var output []byte
	expected := uint64(len(r.fixture.input))
	switch r.name {
	case "decode_fresh":
		expected = uint64(len(r.fixture.records))
		if !slices.Equal(r.records, r.fixture.records) {
			return "", fmt.Errorf("decode_fresh record validation failed")
		}
		var err error
		output, err = json.Marshal(r.records)
		if err != nil {
			return "", err
		}
	case "gzip_compress_reuse":
		expected = uint64(len(r.fixture.compressed))
		output = r.compressed.Bytes()
		if !bytes.Equal(output, r.fixture.compressed) {
			return "", fmt.Errorf("gzip_compress_reuse output validation failed")
		}
	case "crc32_ieee":
		expected = uint64(fixtureCRC32)
		if r.crc != fixtureCRC32 {
			return "", fmt.Errorf("crc32_ieee known vector failed")
		}
		// Hash the verified input outside timing for a comparable diagnostic.
		output = r.fixture.input
	default:
		output = r.last
	}
	if r.name != "gzip_compress_reuse" && !bytes.Equal(output, r.fixture.input) {
		return "", fmt.Errorf("%s complete output validation failed", r.name)
	}
	if r.checksum != uint64(iterations)*expected {
		return "", fmt.Errorf("%s accumulated checksum mismatch", r.name)
	}
	hash := fmt.Sprintf("%016x", crc64.Checksum(output, crc64Table))
	runtime.KeepAlive(r)
	return hash, nil
}

type memoryDelta struct {
	TotalAllocBytes uint64  `json:"total_alloc_bytes"`
	Mallocs         uint64  `json:"mallocs"`
	Frees           uint64  `json:"frees"`
	GCCount         uint32  `json:"gc_count"`
	GCPauseNS       uint64  `json:"gc_pause_ns"`
	AllocatedPerOp  float64 `json:"allocated_bytes_per_op"`
	AllocsPerOp     float64 `json:"allocs_per_op"`
	FreesPerOp      float64 `json:"frees_per_op"`
	PausePerOp      float64 `json:"gc_pause_ns_per_op"`
}

func memDelta(before, after runtime.MemStats, iterations int) memoryDelta {
	n := float64(iterations)
	d := memoryDelta{
		TotalAllocBytes: after.TotalAlloc - before.TotalAlloc,
		Mallocs:         after.Mallocs - before.Mallocs, Frees: after.Frees - before.Frees,
		GCCount: after.NumGC - before.NumGC, GCPauseNS: after.PauseTotalNs - before.PauseTotalNs,
	}
	d.AllocatedPerOp = float64(d.TotalAllocBytes) / n
	d.AllocsPerOp = float64(d.Mallocs) / n
	d.FreesPerOp = float64(d.Frees) / n
	d.PausePerOp = float64(d.GCPauseNS) / n
	return d
}

type measurement struct {
	elapsed time.Duration
	memory  memoryDelta
	crc64   string
}

func (r *runner) measure(iterations int, collectMemory bool) (measurement, error) {
	if iterations < 1 || iterations > maxIterations {
		return measurement{}, fmt.Errorf("iteration count outside 1 through 2^24")
	}
	var before, after runtime.MemStats
	if collectMemory {
		runtime.ReadMemStats(&before)
	}
	start := time.Now() // Go retains its monotonic component for time.Since.
	r.work(iterations)
	elapsed := time.Since(start)
	if collectMemory {
		runtime.ReadMemStats(&after)
	}
	crc, err := r.validate(iterations)
	if err != nil {
		return measurement{}, err
	}
	m := measurement{elapsed: elapsed, crc64: crc}
	if collectMemory {
		m.memory = memDelta(before, after, iterations)
	}
	return m, nil
}

// Calibration is excluded. Growth is <=4x, starts at one operation, and stops
// after at most twelve measurements or 2^24 operations. The target is not a
// hard deadline for an individual operation; a separate watchdog bounds process
// lifetime even if the host or guest becomes severely contended.
func (r *runner) calibrate(target time.Duration) (int, time.Duration, int, error) {
	iterations := 1
	for step := 1; step <= maxCalibrates; step++ {
		m, err := r.measure(iterations, false)
		if err != nil {
			return 0, 0, step, err
		}
		if m.elapsed >= target*95/100 || iterations == maxIterations || step == maxCalibrates {
			return iterations, m.elapsed, step, nil
		}
		next := int(float64(iterations) * float64(target) / float64(max(m.elapsed, 1)))
		next = min(next, iterations*4, maxIterations)
		iterations = max(next, iterations+1)
	}
	return 0, 0, maxCalibrates, fmt.Errorf("unreachable calibration state")
}

func selftest(data *fixtureData) error {
	for _, name := range caseNames {
		r, err := newRunner(name, data)
		if err != nil {
			return err
		}
		r.work(2)
		if _, err := r.validate(2); err != nil {
			return err
		}
	}
	return nil
}

func targetSettings() map[string]string {
	settings := make(map[string]string)
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			switch setting.Key {
			case "-buildmode", "-compiler", "CGO_ENABLED", "GOOS", "GOARCH", "GOARM64":
				settings[setting.Key] = setting.Value
			}
		}
	}
	return settings
}

type result struct {
	Type           string  `json:"type"`
	Case           string  `json:"case"`
	Workers        int     `json:"workers"`
	GOMAXPROCS     int     `json:"gomaxprocs"`
	Repetition     int     `json:"repetition"`
	Iterations     int     `json:"iterations"`
	ElapsedNS      int64   `json:"elapsed_ns"`
	NSPerOp        float64 `json:"ns_per_op"`
	BytesPerOp     int     `json:"bytes_per_op"`
	BytesPerSec    float64 `json:"bytes_per_sec"`
	Checksum       string  `json:"checksum"`
	OutputCRC64    string  `json:"output_crc64_ecma"`
	ChecksumOK     bool    `json:"checksum_ok"`
	WarmupExcluded bool    `json:"warmup_excluded"`
	memoryDelta
}

func run(args []string, out io.Writer) error {
	o, err := parseOptions(args)
	if err != nil {
		return err
	}
	// No GC flags or GOGC environment are changed. This watchdog is armed
	// before fixture preparation and never runs during a successful short test.
	watchdog := time.AfterFunc(o.maxWall, func() {
		fmt.Fprintln(os.Stderr, "jsonstages: process watchdog expired")
		os.Exit(124)
	})
	defer watchdog.Stop()
	previousProcs := runtime.GOMAXPROCS(1)
	defer runtime.GOMAXPROCS(previousProcs)
	data, err := fixture()
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(out)
	if o.selftest {
		if err := selftest(data); err != nil {
			return err
		}
		return encoder.Encode(map[string]any{
			"type": "selftest", "checksum_ok": true, "cases": len(caseNames),
			"fixture_sha256": fixtureSHA256, "fixture_bytes": len(data.input),
			"fixture_crc32_ieee": fmt.Sprintf("%08x", fixtureCRC32),
		})
	}
	chosen := caseNames
	if o.selected != "all" {
		chosen = []string{o.selected}
	}
	if err := encoder.Encode(map[string]any{
		"type": "metadata", "schema": 1, "compiler": runtime.Version(),
		"goos": runtime.GOOS, "goarch": runtime.GOARCH, "num_cpu": runtime.NumCPU(),
		"target_settings": targetSettings(), "gomaxprocs": 1, "workers": 1,
		"fixture_sha256": fixtureSHA256, "fixture_bytes": len(data.input),
		"fixture_crc32_ieee": fmt.Sprintf("%08x", fixtureCRC32), "compressed_bytes": len(data.compressed),
		"target_ns": o.duration.Nanoseconds(), "count": o.count, "cases": chosen,
		"max_wall_ns":      o.maxWall.Nanoseconds(),
		"calibration":      "monotonic wall clock; start 1; growth <=4x; <=12 steps; iterations <=2^24; excluded",
		"warmup":           "fresh prepared runner per repetition; max(1, calibrated iterations/10) warmup operations; excluded",
		"gc":               "one forced GC before each case; inherited Go runtime GC policy unchanged; GC during the hot loop is timed; no per-repetition forced GC",
		"inherited_gc_env": map[string]string{"GOGC": os.Getenv("GOGC"), "GOMEMLIMIT": os.Getenv("GOMEMLIMIT")},
		"memory_stats":     "process-global ReadMemStats before/after timed loop, outside wall timer; diagnostic deltas, not sole GC causality; may perturb caches",
		"validation":       "per-operation length checksum (CRC32 value for crc32_ieee); complete final output and CRC64 outside timing",
		"bytes_per_op":     "logical uncompressed fixture bytes for every case, not allocation or compressed size",
		"gzip":             "default compression; reused Writer and output Buffer for compression; fresh NewReader and ReadAll for decompression",
		"roundtrip":        "same hot pipeline as ../bench.go json_gzip1; stage totals need not sum because allocation, reuse, GC, and loop boundaries differ",
	}); err != nil {
		return err
	}
	for _, name := range chosen {
		// The previous runner is out of scope. Collection between cases avoids
		// retaining the preceding compressor, without forcing GC per repeat.
		runtime.GC()
		calibration, err := newRunner(name, data)
		if err != nil {
			return err
		}
		iterations, elapsed, steps, err := calibration.calibrate(o.duration)
		if err != nil {
			return err
		}
		if err := encoder.Encode(map[string]any{
			"type": "calibration", "case": name, "iterations": iterations,
			"steps": steps, "elapsed_ns": elapsed.Nanoseconds(), "excluded": true,
		}); err != nil {
			return err
		}
		calibration = nil
		for repetition := 1; repetition <= o.count; repetition++ {
			r, err := newRunner(name, data)
			if err != nil {
				return err
			}
			if _, err := r.measure(max(1, iterations/10), false); err != nil {
				return err
			}
			m, err := r.measure(iterations, true)
			if err != nil {
				return err
			}
			row := result{
				Type: "result", Case: name, Workers: 1, GOMAXPROCS: 1, Repetition: repetition,
				Iterations: iterations, ElapsedNS: m.elapsed.Nanoseconds(),
				NSPerOp:    float64(m.elapsed.Nanoseconds()) / float64(iterations),
				BytesPerOp: len(data.input), BytesPerSec: float64(len(data.input)) * float64(iterations) / m.elapsed.Seconds(),
				Checksum: fmt.Sprintf("%016x", r.checksum), OutputCRC64: m.crc64,
				ChecksumOK: true, WarmupExcluded: true, memoryDelta: m.memory,
			}
			if err := encoder.Encode(row); err != nil {
				return err
			}
		}
	}
	return nil
}

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "jsonstages:", err)
		os.Exit(1)
	}
}
