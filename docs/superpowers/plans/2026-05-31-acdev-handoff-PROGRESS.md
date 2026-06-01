# acdev handoff — execution progress (resume here)

**Branch:** `feat/acdev-handoff`
**Plan:** `docs/superpowers/plans/2026-05-31-acdev-handoff.md`
**Spec:** `docs/superpowers/specs/2026-05-31-apple-container-devcontainer-handoff-design.md`
**Execution method:** superpowers:subagent-driven-development (fresh subagent per task; spec review then code-quality review after each).

## Status as of pause (2026-05-31)

| Task | State |
|------|-------|
| T1 Scaffold CLI + Flox test env | ✅ DONE — spec ✅, code-quality ✅. Commit `08b5ec5` (+ `e0b64b0` flox metadata) |
| T2 Config parsing + `up --dry-run` | 🟡 Code committed (`fc8e9ac`), spec review ✅ PASSED. **Code-quality review NOT yet run.** |
| T3 up state machine + fake container | ⬜ not started |
| T4 shell command + flox activation | ⬜ not started |
| T5 status command | ⬜ not started |
| T6 down command (+ --rm) | ⬜ not started |
| T7 preflight checks | ⬜ not started |
| T8 shell hooks (zsh/bash/fish) | ⬜ not started |
| T9 example config + full sweep | ⬜ not started |
| T10 README | ⬜ not started |
| T11 manual integration verification | ⬜ USER-RUN (needs real macOS 26 + Apple Container + the image) |

## Exact resume point

1. Run the **code-quality review for T2** (diff `e0b64b0..fc8e9ac`). T2's spec review already passed; only the quality gate remains before T2 is complete.
2. Then proceed T3 → T10 normally: implementer subagent → spec review → code-quality review → next.
3. T11 is manual — hand the checklist to the user; do not automate.

## How tests run

`flox activate -- bats tests/<file>` and `flox activate -- shellcheck bin/acdev`.
The Flox env already has `bats` + `shellcheck` (committed in manifest). Do NOT `flox init`.

## Notes / decisions carried forward

- macOS default bash is 3.2 — keep `bin/acdev` 3.2-compatible.
- macOS `/private` symlink: `tests/helpers/common.bash` canonicalizes `$PROJECT` with `pwd -P` so mount-path assertions match.
- Config source is `.applecontainer.toml` at project root (NOT devcontainer.json) — deliberate.
- Deferred to post-v1 (do not build): credential mounting, agent auto-launch, port forwarding, lifecycle hooks.
- `container_state` (T3) greps the container name out of `container ls` / `container ls --all` — the single place to adjust after verifying real CLI output (T11 step 1).
