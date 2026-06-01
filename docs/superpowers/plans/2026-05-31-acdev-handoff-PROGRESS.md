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
| T11 manual integration verification | ⬜ USER-RUN (needs real macOS 26 + Apple Container + the image) |

**Full suite: 24/24 bats pass; `shellcheck bin/acdev tests/helpers/fake-container` clean.**

## Code-quality findings folded in during this pass

1. **T2 env-array quoting** — `for kv in ${CFG_ENV[@]:-}` (unquoted, SC2068 suppressed)
   word-split env *values* with spaces. Restored the plan's quoted
   `"${CFG_ENV[@]:-}"` + `[ -n "$kv" ]` guard. Latent (fixtures had no spaces).
2. **T3 container_name double dash** — `basename`'s trailing newline was mapped to
   `-` by `tr` before command-substitution could strip it, yielding
   `acdev-<name>--<hash>`. Now `printf '%s' "$(basename …)" | tr …`. This is what
   the test name assertions (single dash) actually require.

## Exact resume point

Only **T11 (manual)** remains — it cannot run here (no macOS 26 / Apple Container /
arm64 image). Hand the checklist in the plan (Task 11) to the user. The single most
likely thing to adjust after T11 is `container_state` (the `container ls` parser) and
the IP field in `cmd_status` once real `container ls` output is known.

## How tests run

`flox activate -- bats tests/<file>` and `flox activate -- shellcheck bin/acdev`.
The Flox env already has `bats` + `shellcheck` (committed in manifest). Do NOT `flox init`.

## Notes / decisions carried forward

- macOS default bash is 3.2 — keep `bin/acdev` 3.2-compatible.
- macOS `/private` symlink: `tests/helpers/common.bash` canonicalizes `$PROJECT` with `pwd -P` so mount-path assertions match.
- Config source is `.applecontainer.toml` at project root (NOT devcontainer.json) — deliberate.
- Deferred to post-v1 (do not build): credential mounting, agent auto-launch, port forwarding, lifecycle hooks.
- `container_state` (T3) greps the container name out of `container ls` / `container ls --all` — the single place to adjust after verifying real CLI output (T11 step 1).
