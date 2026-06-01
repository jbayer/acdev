# Apple Container — storage, persistence & networking findings

**Context:** research while building `acdev` (cd→container-shell handoff). Goal was to
replicate a devcontainer-flox workflow — in particular sharing/persisting a Nix store
across project containers — using Apple's native `container` CLI.

**Environment:** macOS 26 / Apple silicon · `container` CLI **v0.12.3** (build f989901) ·
verified **2026-05-31**. Every claim below was observed empirically, not inferred from docs.

---

## TL;DR

| Question | Answer |
|---|---|
| Share one `/nix` volume across many running containers (Docker-style)? | **No** — named volumes are ext4 disk images, **single-attach** (one running container at a time). |
| Persist `/nix/store` across container stop/start and macOS reboot? | **Yes, for free** — the container's writable filesystem survives `stop`→`start` and a daemon/host restart. Only *removing* the container discards it. |
| Run MinIO as a shared S3 binary cache that multiple containers consume? | **Yes** — and it's the right way to share build artifacts across projects, since it sidesteps the single-attach volume limit. |
| Reliable container discovery? | Container IPs are **not stable** across restart. Use a **local DNS domain** (`container system dns create`, needs sudo) or **publish-to-host + gateway `192.168.64.1`** (no sudo). |

---

## 1. Named volumes are single-attach disk images

`container volume create` produces an **ext4 disk image**, not a shared host directory:

```
$ container volume create -s 512M acdev-shared-test
$ container volume inspect acdev-shared-test
[ { "driver": "local", "format": "ext4",
    "source": ".../com.apple.container/volumes/acdev-shared-test/volume.img",
    "sizeInBytes": 536870912 } ]
```

Attaching the **same** volume to a **second running container** while the first holds it
**fails**:

```
$ container run -d --name shtest-a -v acdev-shared-test:/data alpine sleep 300   # ok
$ container run -d --name shtest-b -v acdev-shared-test:/data alpine sleep 300
Error: failed to bootstrap container ...
  "The storage device attachment is invalid."
  Invalid virtual machine configuration.
```

**Why:** each container is a lightweight VM and the volume is a raw block device. Two
independent kernels writing one ext4 image would corrupt it, so the platform refuses.
This is the fundamental difference from Docker, where a named volume is a host directory
shared into containers that share one kernel (any number can RW-mount it at once).

**Volume subcommands:** `create`, `delete`/`rm`, `list`/`ls`, `inspect`, `prune`.

### Bind-mounting a shared *host directory* IS concurrent-safe

The multi-attach-capable mechanism is a host bind mount (virtiofs):

```
$ container run -d --name bindtest-a -v /tmp/shared:/data alpine sleep 300
$ container run -d --name bindtest-b -v /tmp/shared:/data alpine sleep 300   # ok, concurrent
# A writes, B sees it live, host sees it too:
B sees:
from-A
from-B
```

This is the same mechanism `acdev` uses for the workspace mount. For a **Nix store**
specifically it works mechanically but carries caveats: virtiofs perf on many small files,
and Nix's SQLite DB locking (`fcntl`/`flock`) is not guaranteed across multiple VMs —
read-mostly sharing is fine; concurrent installs from multiple containers can race.

---

## 2. Persistence across restart & reboot — no volume needed

The container's **writable rootfs persists on disk**. Stored under
`~/Library/Application Support/com.apple.container/`.

**Stop → start keeps written data (including `/nix/store`):**

```
$ container run -d --name persisttest alpine sleep 1200
$ container exec persisttest sh -c 'mkdir -p /nix/store/abc-pkg && echo downloaded-content > /nix/store/abc-pkg/data'
$ container stop persisttest && container start persisttest
$ container exec persisttest cat /nix/store/abc-pkg/data
downloaded-content
```

**Survives a daemon restart (the macOS-reboot proxy):**

```
$ container stop persisttest
$ container system stop && container system start
$ container ls --all          # persisttest still listed, STATE=stopped
$ container start persisttest
$ container exec persisttest cat /nix/store/abc-pkg/data
downloaded-content
```

**The only thing that discards it is removing the container** (`container rm` /
`container delete` / `acdev down --rm`).

### Mapping to `acdev`

| Command | Effect on `/nix/store` |
|---|---|
| `acdev down` | **stop** — keeps container + store ✅ |
| `acdev up` (on stopped) | **restart** — resumes with store intact ✅ |
| `acdev down --rm` | stop **+ delete** — discards the store ❌ |

`acdev` derives a **stable container name** from the project's absolute path, so the same
project always resolves to the same persisted container. **For "don't re-download across
restarts," the requirement is simply: never `--rm`.** No volume, no bind mount.

