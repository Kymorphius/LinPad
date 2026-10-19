package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"hash/crc32"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestOriginalFixtureIdentity(t *testing.T) {
	data, err := fixture()
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(data.input)
	if len(data.input) != 15678 || hex.EncodeToString(hash[:]) != "064b2c6387ef9f667a7ec90c0a76810720571906a80f26d3c3853439ff434655" {
		t.Fatal("fixture no longer matches the original comparison payload")
	}
	if got := crc32.ChecksumIEEE(data.input); got != 0x5ed2d536 {
		t.Fatalf("fixture CRC32 = %08x", got)
	}
	if len(data.records) != 128 || data.records[127].ID != 127 || data.records[127].Name != "record-127" || !data.records[127].Enabled {
		t.Fatal("fixture records differ")
	}
}

func TestEveryStageAndCompleteOutputValidation(t *testing.T) {
	data, err := fixture()
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range caseNames {
		t.Run(name, func(t *testing.T) {
			r, err := newRunner(name, data)
			if err != nil {
				t.Fatal(err)
			}
			r.work(3)
			if crc, err := r.validate(3); err != nil || len(crc) != 16 {
				t.Fatalf("validate CRC64 %q: %v", crc, err)
			}
			r.checksum++
			if _, err := r.validate(3); err == nil {
				t.Fatal("accepted a corrupted accumulated checksum")
			}
			r.work(3)
			switch name {
			case "decode_fresh":
				r.records[63].Payload = "corrupt interior record"
			case "gzip_compress_reuse":
				r.compressed.Bytes()[r.compressed.Len()/2] ^= 1
			case "crc32_ieee":
				r.crc ^= 1
			default:
				r.last[len(r.last)/2] ^= 1
			}
			if _, err := r.validate(3); err == nil {
				t.Fatal("accepted an interior output corruption")
			}
		})
	}
}

func TestArgumentBounds(t *testing.T) {
	for _, args := range [][]string{
		{"-duration=99ms"}, {"-duration=1001ms"}, {"-count=0"}, {"-count=6"},
		{"-case=not-a-case"}, {"-max-wall=4s"}, {"-max-wall=301s"}, {"extra"}, {"-unknown"},
	} {
		if _, err := parseOptions(args); err == nil {
			t.Fatalf("accepted invalid arguments %v", args)
		}
	}
	for _, args := range [][]string{
		nil, {"-duration=100ms", "-count=1", "-max-wall=5s", "-case=roundtrip"},
		{"-duration=1s", "-count=5", "-max-wall=5m", "-selftest"},
	} {
		if _, err := parseOptions(args); err != nil {
			t.Fatalf("rejected valid arguments %v: %v", args, err)
		}
	}
}

func TestMeasuredAllocationCountersAndIterationBounds(t *testing.T) {
	previous := runtime.GOMAXPROCS(1)
	defer runtime.GOMAXPROCS(previous)
	data, err := fixture()
	if err != nil {
		t.Fatal(err)
	}
	r, err := newRunner("encode", data)
	if err != nil {
		t.Fatal(err)
	}
	m, err := r.measure(3, true)
	if err != nil {
		t.Fatal(err)
	}
	// Encoding necessarily creates three independent 15 KiB output arrays.
	// Avoid requiring a particular allocator size class or a forced GC count.
	if m.elapsed <= 0 || m.memory.TotalAllocBytes < 3*uint64(len(data.input)) || m.memory.Mallocs < 3 {
		t.Fatalf("missing timed encoding allocations: %+v", m)
	}
	if m.memory.AllocatedPerOp <= 0 || m.memory.AllocsPerOp < 1 {
		t.Fatalf("missing per-operation allocation metrics: %+v", m.memory)
	}
	for _, n := range []int{0, maxIterations + 1} {
		if _, err := r.measure(n, true); err == nil {
			t.Fatalf("accepted out-of-range iteration count %d", n)
		}
	}
}

func TestSelftestJSONAndGOMAXPROCSRestoration(t *testing.T) {
	previous := runtime.GOMAXPROCS(2)
	defer runtime.GOMAXPROCS(previous)
	var out bytes.Buffer
	if err := run([]string{"-selftest"}, &out); err != nil {
		t.Fatal(err)
	}
	if runtime.GOMAXPROCS(0) != 2 {
		t.Fatal("selftest changed caller's GOMAXPROCS")
	}
	var row struct {
		Type         string `json:"type"`
		ChecksumOK   bool   `json:"checksum_ok"`
		Cases        int    `json:"cases"`
		FixtureBytes int    `json:"fixture_bytes"`
	}
	if err := json.Unmarshal(out.Bytes(), &row); err != nil {
		t.Fatal(err)
	}
	if row.Type != "selftest" || !row.ChecksumOK || row.Cases != 6 || row.FixtureBytes != 15678 || strings.Count(out.String(), "\n") != 1 {
		t.Fatalf("unexpected selftest output: %s", out.String())
	}
}

func TestResultSchemaIncludesGlobalMemoryDeltas(t *testing.T) {
	encoded, err := json.Marshal(result{Type: "result", memoryDelta: memoryDelta{Mallocs: 2}})
	if err != nil {
		t.Fatal(err)
	}
	var row map[string]any
	if err := json.Unmarshal(encoded, &row); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"elapsed_ns", "ns_per_op", "checksum", "output_crc64_ecma", "total_alloc_bytes", "mallocs", "frees", "gc_count", "gc_pause_ns", "allocated_bytes_per_op", "allocs_per_op", "gc_pause_ns_per_op"} {
		if _, ok := row[key]; !ok {
			t.Fatalf("missing result field %q", key)
		}
	}
}

func TestDefaultCalibrationBudget(t *testing.T) {
	o, err := parseOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if o.duration != 300*time.Millisecond || o.count != 3 || o.maxWall != 120*time.Second {
		t.Fatalf("unexpected default runtime budget: %+v", o)
	}
}
