# acdev T11 — macOS integration verification (resume here)

**You are resuming on a real macOS 26 / Apple silicon machine to run Task 11**, the
one task that could not run in the Linux dev container. Everything else (T1–T10) is
done, committed, and green (24/24 bats, shellcheck clean).

- **Branch:** `feat/acdev-handoff` (commits not yet pushed)
- **Plan:** `docs/superpowers/plans/2026-05-31-acdev-handoff.md` — Task 11 has the checklist
- **Progress:** `docs/superpowers/plans/2026-05-31-acdev-handoff-PROGRESS.md`
- **The CLI:** `bin/acdev` (single bash script, all logic). macOS default bash is 3.2 — keep it 3.2-compatible.

## What T11 is for

The whole suite runs against a **fake** `container` binary (`tests/helpers/fake-container`)
that emulates absent/stopped/running and canned `container ls` output. T11 replaces that
fake with the **real Apple `container` CLI** to confirm the assumptions the fake encodes
actually hold. Nothing about the real daemon has been observed yet — treat every flag and
output format as unverified until you see it.

## Run order

1. **Preflight the environment** (not the script): `container --version`, `container system start`.
2. **Verify CLI surface** — Task 11 Step 1. Confirm these flags exist and behave as assumed:
   - `container run`: `-d --name -v -w --user -e`, and `<image> sleep infinity` as the keepalive.
   - `container exec`: `-it -w`.
   - `container ls` vs `container ls --all`: confirm **`ls` lists running only** and **`--all` includes stopped**. This is the single biggest assumption.
   - `container start <name>`, `container stop <name>`, `container rm <name>`.
3. **Preview without side effects first:** `acdev up --dry-run` in a throwaway project prints the exact `container run …` it would execute. Eyeball it before running for real.
4. Work through Task 11 Steps 2–6 (image runs → end-to-end handoff → reuse/status/teardown → hook smoke test → record findings).

## The two functions most likely to need a fix

Both are isolated on purpose — if real output differs, these are the only places to touch:

1. **`container_state()`** (`bin/acdev`) — decides running/stopped/absent by
   `container ls | grep -qw -- "$name"` and `container ls --all | grep -qw …`.
   If the real `ls` doesn't print the bare container name as a whole word (e.g. it
   truncates, adds a prefix, or only shows an ID), adjust the grep/parse here.
   `-qw` requires the name to appear as a word — verify that against real output.
2. **`cmd_status()` IP parse** — takes the **2nd whitespace field** of the matching
   `container ls` row (`awk '{print $2}'`). If the real columns differ (IP in a
   different position, or only shown via `container inspect`), fix the extraction here.

If you change either, **also update `tests/helpers/fake-container`** so its canned
output matches the real format, then re-run `flox activate -- bats tests/` to keep the
suite honest. The fake is the contract; keep it faithful to what you observed.

## Gotchas to watch for (from the spec/notes)

- **virtiofs mount:** confirm host↔container file changes propagate both ways in the
  workspace mount (`-v "$(pwd -P):$CFG_WORKSPACE"`).
- **`pwd -P`:** macOS `/tmp` is a symlink to `/private/tmp`. The script canonicalizes
  with `pwd -P` so the mount path and the name hash are stable — if you demo in `/tmp`,
  expect the real path to be `/private/tmp/...`.
- **Local Network permission:** reaching container services by IP may trigger a macOS
  Local Network prompt the first time. Note it if it happens.
- **`flox activate` inside the container:** the `auto` mode runs `if [ -d .flox ]; then
  exec flox activate; else exec <shell> -l; fi`. Confirm flox is on PATH inside the image.

## When done

- Fold any fixes into `bin/acdev` (+ fake-container + tests), re-run the full suite + shellcheck.
- Record observed real-CLI output (especially `container ls` format) in the PROGRESS doc —
  it's the reference the fake is modeled on.
- Tick Task 11's checkboxes in the plan. Mark T11 ✅ in the PROGRESS table.
- **Do not push or open a PR without asking the user** — the branch is intentionally local.

## How tests + lint run

```
flox activate -- bats tests/
flox activate -- shellcheck bin/acdev tests/helpers/fake-container
```
Do NOT `flox init` — the env already has `bats` + `shellcheck`.
