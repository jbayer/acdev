# Try acdev

About five minutes on an Apple silicon Mac with Apple `container` and Flox
installed. This environment installs the published `jbayer/acdev`, loads the
`cd` hooks, and auto-starts the shared Nix cache.

## 1. Activate

```bash
container system start
cd acdev-demo
flox activate
```

Check that the cache is up:

```bash
flox services status            # nix-cache  Running
curl -s http://127.0.0.1:8126/  # acdev nix-cache proxy
```

## 2. `cd` into a project

```bash
cd demo-project                 # acdev creates the container and drops you into it
flox --version                  # Flox inside the container
exit                            # the container keeps running
```

## 3. Start a new project

Because the cache is running, `acdev init` turns on `nix_cache` for you:

```bash
mkdir -p /tmp/try-acdev && cd /tmp/try-acdev
acdev init                      # "detected the host nix-cache proxy on :8126"
acdev up && acdev shell
flox init && flox install hello # fetched through the cache
exit
```

Install the same package in a second project and it comes from the warm cache.

## Clean up

```bash
cd /tmp/try-acdev && acdev down --rm
cd /path/to/acdev-demo/demo-project && acdev down --rm
exit                            # leaving the activation stops the cache
```
