# How rollback works

Rollback logic lives entirely in [`deploy.sh`](../.github/actions/deploy/deploy.sh), which runs
**on the VPS** at the end of every deploy. It is the single source of truth for the
health-check/rollback decision — there is no separate check on the GitHub Actions side that could
disagree with it.

## State kept per app (`/opt/apps/<app_name>/`)

| File | Meaning |
|---|---|
| `docker-compose.yml` | The currently-live compose file |
| `docker-compose.yml.prev` | A copy of the previous compose file, written just before each overwrite |
| `.last-good-tag` | Plaintext image tag of the last version that passed its health check |
| `.env` | Hand-maintained by you at onboarding; never touched by CI |

## The sequence on every deploy

1. Validate every name in the config's `deploy.env.required` exists in `.env`. Fail immediately,
   before touching anything, if one is missing.
2. Back up the current `docker-compose.yml` → `docker-compose.yml.prev`. Read `.last-good-tag`
   (empty if this is the app's first-ever deploy — see below).
3. Move the newly rendered compose file into place, `docker compose pull && up -d`.
4. Poll `https://<vps-host>:8443/<path_prefix>/health` (or whatever `health_check` says) through
   the real Caddy route — this validates the whole path (container → Caddy label → TLS →
   routing), not just "is the container running."
5. **Health check passes** → write the new tag to `.last-good-tag`, done.
6. **Health check fails, and a previous state exists** → restore `docker-compose.yml.prev`,
   `docker compose up -d` again, re-check health:
   - Restored state passes → logs "ROLLBACK SUCCEEDED", but the **workflow run is still reported
     as failed** (a failed deploy is a failed run, even though the site is back to serving the
     previous good version).
   - Restored state *also* fails → logs "ROLLBACK FAILED — MANUAL INTERVENTION REQUIRED". This
     means the previously-good state has since drifted (e.g. an expired dependency, a manually
     changed `.env` value) — SSH in and investigate; `docker compose logs` in the app's directory
     is the first thing to check.
7. **Health check fails, no previous state (first deploy of this app)** → there is nothing to roll
   back to. `deploy.sh` runs `docker compose down` rather than leaving a broken container publicly
   routable, and reports "FIRST DEPLOY FAILED."

## Why this can't fully protect a brand-new app's first deploy

The pipeline's `smoke-test` job (in the reusable workflow) already runs the built image locally on
the GitHub-hosted runner and checks its health endpoint *before* the VPS is ever touched — this
catches most first-deploy failure modes (crashes on boot, wrong port, wrong health path, missing
dependency) for free. What it can't catch: VPS-specific problems — a required `.env` value that's
present but wrong, resource exhaustion on the box, or a Caddy label typo. For a first deploy, treat
a failure as "investigate before retrying," not "just push again."

## Manually intervening

- Force a specific version back up: `cp docker-compose.yml.prev docker-compose.yml && docker compose up -d`
  from the app's directory on the VPS.
- Check what's actually running: `docker compose ps`, `docker compose logs -f`.
- `.last-good-tag` is plain text — safe to read or hand-edit if you need to reason about state
  after a manual fix.
