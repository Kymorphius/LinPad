#!/bin/sh
# One-shot, opt-in guard for the listener suspend/resume experiment.
# Run as guest root with: NEW_LOG EXPECTED_PID EXPECTED_STARTTIME SECONDS
# This is not a service: it never installs itself or changes startup files.
set -eu
set -f
umask 077

proc_root=/proc
pid_file=/run/linpad-ssh/server.pid
helper=/usr/local/bin/linpad-ssh-start
nc=/usr/bin/nc
timeout=/usr/bin/timeout

fail() { printf '%s\n' "listener-resume-recovery: $*" >&2; exit 1; }

uptime_seconds() {
    IFS=' ' read -r uptime_value uptime_rest < "$proc_root/uptime" || return 1
    uptime_value=${uptime_value%%.*}
    case "$uptime_value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$uptime_value"
}

record() {
    record_time=$(uptime_seconds) || fail 'cannot read uptime'
    printf '%s %s\n' "$record_time" "$*" >&3
}

pid_file_matches() {
    [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
    current_pid=''
    IFS= read -r current_pid < "$pid_file" || :
    [ "$current_pid" = "$expected_pid" ]
}

valid_start_tick() {
    # At most 15 decimal digits (<=999999999999999) keeps subtraction and
    # +/-1 comparisons safely within signed 64-bit BusyBox ash arithmetic.
    # Reject leading zeroes so shell arithmetic cannot interpret octal.
    case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
    [ "${#1}" -le 15 ]
}

same_starttime() {
    valid_start_tick "$1" || return 1
    candidate_tick=$1
    # LinPad derives boot_ticks from separate realtime/uptime snapshots;
    # the same process can therefore differ by one 100-Hz tick (10 ms).
    # Accept only this rounding tolerance. Larger changes fail closed.
    # PID reuse within this 10-ms margin cannot be excluded by starttime
    # alone; same_master also requires every other master identity marker.
    start_delta=$((candidate_tick - expected_start))
    [ "$start_delta" -ge -1 ] && [ "$start_delta" -le 1 ]
}

same_master() {
    pid_file_matches || return 1
    kill -0 "$expected_pid" 2>/dev/null || return 1
    [ "$(readlink "$proc_root/$expected_pid/exe" 2>/dev/null)" = /usr/sbin/dropbear ] || return 1
    stat_line=''
    IFS= read -r stat_line < "$proc_root/$expected_pid/stat" || return 1
    # The comm field can contain spaces or ')'; the fields follow its last ') '.
    stat_tail=${stat_line##*) }
    [ "$stat_tail" != "$stat_line" ] || return 1
    set -- $stat_tail
    [ "$#" -ge 20 ] || return 1
    shift 11
    master_utime=$1 master_stime=$2
    case "$master_utime:$master_stime" in *[!0-9:]*) return 1 ;; esac
    shift 8
    same_starttime "$1" || return 1
    seen_name=0 seen_pid=0 seen_tgid=0 seen_ppid=0 seen_uid=0
    while IFS=' 	' read -r status_key status_a status_b status_c status_d status_extra; do
        case "$status_key" in
            Name:) [ "$status_a" = dropbear ] || return 1; seen_name=1 ;;
            Pid:) [ "$status_a" = "$expected_pid" ] || return 1; seen_pid=1 ;;
            Tgid:) [ "$status_a" = "$expected_pid" ] || return 1; seen_tgid=1 ;;
            PPid:) [ "$status_a" = 1 ] || return 1; seen_ppid=1 ;;
            Uid:) [ "$status_a:$status_b:$status_c:$status_d" = 0:0:0:0 ] || return 1; seen_uid=1 ;;
        esac
    done < "$proc_root/$expected_pid/status"
    [ "$seen_name:$seen_pid:$seen_tgid:$seen_ppid:$seen_uid" = 1:1:1:1:1 ]
}

has_ssh_banner() {
    # BusyBox nc with /dev/null stdin exits before reading a healthy banner.
    # Holding stdin open is necessary. Both the outer command and nc reads
    # are bounded; only a real SSH-2.0 banner counts as healthy.
    "$timeout" 4 /bin/sh -c 'sleep 3 | "$1" -w 2 127.0.0.1 2222' sh "$nc" 2>/dev/null |
        { banner=''; IFS= read -r banner || :; case "$banner" in SSH-2.0-*) exit 0 ;; *) exit 1 ;; esac; }
}

recognized_helper() {
    [ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] || return 1
    { IFS= read -r helper_first && IFS= read -r helper_second; } < "$helper" || return 1
    [ "$helper_first" = '#!/bin/sh' ] && [ "$helper_second" = '# LinPad SSH helper' ]
}

