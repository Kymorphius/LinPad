# Optional guest SSH

`setup_guest_ssh.sh` configures a key-only Dropbear service inside the LinPad
Linux guest. Run it as guest root and provide one client `ssh-ed25519` public
key on standard input. Never provide a private key.

Copy the script and the public key into the guest, then run:

```sh
sh /path/to/setup_guest_ssh.sh < /path/to/client_ed25519.pub
```

The installer uses Alpine's `apk` to install Dropbear if necessary. The guest
must also provide the BusyBox-compatible `/usr/bin/timeout`, `/usr/bin/nc` and
`/usr/bin/nohup` commands, plus the standard shell utilities. The installer
preserves existing authorized keys and reuses the existing SSH host key.

Successful setup starts SSH on IPv4 port **2222** and prints `SSH_SETUP_OK`
followed by the server's public host key. Password authentication is disabled.
Verify that public host key through the trusted guest console before accepting
the server on the first network connection.
The service listens on all IPv4 interfaces, so use the iPad's reachable address
and port 2222 when connecting with the matching client key.

## Start and resume recovery

Start the configured service manually with:

```sh
linpad-ssh-start
```

The helper verifies an existing master's identity and SSH banner before
reporting it healthy. After two failed banner checks, it sends one `TERM` only
to the verified root Dropbear master, waits for that process to exit, and starts
one replacement using the same host key and options. It does not signal SSH
session children or other Linux tasks. Operations have a fixed deadline and an
atomic lock; there is no resident polling process.

Setup also installs `/etc/linpad/lifecycle.d/50-linpad-ssh`. On the desktop
lifecycle's `resume` event, this hook detaches a bounded check equivalent to:

```sh
linpad-ssh-start --recover-existing
```

This mode leaves an absent or stopped service off. It only recovers a service
whose live master can be identified from the managed PID file and `/proc`.
Unknown process identities, changed PID files, symlinked runtime files, or an
existing `start.lock` are refused rather than overwritten. An unknown lock
requires inspection; the helper never assumes that it is stale or removes it.

This recovery is limited to SSH configured by this installer and the existing
desktop lifecycle hook. It does not repair arbitrary listeners, restart LinPad,
or change the Linux image or background-execution settings.
