# Buildkit v2 — CI/CD Security Reorganization — Decisions [!date](2026-08-14)

Board: https://vitrinka.in/w/fixit/boards/devulinka-buildkit-brainstorm-v2-security

## Summary

Buildkit v2 reorganizes CI/CD deploy security across the 3-server estate
(**Devulinka** = dev/CI, **Produlinka** = production, **Webulinka** = websites,
post-rebuild). Goals: deploy SSH keys leave GitHub entirely; workflows declare a
logical deploy **target** (e.g. `eve-prod`) instead of hardcoding hosts/relays;
a single enforced policy decides which repo may deploy where; dispatchers become
one shared, audited framework instead of bespoke per-server scripts. FixIt is
the pilot (deploy-dev first, deploy-production last).

Trigger: the Reservine incident (personal SSH key with unrestricted root in CI)
plus the 2026-08-09 GHA secret-exfil incident, and the 2026-08-14 finding that
FixIt prod deploys still point at the retired standby box.

## Decisions

:::table
| # | Decision | Call | Why |
|---|----------|------|-----|
| D1 | Deploy-control architecture | [!status yellow](Open) | |
| D2 | Target registry location | [!status yellow](Open) | |
| D3 | Target naming vocabulary | [!status yellow](Open) | |
| D4 | Repo→target authorization | [!status yellow](Open) | |
| D5 | Dispatcher standardization | [!status yellow](Open) | |
| D6 | Buildkit v2 consumer API | [!status yellow](Open) | |
| D7 | App-secrets scope | [!status yellow](Open) | |
| D8 | Interim prod deploys | [!status yellow](Open) | |
:::

## Assumptions (not asked — one sane answer)

- FixIt is the pilot repo; `deploy-dev` migrates first, `deploy-production`
  only after deploy-dev is proven (user's explicit call).
- Webulinka onboards to v2 only after its OS rebuild; the registry design
  accounts for it from day 1.
- The eve-ai-layer physical move to Produlinka is its own later project —
  v2 makes it a registry edit, not a workflow rewrite.
- v1 runner/queue mechanics carry over unchanged: `classes.conf` slot classes,
  host `flock` queue, runner size tiers, Firefly hot VM + bastion KVM guests.
- The WG zone model (wg-admin / wg-employee / wg-p2p, 2026-08-09 redesign) is
  the network substrate; v2 builds on it, never bypasses it.
- Forced-command + `from=` + `restrict` stays the floor for ANY authorized key
  on any server (the pattern already live on Devulinka/old-prod).

## Open questions

All eight decisions above — being settled on the board.