recover_once() {
    # Leave enough of the observation window for bounded TERM/restart/health
    # checks. We never signal a process if its identity has changed.
    now=$(uptime_seconds) || return 1
    if [ "$((deadline - now))" -lt 30 ]; then
        record 'insufficient_recovery_time no_signal'
        return 1
    fi
    recognized_helper || { record 'helper_mismatch no_signal'; return 1; }
    same_master || { record 'identity_mismatch no_signal'; return 1; }
    record "term_once pid=$expected_pid utime=$master_utime stime=$master_stime"
    kill -TERM "$expected_pid" || { record 'term_failed'; return 1; }
    wait_round=0
    while [ -d "$proc_root/$expected_pid" ] && [ "$wait_round" -lt 10 ]; do
        # A new starttime at this PID is a reuse, not proof that it is safe to
        # act on that process or invoke a potentially conflicting restart.
        stat_line=''
        IFS= read -r stat_line < "$proc_root/$expected_pid/stat" || { record 'old_pid_unreadable no_restart'; return 1; }
        stat_tail=${stat_line##*) }
        set -- $stat_tail
        [ "$#" -ge 20 ] || { record 'old_pid_unreadable no_restart'; return 1; }
        shift 19
        same_starttime "$1" || { record 'pid_reused no_restart'; return 1; }
        sleep 1
        wait_round=$((wait_round + 1))
    done
    [ ! -d "$proc_root/$expected_pid" ] || { record 'old_pid_still_present no_restart'; return 1; }
    # Preserve a replacement server or a changed/symlinked PID file.
    if [ -e "$pid_file" ] || [ -L "$pid_file" ]; then
        pid_file_matches || { record 'pid_file_changed no_restart'; return 1; }
    fi
    recognized_helper || { record 'helper_changed no_restart'; return 1; }
    record 'old_pid_gone starting_existing_helper'
    "$timeout" 10 "$helper" >&3 2>&1 || { record 'helper_failed'; return 1; }
    if has_ssh_banner; then
        record 'recovery_banner_ok finished'
        return 0
    fi
    record 'recovery_banner_missing finished_no_more_signals'
    return 1
}

main() {
    [ "$#" = 4 ] || fail 'usage: NEW_LOG EXPECTED_PID EXPECTED_STARTTIME SECONDS'
    log=$1 expected_pid=$2 expected_start=$3 duration=$4
    case "$log" in /*) ;; *) fail 'log must be an absolute path in your private experiment directory' ;; esac
    case "$expected_pid" in ''|*[!0-9]*) fail 'invalid expected PID' ;; esac
    [ "${#expected_pid}" -le 10 ] && [ "$expected_pid" -gt 1 ] && [ "$expected_pid" -le 2147483647 ] || fail 'invalid expected PID'
    valid_start_tick "$expected_start" || fail 'invalid expected starttime (maximum 15 decimal digits)'
    case "$duration" in ''|*[!0-9]*) fail 'invalid duration' ;; esac
    [ "${#duration}" -le 3 ] && [ "$duration" -ge 35 ] && [ "$duration" -le 300 ] || fail 'duration must be 35..300 seconds'
    [ "$(id -u)" = 0 ] || fail 'run as guest root'
    [ -x "$nc" ] && [ -x "$timeout" ] || fail 'required BusyBox nc/timeout missing'
    # A new regular file only: noclobber also refuses an existing symlink.
    [ ! -e "$log" ] && [ ! -L "$log" ] || fail 'refusing an existing log'
    set -C
    exec 3> "$log" || fail 'cannot create new log'
    set +C
    [ -f "$log" ] && [ ! -L "$log" ] || fail 'log must be a regular file'
    start=$(uptime_seconds) || fail 'cannot read uptime'
    deadline=$((start + duration))
    record "starting pid=$expected_pid starttime=$expected_start duration=$duration"
    same_master || { record 'initial_identity_mismatch no_signal'; return 1; }
    recognized_helper || { record 'initial_helper_mismatch no_signal'; return 1; }
    has_ssh_banner || { record 'initial_banner_missing not_armed'; return 1; }
    record 'armed initial_banner_ok'
    failures=0 rounds=0
    # The iteration bound also prevents a malformed/frozen uptime from
    # producing an unbounded loop. Sleeps are never shorter than one second.
    max_rounds=$((duration / 5 + 2))
    while [ "$rounds" -lt "$max_rounds" ]; do
        now=$(uptime_seconds) || { record 'uptime_failed no_signal'; return 1; }
        [ "$now" -lt "$deadline" ] || break
        same_master || { record 'identity_changed no_signal'; return 1; }
        record "master_ok utime=$master_utime stime=$master_stime"
        if has_ssh_banner; then
            failures=0
            record 'banner_ok'
        else
            failures=$((failures + 1))
            record "banner_missing consecutive=$failures"
            same_master || { record 'identity_changed_after_probe no_signal'; return 1; }
            if [ "$failures" -ge 2 ]; then
                recover_once
                return "$?"
            fi
        fi
        rounds=$((rounds + 1))
        now=$(uptime_seconds) || return 1
        remaining=$((deadline - now))
        [ "$remaining" -gt 0 ] || break
        delay=5
        [ "$remaining" -ge "$delay" ] || delay=$remaining
        sleep "$delay"
    done
    record 'expired no_signal'
}

main "$@"
