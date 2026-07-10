# devulinka-buildkit

Shared CI/CD kit for projects building on the Devulinka devops VPS (32 vCPU /
128 GB, Hetzner CCX53). Reusable GitHub workflows + composite actions that
give every consumer:

- **One shared persistent BuildKit daemon** (`devulinka-buildkit`, state on
  the Hetzner volume, 100 GiB GC budget) — bun/node/alpine base layers cached
  once for all projects, no `cache-from`/`cache-to` choreography.
- **A host-global build queue**: 2 general slots + 1 priority-reserved slot,
  enforced with `flock` on the host (works across repos of *different*
  owners, which GitHub concurrency cannot do). Protects the box from OOM and
  disk thrash when several projects push at once.
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

À-la-carte composite actions (for workflows that need custom build steps):

```yaml
- uses: LEFTEQ/devulinka-buildkit/actions/attach-builder@v1
- uses: LEFTEQ/devulinka-buildkit/actions/build-lock@v1
  with:
    priority: 'false'
    run: docker buildx build --builder devulinka-buildkit ...
```

## The queue

| Slot | Who |
|------|-----|
| g1, g2 | every build |
| p3 | priority builds only (FixIt deploys, deployik) |

Priority builds try g1 → g2 → p3; normal builds try g1 → g2 and wait.
A priority build is therefore never behind more than one running build.
Locks live at `/var/lock/devulinka/build-{g1,g2,p3}.lock` on the host —
every Devulinka runner container bind-mounts `/var/lock`, so the cap is
global. A slot is held for exactly the lifetime of the wrapped build
process and is released by the kernel on any kind of exit (no stale locks).

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
