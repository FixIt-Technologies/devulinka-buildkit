# devulinka-buildkit

Shared CI/CD kit for projects building on the Devulinka devops server
(Hetzner AX162, 96 threads / 128 GB / 3.5 TB NVMe RAID1). Reusable GitHub
workflows + composite actions that give every consumer:

- **One shared persistent BuildKit daemon** (`devulinka-buildkit`, state on
  the root NVMe, 500 GiB GC budget) — bun/node/alpine base layers cached
  once for all projects, no `cache-from`/`cache-to` choreography.
- **A host-global build queue**: 4 general slots + 1 priority-reserved slot
  for deploy-critical builds (FixIt, deployik), enforced with `flock` on the
  host (works across repos of *different* owners, which GitHub concurrency
  cannot do). Protects the box from OOM and disk thrash when several
  projects push at once.
- **A separate `small` slot class** (4 slots) for cheap CI checks —
  typecheck, lint, quick bun tests — so they never queue behind image
  builds and a burst of them cannot swamp the box.
- **Warm Bun installs** via the shared runner cache volume.

This repo is public because its reusable workflows are consumed by repos
under multiple owners (cross-owner `uses:` requires a public workflow repo).
**It contains no secrets and never will** — secrets stay in each consumer
repo's GitHub settings.

## Consuming

Build + push an image (queued on the host slots):

```yaml
jobs:
  build:
    uses: LEFTEQ/devulinka-buildkit/.github/workflows/build-image.yml@v1
    with:
      runs-on: '["self-hosted","deployik-ci"]'   # your repo's Devulinka runner labels
      image: ghcr.io/lefteq/lovinka-deployik
      dockerfile: docker/Dockerfile
      priority: true          # deploy-critical builds only
      size-limit-mb: 1536     # optional guard
```

Bun test lane:

```yaml
jobs:
  web-test:
    uses: LEFTEQ/devulinka-buildkit/.github/workflows/test-bun.yml@v1
    with:
      runs-on: '["self-hosted","deployik-ci"]'
      working-directory: web
      bun-version: '1.3.9'
      run: |
        bunx tsc --noEmit
        bun run test
        bun run build
```

Small lane — wrap a cheap check so it takes a `small` slot instead of a
build slot (use `build-lock-acquire`/`-release` with `class: small` when the
check spans multiple steps):

```yaml
- uses: LEFTEQ/devulinka-buildkit/actions/build-lock@v1
  with:
    class: small
    run: |
      bunx tsc --noEmit
      bun run lint
```

E2E lane — hold an `e2e` slot for the whole heavy phase (compose stack +
browser run) so concurrent E2E across repos can't stack up on the host.
Acquire/release because the phase spans multiple steps:

```yaml
- uses: LEFTEQ/devulinka-buildkit/actions/build-lock-acquire@v1
  with:
    class: e2e
# ... compose up, run tests ...
- uses: LEFTEQ/devulinka-buildkit/actions/build-lock-release@v1
  if: always()
```

À-la-carte composite actions (for workflows that need custom build steps):

```yaml
- uses: LEFTEQ/devulinka-buildkit/actions/attach-builder@v1
- uses: LEFTEQ/devulinka-buildkit/actions/build-lock@v1
  with:
    priority: 'false'
    run: docker buildx build --builder devulinka-buildkit ...
```

## The queue

Slot classes are defined in **`classes.conf`** at the repo root — the single
place host capacity is tuned (`name|slots|priority_slots|pressure_gate`).
Shipped classes:

| Class | Slots | Priority extra | Pressure-gated | For |
|-------|-------|----------------|----------------|-----|
| `build` | g1–g4 | p3 (deploy-critical: FixIt deploys, deployik) | yes | heavy image builds |
| `small` | s1–s4 | — | no | cheap CI checks (typecheck, lint, quick tests) |
| `e2e` | e1–e3 | — | yes | full compose stacks + browser E2E |

Priority requests try the normal slots first and fall back to the reserved
priority slot — a priority build is therefore never behind more than one
running build. Pressure-gated classes additionally postpone admission while
the host is loaded (1-min loadavg ≥ `BK_LOAD_MAX`, default 85% of nproc, or
`MemAvailable` < `BK_MEM_MIN_GB`, default 12 GiB); `--priority` bypasses the
gate.

Locks live at `/var/lock/devulinka/build-<slot>.lock` on the host — every
Devulinka runner container bind-mounts `/var/lock`, so the cap is global
across repos of all owners. A slot is held for exactly the lifetime of the
wrapped process and is released by the kernel on any kind of exit (no stale
locks).

**Changing capacity or adding a class:** edit `classes.conf`, merge, move
the `v1` tag (`git tag -f v1 && git push -f origin v1`). Consumers pick it
up on their next job — the action checkout ships the file; no host deploy,
no runner restart.

## Requirements on the runner

- Devulinka self-hosted runner (DooD: host `/var/run/docker.sock` mounted,
  `/var/lock` mounted RW).
- The shared builder must exist on the host — created idempotently by
  `lovinka-devops-infra/scripts/create-devulinka-builder.sh`
  (daemon container `buildx_buildkit_devulinka-buildkit0`, state volume
  bind-mounted to `/mnt/data/buildkit-devulinka`, buildkitd config in
  `lovinka-devops-infra/apps/gh-runner/buildkitd-devulinka.toml`).

## Versioning

Consumers pin `@v1` (moving major tag). Breaking changes bump to `@v2`.

## Roadmap

- `deploy-compose.yml` — reusable SSH + `docker compose` rollout (extracted
  from FixIt deploy-dev; lands with the FixIt migration).
- `bk-test-base` images — pre-baked runtime + Playwright test images.
- Turbo/Nx remote-cache wiring + template-DB snapshot helpers.

Decision log: `lovinka-devops-infra/docs/specs/2026-07-10-devulinka-buildkit-decisions.md`.

## Onboarding a new project

```bash
blueprint/new-project.sh <owner>/<repo> <shortname> [--go] [--priority]
```

Generates the three pieces a new project needs: the runner compose block for
`lovinka-devops-infra/apps/gh-runner/docker-compose.yml` (GitHub-App auth — no
PAT), a starter `ci.yml` wired to the kit, and the remaining manual steps
(install the `devulinka-runners` app on the repo, deploy the runner stack).