**When a volume still helps:** put `/nix` on a **per-project named volume** only if you
want to *recreate* the container (e.g. updated base image) without losing the store.
Single-attach is fine (one container per project). Tradeoff: fixed-size ext4 image that
shadows the image's own `/nix`, so it needs seeding on first use.

---

## 3. Networking & discovery

Default network exists out of the box:

```
$ container network ls
NETWORK  STATE    SUBNET
default  running  192.168.64.0/24
```

Each container gets a `hostname` on the network; clients get a resolver at the gateway:

```
# inside a container:
$ cat /etc/resolv.conf
nameserver 192.168.64.1
```

**Verified reachability paths:**

| Path | Result | Stable across restart? |
|---|---|---|
| Container → container by **IP** (`192.168.64.6:8080`) | ✅ reachable | ❌ **IP reassigned** on start (`.6 → .8`) |
| **Publish to host** (`-p 8090:8080`) → reach via **gateway** `192.168.64.1:8090` | ✅ reachable | ✅ gateway is always `.1` |
| **Local DNS domain** (`container system dns create <domain>`) | available | ✅ stable name (needs one-time `sudo`) |

> **Key gotcha:** container IPs are **not stable** — they're reassigned every start
> (also observed with the acdev demo container: `.3 → .4 → .5`). Never hard-code a
> container's raw IP for a persistent service. Use a DNS name or the host gateway.

**`container system dns`** subcommands: `create` (admin), `delete`/`rm` (admin), `list`/`ls`.
No domains are registered by default. After `sudo container system dns create test`, a
container named `minio` is reachable as `minio.test` from other containers and the host.

---

## 4. MinIO as a shared S3 binary cache (recommended cross-project pattern)

You can't share a `/nix` *disk* across containers (§1), but you can share it as a
*network cache*. This is the idiomatic Nix approach and fits Apple Container well.

**Architecture:** one persistent MinIO container + a bucket that is a Nix binary cache +
each project container configured as a client.

1. **Stable discovery — pick one:**
   - DNS (cleanest): `sudo container system dns create test`, run MinIO as `--name minio`,
     clients use `http://minio.test:9000`.
   - No-sudo: publish MinIO (`-p 9000:9000`), clients use the gateway `http://192.168.64.1:9000`.
2. **Persist MinIO's data** on a named volume: `-v minio-data:/data -s 50G`
   (single-attach is fine — only MinIO touches it; survives container `rm`/recreate).
3. **Wire up the cache** (standard Nix; MinIO is just S3-compatible storage):
   - Generate a signing key once: `nix-store --generate-binary-cache-key cache-1 sk pk`.
   - **Push** paths: `nix copy --to 's3://nixcache?endpoint=http://minio.test:9000&region=us-east-1' <path>`
     (MinIO access/secret keys in env). Flox is Nix underneath, so flox-installed paths copy the same way.
   - **Consume** in each container's `nix.conf`:
     ```
     extra-substituters = http://minio.test:9000/nixcache
     extra-trusted-public-keys = cache-1:<pubkey>
     ```
   A binary cache is just files (`nix-cache-info`, `*.narinfo`, `nar/*.nar.xz`), so even a
   public bucket served over plain HTTP works as a read substituter.

**Caveats:**
- **Signing required** — clients reject unsigned paths unless `require-sigs = false` (avoid).
- **Push is not automatic** — the cache only has what you `nix copy` into it; upstream
  (cache.nixos.org) pull-through is not built in.
- **Ordering** — MinIO must be up before clients substitute; otherwise they fall back to
  upstream (graceful, not fatal).
- **Worth it when** you have many projects/containers and want to share build artifacts —
  which is exactly the gap single-attach volumes leave open. For single-project
  persistence, §2 (just don't `--rm`) is simpler and sufficient.

---

## Appendix — CLI surface touched (v0.12.3)

- **Storage:** `container volume {create,inspect,ls,rm,prune}`; `run -v <name|hostpath>:<target>`,
  `--mount type=,source=,target=,readonly`, `--tmpfs`.
- **Lifecycle/persistence:** `run -d`, `start`, `stop`, `rm`/`delete`, `system {start,stop,status}`.
- **Networking:** `container network {create,ls,inspect,rm,prune}`; default net `192.168.64.0/24`,
  gateway/DNS `.1`; `run --network`, `-p/--publish host:container`, `--dns`, `--dns-domain`.
- **Discovery:** `container system dns {create,delete,ls}` (create/delete need admin).
- **Misc:** `container inspect` (JSON: hostname, networks, mounts, dns), `container ls` is a
  9-column table `ID IMAGE OS ARCH STATE ADDR CPUS MEMORY STARTED` (ADDR carries `/24` CIDR).
