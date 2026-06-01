# acdev — seamless cd→container-shell handoff on macOS with Apple Container

`cd` into a project that has an `.applecontainer.toml` and you land in a
Flox-activated shell **inside** a hardware-isolated Apple Container — no Docker,
no Dev Containers extension. This recreates the devcontainer-flox workflow using
Apple's native `container` CLI (Path B: direct CLI orchestration).

`acdev` ships as a **Flox package** (`[build.acdev]`): one build bundles the CLI
and all three shell hooks, and a ready-to-run **example environment** under
`example/` demonstrates the whole flow.

## Requirements

- Apple silicon Mac, macOS 26 (Tahoe).
- [`apple/container`](https://github.com/apple/container) installed and running
  (`container system start`).
- [Flox](https://flox.dev) on the host — the supported way to build, install, and
  run `acdev`.

## Quick start (Flox)

Build the package and try the bundled example environment:

```bash
flox build acdev                  # → ./result-acdev (bundles CLI + hooks)
flox activate -d example          # puts acdev on PATH, registers the hooks
cd example/demo-project           # ships an .applecontainer.toml → handoff fires
```

`cd`-ing into `example/demo-project` triggers `acdev up && acdev shell` and drops
you into the container. Exit the shell and the container keeps running; the next
`cd` back in is instant.

> The example's `[profile]` references the build output at `../result-acdev`, so
> run `flox build acdev` first. Re-activate if you rebuild.

## Use acdev in your own projects (Flox)

The example environment is the template. To make any Flox environment hand off to
Apple Container on `cd`, build the package and wire it into that environment's
`[profile]` — add `acdev` to PATH and source the matching hook:

```toml
# in your environment's .flox/env/manifest.toml
[profile]
bash = '''
  _acdev_pkg="/abs/path/to/acdev/result-acdev"     # output of `flox build acdev`
  export PATH="$_acdev_pkg/bin:$PATH"
  . "$_acdev_pkg/share/acdev/hooks/acdev.bash"
'''
# zsh / fish: same idea, sourcing acdev.zsh / acdev.fish
```

See `example/.flox/env/manifest.toml` for the full bash/zsh/fish version.

Then, in any project you want managed:

```bash
acdev init        # write a starter .applecontainer.toml (no-op if one exists)
cd <that project> # → dropped into the container shell
```

> A future `flox publish` will make this a one-liner — `flox install jbayer/acdev`
> plus sourcing `$FLOX_ENV/share/acdev/hooks/...` — with no local build step.

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
