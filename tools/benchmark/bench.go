// bench is a same-source CPU, data-processing, and memory-copy comparison.
// Build this file directly; it has no external dependencies or Go module.
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"math/bits"
	"os"
	"runtime"
	"sync"
	"time"
)

const (
	integerRounds = 4096
	floatRounds   = 4096
	maxIterations = 1 << 26
	maxCalibrates = 12
)

var integerVectors = [...]uint64{
	0xa3180bf8f2684057, 0x4614aa8621595cc8,
	0x187d4764d250a372, 0xcb3609e9e6d18774,
}

// These calls deliberately remain observable and cannot be inlined or folded
// into the loop's expected checksum. Each operation does 4096 serial rounds.
//
//go:noinline
func integerKernel(seed uint64) uint64 {
	x := seed
	for i := 0; i < integerRounds; i++ {
		x ^= bits.RotateLeft64(x, 13)
		x *= 0x9e3779b185ebca87
		x += 0xd1b54a32d192ed03
		x ^= x >> 29
	}
	return x
}

//go:noinline
func floatKernel() float64 {
	x, y, z := 0.25, 0.75, 1.25
	for i := 0; i < floatRounds; i++ {
		x = x*0.99991 + y*0.00009
		y = y*0.99989 + z*0.00011
		z = z*0.99987 + x*0.00013
	}
	return x + y + z
}

type fixtureRecord struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Payload string `json:"payload"`
}

func fixture() ([]byte, error) {
	records := make([]fixtureRecord, 128)
	for i := range records {
		records[i] = fixtureRecord{
			ID: i, Name: fmt.Sprintf("record-%03d", i), Enabled: i%3 != 0,
			Payload: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		}
	}
	return json.Marshal(records)
}

// JSON parsing/encoding and gzip compression/decompression are all timed.
// Buffers and the compressor's working storage are allocated before timing.
type jsonWorker struct {
	input      []byte
	compressed bytes.Buffer
	writer     *gzip.Writer
	last       []byte
}

func newJSONWorker(input []byte) *jsonWorker {
	w := &jsonWorker{input: input}
	w.compressed.Grow(len(input))
	w.writer = gzip.NewWriter(&w.compressed)
	return w
}

func (w *jsonWorker) operation() error {
	var records []fixtureRecord
	if err := json.Unmarshal(w.input, &records); err != nil {
		return err
	}
	encoded, err := json.Marshal(records)
	if err != nil {
		return err
	}
	w.compressed.Reset()
	w.writer.Reset(&w.compressed)
	if _, err := w.writer.Write(encoded); err != nil {
		return err
	}
	if err := w.writer.Close(); err != nil {
		return err
	}
	reader, err := gzip.NewReader(bytes.NewReader(w.compressed.Bytes()))
	if err != nil {
		return err
	}
	w.last, err = io.ReadAll(reader)
	closeErr := reader.Close()
	if err != nil {
		return err
	}
	return closeErr
}

type worker struct {
	seed     uint64
	expected uint64
	checksum uint64
	src      []byte
	dst      []byte
	json     *jsonWorker
	err      error
}

type benchCase struct {
	Name       string `json:"case"`
	Workers    int    `json:"workers"`
	Kind       string `json:"kind"`
	BytesPerOp int64  `json:"bytes_per_op"`
	Payload    int64  `json:"payload_bytes"`
	Rounds     int    `json:"rounds_per_worker_op,omitempty"`
}

var cases = []benchCase{
	{Name: "integer1", Workers: 1, Kind: "integer", Rounds: integerRounds},
	{Name: "integer4", Workers: 4, Kind: "integer", Rounds: integerRounds},
	{Name: "float1", Workers: 1, Kind: "float", Rounds: floatRounds},
	{Name: "json_gzip1", Workers: 1, Kind: "json_gzip"},
	{Name: "memcpy1", Workers: 1, Kind: "memcpy", BytesPerOp: 16 << 20, Payload: 32 << 20},
	{Name: "memcpy4", Workers: 4, Kind: "memcpy", BytesPerOp: 32 << 20, Payload: 64 << 20},
}

type runner struct {
	bench   benchCase
	workers []worker
}

