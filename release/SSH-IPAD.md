# Connect to LinPad over USB or Wi-Fi

SSH runs commands inside the Linux guest without attaching a debugger. The
[guest setup script](../tools/setup_guest_ssh.sh) installs Dropbear with public-key
authentication on IPv4 port `2222`. The Mac USB proxy listens only on
`127.0.0.1:12222`.

## Initial setup

1. On the Mac, install the USB proxy with `brew install libusbmuxd` and create a
   dedicated Ed25519 SSH key if one is not already available.
2. Transfer `tools/setup_guest_ssh.sh` and the single-line **public** key to the
   guest through a trusted initial channel. Run the script as guest root, with
   the public key on standard input:

   ```sh
   sh /path/to/setup_guest_ssh.sh < /path/to/login-key.pub
   ```

   The script installs Dropbear if needed and appends the public key while
   preserving existing `authorized_keys` entries. It does not change the root
   password or the system sshd configuration.
3. Read `/tmp/linpad-ssh-hostkey.pub` from the guest through that trusted channel.
   Pin its `ssh-ed25519` public key in the Mac's dedicated known-hosts file under
   the alias `linpad-ipad`. The line has this form:

   ```text
   linpad-ipad ssh-ed25519 <verified-host-public-key>
   ```

   Verify this host key independently before the first SSH connection.

The Mac client defaults to `~/.ssh/linpad_ipad_ed25519` for the login key and
`~/.ssh/linpad_ipad_known_hosts` for the pinned host key. Set `LINPAD_SSH_KEY` and
`LINPAD_SSH_KNOWN_HOSTS` to use other files. Keep private keys and actual device
identifiers outside the repository.

The guest stores its host key in `/etc/linpad-ssh`, and its root-only runtime
directory and log are `/run/linpad-ssh` and `/run/linpad-ssh/server.log`.

## Connect from the Mac

For USB, set the paired device identifier and run:

```sh
export LINPAD_DEVICE_UDID='<paired-device-identifier>'
./tools/ipad_ssh.sh usb
```

Alternatively, save that identifier in
`~/.config/linpad/ssh-device-udid`. The client reuses an existing local proxy or
starts a temporary `iproxy`; on exit it stops only the proxy it started.

For Wi-Fi, set the iPad's reachable address or hostname:

```sh
LINPAD_WIFI_HOST='<iPad-address-or-hostname>' ./tools/ipad_ssh.sh wifi
```

The Mac and iPad must be able to reach each other over the network. Find the
address in the iPad's Wi-Fi settings, or run `ifconfig en0` in a working guest
session. The client uses IPv4.

Pass a remote command after the transport argument:

```sh
./tools/ipad_ssh.sh usb 'uname -m; id'
```

## Start and verify the service

SSH is started on demand. After LinPad is terminated or restarted, run this in
the guest terminal before reconnecting:

```sh
linpad-ssh-start
```

Keep LinPad in the foreground while using SSH. App suspension, screen lock, or
system termination can interrupt a connection. Starting SSH does not restore
LinPad JIT; see [USB JIT setup](USB-JIT.md) for that separate operation.

Verify both USB and Wi-Fi remote commands, an interactive PTY, and repeated
invocations of the starter. A reachable TCP port alone does not verify SSH
protocol health or authentication.

## Listener recovery after suspension

The setup script also installs `/etc/linpad/lifecycle.d/50-linpad-ssh`. On the
desktop's `resume` event it launches one bounded health check and returns
immediately. There is no periodic background watcher. The hook invokes
`linpad-ssh-start --recover-existing`, which leaves SSH off when its managed
master is absent or already dead.

The starter checks a real local SSH protocol banner before reporting an
existing server healthy. After two bounded failures it can send one TERM to
the verified root Dropbear master, then restart the service only after that
process exits. Before recovery it checks the PID file, executable, process
name, PID/Tgid, parent, root UIDs, and start time. A private operation lock
prevents overlapping starts; unknown locks or changed identities stop recovery.
It does not signal process groups or authenticated children, replace keys, or
change SSH options.

Existing network connections may still disconnect across suspension, and this
recovery applies only to the managed SSH service. Reconnect from the Mac after
LinPad returns to the foreground; the bounded check may take several seconds.
Independent terminal and tmux tasks remain separate from the managed SSH master.

The generated starter and resume hook have regression coverage in
[`setup-guest-ssh-health-test.py`](../tests/unit/setup-guest-ssh-health-test.py)
and [`ssh-resume-hook-test.py`](../tests/unit/ssh-resume-hook-test.py).
