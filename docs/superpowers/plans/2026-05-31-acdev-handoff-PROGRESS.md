# acdev handoff — execution progress (resume here)

**Branch:** `feat/acdev-handoff`
**Plan:** `docs/superpowers/plans/2026-05-31-acdev-handoff.md`
**Spec:** `docs/superpowers/specs/2026-05-31-apple-container-devcontainer-handoff-design.md`
**Execution method:** superpowers:subagent-driven-development (fresh subagent per task; spec review then code-quality review after each).

## Status as of 2026-06-01 — implementation COMPLETE (T1–T10)

| Task | State |
|------|-------|
| T1 Scaffold CLI + Flox test env | ✅ DONE — spec ✅, code-quality ✅. Commit `08b5ec5` (+ `e0b64b0` flox metadata) |
| T2 Config parsing + `up --dry-run` | ✅ DONE — code `fc8e9ac`; code-quality fix `(env-array quoting)` committed separately |
| T3 up state machine + fake container | ✅ DONE — incl. `container_name` double-dash fix |
| T4 shell command + flox activation | ✅ DONE |
| T5 status command | ✅ DONE |
| T6 down command (+ --rm) | ✅ DONE |
| T7 preflight checks | ✅ DONE |
| T8 shell hooks (zsh/bash/fish) | ✅ DONE |
| T9 example config + full sweep | ✅ DONE — 24/24 bats pass, shellcheck clean |
| T10 README | ✅ DONE |
| T11 real Apple Container integration verification | ✅ DONE — verified on macOS 26 / Apple silicon, `container` v0.12.3. One fix folded in (`cmd_status` IP column) + fake updated to match real `container ls`. See "Task 11 results" below. |

**Full suite: 24/24 bats pass; `shellcheck bin/acdev tests/helpers/fake-container` clean.**

## Task 11 results — real Apple Container integration (verified 2026-05-31)

Ran on macOS 26 / Apple silicon against the real `container` CLI **v0.12.3**
(build f989901) with image `jbayer/devcontainer-flox:1.12.1` (linux/arm64).

### CLI surface — all assumed flags exist and behave as encoded
- `container run`: `-d/--detach`, `--name`, `-v/--volume`, `-w/--workdir`, `-u/--user`, `-e/--env` ✅
- `container exec`: `-i`, `-t`, `-w` (combined `-it` works) ✅
- `container ls` (= `list`): `-a/--all` "Include containers that are not running" ✅
- `container start <name>`, `container stop <name>` ✅
- `container rm <name>` — accepted as an alias for `container delete` ✅

### `container ls` real output (this is the format the fake is now modeled on)
Running:
```
ID                         IMAGE                                      OS     ARCH   STATE    ADDR             CPUS  MEMORY   STARTED
acdev-acdev-demo-f402b9e1  docker.io/jbayer/devcontainer-flox:1.12.1  linux  arm64  running  192.168.64.3/24  4     1024 MB  2026-06-01T04:30:04Z
```
Stopped (only appears under `--all`; ADDR is blank):
```
ID                         IMAGE                                      OS     ARCH   STATE    ADDR  CPUS  MEMORY   STARTED
acdev-acdev-demo-f402b9e1  docker.io/jbayer/devcontainer-flox:1.12.1  linux  arm64  stopped        4     1024 MB  2026-06-01T04:30:04Z
```
- **9 columns, with a header row.** ID (col 1) is the `--name`, full & untruncated.
- **ADDR is column 6** and carries a **`/24` CIDR suffix**.
- **`ls` lists running only; `--all` adds stopped** — the single biggest assumption: **CONFIRMED**.

### Assumption check on the two isolated functions
- **`container_state()` — NO CHANGE.** `grep -qw -- "$name"` matches the full name in
  col 1; header row doesn't contain the name; running→in `ls`, stopped→only in `ls --all`,
  absent→neither. All three transitions exercised live (create→stop→restart).
