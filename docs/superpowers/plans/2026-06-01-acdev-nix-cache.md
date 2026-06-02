# acdev shared Nix binary cache — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in transparent Nix binary cache so acdev project containers download Flox/Nix packages once per machine instead of re-fetching from the internet.

**Architecture:** A host-side nginx `proxy_cache` (bundled in the acdev Flox package, run as a `[services]` entry in the example environment) sits in front of `cache.flox.dev` + `cache.nixos.org`. Containers reach it at the host gateway and use it as a preferred Nix substituter, injected by acdev via `-e NIX_CONFIG` when a project sets `nix_cache` in `.applecontainer.toml`.

**Tech Stack:** Bash (`bin/acdev`, 3.2-compatible), nginx, Flox (build + service), bats + shellcheck.

**Spec:** `docs/superpowers/specs/2026-06-01-acdev-nix-cache-design.md`

---

## Verified facts this plan relies on (from the design trace)

- `flox install` honors the Nix `substituters` setting; with the proxy listed as a **preferred** substituter (`?priority=1`) and returning a valid `200 /nix-cache-info`, flox queries it for narinfo. Proven: 5 narinfo GETs hit the proxy.
- `-e NIX_CONFIG="extra-substituters = …"` on `container run` **survives flox** (flox merges it) and is **inherited by `container exec`** sessions. `extra-trusted-substituters` is NOT required (single-user Nix in the container).
- Container reaches the host at `http://192.168.64.1:PORT`. `curl` exists in the image; `wget` does not.

## File Structure

- `bin/acdev` — add `nix_cache` config field (`CFG_NIX_CACHE`) and the `-e NIX_CONFIG` injection in `_up_create`.
- `bin/acdev-nix-cache` — new host-side launcher: renders the nginx template and execs nginx. Bundled in the package.
- `nix-cache/nginx.conf.template` — new nginx `proxy_cache` config with `@PORT@`/`@LISTEN@`/`@CACHE_DIR@` placeholders.
- `tests/nix-cache.bats` — bats for the client injection and the launcher's `--print-config`.
- `.flox/env/manifest.toml` — extend `[build.acdev]` to bundle the launcher + template; bump version.
- `example/.flox/env/manifest.toml` — `[install] nginx` + `[services.nix-cache]`.
- `examples/.applecontainer.toml`, `example/demo-project/.applecontainer.toml` — document `nix_cache` (commented).
- `README.md`, `bin/acdev` usage text — document the feature.

---

## Task 1: Client injection — `nix_cache` → `-e NIX_CONFIG` on `up`

**Files:**
- Modify: `bin/acdev` (`resolve_config`, globals, `_up_create`)
- Test: `tests/nix-cache.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/nix-cache.bats`:
```bash
setup() { load 'helpers/common'; setup_acdev; }
teardown() { teardown_acdev; }

@test "up --dry-run injects NIX_CONFIG when nix_cache is set" {
  printf 'image = "img:1"\nnix_cache = "http://192.168.64.1:8126"\n' >.applecontainer.toml
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"-e NIX_CONFIG=extra-substituters = http://192.168.64.1:8126/flox?priority=1 http://192.168.64.1:8126/nixos?priority=2"* ]]
}

@test "up --dry-run has no NIX_CONFIG when nix_cache is unset" {
  printf 'image = "img:1"\n' >.applecontainer.toml
  run acdev up --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"NIX_CONFIG"* ]]
}

@test "trailing slash on nix_cache is normalized" {
  printf 'image = "img:1"\nnix_cache = "http://192.168.64.1:8126/"\n' >.applecontainer.toml
  run acdev up --dry-run
  [[ "$output" == *"http://192.168.64.1:8126/flox?priority=1"* ]]
  [[ "$output" != *"8126//flox"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flox activate -- bats tests/nix-cache.bats`
Expected: FAIL — `nix_cache` is ignored, no `NIX_CONFIG` emitted.

- [ ] **Step 3: Add the config field**

