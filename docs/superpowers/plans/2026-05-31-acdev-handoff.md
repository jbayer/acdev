# acdev — cd→Container-Shell Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `acdev`, a bash CLI plus shell hooks that transparently drop you into a Flox-activated, per-project container shell (via Apple's `container` CLI) when you `cd` into a directory containing `.applecontainer.toml`.

**Architecture:** A single bash orchestrator script (`bin/acdev`) shells out to `apple/container`. It parses a minimal `.applecontainer.toml`, derives a stable per-project container name, and implements idempotent `up`/`shell`/`status`/`down`. A thin shell hook (zsh/bash/fish) calls `acdev up && acdev shell` on directory change. The container is kept alive by a `sleep infinity` keepalive so the interactive `exec` shell can be entered, exited, and re-entered cheaply.

**Tech Stack:** Bash, Apple `container` CLI, Flox (for the dev/test environment + for the in-container environment), `bats-core` (shell test framework), `shellcheck` (lint).

**Spec:** `docs/superpowers/specs/2026-05-31-apple-container-devcontainer-handoff-design.md`

---

## File Structure

- `bin/acdev` — the orchestrator CLI (all logic lives here).
- `hooks/acdev.zsh`, `hooks/acdev.bash`, `hooks/acdev.fish` — shell hook snippets.
- `examples/.applecontainer.toml` — sample config.
- `tests/helpers/fake-container` — fake `container` binary that records argv and emits canned output, driven by env vars.
- `tests/helpers/common.bash` — shared test setup (puts `bin/` and the fake on `PATH`, makes a temp workspace).
- `tests/config.bats`, `tests/up.bats`, `tests/shell.bats`, `tests/status.bats`, `tests/down.bats`, `tests/preflight.bats`, `tests/hook.bats` — tests.
- `.flox/` — Flox dev environment providing `bats`, `shellcheck`.
- `README.md` — install, usage, and the manual integration/demo checklist.

**Testing model:**
- `bin/acdev --dry-run <cmd>` prints the exact `container ...` command(s) to **stdout** (human status goes to **stderr**), so command-construction and config-parsing are asserted with no VM.
- `tests/helpers/fake-container` simulates container state (absent/stopped/running) so the up/reuse/restart/down state machine is tested end-to-end with no VM.
- Real Apple Container behavior is validated by a **manual** checklist (Task 11) since it requires macOS 26 on Apple silicon.

---

## Task 1: Repo scaffold + Flox test environment

**Files:**
- Create: `.flox/` (via `flox init` + installs)
- Create: `.gitignore`
- Create: `tests/helpers/common.bash`
- Test: `tests/smoke.bats`

- [ ] **Step 1: Create the Flox dev/test environment**

Run:
```bash
flox init
flox install bats shellcheck
```
Expected: `.flox/env/manifest.toml` created; `flox list` shows `bats` and `shellcheck`.

- [ ] **Step 2: Add a .gitignore**

Create `.gitignore`:
```gitignore
# Flox runtime artifacts
.flox/run/
.flox/cache/
# Test scratch
tests/.tmp/
```

- [ ] **Step 3: Write the shared test helper**

Create `tests/helpers/common.bash`:
```bash
# Shared bats setup. Source from each test file's setup().
# Puts bin/ and the fake container on PATH ahead of the real one,
# and creates an isolated temp workspace per test.

setup_acdev() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FAKE_DIR="$REPO_ROOT/tests/helpers"
  # bin/ first (acdev), then fake-container dir (shadows real `container`)
  PATH="$REPO_ROOT/bin:$FAKE_DIR:$PATH"
  export PATH

  # Where the fake container records its invocations.
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/acdev-test.XXXXXX")"
  export ACDEV_FAKE_LOG="$WORK/calls.log"
  : >"$ACDEV_FAKE_LOG"

  # A throwaway project directory we cd into.
  PROJECT="$WORK/myproject"
  mkdir -p "$PROJECT"
  cd "$PROJECT" || return 1
}

teardown_acdev() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}
```

- [ ] **Step 4: Write the smoke test (failing)**

Create `tests/smoke.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

@test "acdev --help prints usage and exits 0" {
  run acdev --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: acdev"* ]]
}

@test "acdev with no args prints usage and exits non-zero" {
  run acdev
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: acdev"* ]]
}
```

- [ ] **Step 5: Run the smoke test to verify it fails**