func newRunner(b benchCase, input []byte) (*runner, error) {
	r := &runner{bench: b, workers: make([]worker, b.Workers)}
	for i := range r.workers {
		w := &r.workers[i]
		switch b.Kind {
		case "integer":
			w.seed = 0x123456789abcdef0 + uint64(i)
			w.expected = integerVectors[i]
		case "float":
			value := floatKernel()
			if math.IsNaN(value) || math.IsInf(value, 0) || math.Abs(value-2.15365514383942) > 1e-12 {
				return nil, fmt.Errorf("float known vector failed: %.17g", value)
			}
			w.expected = math.Float64bits(value)
		case "json_gzip":
			w.json = newJSONWorker(input)
			// The first compression allocates its internal lazy storage here.
			if err := w.json.operation(); err != nil {
				return nil, err
			}
			w.expected = uint64(len(input))
		case "memcpy":
			length := int(b.BytesPerOp) / b.Workers
			w.src, w.dst = make([]byte, length), make([]byte, length)
			for j := range w.src {
				w.src[j] = byte((j*131 + i*17 + 11) & 255)
			}
		}
	}
	return r, nil
}

func (r *runner) work(w *worker, iterations int) {
	w.checksum, w.err = 0, nil
	switch r.bench.Kind {
	case "integer":
		for n := 0; n < iterations; n++ {
			w.checksum += integerKernel(w.seed)
		}
	case "float":
		for n := 0; n < iterations; n++ {
			w.checksum += math.Float64bits(floatKernel())
		}
	case "json_gzip":
		for n := 0; n < iterations; n++ {
			if w.err = w.json.operation(); w.err != nil {
				return
			}
			w.checksum += uint64(len(w.json.last))
		}
	case "memcpy":
		for n := 0; n < iterations; n++ {
			w.checksum += uint64(copy(w.dst, w.src))
		}
	}
}

// measure creates exactly Workers worker goroutines before starting the clock.
// One operation is one unit on EACH worker, so integer4/memcpy4 report aggregate
// four-worker operations. Full data validation is outside the measured region.
func (r *runner) measure(iterations int) (time.Duration, bool, error) {
	var done sync.WaitGroup
	start := make(chan struct{})
	done.Add(len(r.workers))
	for i := range r.workers {
		go func(w *worker) {
			defer done.Done()
			<-start
			r.work(w, iterations)
		}(&r.workers[i])
	}
	before := time.Now()
	close(start)
	done.Wait()
	elapsed := time.Since(before)
	ok, err := r.validate(iterations)
	return elapsed, ok, err
}

func (r *runner) validate(iterations int) (bool, error) {
	for i := range r.workers {
		w := &r.workers[i]
		if w.err != nil {
			return false, w.err
		}
		switch r.bench.Kind {
		case "integer", "float":
			if w.checksum != uint64(iterations)*w.expected {
				return false, fmt.Errorf("%s worker %d checksum mismatch", r.bench.Name, i)
			}
		case "json_gzip":
			if w.checksum != uint64(iterations)*w.expected || !bytes.Equal(w.json.last, w.json.input) {
				return false, fmt.Errorf("JSON/gzip roundtrip mismatch")
			}
		case "memcpy":
			if w.checksum != uint64(iterations)*uint64(len(w.src)) || !bytes.Equal(w.dst, w.src) {
				return false, fmt.Errorf("copy worker %d mismatch", i)
			}
		}
	}
	runtime.KeepAlive(r)
	return true, nil
}

// Calibration is custom, wall-clock based, and excluded from reported results.
// Start at one iteration; each step grows at most fourfold, with at most twelve
// steps and 2^26 iterations. Use one common N for the three measured repeats.
// duration is a calibration target, not a hard real-time deadline; callers can
// use their own process timeout to bound stalls or severe system contention.
func (r *runner) calibrate(target time.Duration) (int, time.Duration, error) {
	iterations := 1
	var elapsed time.Duration
	for step := 0; step < maxCalibrates; step++ {
		var err error
		elapsed, _, err = r.measure(iterations)
		if err != nil {
			return 0, 0, err
		}
		if elapsed >= target*95/100 || iterations == maxIterations || step == maxCalibrates-1 {
			return iterations, elapsed, nil
		}
		next := int(float64(iterations) * float64(target) / float64(max(elapsed, 1)))
		next = min(next, iterations*4, maxIterations)
		iterations = max(next, iterations+1)
	}
	return iterations, elapsed, nil
}

type result struct {
	Type           string  `json:"type"`
	Case           string  `json:"case"`
	Workers        int     `json:"workers"`
	Repetition     int     `json:"repetition"`
	Iterations     int     `json:"iterations"`
	ElapsedNS      int64   `json:"elapsed_ns"`
	NSPerOp        float64 `json:"ns_per_op"`
	BytesPerOp     int64   `json:"bytes_per_op"`
	BytesPerSec    float64 `json:"bytes_per_sec,omitempty"`
	ChecksumOK     bool    `json:"checksum_ok"`
	WarmupExcluded bool    `json:"warmup_excluded"`
}

