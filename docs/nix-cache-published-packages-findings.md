# Findings: the acdev Nix cache and `flox publish`ed packages

**Date:** 2026-06-02
**Context:** acdev ships an optional shared Nix binary cache — an nginx
`proxy_cache` pull-through in front of `cache.flox.dev` and `cache.nixos.org`
(see the README "Shared Nix binary cache" section). A showcase environment that
installs a *published* catalog package (`flox/claude-code-plugin-superpowers`)
re-downloaded ~287 MB and took ~75–85 s on every fresh container, even though the
cache was enabled and warm. This documents why, with evidence, and what can and
cannot be done about it.

## TL;DR

- The proxy works correctly for **base catalog packages** (nixpkgs-derived:
  `hello`, `nodejs`, `cmatrix`, …). These are fetched through Nix **substituters**
  (`cache.flox.dev` / `cache.nixos.org`), which the proxy caches.
- The proxy **cannot** cache **published packages** (anything made with
  `flox publish`). flox fetches those with `nix copy --from s3://…egress-store…`
  using per-fetch AWS credentials — **bypassing Nix substituters entirely** — and
  the content isn't on `cache.flox.dev` at all. So neither the proxy nor any
  substituter-shaped cache (attic/harmonia/nix-serve) is ever in that code path.
- The only thing that avoids the re-download is the **store path already being
  present** in the container's `/nix/store`. Confirmed: present → the S3 copy is a
  no-op (**83 s → 1 s**).
- **This is not an acdev bug.** The architecturally correct fix is flox-side:
  serve published packages via the `cache.flox.dev` substituter, and the existing
  proxy would "just work" for them.

## Background: two fetch paths in flox

| Package type | Example | How flox fetches it | Proxy-cacheable? |
|---|---|---|---|
| **Base catalog** (nixpkgs-derived) | `hello`, `nodejs` | Nix **substituters** → `cache.flox.dev` / `cache.nixos.org` over HTTPS | ✅ yes |
| **Published** (`flox publish`) | `flox/claude-code-plugin-superpowers` | `nix copy --from s3://floxhub-catalog-publisher-egress-store-production/cache/flox` with AWS STS creds | ❌ no |

acdev injects the proxy as a preferred substituter when it creates a container:

```
-e NIX_CONFIG=extra-substituters = http://192.168.64.1:8126/flox?priority=1 http://192.168.64.1:8126/nixos?priority=2
```

That only influences the **substituter** path (the first row). Published packages
never consult substituters, so `NIX_CONFIG` is irrelevant to them.

## Evidence

All tests used a fresh container from `jbayer/devcontainer-flox:latest` with the
proxy injected exactly as acdev does, installing
`flox/claude-code-plugin-superpowers`. Proxy cache dir:
`acdev-demo/.flox/cache/nix-cache/cache`.

### 1. The proxy is never touched for the published package

Two fresh containers, same install, measuring proxy-cache growth:

| Run | Wall time | Proxy cache delta |
|---|---|---|
| A (cold) | 85 s | 65 MB → 65 MB (**0 MB**) |
| B (warm) | 75 s | 65 MB → 65 MB (**0 MB**) |

Cold vs warm made no difference, and the proxy didn't grow at all — yet content
was clearly downloaded.

### 2. Where the content actually comes from

`flox install -vv` revealed the mechanism (secrets redacted):

```
flox_rust_sdk::providers::buildenv: trying to copy published package
  cmd=env AWS_ACCESS_KEY_ID=*** AWS_SESSION_TOKEN=*** nix copy
      --from 's3://floxhub-catalog-publisher-egress-store-production/cache/flox'
      /nix/store/2vrhfvx5…-claude-code-plugin-superpowers-5.1.0
…
Succesfully copied custom package … location_url=s3://floxhub-catalog-publisher-egress-store-production/cache/flox
```

- Container `/nix/store` grew **386 MB → 673 MB (+287 MB, +65 paths)**.
- The S3 copy ran `15:40:29 → 15:41:34` = **65 s** — the bulk of the slow install.

### 3. The published path isn't on the public substituter at all

For store hash `2vrhfvx5la7f2ma4zyx9qqjai535s795`:

```
GET (proxy)  /flox/<hash>.narinfo   -> HTTP 404
GET (proxy)  /nixos/<hash>.narinfo  -> HTTP 404
GET (direct) https://cache.flox.dev/<hash>.narinfo -> HTTP 404
```