In `bin/acdev`, add `CFG_NIX_CACHE` to the globals line:
```bash
CFG_IMAGE=""; CFG_USER=""; CFG_WORKSPACE=""; CFG_SHELL=""; CFG_FLOX=""; CFG_NIX_CACHE=""
```
In `resolve_config`, add a case under the non-`env` key dispatch (next to `flox)`):
```bash
        nix_cache) CFG_NIX_CACHE="$val" ;;
```

- [ ] **Step 4: Inject NIX_CONFIG in `_up_create`**

In `bin/acdev`, in `_up_create`, after the `CFG_ENV` loop and before `args+=("$CFG_IMAGE" sleep infinity)`:
```bash
  if [ -n "$CFG_NIX_CACHE" ]; then
    local base="${CFG_NIX_CACHE%/}"   # strip a single trailing slash
    args+=(-e "NIX_CONFIG=extra-substituters = $base/flox?priority=1 $base/nixos?priority=2")
  fi
```

- [ ] **Step 5: Run to verify pass**

Run: `flox activate -- bats tests/nix-cache.bats`
Expected: PASS (3 tests).

- [ ] **Step 6: Full suite + lint**

Run:
```bash
flox activate -- bats tests/
flox activate -- shellcheck bin/acdev tests/helpers/fake-container
```
Expected: all pass; shellcheck clean.

- [ ] **Step 7: Commit**

```bash
git add bin/acdev tests/nix-cache.bats
git commit -m "feat(acdev): inject Nix substituter via nix_cache config field"
```

---

## Task 2: nginx cache template + host launcher script

**Files:**
- Create: `nix-cache/nginx.conf.template`
- Create: `bin/acdev-nix-cache`
- Test: `tests/nix-cache.bats` (append)

- [ ] **Step 1: Write the nginx template**

Create `nix-cache/nginx.conf.template`:
```nginx
# Rendered by bin/acdev-nix-cache: @PORT@ @LISTEN@ @CACHE_DIR@ are substituted.
worker_processes 1;
daemon off;
error_log stderr info;
pid @CACHE_DIR@/nginx.pid;
events { worker_connections 1024; }
http {
  access_log off;
  client_body_temp_path @CACHE_DIR@/client-tmp;
  proxy_temp_path       @CACHE_DIR@/proxy-tmp;
  proxy_cache_path @CACHE_DIR@/cache levels=1:2 keys_zone=nixcache:50m max_size=20g inactive=90d use_temp_path=off;

  proxy_cache nixcache;
  proxy_cache_valid 200 301 302 90d;
  proxy_cache_valid 404 1m;
  proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
  proxy_ssl_server_name on;
  proxy_http_version 1.1;
  add_header X-Cache-Status $upstream_cache_status always;

  server {
    listen @LISTEN@:@PORT@;

    location = / { return 200 "acdev nix-cache proxy\n"; }

    location /flox/ {
      proxy_pass https://cache.flox.dev/;
      proxy_set_header Host cache.flox.dev;
    }
    location /nixos/ {
      proxy_pass https://cache.nixos.org/;
      proxy_set_header Host cache.nixos.org;
    }
  }
}
```

- [ ] **Step 2: Write the launcher script**

Create `bin/acdev-nix-cache`:
```bash
#!/usr/bin/env bash
# Host-side launcher for the acdev Nix binary cache (nginx proxy_cache).
# Renders the bundled nginx template and execs nginx in the foreground.
set -euo pipefail

PORT="${ACDEV_NIX_CACHE_PORT:-8126}"
# Bind to the container-bridge gateway so the cache is reachable only from the
# container network, not the LAN. Requires the container system to be running
# (the bridge owns this IP). Set to 0.0.0.0 to broaden (see README).
LISTEN="${ACDEV_NIX_CACHE_LISTEN:-192.168.64.1}"
CACHE_DIR="${ACDEV_NIX_CACHE_DIR:-$HOME/.cache/acdev/nix-cache}"

# Template path: env override (tests) > build-substituted default > repo-relative.
TEMPLATE="${ACDEV_NIX_CACHE_TEMPLATE:-@TEMPLATE_PATH@}"
if [ ! -f "$TEMPLATE" ]; then
  TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/nix-cache/nginx.conf.template"
fi
[ -f "$TEMPLATE" ] || { printf 'acdev-nix-cache: template not found: %s\n' "$TEMPLATE" >&2; exit 1; }

mkdir -p "$CACHE_DIR/cache" "$CACHE_DIR/client-tmp" "$CACHE_DIR/proxy-tmp"
rendered="$CACHE_DIR/nginx.conf"
sed -e "s|@PORT@|$PORT|g" -e "s|@LISTEN@|$LISTEN|g" -e "s|@CACHE_DIR@|$CACHE_DIR|g" \
  "$TEMPLATE" >"$rendered"

if [ "${1:-}" = "--print-config" ]; then
  cat "$rendered"
  exit 0
fi
exec nginx -c "$rendered"
```
Then: `chmod +x bin/acdev-nix-cache`