Run: `flox activate -- bats tests/smoke.bats`
Expected: FAIL — `acdev: command not found` (bin/acdev doesn't exist yet).

- [ ] **Step 6: Create the minimal acdev skeleton**

Create `bin/acdev` (and `chmod +x bin/acdev`):
```bash
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: acdev <command> [options]

Commands:
  up        Create or reuse this project's container
  shell     Enter the project's container shell
  status    Show the project's container state
  down      Stop the project's container (--rm to also remove)

Options:
  --dry-run   Print the container commands instead of running them
  --help      Show this help

A project is any directory containing .applecontainer.toml.
EOF
}

main() {
  if [ "$#" -eq 0 ]; then
    usage >&2
    return 2
  fi
  case "$1" in
    --help|-h) usage; return 0 ;;
    *) usage >&2; return 2 ;;   # real dispatch added in later tasks
  esac
}

main "$@"
```

Then run: `chmod +x bin/acdev`

- [ ] **Step 7: Run the smoke test to verify it passes**

Run: `flox activate -- bats tests/smoke.bats`
Expected: PASS (2 tests).

- [ ] **Step 8: Commit**

```bash
git add .flox .gitignore bin/acdev tests/helpers/common.bash tests/smoke.bats
git commit -m "feat(acdev): scaffold CLI skeleton + bats test env"
```

---

## Task 2: Config parsing + `up --dry-run` command construction

**Files:**
- Modify: `bin/acdev`
- Test: `tests/config.bats`

This task adds: TOML subset parsing, defaults, stable container naming, and the `container run` command emitted by `up --dry-run`. State logic comes in Task 3.

- [ ] **Step 1: Write the failing tests**

Create `tests/config.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

write_config() { printf '%s\n' "$@" >"$PROJECT/.applecontainer.toml"; }

@test "up --dry-run builds the run command from config" {
  write_config \
    'image = "jbayer/devcontainer-flox:1.12.1"' \
    'user = "flox"' \
    'workspace = "/workspaces/container"'
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"container run -d"* ]]
  [[ "$output" == *"--name acdev-myproject-"* ]]
  [[ "$output" == *"-v $PROJECT:/workspaces/container"* ]]
  [[ "$output" == *"-w /workspaces/container"* ]]
  [[ "$output" == *"--user flox"* ]]
  [[ "$output" == *"jbayer/devcontainer-flox:1.12.1 sleep infinity"* ]]
}

@test "workspace defaults to /workspaces/<basename> when omitted" {
  write_config 'image = "img:1"'
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"-w /workspaces/myproject"* ]]
  [[ "$output" == *"-v $PROJECT:/workspaces/myproject"* ]]
}

@test "user is omitted from run command when not set" {
  write_config 'image = "img:1"'
  run acdev up --dry-run
  [[ "$output" != *"--user"* ]]
}

@test "env table becomes -e KEY=VAL flags" {
  write_config 'image = "img:1"' '[env]' 'FOO = "bar"' 'BAZ = "qux"'
  run acdev up --dry-run
  [[ "$output" == *"-e FOO=bar"* ]]
  [[ "$output" == *"-e BAZ=qux"* ]]
}

@test "missing image is a clear error" {
  write_config 'user = "flox"'
  run acdev up --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"image"* ]]
}

@test "missing .applecontainer.toml is a clear error" {
  run acdev up --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *".applecontainer.toml"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flox activate -- bats tests/config.bats`
Expected: FAIL (dispatch falls through to usage; no run command emitted).

- [ ] **Step 3: Implement config parsing + naming + up command construction**

In `bin/acdev`, add these functions **above** `main()`:
```bash
# --- output helpers -------------------------------------------------------
# Human-facing status goes to stderr so stdout carries only emitted commands
# (needed for --dry-run assertions).
emit() { printf '%s\n' "$*" >&2; }
die()  { printf 'acdev: %s\n' "$*" >&2; exit 1; }

DRY_RUN=0

# Run a `container` subcommand, or print it under --dry-run.
container_do() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "container $*"
  else
    command container "$@"
  fi
}

# --- config ---------------------------------------------------------------
# Globals populated by resolve_config:
CFG_IMAGE=""; CFG_USER=""; CFG_WORKSPACE=""; CFG_SHELL=""; CFG_FLOX=""
CFG_ENV=()   # array of "KEY=VALUE"

# Strip surrounding double quotes and edge whitespace.
_unquote() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"   # ltrim
  v="${v%"${v##*[![:space:]]}"}"   # rtrim
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "$v"
}

resolve_config() {
  [ -f .applecontainer.toml ] || die "no .applecontainer.toml in $(pwd)"
  local section="" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                      # drop comments
    line="${line#"${line%%[![:space:]]*}"}" # ltrim
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    key="${line%%=*}"; val="${line#*=}"
    key="$(_unquote "$key")"; val="$(_unquote "$val")"
    if [ "$section" = "env" ]; then
      CFG_ENV+=("$key=$val")
    else
      case "$key" in
        image)     CFG_IMAGE="$val" ;;
        user)      CFG_USER="$val" ;;
        workspace) CFG_WORKSPACE="$val" ;;
        shell)     CFG_SHELL="$val" ;;
        flox)      CFG_FLOX="$val" ;;
      esac
    fi
  done < .applecontainer.toml

  [ -n "$CFG_IMAGE" ] || die "config error: 'image' is required in .applecontainer.toml"
  [ -n "$CFG_SHELL" ] || CFG_SHELL="bash"
  [ -n "$CFG_FLOX" ]  || CFG_FLOX="auto"
  if [ -z "$CFG_WORKSPACE" ]; then
    CFG_WORKSPACE="/workspaces/$(basename "$(pwd -P)")"
  fi
}

# Stable per-project container name: acdev-<basename>-<8 hex of abs path>.
container_name() {
  local abs base hash
  abs="$(pwd -P)"
  base="$(basename "$abs" | tr -c 'A-Za-z0-9_.-' '-')"
  hash="$(printf '%s' "$abs" | shasum -a 256 | cut -c1-8)"
  printf 'acdev-%s-%s' "$base" "$hash"
}
```

Then replace the body of `cmd_up`'s precursor by adding a `cmd_up` function (state logic is a stub for now — just emit the create command):
```bash
cmd_up() {
  resolve_config
  local name; name="$(container_name)"
  local args=(run -d --name "$name" -v "$(pwd -P):$CFG_WORKSPACE" -w "$CFG_WORKSPACE")
  [ -n "$CFG_USER" ] && args+=(--user "$CFG_USER")
  local kv
  for kv in "${CFG_ENV[@]:-}"; do
    [ -n "$kv" ] && args+=(-e "$kv")
  done
  args+=("$CFG_IMAGE" sleep infinity)
  container_do "${args[@]}"
}
```

Update `main()` to parse `--dry-run` and dispatch `up`:
```bash
main() {
  local cmd="" rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; return 0 ;;
      up|shell|status|down) cmd="$1" ;;
      *) rest+=("$1") ;;
    esac
    shift
  done
  case "$cmd" in
    up) cmd_up "${rest[@]:-}" ;;
    "") usage >&2; return 2 ;;
    *)  usage >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Run to verify pass**

Run: `flox activate -- bats tests/config.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Lint**

Run: `flox activate -- shellcheck bin/acdev`
Expected: no errors (warnings about `${CFG_ENV[@]:-}` are acceptable; fix any actual errors).

- [ ] **Step 6: Commit**

```bash
git add bin/acdev tests/config.bats
git commit -m "feat(acdev): parse .applecontainer.toml and build run command"
```

---

## Task 3: State machine — create / restart / reuse via fake container

**Files:**
- Create: `tests/helpers/fake-container`
- Modify: `bin/acdev`
- Test: `tests/up.bats`

- [ ] **Step 1: Write the fake container binary**

Create `tests/helpers/fake-container` (and `chmod +x`):
```bash
#!/usr/bin/env bash
# Test double for Apple's `container` CLI.
# - Records argv (one line per call) to $ACDEV_FAKE_LOG.
# - Simulates state via $ACDEV_FAKE_STATE: absent | stopped | running.
#   `container ls`        lists RUNNING containers only.
#   `container ls --all`  lists ALL containers (running + stopped).
# The "name" reported is taken from $ACDEV_FAKE_NAME if set.
set -euo pipefail
echo "$*" >>"${ACDEV_FAKE_LOG:-/dev/null}"

state="${ACDEV_FAKE_STATE:-absent}"
name="${ACDEV_FAKE_NAME:-}"

case "$1" in
  ls)
    all=0; [[ "$*" == *"--all"* ]] && all=1
    case "$state" in
      running)              [ -n "$name" ] && echo "$name 192.168.64.42 running" ;;
      stopped) [ "$all" = 1 ] && { [ -n "$name" ] && echo "$name - stopped"; } ;;
      absent)  : ;;
    esac
    ;;
  *) : ;;   # run/start/stop/exec/etc. just get logged
esac
exit 0
```

Make the fake the resolved `container` for tests by symlinking the expected name next to it:
```bash
ln -s fake-container tests/helpers/container
```
(`common.bash` already puts `tests/helpers` on `PATH`, so `container` resolves to this fake.)

- [ ] **Step 2: Write the failing tests**

Create `tests/up.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "absent container is created" {
  export ACDEV_FAKE_STATE=absent
  run acdev up
  [ "$status" -eq 0 ]
  grep -q "^run -d --name acdev-myproject-" "$ACDEV_FAKE_LOG"
  [[ "$output" == *"created"* ]]
}

@test "stopped container is restarted, not recreated" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=stopped ACDEV_FAKE_NAME="$name"
  run acdev up
  [ "$status" -eq 0 ]
  grep -q "^start $name" "$ACDEV_FAKE_LOG"
  ! grep -q "^run -d" "$ACDEV_FAKE_LOG"
  [[ "$output" == *"restarted"* ]]
}

@test "running container is reused (no run, no start)" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev up
  [ "$status" -eq 0 ]
  ! grep -q "^run -d" "$ACDEV_FAKE_LOG"
  ! grep -q "^start " "$ACDEV_FAKE_LOG"
  [[ "$output" == *"reusing"* ]]
}
```

- [ ] **Step 3: Run to verify failure**

Run: `flox activate -- bats tests/up.bats`
Expected: FAIL — `cmd_up` always emits a run command and prints no created/restarted/reusing status.

- [ ] **Step 4: Implement the state machine**

In `bin/acdev`, add a state probe (substring match on the name — robust to column-format changes; the single place to adjust after verifying real `container ls` output):
```bash
# Echoes: running | stopped | absent
container_state() {
  local name="$1"
  if command container ls 2>/dev/null | grep -qw -- "$name"; then
    echo running
  elif command container ls --all 2>/dev/null | grep -qw -- "$name"; then
    echo stopped
  else
    echo absent
  fi
}
```

Replace `cmd_up` with the full state machine:
```bash
cmd_up() {
  resolve_config
  local name; name="$(container_name)"
  emit "🍎 acdev: project '$(basename "$(pwd -P)")'  ($name)"
  emit "   image     $CFG_IMAGE"
  emit "   workspace $(pwd -P) → $CFG_WORKSPACE"

  # Under --dry-run we can't probe a real daemon; just emit the create command.
  if [ "$DRY_RUN" = 1 ]; then
    _up_create "$name"; return 0
  fi

  case "$(container_state "$name")" in
    running)
      emit "✔ reusing running container" ;;
    stopped)
      container_do start "$name" >/dev/null
      emit "✔ restarted container" ;;
    absent)
      _up_create "$name" >/dev/null
      emit "✔ created container" ;;
  esac
}

_up_create() {
  local name="$1"
  local args=(run -d --name "$name" -v "$(pwd -P):$CFG_WORKSPACE" -w "$CFG_WORKSPACE")
  [ -n "$CFG_USER" ] && args+=(--user "$CFG_USER")
  local kv
  for kv in "${CFG_ENV[@]:-}"; do
    [ -n "$kv" ] && args+=(-e "$kv")
  done
  args+=("$CFG_IMAGE" sleep infinity)
  container_do "${args[@]}"
}
```

- [ ] **Step 5: Run to verify pass**

Run: `flox activate -- bats tests/up.bats tests/config.bats`
Expected: PASS (all). The dry-run config tests still pass because `_up_create` emits the same command to stdout.

- [ ] **Step 6: Commit**

```bash
git add tests/helpers/fake-container tests/helpers/container bin/acdev tests/up.bats
git commit -m "feat(acdev): up state machine (create/restart/reuse)"
```

---

## Task 4: `acdev shell` — enter with conditional flox activation

**Files:**
- Modify: `bin/acdev`
- Test: `tests/shell.bats`

`exec` is interactive, so behavior is asserted via `--dry-run` (the emitted `container exec` command).

- [ ] **Step 1: Write the failing tests**

Create `tests/shell.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

@test "shell --dry-run emits exec with flox-conditional entry (flox=auto)" {
  printf 'image = "img:1"\nworkspace = "/workspaces/myproject"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"container exec -it -w /workspaces/myproject acdev-myproject-"* ]]
  [[ "$output" == *'if [ -d .flox ]'* ]]
  [[ "$output" == *"exec flox activate"* ]]
  [[ "$output" == *"exec bash -l"* ]]
}

@test "flox=false never activates flox" {
  printf 'image = "img:1"\nflox = "false"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [[ "$output" != *"flox activate"* ]]
  [[ "$output" == *"exec bash -l"* ]]
}

@test "flox=true always activates flox" {
  printf 'image = "img:1"\nflox = "true"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [[ "$output" == *"exec flox activate"* ]]
  [[ "$output" != *'if [ -d .flox ]'* ]]
}

@test "shell honors a custom shell" {
  printf 'image = "img:1"\nflox = "false"\nshell = "zsh"\n' >.applecontainer.toml
  run acdev shell --dry-run
  [[ "$output" == *"exec zsh -l"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flox activate -- bats tests/shell.bats`
Expected: FAIL — `shell` is not dispatched.

- [ ] **Step 3: Implement `cmd_shell`**

In `bin/acdev`, add:
```bash
# Build the in-container entry command honoring CFG_FLOX and CFG_SHELL.
_entry_script() {
  case "$CFG_FLOX" in
    true)  printf 'exec flox activate' ;;
    false) printf 'exec %s -l' "$CFG_SHELL" ;;
    *)     printf 'if [ -d .flox ]; then exec flox activate; else exec %s -l; fi' "$CFG_SHELL" ;;
  esac
}

cmd_shell() {
  resolve_config
  local name; name="$(container_name)"
  emit "→  entering shell (flox: $CFG_FLOX)"
  ACDEV_INSIDE=1 container_do exec -it -w "$CFG_WORKSPACE" "$name" \
    "$CFG_SHELL" -lc "ACDEV_INSIDE=1; $(_entry_script)"
}
```

Add `shell)` to the dispatch `case` in `main()`:
```bash
    shell)  cmd_shell "${rest[@]:-}" ;;
```

- [ ] **Step 4: Run to verify pass**

Run: `flox activate -- bats tests/shell.bats`
Expected: PASS (4 tests).

Note: the emitted exec runs `<shell> -lc "ACDEV_INSIDE=1; <entry>"`. The `ACDEV_INSIDE=1` assignment marks the session; `exec` then replaces it with the interactive shell. Verify the test substrings (`exec flox activate`, `exec bash -l`, `if [ -d .flox ]`) are all present.

- [ ] **Step 5: Lint + commit**

```bash
flox activate -- shellcheck bin/acdev
git add bin/acdev tests/shell.bats
git commit -m "feat(acdev): shell command with conditional flox activation"
```

---

## Task 5: `acdev status`

**Files:**
- Modify: `bin/acdev`
- Test: `tests/status.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/status.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "status reports running and shows the IP" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev status
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"* ]]
  [[ "$output" == *"192.168.64.42"* ]]
  [[ "$output" == *"$name"* ]]
}

@test "status reports absent" {
  export ACDEV_FAKE_STATE=absent
  run acdev status
  [ "$status" -eq 0 ]
  [[ "$output" == *"absent"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flox activate -- bats tests/status.bats`
Expected: FAIL — `status` not dispatched.

- [ ] **Step 3: Implement `cmd_status`**

In `bin/acdev`, add:
```bash
cmd_status() {
  resolve_config
  local name state line ip
  name="$(container_name)"
  state="$(container_state "$name")"
  printf 'project   %s\n' "$(basename "$(pwd -P)")"
  printf 'container %s\n' "$name"
  printf 'state     %s\n' "$state"
  printf 'image     %s\n' "$CFG_IMAGE"
  printf 'workspace %s → %s\n' "$(pwd -P)" "$CFG_WORKSPACE"
  if [ "$state" = running ]; then
    # IP is the 2nd field of the matching `container ls` row.
    line="$(command container ls 2>/dev/null | grep -w -- "$name" | head -n1)"
    ip="$(printf '%s' "$line" | awk '{print $2}')"
    [ -n "$ip" ] && printf 'ip        %s\n' "$ip"
  fi
}
```

Add to dispatch in `main()`:
```bash
    status) cmd_status "${rest[@]:-}" ;;
```

- [ ] **Step 4: Run to verify pass**

Run: `flox activate -- bats tests/status.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add bin/acdev tests/status.bats
git commit -m "feat(acdev): status command"
```

---

## Task 6: `acdev down` (+ `--rm`)

**Files:**
- Modify: `bin/acdev`
- Test: `tests/down.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/down.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "down stops the container" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev down
  [ "$status" -eq 0 ]
  grep -q "^stop $name" "$ACDEV_FAKE_LOG"
  ! grep -q "^rm " "$ACDEV_FAKE_LOG"
}

@test "down --rm stops and removes" {
  name="acdev-myproject-$(printf '%s' "$PROJECT" | shasum -a 256 | cut -c1-8)"
  export ACDEV_FAKE_STATE=running ACDEV_FAKE_NAME="$name"
  run acdev down --rm
  [ "$status" -eq 0 ]
  grep -q "^stop $name" "$ACDEV_FAKE_LOG"
  grep -q "^rm $name" "$ACDEV_FAKE_LOG"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flox activate -- bats tests/down.bats`
Expected: FAIL — `down` not dispatched.

- [ ] **Step 3: Implement `cmd_down`**

In `bin/acdev`, add:
```bash
cmd_down() {
  resolve_config
  local name rm=0 a
  name="$(container_name)"
  for a in "$@"; do [ "$a" = "--rm" ] && rm=1; done
  container_do stop "$name" >/dev/null 2>&1 || true
  emit "✔ stopped $name"
  if [ "$rm" = 1 ]; then
    container_do rm "$name" >/dev/null 2>&1 || true
    emit "✔ removed $name"
  fi
}
```

Add to dispatch in `main()`:
```bash
    down)   cmd_down "${rest[@]:-}" ;;
```

(Note: `--rm` is collected into `rest` by the option loop, so it reaches `cmd_down`.)

- [ ] **Step 4: Run to verify pass**

Run: `flox activate -- bats tests/down.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add bin/acdev tests/down.bats
git commit -m "feat(acdev): down command with --rm"
```

---

## Task 7: Preflight checks (clear errors for Apple Container gotchas)

**Files:**
- Modify: `bin/acdev`
- Test: `tests/preflight.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/preflight.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; printf 'image = "img:1"\n' >.applecontainer.toml; }
teardown() { teardown_acdev; }

@test "missing container binary gives an actionable error" {
  # Shadow PATH so `container` cannot be found, but acdev still can.
  PATH="$REPO_ROOT/bin:/usr/bin:/bin"
  run acdev up
  [ "$status" -ne 0 ]
  [[ "$output" == *"container"* ]]
  [[ "$output" == *"install"* || "$output" == *"not found"* ]]
}

@test "daemon-down is surfaced, not swallowed" {
  export ACDEV_FAKE_STATE=daemon_down
  run acdev up
  [ "$status" -ne 0 ]
  [[ "$output" == *"container system start"* ]]
}
```

Extend `tests/helpers/fake-container` to simulate a down daemon — add this near the top after reading `state`:
```bash
if [ "${ACDEV_FAKE_STATE:-}" = "daemon_down" ]; then
  echo "Cannot connect to the container service" >&2
  exit 1
fi
```

- [ ] **Step 2: Run to verify failure**

Run: `flox activate -- bats tests/preflight.bats`
Expected: FAIL — no preflight; missing binary throws an opaque error and daemon-down isn't translated.

- [ ] **Step 3: Implement preflight**

In `bin/acdev`, add:
```bash
preflight() {
  if ! command -v container >/dev/null 2>&1; then
    die "the 'container' CLI was not found. Install Apple Container (apple/container) and ensure it is on your PATH."
  fi
  # Probe the daemon with a cheap call; translate the common failure.
  if ! command container ls >/dev/null 2>&1; then
    die "cannot reach the container service. Start it with: container system start"
  fi
}
```

Call `preflight` at the start of `cmd_up`, `cmd_status`, and `cmd_down` (NOT under `--dry-run`, and NOT in `cmd_shell` which relies on `up` having run). Guard it:
```bash
# inside cmd_up, after resolve_config and the emit header, before state probe:
  if [ "$DRY_RUN" != 1 ]; then preflight; fi
```
Add the same `[ "$DRY_RUN" != 1 ] && preflight` line at the top of `cmd_status` and `cmd_down` (after `resolve_config`).

- [ ] **Step 4: Run to verify pass**

Run: `flox activate -- bats tests/preflight.bats tests/up.bats tests/status.bats tests/down.bats`
Expected: PASS (all). The fake `container` answers `ls` successfully in normal states, so preflight passes there.

- [ ] **Step 5: Lint + commit**

```bash
flox activate -- shellcheck bin/acdev
git add bin/acdev tests/preflight.bats tests/helpers/fake-container
git commit -m "feat(acdev): preflight checks for missing CLI and down daemon"
```

---

## Task 8: Shell hooks (zsh / bash / fish)

**Files:**
- Create: `hooks/acdev.zsh`, `hooks/acdev.bash`, `hooks/acdev.fish`
- Test: `tests/hook.bats`

- [ ] **Step 1: Write the hook files**

Create `hooks/acdev.zsh`:
```sh
# acdev auto-handoff (zsh). Source from ~/.zshrc:
#   source /path/to/hooks/acdev.zsh
chpwd() {
  if [ -f ".applecontainer.toml" ] && [ -z "$ACDEV_INSIDE" ]; then
    acdev up && ACDEV_INSIDE=1 acdev shell
  fi
}
```

Create `hooks/acdev.bash`:
```sh
# acdev auto-handoff (bash). Source from ~/.bashrc:
#   source /path/to/hooks/acdev.bash
cd() {
  builtin cd "$@" || return
  if [ -f ".applecontainer.toml" ] && [ -z "$ACDEV_INSIDE" ]; then
    acdev up && ACDEV_INSIDE=1 acdev shell
  fi
}
```

Create `hooks/acdev.fish`:
```fish
# acdev auto-handoff (fish). Source from ~/.config/fish/config.fish:
#   source /path/to/hooks/acdev.fish
function __acdev_autostart --on-variable PWD
    if test -f .applecontainer.toml; and test -z "$ACDEV_INSIDE"
        acdev up; and ACDEV_INSIDE=1 acdev shell
    end
end
```

- [ ] **Step 2: Write the failing test**

Create `tests/hook.bats` (tests the bash hook with `acdev` stubbed so nothing real runs):
```bash
setup() {
  load 'helpers/common'; setup_acdev
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Stub acdev to just record calls.
  STUB="$WORK/bin"; mkdir -p "$STUB"
  cat >"$STUB/acdev" <<EOF
#!/usr/bin/env bash
echo "acdev \$*" >>"$WORK/hook.log"
EOF
  chmod +x "$STUB/acdev"
  PATH="$STUB:$PATH"
}
teardown() { teardown_acdev; }

@test "bash hook fires acdev up && shell when marker present" {
  : >"$WORK/hook.log"
  mkdir -p "$WORK/proj"; touch "$WORK/proj/.applecontainer.toml"
  source "$REPO_ROOT/hooks/acdev.bash"
  cd "$WORK/proj"
  grep -q "acdev up" "$WORK/hook.log"
  grep -q "acdev shell" "$WORK/hook.log"
}

@test "bash hook is a no-op without the marker" {
  : >"$WORK/hook.log"
  mkdir -p "$WORK/plain"
  source "$REPO_ROOT/hooks/acdev.bash"
  cd "$WORK/plain"
  [ ! -s "$WORK/hook.log" ]
}

@test "bash hook is suppressed inside a session" {
  : >"$WORK/hook.log"
  mkdir -p "$WORK/proj2"; touch "$WORK/proj2/.applecontainer.toml"
  source "$REPO_ROOT/hooks/acdev.bash"
  ACDEV_INSIDE=1 bash -c 'source "'"$REPO_ROOT"'/hooks/acdev.bash"; cd "'"$WORK"'/proj2"; echo done' >/dev/null
  [ ! -s "$WORK/hook.log" ]
}
```

- [ ] **Step 3: Run to verify failure**

Run: `flox activate -- bats tests/hook.bats`
Expected: FAIL — hook files don't exist yet (first test) → fix by creating them in Step 1 (already done), so this run should actually move FAIL→PASS. If Step 1 is complete, run and confirm PASS; if you wrote the test first, it fails on missing `hooks/acdev.bash`.

- [ ] **Step 4: Run to verify pass**

Run: `flox activate -- bats tests/hook.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add hooks tests/hook.bats
git commit -m "feat(acdev): zsh/bash/fish auto-handoff hooks"
```

---

## Task 9: Example config + full test sweep

**Files:**
- Create: `examples/.applecontainer.toml`
- Test: run the whole suite

- [ ] **Step 1: Write the example config**

Create `examples/.applecontainer.toml`:
```toml
# Drop this file at the root of a project to make it acdev-managed.
# Reuse your existing project image (digest pin recommended).
image = "jbayer/devcontainer-flox:1.12.1@sha256:972c46da0f5e2d80c17d2a8acab1591bf65f3476b0948410ee1db34299314a54"

# Optional (defaults shown):
user      = "flox"                  # exec/run as this user
# workspace = "/workspaces/myproj"  # default: /workspaces/<dir-basename>
shell     = "bash"                  # shell to drop into
flox      = "auto"                  # auto = activate iff .flox/ exists; true/false to force

# [env]
# EXAMPLE = "value"
```

- [ ] **Step 2: Run the entire suite + lint**

Run:
```bash
flox activate -- bats tests/
flox activate -- shellcheck bin/acdev tests/helpers/fake-container
```
Expected: all tests PASS; shellcheck clean (or only acceptable warnings).

- [ ] **Step 3: Commit**

```bash
git add examples/.applecontainer.toml
git commit -m "docs(acdev): add example .applecontainer.toml"
```

---

## Task 10: README — install, usage, demo script

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

Create `README.md`:
```markdown
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

## Use

1. Drop `.applecontainer.toml` at a project root (see `examples/`).
2. `cd` into it → you're dropped into the container shell.
3. Exit the shell → the container keeps running; next `cd` is instant.

Manual commands:

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(acdev): README with install, usage, and how-it-works"
```

---

## Task 11: Manual integration verification (real Apple Container)

**This task is MANUAL** — it requires macOS 26 on Apple silicon with `apple/container`
installed and the `jbayer/devcontainer-flox` image available for linux/arm64. It cannot
run in CI. Record results in the PR / a scratch note.

- [ ] **Step 1: Verify CLI surface against the installed version**

Run and confirm the flags the script uses exist:
```bash
container --version
container run --help     # -d, --name, -v, -w, --user, -e
container exec --help    # -it, -w
container ls --help      # --all; confirm running-only vs --all behavior
container start --help
container stop --help
```
If any flag differs, update `bin/acdev` (state probe is isolated in `container_state`).

- [ ] **Step 2: Confirm the image runs**

```bash
container run --rm jbayer/devcontainer-flox:1.12.1 bash -lc 'flox --version && sleep 0.1'
```
Expected: prints a Flox version. If it fails on architecture, note the linux/arm64
requirement and pick an arm64-capable image/tag.

- [ ] **Step 3: End-to-end handoff**

```bash
mkdir -p /tmp/acdev-demo && cd /tmp/acdev-demo
cp /path/to/repo/examples/.applecontainer.toml .
flox init   # so .flox/ exists and auto-activation triggers
acdev up
acdev shell   # expect: inside container, flox-activated; `pwd` is the workspace mount
```
Inside the shell, verify: `echo "$ACDEV_INSIDE"` is `1`; a file created on the host
in `/tmp/acdev-demo` is visible, and vice versa (virtiofs read-write sanity).

- [ ] **Step 4: Reuse + status + teardown**

```bash
exit                 # leave the shell
acdev up             # expect: "reusing running container"
acdev status         # expect: running + an IP (e.g. 192.168.64.x)
acdev down --rm      # expect: stopped + removed
```

- [ ] **Step 5: Hook smoke test**

With the hook sourced in your real shell, `cd /tmp/acdev-demo` and confirm you are
dropped into the container shell automatically; `exit` returns you to the host.

- [ ] **Step 6: Record findings**

Note any deviations (flag names, `container ls` format, virtiofs quirks, Local
Network permission prompts) and fold fixes back into `bin/acdev`.

---

## Notes for the implementer

- **stdout vs stderr discipline:** human status uses `emit` → stderr; `container_do`
  under `--dry-run` prints the command to stdout. Tests assert on combined output
  (bats `$output` merges them), but keep the split so piping `--dry-run` stays clean.
- **`set -euo pipefail`:** when iterating `"${CFG_ENV[@]:-}"`, the `:-` guard avoids
  unbound-variable errors on empty arrays. Keep it.
- **The state probe is the single risk point.** `container_state` greps the container
  name out of `container ls` / `container ls --all`. If the real CLI's output doesn't
  contain the bare name as a word, that's the one function to adjust (Task 11, Step 1).
- **Don't add features beyond the plan** (credentials, agent auto-launch, ports) —
  they're deliberately deferred in the spec.
```