So even if flox *did* consult substituters for published packages, there'd be
nothing to proxy. Published artifacts live only in the S3 egress store.

### 4. Contrast: the proxy does work for substituter-backed content

Earlier in the same environment the proxy held **46 `cache.flox.dev` NAR
payloads + 58 narinfos** and **12 `cache.nixos.org` NARs + 12 narinfos**, and a
cached object served from disk:

```
GET /flox/qah6sg7…narinfo -> HTTP 200, X-Cache-Status: HIT
```

### 5. What actually avoids the re-download: store presence

Same container, install twice:

| Install | Wall time | S3 copy attempts |
|---|---|---|
| 1st (cold store) | 83 s | 1 |
| 2nd (path already in `/nix/store`) | **1 s** | **0** |

`nix copy --from` is a no-op when the path already exists in the target store.

## Why the proxy can't be made to cache published packages

1. **nginx `proxy_cache` is pull-through only.** It populates solely by proxying
   real GETs to the upstream, keyed by upstream URL; there is no upload/injection
   API. And the published content 404s on the upstreams, so no legitimate request
   would ever make the proxy hold it.
2. **flox bypasses substituters for published packages.** It runs a hardcoded
   `nix copy --from s3://…` with per-fetch credentials. Any substituter-shaped
   cache (the proxy, or attic/harmonia/nix-serve) is simply never consulted on
   that path. Pushing content somewhere flox doesn't look yields no benefit.

## Options and mitigations

Ordered from least to most effort:

1. **Reuse the container / store persistence (works today, zero infra).** The
   writable layer (including `/nix/store`) survives stop/start, so `acdev down`
   → `acdev up` *without* `--rm` won't re-copy. For a showcase that reuses one
   container, this is the practical fix. The re-download only hits a brand-new
   container.

2. **Host-side store stash + seed (acdev-side, real engineering).** Instead of
   uploading to the proxy, stash the closure on the host once and *seed* a new
   container's store from it over the LAN before flox needs it:
   - capture once: `nix copy --to file:///host/stash <env-closure>`
     (or `nix-store --export`)
   - on a fresh container: `nix copy --from file:///host/stash --no-check-sigs <paths>`
     into the store → flox then finds the paths present → no S3 copy.

   `--no-check-sigs` avoids signing-key management (it's your own trusted store).
   The catch is a chicken-and-egg: you need the closure paths to seed them, which
   acdev can solve by recording a project's env closure after the first build and
   replaying it on recreate. Trade-off: a growing host stash and extra moving
   parts.

3. **attic / harmonia / nix-serve.** Great for *pushing* and serving caches, but
   they only help consumers that use them **as substituters** — which flox won't
   for published packages. They'd accelerate base-catalog content (already
   proxied), not the published case. Net: doesn't solve this.

4. **Flox-side fix (correct, out of acdev's control).** If published packages were
   also served via the `cache.flox.dev` **substituter** (in addition to, or
   instead of, the S3 egress copy), the existing acdev proxy would work for them
   with no acdev changes and no stash. This is the architecturally right fix.

## Recommendation

- Document the cache's coverage (base-catalog yes, published no) so it isn't
  surprising — done in the README.
- For published-package-heavy showcases, prefer **container reuse** over `--rm`.
- Pursue the **flox-side** change to expose published packages via the
  `cache.flox.dev` substituter; that is the only thing that makes fresh-container
  activations of published packages fast.

## Reproduction

```bash
NEW=docker.io/jbayer/devcontainer-flox:latest
G=192.168.64.1:8126
NIXCFG="extra-substituters = http://$G/flox?priority=1 http://$G/nixos?priority=2"
PKG=flox/claude-code-plugin-superpowers
CACHE=acdev-demo/.flox/cache/nix-cache/cache

container run -d --name cc -e NIX_CONFIG="$NIXCFG" "$NEW" sleep infinity
du -sm "$CACHE"                                   # proxy size before
container exec -w /home/flox cc bash -lc \
  "mkdir -p p && cd p && flox init && flox install -vv $PKG 2>&1 | grep -i 's3://'"
du -sm "$CACHE"                                   # proxy size after (unchanged)
container rm -f cc
```