- [ ] **Step 3: Write the failing launcher test**

Append to `tests/nix-cache.bats`:
```bash
@test "acdev-nix-cache --print-config renders the template (default listen)" {
  export ACDEV_NIX_CACHE_TEMPLATE="$REPO_ROOT/nix-cache/nginx.conf.template"
  export ACDEV_NIX_CACHE_DIR="$WORK/nixcache"
  export ACDEV_NIX_CACHE_PORT=8126
  run acdev-nix-cache --print-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"listen 192.168.64.1:8126;"* ]]
  [[ "$output" == *"proxy_pass https://cache.flox.dev/;"* ]]
  [[ "$output" == *"proxy_pass https://cache.nixos.org/;"* ]]
  [[ "$output" == *"$WORK/nixcache/cache"* ]]
}

@test "acdev-nix-cache honors ACDEV_NIX_CACHE_LISTEN override" {
  export ACDEV_NIX_CACHE_TEMPLATE="$REPO_ROOT/nix-cache/nginx.conf.template"
  export ACDEV_NIX_CACHE_DIR="$WORK/nixcache"
  export ACDEV_NIX_CACHE_LISTEN=0.0.0.0
  run acdev-nix-cache --print-config
  [[ "$output" == *"listen 0.0.0.0:8126;"* ]]
}
```
(`REPO_ROOT` and `WORK` are exported by `setup_acdev` in `tests/helpers/common.bash`; `bin/` is already on `PATH`.)

- [ ] **Step 4: Run to verify pass**

Run: `flox activate -- bats tests/nix-cache.bats`
Expected: PASS (4 tests). The render test exercises the launcher directly from `bin/`.

- [ ] **Step 5: Lint**

