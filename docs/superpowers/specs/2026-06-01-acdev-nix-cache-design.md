# acdev shared Nix binary cache — design

**Date:** 2026-06-01
**Status:** Draft for review
**Related:** `docs/apple-container-storage-networking-findings.md` (empirical Apple Container research),
`2026-05-31-apple-container-devcontainer-handoff-design.md` (acdev itself)

## Problem

Each acdev project runs its own Apple Container with its own `/nix/store`. When you
`flox install` inside several project containers — or rebuild one — the same
Flox/Nix packages are downloaded from the internet again and again. The goal is to
**download each package once per machine** and serve every container's subsequent
fetches locally.

Primary goal: **avoid re-downloading** (time/bandwidth). Disk deduplication across
containers is explicitly *not* a goal here (each container keeps its own copy of the
paths it uses).

## Approach: transparent pull-through caching proxy

Run a caching reverse proxy on the macOS host, in front of the upstream binary
caches. Containers point their Nix substituters at the proxy. On a cache miss the
proxy fetches from upstream, stores the artifact on the Mac's SSD, and serves it;
every later fetch (any container, any rebuild) is served locally.

Because the proxy passes upstream bytes through verbatim, **upstream signatures are
preserved** and containers verify with keys they already trust — **no signing keys,
no `nix copy`, fully automatic**.

### Why this shape (decisions already validated)

- **macOS host process, not a container.** Stable address (host gateway
  `192.168.64.1`, verified), auto-start as a service, dynamic-size SSD cache, no VM
  overhead. Apple Container has no restart policy (verified: containers come back
  `stopped` after a daemon restart), which makes a containerized always-on cache
  awkward.
- **nginx `proxy_cache`, not harmonia/attic/nix-serve.** Those are *push* caches
  (serve a local store you populate); they do not pull-through from upstream. nginx
  `proxy_cache` is a transparent HTTP cache, which is exactly what "avoid
  re-downloading" needs. The Nix cache protocol is immutable content-addressed files
  (`/nix-cache-info`, `<hash>.narinfo`, `/nar/...`), so it caches cleanly with long
  TTLs and no invalidation logic.
- **Two upstreams.** The in-container Flox uses **`cache.flox.dev`** (primary;
  signer `flox-cache-public-1`) and **`cache.nixos.org`** (nixpkgs base; signer
  `cache.nixos.org-1`). Both keys are already in the image's `trusted-public-keys`.

### Key empirical finding (de-risks the whole design)

A trace against the real container CLI proved that **`flox install` honors the Nix
`substituters` setting**: with a valid pull-through proxy listed as a *preferred*
substituter, `flox install hello` queried the proxy for narinfo (5 narinfo GETs
observed). Caveats learned:

- A substituter must return a valid `200 /nix-cache-info` or Nix disqualifies it
  ("does not appear to be a binary cache") and never sends narinfo queries.
- Substituters are **alternatives, not a chain** — to route traffic *through* the
  proxy it must be **preferred** (lower `priority` number than the direct upstream;
  `cache.nixos.org` is priority 40, so the proxy uses `priority=1`/`2`).
- Container reaches the host proxy at `http://192.168.64.1:PORT` (gateway verified
  reachable from containers; `curl` is present in the image, `wget` is not).

## Architecture

```
[ macOS host ]
  Flox service: nginx proxy_cache              cache dir on SSD (persists across all)
     ├── location /flox/  → https://cache.flox.dev   (primary)
     └── location /nixos/ → https://cache.nixos.org  (nixpkgs base)
              ▲  HTTP, host gateway
              │  http://192.168.64.1:PORT
  ┌───────────┴───────────────┐
[ container A ]            [ container B ]   …
  Nix config (injected by acdev when nix_cache is set):
    extra-substituters       = http://192.168.64.1:PORT/flox?priority=1
                               http://192.168.64.1:PORT/nixos?priority=2
    extra-trusted-substituters = (both)
  trusted-public-keys already include flox-cache-public-1 + cache.nixos.org-1
```

Data flow for `flox install X` in a container:
1. Nix queries substituters for each path's narinfo; the proxy is preferred → asked first.
2. Proxy **hit** → served from SSD, no internet. **Miss** → proxy fetches upstream,
   caches the NAR, serves it. Next container/rebuild gets the local copy.
3. Verbatim passthrough → upstream signature verifies against already-trusted keys.

## Components

### 1. The proxy (packaged in the acdev Flox build)

The acdev package (`[build.acdev]`) gains a bundled nginx config template:

```
$out/share/acdev/nix-cache/nginx.conf.template
```

The template defines two `proxy_cache` server/location blocks (one per upstream)
with: a file cache path, generous `proxy_cache_valid` for 200s, negative caching for
404s, `proxy_cache_use_stale` so a transient upstream failure still serves cached
content, and `proxy_ssl_server_name on` for the HTTPS upstreams. Placeholders
(cache dir, port, listen address) are filled in at service start.