func selftest(input []byte) error {
	for i, expected := range integerVectors {
		if got := integerKernel(0x123456789abcdef0 + uint64(i)); got != expected {
			return fmt.Errorf("integer known vector %d: got %016x, want %016x", i, got, expected)
		}
	}
	for _, b := range cases {
		r, err := newRunner(b, input)
		if err != nil {
			return err
		}
		// Correctness uses two operations per worker and no clock reads.
		for i := range r.workers {
			r.work(&r.workers[i], 2)
		}
		if _, err := r.validate(2); err != nil {
			return err
		}
	}
	return nil
}

func run() error {
	duration := flag.Duration("duration", 500*time.Millisecond, "per-repetition wall-clock calibration target (100ms through 2s)")
	count := flag.Int("count", 3, "measured repetitions per case (1 through 5)")
	selected := flag.String("case", "all", "exact case: all, integer1, integer4, float1, json_gzip1, memcpy1, memcpy4")
	onlySelftest := flag.Bool("selftest", false, "check known vectors and complete data roundtrips without benchmark results")
	flag.Parse()
	if flag.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if *duration < 100*time.Millisecond || *duration > 2*time.Second || *count < 1 || *count > 5 {
		return fmt.Errorf("duration must be 100ms through 2s; count must be 1 through 5")
	}
	input, err := fixture()
	if err != nil {
		return err
	}
	var chosen []benchCase
	for _, b := range cases {
		if *selected == "all" || *selected == b.Name {
			if b.Kind == "json_gzip" {
				b.BytesPerOp = int64(len(input))
			}
			chosen = append(chosen, b)
		}
	}
	if len(chosen) == 0 {
		return fmt.Errorf("unknown case %q", *selected)
	}
	encoder := json.NewEncoder(os.Stdout)
	if *onlySelftest {
		if err := selftest(input); err != nil {
			return err
		}
		return encoder.Encode(map[string]any{"type": "selftest", "checksum_ok": true, "cases": len(cases)})
	}
	hash := sha256.Sum256(input)
	if err := encoder.Encode(map[string]any{
		"type": "metadata", "schema": 1, "compiler": runtime.Version(),
		"goos": runtime.GOOS, "goarch": runtime.GOARCH, "num_cpu": runtime.NumCPU(),
		"fixture_sha256": hex.EncodeToString(hash[:]), "fixture_bytes": len(input),
		"target_ns": duration.Nanoseconds(), "count": *count, "cases": chosen,
		"calibration": "custom wall-clock; growth <=4x; <=12 steps; iterations <=2^26; excluded",
		"warmup":      "before every measured repetition: max(1, calibrated iterations/10); excluded",
		"operation":   "one kernel/copy/roundtrip per worker; workers run simultaneously; aggregate bytes per op",
	}); err != nil {
		return err
	}
	for _, b := range chosen {
		previousProcs := runtime.GOMAXPROCS(b.Workers)
		r, err := newRunner(b, input)
		if err != nil {
			return err
		}
		iterations, calibrationElapsed, err := r.calibrate(*duration)
		if err != nil {
			return err
		}
		if err := encoder.Encode(map[string]any{
			"type": "calibration", "case": b.Name, "workers": b.Workers,
			"iterations": iterations, "elapsed_ns": calibrationElapsed.Nanoseconds(),
			"excluded": true,
		}); err != nil {
			return err
		}
		for repetition := 1; repetition <= *count; repetition++ {
			if _, _, err := r.measure(max(1, iterations/10)); err != nil {
				return err
			}
			elapsed, ok, err := r.measure(iterations)
			if err != nil {
				return err
			}
			row := result{
				Type: "result", Case: b.Name, Workers: b.Workers, Repetition: repetition,
				Iterations: iterations, ElapsedNS: elapsed.Nanoseconds(),
				NSPerOp:    float64(elapsed.Nanoseconds()) / float64(iterations),
				BytesPerOp: b.BytesPerOp, ChecksumOK: ok, WarmupExcluded: true,
			}
			if b.BytesPerOp != 0 {
				row.BytesPerSec = float64(b.BytesPerOp) * float64(iterations) / elapsed.Seconds()
			}
			if err := encoder.Encode(row); err != nil {
				return err
			}
		}
		runtime.GOMAXPROCS(previousProcs)
		// Release the previous case's buffers before allocating the next case.
		r = nil
		runtime.GC()
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "benchmark:", err)
		os.Exit(1)
	}
}
