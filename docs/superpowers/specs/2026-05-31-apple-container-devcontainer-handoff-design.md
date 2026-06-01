# Design: `acdev` — Seamless `cd`→Container-Shell Handoff with Apple Container

**Date:** 2026-05-31
**Status:** Approved (design) — pending spec review
**Author:** James Bayer (with Claude Code)

## Summary

A demonstration of orchestrating AI-agentic development on macOS using Apple's
native `container` CLI (the `apple/container` project) as a Docker-free sandbox.
It recreates the *feel* of the Docker + Dev Containers workflow from
[`jbayer/devcontainer-flox`](https://github.com/jbayer/devcontainer-flox): you
`cd` into a project directory in a normal macOS terminal and are transparently
dropped into a shell **inside** a hardware-isolated container, with the project
directory mounted and the Flox environment activated.

This is **Path B** (native CLI orchestration), deliberately *not* an attempt to
make Apple Container speak the Dev Container spec — `apple/container` does not
implement the Docker daemon API and the upstream dev-container request
([apple/container#84](https://github.com/apple/container/issues/84)) was closed
as "not planned." We orchestrate the `container` CLI directly.

## Goals (v1)

- **Seamless handoff:** `cd` into a directory containing `.applecontainer.toml`
  → land in a container shell, via a shell hook. This is the core deliverable.
- **Reuse a per-project container:** start if absent, restart if stopped, attach
  if already running. Re-entry is fast and stateful.
- **Clear, devcontainer-style status output:** image, mount, created/reused,
  success/failure with actionable errors (not raw stack traces).
- **Auto-activate Flox:** if the workspace has a `.flox/` directory, run
  `flox activate` on shell entry.

## Non-goals (deferred)

- Parsing `devcontainer.json` (would imply spec support Apple Container lacks).
- Credential mounting (SSH agent, git identity) — designed around later; v1 skips it.
- Auto-launching an AI agent (e.g. Claude Code) on entry.
- Port publishing / `forwardPorts` (reach services by container IP instead).
- Lifecycle commands, Dev Container Features, multi-container topologies, Compose.

## Architecture

Three small, independent pieces:

1. **`acdev`** — a standalone bash script on `PATH`. The orchestrator; the only
   place container logic lives. Shells out to Apple's `container` CLI.
   Subcommands: `up`, `shell`, `status`, `down`. Invokable by hand or by the hook.
2. **`.applecontainer.toml`** — per-project config at the workspace root. Its
   presence both configures the container and is the marker the shell hook detects.
3. **Shell hook** — a few lines for zsh/bash/fish that, on `cd` into a directory
   containing `.applecontainer.toml`, run `acdev up && acdev shell`, guarded so it
   will not re-trigger from inside a session.

### Data flow

```
cd <project>
  └─ hook sees .applecontainer.toml (and ACDEV_INSIDE unset)
       └─ acdev up      → create-or-reuse the project's container
            └─ acdev shell → container exec -it … (flox activate if .flox/ present)
                 └─ you are now in the sandboxed shell
exit
  └─ back on host; container keeps running → next entry is instant
```

### Two-process model (why a keepalive is needed)

A container lives exactly as long as its **main process** runs. We launch a
do-nothing keepalive (`sleep infinity`) as that main process via
`container run -d`, so the container stays alive and idle in the background. The
interactive shell is a **separate** process attached later with
`container exec -it`. Exiting the shell ends only the exec session; the keepalive
keeps the container warm, which is what makes per-project reuse work. (This is the
same `overrideCommand → sleep infinity` trick the Docker devcontainer uses under
the hood, made explicit here.)

```
┌─────────────── container (lightweight VM) ───────────────┐
│  main:  sleep infinity   ← keeps it alive (from `up`)     │
│  exec:  flox activate     ← your interactive shell         │
└────────────────────────────────────────────────────────────┘
```

## Component: `.applecontainer.toml`

Per-project config at the workspace root. Minimal — only fields Apple Container
can honor, plus our handoff behavior. The schema can grow into deferred features
without breaking existing files.

```toml
# Required: the OCI image (reuse your existing project image)
image = "jbayer/devcontainer-flox:1.12.1@sha256:972c46da..."

# Optional (defaults shown)
user      = "flox"                  # exec/run as this user
workspace = "/workspaces/container" # mount target for $PWD; default /workspaces/<dir-basename>
shell     = "bash"                  # shell to drop into
flox      = "auto"                  # auto = activate iff .flox/ exists; true/false to force

# Optional environment passed into the container
[env]
# FOO = "bar"
```

Behavioral notes:

- **`$PWD` is bind-mounted** to `workspace` read-write (`-v "$PWD":<workspace>`),
  and `workspace` is the working directory — the analog of the devcontainer
  workspace mount.
- **Container name is derived from the absolute project path**
  (`acdev-<basename>-<shorthash>`), so each project gets one stable, reusable
  container and two projects sharing a basename do not collide.
- `image` is required; everything else has a default.

## Component: `acdev` CLI

### `acdev up` — idempotent create-or-reuse

1. Resolve config from `.applecontainer.toml` in `$PWD`; compute the container
   name from the absolute path.
2. Probe state via `container ls --all`:
   - **Running** → no-op, report "reusing".
   - **Stopped** → `container start <name>`, report "restarted".
   - **Absent** → create:
     ```
     container run -d --name <name> \
       -v "$PWD":<workspace> -w <workspace> \
       [--user <user>] [-e KEY=VAL …] \
       <image> sleep infinity
     ```
     report "created".

### `acdev shell` — enter

Ensure the container is up (invoke `up` logic if needed), then attach:

```
container exec -it -w <workspace> <name> bash -lc '
  if [ -d .flox ]; then exec flox activate; else exec bash -l; fi'
```

- Sets `ACDEV_INSIDE=1` in the session so the hook will not re-trigger and so the
  user can tell at a glance they are sandboxed.
- The `flox` config value overrides the `.flox/`-presence auto-detection when set
  to `true`/`false`.

### `acdev status`

Prints: container name, state (running/stopped/absent), image, workspace mount,
and the container **IP** (from `container ls`) — the reliable way to reach
services on Apple Container.

### `acdev down`

`container stop <name>`; with `--rm`, also `container rm <name>`. The container
otherwise persists across `cd`s by design (this is what makes reuse fast).

### Lifecycle stance

One long-lived container per project, started lazily, never auto-removed. The
user explicitly tears down with `acdev down`.

## Component: shell hook

Installed in the user's shell rc. Triggers on directory change; guarded by
`ACDEV_INSIDE` and the presence of `.applecontainer.toml`.

**zsh:**
```sh
chpwd() {
  if [ -f ".applecontainer.toml" ] && [ -z "$ACDEV_INSIDE" ]; then
    acdev up && ACDEV_INSIDE=1 acdev shell
  fi
}
```

**bash:**
```sh
cd() {
  builtin cd "$@" || return
  if [ -f ".applecontainer.toml" ] && [ -z "$ACDEV_INSIDE" ]; then
    acdev up && ACDEV_INSIDE=1 acdev shell
  fi
}
```

**fish:**
```fish
function __acdev_autostart --on-variable PWD
    if test -f .applecontainer.toml; and test -z "$ACDEV_INSIDE"
        acdev up; and ACDEV_INSIDE=1 acdev shell
    end
end
```

## Status output & error handling

devcontainer-style, prefixed progress with a clear result line per action:

```
🍎 acdev: project 'container'  (acdev-container-9f3a)
   image     jbayer/devcontainer-flox:1.12.1
   workspace /Users/.../container → /workspaces/container
→  creating container…            ✔ created
→  entering shell (flox: active)  ✔
```

On reuse: `✔ reusing running container`. Failures are explicit and actionable.

Apple Container gotchas surfaced explicitly:

- **Not installed / unsupported host** — check `container` exists and we are on
  Apple silicon + macOS 26; otherwise a one-line explanation + pointer.
- **Daemon not started** — if calls fail because the system service is down, tell
  the user to run `container system start`; do not silently fail.
- **Image won't pull / arch mismatch** — surface the pull error; note the
  linux/arm64 requirement.
- **Mount sanity** — after create, verify the workspace mount is readable inside;
  warn on the known virtiofs write-back quirk.
- Port/Local-Network-permission gotcha is out of scope for v1 (no port
  publishing); `acdev status` shows the container IP so services are reached the
  reliable way.

## Testing strategy

- **`--dry-run` flag** on `acdev`: print the exact `container` commands instead of
  running them. Enables fast assertions on config parsing and command
  construction with no VM.
- **Fake `container` shim** on `PATH` (records args) to unit-test the
  up/reuse/down state logic end-to-end without real VMs. Tests in `bats` or plain
  shell.
- **Manual integration checklist** (doubles as the demo script):
  1. `cd` into the project → land in flox-activated shell.
  2. Exit, `cd` in again → "reusing".
  3. `acdev status` → running + IP.
  4. `acdev down` → stopped.

## Risks / assumptions to verify during implementation

`apple/container` is pre-1.0 and fast-moving; verify against the installed version:

- Exact subcommands/flags: `container run -d`, `exec -it`, `start`, `stop`,
  `ls --all`, `--user`, `-w`, `-e`, `--name` — confirm via `--help`.
- `jbayer/devcontainer-flox` is available for **linux/arm64** and runs under
  Apple Container (has `bash`, `sleep`, `flox`).
- How running-vs-stopped state reads out of `container ls`.

## Future extensions (post-v1)

- Credential passthrough (SSH agent, git identity), designed around virtiofs's
  no-single-file-mount limitation (mount parent dirs or copy in).
- Optional auto-launch of an AI agent on entry (e.g. `claude`).
- Lifecycle hooks in `.applecontainer.toml` (e.g. `post_start`).
- Packaging `acdev` itself as a Flox package for easy install.