- **`cmd_status()` IP parse — FIXED.** Old code read `awk '{print $2}'`, which is the
  **IMAGE** column (live bug observed: `ip docker.io/jbayer/devcontainer-flox:1.12.1`).
  IP/ADDR is **field 6**; changed to `awk '{print $6}'` and strip the CIDR suffix
  (`${ip%%/*}`). Verified live: `ip  192.168.64.4`.
- **`tests/helpers/fake-container` — UPDATED** to emit the real 9-column table (header +
  ADDR in col 6 with `/24`, blank ADDR when stopped). Fake stays the contract; 24/24 bats
  still green, shellcheck clean.

### End-to-end (throwaway project in /tmp/acdev-demo)
- `acdev up --dry-run` printed the exact `container run …` — eyeballed, correct.
- `acdev up` → created; `acdev up` again → "reusing running container"; stop + `acdev up` → "restarted".
- **virtiofs is two-way:** host-written file readable in container, container-written file readable on host.
- **flox is on PATH inside the image** at `/usr/bin/flox` (v1.12.1); `auto` mode activates because `.flox/` exists.
- `acdev status` → running + clean IP; `acdev down --rm` → stopped + removed; container gone from `ls --all`.
- **Hook smoke test (real pty):** sourcing `hooks/acdev.bash` and `cd`-ing into the project
  auto-ran `up` + `shell` and dropped into the container (`uname` → `Linux … aarch64`,
  `pwd` → `/workspaces/acdev-demo`).

### Gotchas observed
- **`/tmp` → `/private/tmp`:** `pwd -P` canonicalized the demo to `/private/tmp/acdev-demo`
  for both the mount path and the name hash, as designed.
- **Local Network prompt:** not triggered — interaction was via `container exec`, not by
  connecting to a container service by IP, so the macOS prompt never came up. (Expect it the
  first time a service is reached by its `192.168.64.x` address.)
- **Minor, not fixed (out of T11 scope):** inside the container `echo "$ACDEV_INSIDE"` is
  empty because the entry script `exec`s `flox activate` and the unexported `ACDEV_INSIDE=1`
  doesn't survive the re-exec. Harmless — that var only guards the *host* hook from
  re-triggering, and the container shell never sources the host hook. Lives in `cmd_shell`'s
  entry script, outside the two functions T11 scoped for changes; left as-is.

## Code-quality findings folded in during this pass

1. **T2 env-array quoting** — `for kv in ${CFG_ENV[@]:-}` (unquoted, SC2068 suppressed)
   word-split env *values* with spaces. Restored the plan's quoted
   `"${CFG_ENV[@]:-}"` + `[ -n "$kv" ]` guard. Latent (fixtures had no spaces).
2. **T3 container_name double dash** — `basename`'s trailing newline was mapped to
   `-` by `tr` before command-substitution could strip it, yielding
   `acdev-<name>--<hash>`. Now `printf '%s' "$(basename …)" | tr …`. This is what
   the test name assertions (single dash) actually require.

## Exact resume point

**All tasks T1–T11 complete.** T11 was run on real macOS 26 / Apple silicon against
`container` v0.12.3 (see "Task 11 results" above). One fix folded in (`cmd_status` IP
column → field 6, strip CIDR) plus `tests/helpers/fake-container` updated to the real
`container ls` format. `container_state` needed no change. Branch stays **local** — not
pushed, no PR (per the resume note's guardrail).

## How tests run

`flox activate -- bats tests/<file>` and `flox activate -- shellcheck bin/acdev`.
The Flox env already has `bats` + `shellcheck` (committed in manifest). Do NOT `flox init`.

## Notes / decisions carried forward

- macOS default bash is 3.2 — keep `bin/acdev` 3.2-compatible.
- macOS `/private` symlink: `tests/helpers/common.bash` canonicalizes `$PROJECT` with `pwd -P` so mount-path assertions match.
- Config source is `.applecontainer.toml` at project root (NOT devcontainer.json) — deliberate.
- Deferred to post-v1 (do not build): credential mounting, agent auto-launch, port forwarding, lifecycle hooks.
- `container_state` (T3) greps the container name out of `container ls` / `container ls --all` — the single place to adjust after verifying real CLI output (T11 step 1).
