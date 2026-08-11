# devulinka-buildkit

Reusable GitHub Actions workflows and composite actions for projects that build
on **Devulinka**, the self-hosted CI box behind the FixIt / lovinka products.
Consumers get a shared persistent BuildKit daemon (so base layers are cached
once for every project, with no `cache-from`/`cache-to` choreography), warm Bun
installs from a shared runner volume, and — the part GitHub cannot give you — a
**host-global admission queue** that caps how much work runs on the box at once,
across repos owned by different accounts.

This repo is **public on purpose**: a cross-owner `uses:` reference requires a
public workflow repo. It contains no secrets and never will — every credential
lives in the consuming repo's own Actions secrets.

## Quickstart (consuming the kit)

Nothing to install. Pin the moving major tag `@v1` and call a workflow. Jobs
must land on a Devulinka self-hosted runner — see [Runner requirements](#runner-requirements).

**Build and push an image**, queued on the host's `build` slots:

```yaml
jobs:
  build:
    permissions:
      contents: read
      packages: write
    uses: FixIt-Technologies/devulinka-buildkit/.github/workflows/build-image.yml@v1
    with:
      runs-on: '["self-hosted","deployik-ci"]'   # your repo's runner labels
      image: ghcr.io/<owner>/<name>              # no tag; defaults to latest + short SHA
      dockerfile: docker/Dockerfile
      priority: true          # deploy-critical builds only
      size-limit-mb: 1536     # optional: fail if the pushed image is bigger
```

Other inputs: `context` (default `.`), `ref`, `tags` (newline-separated),
`build-args` (newline-separated `KEY=VALUE`), `push` (default true), `builder`,
`lock-timeout` (default 2700s). It outputs `image-ref` (the first pushed ref).
Registry login defaults to `github.actor` + `github.token`; pass the optional
`registry-username` / `registry-password` secrets when the target GHCR package
does not grant the calling repo's token write access.

**Bun test lane:**

```yaml
jobs:
  test:
    uses: FixIt-Technologies/devulinka-buildkit/.github/workflows/test-bun.yml@v1
    with:
      runs-on: '["self-hosted","deployik-ci"]'
      working-directory: web
      bun-version: '1.3.9'    # keep in sync with your packageManager field
      clean: false            # keep node_modules / .next/cache / *.tsbuildinfo warm
      run: |
        bunx tsc --noEmit
        bun run test
        bun run build
```

Also takes `ref`, `install` (default true), `frozen-lockfile` (default true) and
`timeout-minutes` (default 30). Note this lane does **not** take a slot — wrap
the expensive part yourself if it deserves one.

**Take a slot around your own steps.** Single command:

```yaml
- uses: FixIt-Technologies/devulinka-buildkit/actions/build-lock@v1
  with:
    class: small
    run: |
      bunx tsc --noEmit
      bun run lint
```

Multi-step phase (compose stack + browser E2E), acquire/release:

```yaml
- uses: FixIt-Technologies/devulinka-buildkit/actions/build-lock-acquire@v1
  with:
    class: e2e
# ... compose up, run the suite ...
- uses: FixIt-Technologies/devulinka-buildkit/actions/build-lock-release@v1
  if: always()
```

`actions/attach-builder@v1` attaches a job to the shared BuildKit daemon when
you need custom build steps instead of `build-image.yml`.

## The admission queue

Slot classes live in **`classes.conf`** at the repo root — one line per class,
`name|slots|priority_slots|pressure_gate`. That file is the only place host
capacity is defined; `scripts/bk-lock.sh` reads it at job time.

| Class | Slots | Priority extra | Pressure-gated | For |
|-------|-------|----------------|----------------|-----|
| `build` | g1–g4 | p3 | yes | heavy image builds |
| `small` | s1–s4 | — | no | cheap checks: typecheck, lint, quick tests |
| `e2e` | e1–e8 | — | yes | full compose stacks + browser suites |

- A `--priority` request tries the general slots first and falls back to the
  reserved one, so a deploy-critical build is never queued behind more than one
  running build. Classes with no priority slot ignore the flag.
- Pressure-gated classes additionally postpone admission (within their timeout)
  while the host is loaded: 1-minute loadavg ≥ `BK_LOAD_MAX` (default 85% of
  `nproc`) or `MemAvailable` < `BK_MEM_MIN_GB` (default 12 GiB). `--priority`
  bypasses the gate. `/proc/loadavg` and `/proc/meminfo` are not namespaced, so
  a runner container reads the *host's* numbers — which is the point.
- Locks are plain `flock(2)` files at `/var/lock/devulinka/build-<slot>.lock`.
  Every Devulinka runner bind-mounts the host `/var/lock`, so the same inodes
  are contended across all repos and owners. The fd is held for exactly the
  lifetime of the wrapped process and the kernel drops it on any exit — clean,
  killed or OOM — so there is no stale-lock cleanup.
- Waiting past `--timeout` exits **75**. Queue events (`wait`, `defer`,
  `acquire`, `release`, `timeout`) are appended as JSONL to
  `/var/lock/devulinka/events.jsonl`, best-effort — telemetry never fails a build.

## Runner size tiers

Independently of the queue, each runner container carries a size label
`devulinka-<N>vcpu-ubuntu-2604`, enforced on the container as a soft CPU weight
(`cpu_shares: N*1024` — bursts on an idle host, yields under contention) plus a
hard memory cap on a 1:2 ladder: 2 vCPU/4 GB for lint and typecheck, 4/8 for
unit suites, 8/16 for browser E2E, 16/32 for image builds. Lane labels keep
their warm workdirs, so a workflow can target its lane label for cache affinity
or a size label alone. Sizes bound one container; slot classes bound the host.

Tier definitions live in the private infra repo
(`lovinka-devops-infra/apps/gh-runner/docker-compose.yml`).

## Runner requirements

- A Devulinka self-hosted runner: DooD (host `/var/run/docker.sock` mounted) and
  `/var/lock` bind-mounted read-write.
- The shared builder must exist on the host — created idempotently by
  `lovinka-devops-infra/scripts/create-devulinka-builder.sh`. `attach-builder`
  only re-creates the client-side handle (buildx metadata does not survive a
  runner restart); the daemon container and its cache live on the host.
- Linux only: `bk-lock.sh` needs `flock(1)` and exits 2 with a clear message
  anywhere else.

## Repository map

| Path | What |
|---|---|
| `.github/workflows/build-image.yml` | reusable image build (login → attach builder → locked `buildx build` → optional size guard) |
| `.github/workflows/test-bun.yml` | reusable Bun install + run lane |
| `.github/workflows/external-watchdog.yml` | this repo's own cron job, not part of the kit — a GitHub-hosted dead-man's switch that probes the fleet from outside and pages via Telegram. Must stay on `ubuntu-latest`: a self-hosted runner would die with the box it watches. |
| `actions/build-lock/` | run one command holding a slot |
| `actions/build-lock-acquire/`, `actions/build-lock-release/` | hold a slot across steps (background holder, 6 h failsafe) |
| `actions/attach-builder/` | attach the job to the shared BuildKit daemon |
| `scripts/bk-lock.sh` | the semaphore itself — everything above is a wrapper |
| `classes.conf` | slot capacity, the single source of truth |
| `blueprint/new-project.sh` | onboarding generator (below) |

## Development

There is no build, no dependency install and no test suite here — the repo is
YAML plus one Bash script. Changes are validated by the consumers that call
them, so keep them small and watch the first consuming run.

**Changing capacity or adding a class:** edit `classes.conf`, merge, then move
the major tag:

```bash
git tag -f v1 && git push -f origin v1
```

Consumers pick it up on their next job — the action checkout ships the file. No
host deploy, no runner restart. Note that `bk-lock.sh` carries a `BUILTIN_CLASSES`
fallback for the case where `classes.conf` is unreadable; re-sync it when you
change capacity.

**Onboarding a new project:**

```bash
blueprint/new-project.sh <owner>/<repo> <shortname> [--go] [--priority]
```

Prints three blocks to stdout: the runner service for the private infra repo's
`gh-runner` compose (GitHub App auth, no PAT), a starter `ci.yml` wired to this
kit, and the manual steps that remain (install the runner GitHub App on the
repo, deploy the runner stack). Review the generated `ci.yml` before committing
it — in particular, decide deliberately whether its `pull_request` lanes should
run on the shared self-hosted box for a public repo.

**Versioning:** consumers pin `@v1`, a moving major tag. Breaking changes bump
to `@v2`; everything else moves `v1`.

## Repository etiquette

- `main` is protected by a ruleset: pull requests only, no force-push, no
  deletion, one approving review **from the code owner** (`.github/CODEOWNERS`),
  and stale reviews are dismissed on push. Merge, squash and rebase are all
  allowed.
- Branch naming follows `work/<slug>` (e.g. `work/ci-speed`), with `feat/<slug>`
  also in use.
- Conventional Commits, scoped to the piece you touched: `feat(classes):`,
  `feat(bk-lock):`, `docs+blueprint:`.
- This is public and consumed cross-owner. Never add a secret, an internal
  hostname, or a private mesh address; keep credentials in the consuming repo.
