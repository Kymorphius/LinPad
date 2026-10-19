//go:build linux && arm64

// Probe CPU timer capability in this process only. No timer is ever armed, no
// signal is sent, and every successfully created POSIX timer is deleted.
package main

import (
	"encoding/json"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

type sigevent struct {
	Value  uint64
	Signo  int32
	Notify int32
	Tail   [48]byte
}

type timerResult struct {
	Clock       int           `json:"clock"`
	CreateErrno syscall.Errno `json:"create_errno"`
	DeleteErrno syscall.Errno `json:"delete_errno"`
}

func main() {
	if unsafe.Sizeof(sigevent{}) != 64 {
		os.Exit(1)
	}
	var zero [4]int64
	_, _, profErr := syscall.RawSyscall(syscall.SYS_SETITIMER, 2, uintptr(unsafe.Pointer(&zero)), 0)
	event := sigevent{Signo: 27, Notify: 1} // SIGEV_NONE: no delivery target.
	results := make([]timerResult, 0, 3)
	failedCleanup := false
	for _, clock := range []int{1, 2, 3} { // MONOTONIC, PROCESS_CPUTIME, THREAD_CPUTIME.
		var id int32
		_, _, createErr := syscall.RawSyscall(syscall.SYS_TIMER_CREATE, uintptr(clock),
			uintptr(unsafe.Pointer(&event)), uintptr(unsafe.Pointer(&id)))
		row := timerResult{Clock: clock, CreateErrno: createErr}
		if createErr == 0 {
			_, _, row.DeleteErrno = syscall.RawSyscall(syscall.SYS_TIMER_DELETE, uintptr(id), 0, 0)
			failedCleanup = failedCleanup || row.DeleteErrno != 0
		}
		results = append(results, row)
	}
	runtime.KeepAlive(event)
	if json.NewEncoder(os.Stdout).Encode(map[string]any{
		"setitimer_prof_zero_errno": profErr, "timers": results,
		"timers_armed": false, "cleanup_ok": !failedCleanup,
	}) != nil || failedCleanup {
		os.Exit(1)
	}
}
