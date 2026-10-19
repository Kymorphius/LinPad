#!/bin/sh
# Connect to LinPad without attaching a debugger. No global SSH config changes.
set -eu
umask 077

usage() {
    printf '%s\n' 'Usage: ipad_ssh.sh [usb|wifi] [ssh command arguments...]' \
        'Wi-Fi host: LINPAD_WIFI_HOST (default iPad.local)' \
        'USB device: LINPAD_DEVICE_UDID or ~/.config/linpad/ssh-device-udid'
}

mode=${1:-usb}
case "$mode" in
    usb|wifi) [ "$#" -eq 0 ] || shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

key=${LINPAD_SSH_KEY:-"$HOME/.ssh/linpad_ipad_ed25519"}
known_hosts=${LINPAD_SSH_KNOWN_HOSTS:-"$HOME/.ssh/linpad_ipad_known_hosts"}
[ -f "$key" ] && [ -f "$known_hosts" ] || {
    printf '%s\n' 'LinPad SSH key or pinned host key is missing; complete initial setup first.' >&2
    exit 1
}

proxy_pid=''
proxy_log=''
cleanup() {
    if [ -n "$proxy_pid" ]; then
        kill "$proxy_pid" 2>/dev/null || :
        wait "$proxy_pid" 2>/dev/null || :
    fi
    [ -z "$proxy_log" ] || rm -f "$proxy_log"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$mode" = wifi ]; then
    host=${LINPAD_WIFI_HOST:-iPad.local}
    port=2222
else
    host=127.0.0.1
    port=12222
    if ! nc -z -w 1 "$host" "$port" 2>/dev/null; then
        command -v iproxy >/dev/null 2>&1 || {
            printf '%s\n' 'Install the USB proxy first: brew install libusbmuxd' >&2
            exit 1
        }
        udid=${LINPAD_DEVICE_UDID:-}
        if [ -z "$udid" ] && [ -f "$HOME/.config/linpad/ssh-device-udid" ]; then
            IFS= read -r udid < "$HOME/.config/linpad/ssh-device-udid" || :
        fi
        [ -n "$udid" ] || { printf '%s\n' 'Set LINPAD_DEVICE_UDID for the paired iPad.' >&2; exit 1; }
        proxy_log=$(mktemp "${TMPDIR:-/tmp}/linpad-iproxy.XXXXXX")
        iproxy --local --source 127.0.0.1 --udid "$udid" 12222:2222 > "$proxy_log" 2>&1 &
        proxy_pid=$!
        attempt=0
        until nc -z -w 1 "$host" "$port" 2>/dev/null; do
            if ! kill -0 "$proxy_pid" 2>/dev/null || [ "$attempt" -ge 30 ]; then
                cat "$proxy_log" >&2
                printf '%s\n' 'USB proxy did not start; no existing process was stopped.' >&2
                exit 1
            fi
            sleep 0.1
            attempt=$((attempt + 1))
        done
    fi
fi

# Dropbear's noninteractive default PATH omits /usr/local/bin on Alpine.
# SSH itself joins command arguments as shell text; preserve that convention.
if [ "$#" -gt 0 ]; then
    set -- "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH; $*"
fi

status=0
ssh -4 -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$known_hosts" -o HostKeyAlias=linpad-ipad \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -p "$port" "root@$host" "$@" || status=$?
exit "$status"
