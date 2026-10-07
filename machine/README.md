# Ubuntu image for `container machine`

A `Dockerfile` for an Ubuntu 24.04 image that boots systemd, for use with
Apple `container machine`: a long-lived Linux VM with your macOS user and
home directory, rather than a per-project container. Tested with Apple
`container` 1.5.0. acdev doesn't use this; it's a separate setup.

The image adds systemd, sudo, openssh-server, and the usual tools, restores
the full (non-minimized) Ubuntu, and masks units that fail inside a VM
without real hardware or a console.

## Build and create

```bash
container build -t local/ubuntu-machine machine/
container machine create local/ubuntu-machine --name ubuntu --set-default
```

`create` boots the machine. Add `--cpus 4 --memory 4G` to size it; by default
it gets half of system memory.

## Use

```bash
container machine run -n ubuntu              # interactive shell
container machine run -n ubuntu -- uname -a  # one command
```

Inside, you're your macOS user with passwordless `sudo`, starting in the same
directory you ran the command from. Your home directory is mounted read-write
(`--home-mount ro|none` changes that).

- **Quote compound commands as one string.** `machine run` joins its
  arguments into a single shell command line, so
  `-- bash -c 'echo hi'` loses the quoting. Use
  `-- "bash -c 'echo hi; echo there'"`.
- **Give systemd a few seconds after boot.** Right after `create` or the first
  `run` on a stopped machine, `systemctl` can fail with
  `Failed to connect to bus`. `systemctl is-system-running` reports `running`
  once boot finishes.
- **SSH is socket-activated.** `systemctl is-active ssh` says `inactive` until
  something connects; `ssh.socket` is the unit to check.

## Manage

```bash
container machine ls
container machine stop ubuntu
container machine delete ubuntu
```

Rebuilding the image doesn't change an existing machine. Delete and recreate
the machine to pick up a new image.
