# Try the acdev environment

Five minutes, two terminals, on Apple-silicon macOS with the Apple `container`
CLI and Flox installed. This env installs the published `jbayer/acdev`, runs the
shared Nix cache as an **auto-started** service, and registers the
`cd`→container-shell auto-handoff.

## 1. Activate (the cache starts itself)

```bash
container system start          # Apple Container running
cd acdev
flox activate                   # auto-start brings up the nix-cache service
```

Verify the proxy is live:

```bash
flox services status            # nix-cache → Running
curl -s http://127.0.0.1:8126/  # → acdev nix-cache proxy
```

## 2. Auto-handoff: just `cd` into a project

The activated shell has the hooks loaded. `cd` into the bundled project and acdev
creates/enters the container for you — no `acdev up`/`shell` needed:

```bash
cd demo-project                 # → 🍎 acdev … drops you inside the container
echo "$NIX_CONFIG"              # (set if this project opts into the cache)
exit                            # leave the container shell
```

## 3. New project — `init` auto-detects the cache

Because the proxy is running, `acdev init` writes an **active** `nix_cache` line
(commented out when it isn't):

```bash
mkdir -p /tmp/try-acdev && cd /tmp/try-acdev
acdev init                      # ↳ "detected the host nix-cache proxy on :8126 — enabled nix_cache."
grep nix_cache .applecontainer.toml   # nix_cache = "http://192.168.64.1:8126"  (uncommented)
acdev up && acdev shell
#   inside:  flox init && flox install hello   ← pulled through the cache
#   exit
```

Install the same thing from a *second* project and it's served from the warm
cache — no re-download.

## Optional: guided picker (uses `gum`)

`gum` is on PATH in this env. Pick a step interactively:

```bash
case "$(gum choose 'status' 'open demo-project' 'new project')" in
  status)           flox services status ;;
  'open demo-project') cd "$PWD/demo-project" ;;
  'new project')    d=$(gum input --placeholder name); mkdir -p "/tmp/$d" && cd "/tmp/$d" && acdev init ;;
esac
```

## Teardown

```bash
cd /tmp/try-acdev && acdev down --rm     # remove any test container
flox services stop nix-cache             # or just `exit` the activation
```