Run: `flox activate -- shellcheck bin/acdev bin/acdev-nix-cache`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add nix-cache/nginx.conf.template bin/acdev-nix-cache tests/nix-cache.bats
git commit -m "feat(acdev): nginx proxy_cache template + acdev-nix-cache launcher"
```

---

## Task 3: Bundle launcher + template in the Flox package; bump version

**Files:**
- Modify: `.flox/env/manifest.toml` (`[build.acdev]`)

- [ ] **Step 1: Extend the build to bundle the cache assets**

In `.flox/env/manifest.toml`, bump the version and extend the `[build.acdev]` command. Replace the `version` line and the `command` body:
```toml
version = "0.1.3"
runtime-packages = []
command = '''
  mkdir -p "$out/bin" "$out/share/acdev/hooks" "$out/share/acdev/nix-cache"
  cp bin/acdev "$out/bin/acdev"
  chmod 0755 "$out/bin/acdev"
  cp hooks/acdev.bash hooks/acdev.zsh hooks/acdev.fish "$out/share/acdev/hooks/"
  cp nix-cache/nginx.conf.template "$out/share/acdev/nix-cache/nginx.conf.template"
  # Launcher: pin the template path to the package's absolute location.
  sed "s|@TEMPLATE_PATH@|$out/share/acdev/nix-cache/nginx.conf.template|g" \
    bin/acdev-nix-cache >"$out/bin/acdev-nix-cache"
  chmod 0755 "$out/bin/acdev-nix-cache"
'''
```

- [ ] **Step 2: Build and verify the package layout**

Run:
```bash
flox build acdev
ls result-acdev/bin/acdev-nix-cache result-acdev/share/acdev/nix-cache/nginx.conf.template
grep -c '@TEMPLATE_PATH@' result-acdev/bin/acdev-nix-cache
result-acdev/bin/acdev-nix-cache --print-config | grep -c 'cache.flox.dev'
```
Expected: both files exist; `@TEMPLATE_PATH@` count is `0` (substituted); the proxy line is present (`--print-config` works with the build-substituted template path, no env override).

- [ ] **Step 3: Commit**

```bash
git add .flox/env/manifest.toml .flox/env/manifest.lock
git commit -m "feat(flox): bundle nix-cache launcher + template; acdev 0.1.3"
```

---

## Task 4: Wire the cache service into the example environment

**Files:**
- Modify: `example/.flox/env/manifest.toml`

- [ ] **Step 1: Add nginx + the service**

In `example/.flox/env/manifest.toml`, add `nginx` to `[install]` and a service. Under `[install]`:
```toml
nginx.pkg-path = "nginx"
```
Add a new section (cache dir under the env cache so it is self-contained and gitignored):
```toml
## Shared Nix binary cache (nginx proxy_cache in front of cache.flox.dev +
## cache.nixos.org). Start with: flox activate -d example --start-services
## Point a project at it with `nix_cache = "http://192.168.64.1:8126"`.
[services.nix-cache]
command = "ACDEV_NIX_CACHE_DIR=\"$FLOX_ENV_CACHE/nix-cache\" acdev-nix-cache"
```

- [ ] **Step 2: Verify the service definition renders (no real start needed)**

Run:
```bash
flox activate -d example -- bash -c 'command -v nginx && echo nginx-ok'
flox services -d example status 2>&1 | grep -i nix-cache || true
```
Expected: `nginx-ok`, and the `nix-cache` service is listed. Note: `acdev-nix-cache`
comes from the **published** package — the example pins `jbayer/acdev`, which won't
include the launcher until `0.1.3` is published (Task 7). Until then, the live
service start is exercised by Task 6 against the local `./result-acdev` build, not via
the example env. After publish + pin (Task 7), re-run `flox activate -d example
--start-services` to confirm the service starts end-to-end.

- [ ] **Step 3: Commit**

```bash
git add example/.flox/env/manifest.toml example/.flox/env/manifest.lock
git commit -m "feat(flox): run the nix-cache as a service in the example env"
```

---

## Task 5: Documentation (usage text + README + example configs)

**Files:**
- Modify: `bin/acdev` (usage), `README.md`, `examples/.applecontainer.toml`, `example/demo-project/.applecontainer.toml`

- [ ] **Step 1: Document the field in both example configs**

In `examples/.applecontainer.toml`, add after the `flox` line:
```toml
# nix_cache = "http://192.168.64.1:8126"  # use the host nix-cache proxy (see README)
```
In `example/demo-project/.applecontainer.toml`, add the same commented line after the `flox` line.

- [ ] **Step 2: Add a README section**

In `README.md`, add a section after "How it works":
```markdown
## Shared Nix binary cache (optional)

Avoid re-downloading Flox/Nix packages across project containers and rebuilds.
A host-side nginx proxy caches `cache.flox.dev` + `cache.nixos.org` on your SSD;
containers fetch through it. Signatures pass through, so nothing needs signing.

Start the cache (bundled in the acdev package, run by the example env):