Inputs: two upstream URLs (fixed), a cache directory, a listen port/address.
Output: an HTTP cache endpoint. Independently testable by curl-ing
`/<known-hash>.narinfo` through it and checking the cache dir fills.

### 2. The cache service (defined in the example Flox environment)

`example/.flox/env/manifest.toml` gains:
- `[install] nginx` (and the existing `acdev` from the catalog).
- `[services.nix-cache]` that renders the template (substituting cache dir/port) and
  runs `nginx -c <rendered>` in the foreground.

Defaults (configurable): port `8126`, listen `192.168.64.1` (container-network only,
not the LAN), cache dir on the host SSD at a stable path (e.g.
`${FLOX_ENV_CACHE}/nix-cache` or `~/.cache/acdev/nix-cache` — TBD in plan).

Activating the example with services started (`flox activate -d example
--start-services`, or `flox services start`) brings up the cache. This makes the
example the reference for "acdev + shared cache."

### 3. Client wiring (acdev)

New optional `.applecontainer.toml` field:

```toml
nix_cache = "http://192.168.64.1:8126"   # base URL of the host proxy
```

When set, `cmd_up`'s `container run` injects Nix config so the container's flox uses
the proxy. acdev derives the two substituter URLs from the base
(`<base>/flox?priority=1`, `<base>/nixos?priority=2`) and sets the substituters +
trusted-substituters. Parsing/validation lives alongside the other `CFG_*` fields;
the injection is a single isolated spot in the run-command construction
(parallel to how `-e`, `--user` are added today). When unset, behavior is unchanged.

Injection mechanism is an implementation choice to validate (see Open Questions):
preferred is `-e NIX_CONFIG="..."` on `container run` (no extra round-trip);
fallback is writing `~/.config/nix/nix.conf` in the container (this is the form the
trace proved works).

## Configuration surface summary

| Where | Setting | Purpose |
|---|---|---|
| `.applecontainer.toml` | `nix_cache = "http://192.168.64.1:8126"` | opt-in; points a project's container at the proxy |
| `example/.flox/.../manifest.toml` | `[install] nginx`, `[services.nix-cache]` | runs the proxy on the host |
| acdev package `$out/share/acdev/nix-cache/` | `nginx.conf.template` | the proxy config shipped with acdev |

## Persistence, discovery, security

- **Persistence:** cache lives on the Mac SSD — survives container removal, daemon
  restart, and reboot. Grows dynamically; cleared with `rm`/an optional prune.
- **Discovery:** host gateway `192.168.64.1:PORT` — stable, no DNS, no sudo.
- **Security:** bind nginx to `192.168.64.1` so the cache is reachable only from the
  container network, not the LAN. Content is signed upstream and verified in the
  container regardless.

## Non-goals (YAGNI)

- **Not a push cache** — no `nix copy`, no signing, no serving locally-built paths.
- **Not disk deduplication** — each container keeps its own copy of used paths.
- **Not the macOS-native `/nix/store`** — the host store is darwin-arm64; containers
  are linux-arm64, so the host store cannot serve them. Ruled out.
- **Not multi-host / team sharing** — single developer machine. (attic would be the
  upgrade path if that changes.)
- **No auto-management of the cache lifecycle from acdev** — the proxy is a Flox
  service, separate from per-project container lifecycle. acdev only wires clients to it.

## Open questions / validation points for the implementation plan

1. **Injection mechanism:** confirm `-e NIX_CONFIG="extra-substituters = …"` is
   honored by the in-container flox (the file form is already proven). Confirm
   whether `extra-trusted-substituters` is required in the container's single-user
   Nix (store owned by `flox`, no daemon) or whether `extra-substituters` alone
   suffices.
2. **Two-upstream routing:** confirm listing both proxied URLs as substituters makes
   Nix try each correctly (it already does "query all, use whichever has the path").
   Decide proxy layout: two locations under one port (`/flox`, `/nixos`) vs. a
   single location with upstream failover.
3. **nginx specifics:** `proxy_cache_valid` durations, max cache size / `proxy_cache`
   zone sizing, correct handling of `.narinfo` vs `/nar/` and HTTPS upstreams with
   SNI, negative-cache TTL.
4. **Cache dir location:** `${FLOX_ENV_CACHE}/nix-cache` (self-contained in the
   example env) vs. `~/.cache/acdev/nix-cache` (shared, env-independent).
5. **End-to-end proof:** real two-container test — cold install populates the cache;
   second container's install is served locally (observe cache-dir growth / nginx
   `X-Cache-Status` HIT) with no upstream fetch.

## Testing strategy

- **Unit (bats, fake container):** `nix_cache` parsing; `up --dry-run` emits the
  correct substituter injection when set and nothing when unset; base-URL → two
  substituter URLs derivation.
- **Lint:** shellcheck clean (`bin/acdev`).
- **Integration (manual, real Apple Container — macOS only):** bring up the cache
  service; two project containers with `nix_cache` set; verify cold→warm install
  (cache HIT, no upstream hit) and signature verification still passes.
```
