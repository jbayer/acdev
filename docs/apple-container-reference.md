# Apple Container — Reference for Agent Sandboxing on macOS

Context doc for using Apple's native container runtime (`apple/container`) as a
Docker-alternative sandbox for AI agentic development on macOS. Verify
subcommands with `--help` before baking them into tooling.

## What it is

- `apple/container` CLI built on the `apple/containerization` Swift framework. Open source (Apache 2.0).
- **Apple silicon only. Requires macOS 26 (Tahoe)** — relies on its virtualization/networking features. Older macOS unsupported.
- **Isolation model: one lightweight VM per container** (vs. Docker's shared VM). Hardware-level isolation between containers — a strong fit for sandboxing untrusted/misbehaving agent actions.

## Mounting a project working directory

```bash
# Bind-mount host dir into container (read-write)
container run -v /host/path:/container/path <image>

# Read-only
container run -v /host/path:/container/path:ro <image>
```

Caveats:
- Backed by **virtiofs**. Validate the read-write path before trusting it; virtiofs on Apple Virtualization Framework has a history of subtle write-back/size-consistency bugs.
- **No single-file mounts** — virtiofs shares directories only. Injecting one file means exposing its parent dir.

## Volumes (named)

CLI volume management exists (was missing only in the earliest releases):

```bash
container volume create mydata
container volume ls
container run -v mydata:/var/lib/mysql <image>
container volume rm mydata
container volume prune          # added ~0.8 series
```

- Constraint: a named volume **cannot be read/written concurrently by multiple running containers**.

## Networks

```bash
container network create mynet
container network ls
container run -d --name web1 --network mynet <image>
container network rm mynet
# Name-based service discovery (containers ping each other by name) requires macOS 26
```

## Reaching a container port from outside

Two mechanisms — prefer #1 for reliability:

1. **Direct container IP (most reliable).** Each container gets its own IP; connect straight to it, no forwarding.
   ```bash
   container ls                 # read the container's IP (e.g. 192.168.64.x)
   curl http://192.168.64.x:3001
   ```
2. **Port publishing to localhost** (`-p` / `--publish`) works but is flakier:
   ```bash
   container run -d -p 127.0.0.1:8080:80/tcp <image>
   # flag must come BEFORE the image name
   ```
   **Gotcha (most common failure):** macOS **Local Network privacy permission**. The terminal/IDE running `container` (iTerm2, VS Code, JetBrains, etc.) must be granted Local Network access under System Settings → Privacy & Security. Without it, `localhost` forwarding silently fails (empty reply / connection reset) **while the direct container IP keeps working**. Grant the permission before debugging code-level issues.

## Known limitations

- **No native Docker Compose.** Multi-container topologies are manual or rely on third-party bridges (e.g. Container-Compose). No declarative orchestration of the volume+network+services graph.
- **devcontainer support is partial/buggy** — networking issues, no setup-script support.
- No declarative provisioning; per-object CLI management only.
- Underlying `containerization` Swift API and community GUIs (e.g. container-ui) exist for anything the CLI doesn't expose, but routine volume/network/port work doesn't require dropping down.

## Practical agent-sandbox recipe

```bash
# Isolated sandbox with the project mounted, on its own network, reachable by IP
container network create agent-net
container run -d --name agent-box \
  --network agent-net \
  -v "$PWD":/workspace:rw \
  -w /workspace \
  <image>
container ls                       # grab agent-box IP for host->container access
container exec -it agent-box bash   # drop into the sandbox
```

- VM-per-container boundary contains the agent at the hypervisor level.
- Reach services by the container's dedicated IP.
- Use a named network only if you need name-based discovery between multiple sandboxes.

## Verification checklist before relying on it

- [ ] Confirm exact subcommands: `container volume --help`, `container network --help`, `container run --help`.
- [ ] Confirm installed version and any version-specific networking behavior.
- [ ] Test the bind-mount read-write path with real edits from both host and container.
- [ ] Grant Local Network permission to the terminal/IDE if using `-p` localhost publishing.