\`\`\`bash
flox activate -d example --start-services   # runs acdev-nix-cache on :8126
\`\`\`

Point a project at it in `.applecontainer.toml`:

\`\`\`toml
nix_cache = "http://192.168.64.1:8126"
\`\`\`

acdev then injects the proxy as a preferred Nix substituter (`-e NIX_CONFIG`)
when it creates the container. The cache listens on `192.168.64.1:8126` (the
container-bridge gateway) so it is reachable only from the container network, not
your LAN — start the container system first (`container system start`) so that IP
exists. Set `ACDEV_NIX_CACHE_LISTEN=0.0.0.0` to broaden, and `ACDEV_NIX_CACHE_DIR`
to relocate the cache directory.

> Takes effect on container **creation**. If you add `nix_cache` to an existing
> project, recreate its container: `acdev down --rm && acdev up`.
\`\`\`

- [ ] **Step 3: Commit**

```bash
git add bin/acdev README.md examples/.applecontainer.toml example/demo-project/.applecontainer.toml
git commit -m "docs(acdev): document the nix_cache field and shared cache"
```

---

## Task 6: Manual integration test (real Apple Container, macOS only)

**This task is MANUAL** — requires macOS + Apple Container + the image. Uses the local
build (`./result-acdev`) so it does not depend on publishing.

- [ ] **Step 1: Start the cache from the local build**

```bash
flox build acdev
ACDEV_NIX_CACHE_DIR=/tmp/acdev-cache-test ./result-acdev/bin/acdev-nix-cache &
sleep 2
curl -s http://192.168.64.1:8126/ ; echo            # -> "acdev nix-cache proxy"
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.64.1:8126/flox/nix-cache-info
```
Expected: root returns the banner; `/flox/nix-cache-info` returns `200` (proxied from cache.flox.dev).

- [ ] **Step 2: Cold install through the proxy populates the cache**

```bash
export PATH="$(git -C ~/workspaces/container rev-parse --show-toplevel)/result-acdev/bin:$PATH"
mkdir -p /tmp/cachedemo-a && cd /tmp/cachedemo-a
printf 'image = "jbayer/devcontainer-flox:1.12.1"\nnix_cache = "http://192.168.64.1:8126"\n' >.applecontainer.toml
acdev up
# enter and install something not present, then check the cache filled:
# acdev shell ; flox init ; flox install jq ; exit
du -sh /tmp/acdev-cache-test/cache
```
Expected: cache dir grows; nginx access shows `X-Cache-Status: MISS` then stored.

- [ ] **Step 3: Warm install in a second project is served locally**

```bash
mkdir -p /tmp/cachedemo-b && cd /tmp/cachedemo-b
cp /tmp/cachedemo-a/.applecontainer.toml .
# acdev up ; acdev shell ; flox init ; flox install jq   # same package
```
Verify the second install is served from cache: tail nginx and look for `X-Cache-Status: HIT`
(temporarily set `access_log` on and add `$upstream_cache_status`, or curl a known
`<hash>.narinfo` twice and observe MISS then HIT). Confirm signature verification still passes
(install succeeds without `require-sigs` changes).

- [ ] **Step 4: Teardown**

```bash
kill %1 2>/dev/null            # stop nginx
container ls --all             # remove demo containers: container rm -f <name>
rm -rf /tmp/cachedemo-a /tmp/cachedemo-b /tmp/acdev-cache-test
```

- [ ] **Step 5: Record findings** in the spec/PROGRESS: real `X-Cache-Status` behavior, cache dir growth, any nginx config adjustments needed.

---

## Task 7: Publish + pin example (GATED — requires user approval)

**Do NOT run without explicit user approval** (outward-facing FloxHub publish).

- [ ] **Step 1: Merge the branch to `main`** (via finishing-a-development-branch).
- [ ] **Step 2: Publish** `flox publish -o jbayer acdev` (publishes `0.1.3` with the cache assets).
- [ ] **Step 3: Pin the example** to `acdev.version = "0.1.3"`, re-lock, commit, push.
- [ ] **Step 4: Verify** `flox show jbayer/acdev` shows `0.1.3`; `flox activate -d example` resolves `acdev-nix-cache`.

---

## Notes for the implementer

- **bash 3.2** — keep `bin/acdev` and `bin/acdev-nix-cache` 3.2-compatible (no `${var^^}`, no associative arrays).
- **Listen address** — defaults to `192.168.64.1` (verified bindable; the bridge owns this IP) so the cache is LAN-isolated. Requires the container system to be running before the service starts; `ACDEV_NIX_CACHE_LISTEN=0.0.0.0` broadens it.
- **Injection is create-time** — `-e NIX_CONFIG` is set on `container run`; changing `nix_cache` requires recreating the container.
- **No signing anywhere** — passthrough preserves upstream signatures; trusted keys are already in the image.
- **Don't expand scope** — no push cache, no disk dedup, no auto-managing the cache lifecycle from acdev.
```
