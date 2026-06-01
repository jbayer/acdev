# acdev — seamless cd→container-shell handoff on macOS with Apple Container

`cd` into a project that has an `.applecontainer.toml` and you land in a
Flox-activated shell **inside** a hardware-isolated Apple Container — no Docker,
no Dev Containers extension. This recreates the devcontainer-flox workflow using
Apple's native `container` CLI (Path B: direct CLI orchestration).

## Requirements

- Apple silicon Mac, macOS 26 (Tahoe).
- [`apple/container`](https://github.com/apple/container) installed and running
  (`container system start`).
- [Flox](https://flox.dev) on the host (for the dev/test environment).

## Install

```bash
# Put acdev on your PATH (adjust the path to this checkout):
ln -s "$PWD/bin/acdev" /usr/local/bin/acdev

# Enable the auto-handoff hook in your shell rc:
echo 'source '"$PWD"'/hooks/acdev.zsh'  >> ~/.zshrc    # zsh
echo 'source '"$PWD"'/hooks/acdev.bash' >> ~/.bashrc   # bash
echo 'source '"$PWD"'/hooks/acdev.fish' >> ~/.config/fish/config.fish  # fish
```

### Or: install as a Flox package

`acdev` is also packaged as a Flox manifest build (`[build.acdev]` in
`.flox/env/manifest.toml`). It bundles the CLI and all three shell hooks:

```
$out/bin/acdev                                 # the CLI
$out/share/acdev/hooks/acdev.{bash,zsh,fish}   # auto-handoff hooks
```

Build it from the repo root (Apple silicon macOS only):

```bash
flox build acdev        # → ./result-acdev
./result-acdev/bin/acdev --help
```

A ready-to-use **example environment** under `example/` consumes that build: it
puts `acdev` on PATH and registers the hooks in its `[profile]`. After building:

```bash
flox activate -d example          # acdev on PATH + hooks active
cd example/demo-project           # has .applecontainer.toml → auto-handoff fires
```

`cd`-ing into `example/demo-project` (which ships an `.applecontainer.toml`)
triggers `acdev up && acdev shell` and drops you into the container. The example
manifest references the build output at `../result-acdev`, so run `flox build
acdev` first; re-activate if you rebuild.

## Use

1. Run `acdev init` in a project root to generate a starter `.applecontainer.toml`
   (or copy one from `examples/`).
2. `cd` into it → you're dropped into the container shell.
3. Exit the shell → the container keeps running; next `cd` is instant.

Manual commands:

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

## Development

```bash
flox activate -- bats tests/          # run the suite
flox activate -- shellcheck bin/acdev # lint
```
