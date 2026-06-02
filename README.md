# acdev — seamless cd→container-shell handoff on macOS with Apple Container

`cd` into a project that has an `.applecontainer.toml` and you land in a
Flox-activated shell **inside** a hardware-isolated Apple Container — no Docker,
no Dev Containers extension. This recreates the devcontainer-flox workflow using
Apple's native `container` CLI (Path B: direct CLI orchestration).

`acdev` is published to FloxHub as **[`jbayer/acdev`](https://hub.flox.dev)** — the
package bundles the CLI and all three shell hooks. A ready-to-run **example
environment** under `example/` demonstrates the whole flow.

## Requirements

- Apple silicon Mac, macOS 26 (Tahoe).
- [`apple/container`](https://github.com/apple/container) installed and running
  (`container system start`).
- [Flox](https://flox.dev) on the host — the supported way to install and run
  `acdev`.

## Quick start (Flox)

Try the bundled example environment (it installs the published package — no build
step needed):

```bash
flox activate -d example          # installs jbayer/acdev, registers the hooks
cd example/demo-project           # ships an .applecontainer.toml → handoff fires
```

`cd`-ing into `example/demo-project` triggers `acdev up && acdev shell` and drops
you into the container. Exit the shell and the container keeps running; the next
`cd` back in is instant.

## Use acdev in your own projects (Flox)

Install the published package and register the matching hook in your
environment's `[profile]`. Installing puts `acdev` on PATH and ships the hooks at
`$FLOX_ENV/share/acdev/hooks/`:

```toml
# in your environment's .flox/env/manifest.toml
[install]
acdev.pkg-path = "jbayer/acdev"

[profile]
bash = '''
  [ -r "$FLOX_ENV/share/acdev/hooks/acdev.bash" ] && . "$FLOX_ENV/share/acdev/hooks/acdev.bash"
'''
# zsh / fish: source acdev.zsh / acdev.fish the same way
```

See `example/.flox/env/manifest.toml` for the full bash/zsh/fish version. Then, in
any project you want managed:

```bash
acdev init        # write a starter .applecontainer.toml (no-op if one exists)
cd <that project> # → dropped into the container shell
```

## Commands

```bash
acdev init      # write a starter .applecontainer.toml (no-op if one exists)
acdev up        # create or reuse the project container
acdev shell     # enter it
acdev status    # name / state / image / mount / IP
acdev down      # stop it (--rm to also remove)
acdev up --dry-run   # print the container commands without running them
```

## How it works

- One long-lived container per project, kept alive by a `sleep infinity`
  keepalive; your interactive shell is a separate `container exec` session.
- The container name is derived from the project's absolute path, so each
  project gets one stable, reusable container.
- Reach services running in the container by its IP (`acdev status`) — the
  reliable path on Apple Container.

## Shared Nix binary cache (optional)

Avoid re-downloading Flox/Nix packages across project containers and rebuilds.
A host-side nginx proxy caches `cache.flox.dev` + `cache.nixos.org` on your SSD;
containers fetch through it. Signatures pass through, so nothing needs signing.

Start the cache (bundled in the acdev package, run by the example env):

```bash
flox activate -d example --start-services   # runs acdev-nix-cache on :8126
```

Point a project at it in `.applecontainer.toml`:

```toml
nix_cache = "http://192.168.64.1:8126"
```

acdev then injects the proxy as a preferred Nix substituter (`-e NIX_CONFIG`) when it
creates the container. The cache listens on `192.168.64.1:8126` (the container-bridge
gateway) so it is reachable only from the container network, not your LAN — start the
container system first (`container system start`) so that IP exists. Set
`ACDEV_NIX_CACHE_LISTEN=0.0.0.0` to broaden, and `ACDEV_NIX_CACHE_DIR` to relocate the
cache directory.

> Takes effect on container **creation**. If you add `nix_cache` to an existing project,
> recreate its container: `acdev down --rm && acdev up`.

## Troubleshooting

`up`, `status`, and `down` preflight the Apple Container CLI and daemon, and fail
fast with an actionable message (exit 1) instead of a cryptic error:

- **`container` not installed / not on PATH:**

  ```
  acdev: the 'container' CLI was not found. Install Apple Container
  (apple/container) and ensure it is on your PATH.
  ```

- **Container service not started:**

  ```
  acdev: cannot reach the container service. Start it with: container system start
  ```

`acdev init` and `acdev up --dry-run` deliberately skip these checks — they don't
touch the daemon, so they work with `container` absent or stopped.

## Without Flox (manual fallback)

If you aren't using Flox, you can run the script directly and source the hooks
from your shell rc:

```bash
ln -s "$PWD/bin/acdev" /usr/local/bin/acdev
echo 'source '"$PWD"'/hooks/acdev.zsh'  >> ~/.zshrc    # zsh
echo 'source '"$PWD"'/hooks/acdev.bash' >> ~/.bashrc   # bash
echo 'source '"$PWD"'/hooks/acdev.fish' >> ~/.config/fish/config.fish  # fish
```

## Development

```bash
flox activate -- bats tests/          # run the suite
flox activate -- shellcheck bin/acdev # lint
flox build acdev                      # build the package
```
