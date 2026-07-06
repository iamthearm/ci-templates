# ci-templates

A reusable GitHub Actions pipeline: push to `main` → test → build a Docker image → push to GHCR →
deploy to a VPS via `docker compose` → health-check → automatic rollback on failure.

This repo is deliberately separate from any app repo and from the special `.github` org-defaults
repo. **A repo is only affected by this pipeline if it explicitly adds the caller workflow below.**
Nothing here runs automatically anywhere else.

## How a repo opts in

1. Add `.github/deploy.config.yml` (see [`schema/deploy.config.schema.json`](schema/deploy.config.schema.json)
   and the worked examples in [`examples/`](examples/)).
2. Add a caller workflow:

   ```yaml
   # .github/workflows/deploy.yml
   name: Deploy

   on:
     push:
       branches: [main]

   permissions:
     contents: read
     packages: write

   jobs:
     deploy:
       uses: iamthearm/ci-templates/.github/workflows/deploy.yml@v1
       with:
         config_path: .github/deploy.config.yml
       secrets:
         VPS_HOST: ${{ secrets.VPS_HOST }}
         VPS_USER: ${{ secrets.VPS_USER }}
         VPS_SSH_KEY: ${{ secrets.VPS_SSH_KEY }}
         VPS_HOST_KEY: ${{ secrets.VPS_HOST_KEY }}
   ```

3. Set the four secrets on the repo (see [`docs/ONBOARDING.md`](docs/ONBOARDING.md)).

For a runnable reference, see `example-node-app/` alongside this repo in the same workspace — a
minimal Node service with its own Dockerfile, `/health` endpoint, and this exact caller workflow.

## What's in here

| Path | Purpose |
|---|---|
| `.github/workflows/deploy.yml` | The reusable pipeline (`workflow_call`) |
| `.github/actions/prepare/` | Validates `deploy.config.yml`, exposes it as JSON for later jobs |
| `.github/actions/deploy/` | Renders the app's compose file and runs the SSH deploy + rollback |
| `schema/deploy.config.schema.json` | Config schema (for editor tooling; `prepare` is the authoritative validator) |
| `edge/` | The shared Caddy reverse-proxy stack that runs once on the VPS |
| `examples/` | Worked `deploy.config.yml` examples (generic HTTP service, Unity/Gridlock) |
| `docs/ONBOARDING.md` | VPS setup, secrets, per-app onboarding, safe-testing checklist |
| `docs/ROLLBACK.md` | How automatic rollback works, how to intervene manually |

## Versioning

App repos pin this repo by tag (`@v1`), never `@main`. Deploys are fully automatic with no manual
approval gate, so a bad change here must not be able to silently roll out to every app repo at
once just because someone pushed to `main` of this repo. Bump to a new major tag (`v2`) for any
change to the `deploy.config.yml` schema or the secrets contract; patch within `v1.x` for
bug fixes and non-breaking additions.

## Design notes worth knowing before changing this

- The per-app `docker-compose.yml` is **generated** from `deploy.config.yml` by the `deploy`
  action — app authors never hand-write Caddy labels. This is what keeps the caller workflow to
  ~15 lines.
- Only one docker-compose file per app, each in its own VPS directory. No shared compose file
  across apps, so one app's deploy can't touch another's.
- The VPS-side `deploy.sh` is the single source of truth for the health-check/rollback decision —
  it curls the app's **public** URL through the real proxy path, not a separate check split
  between the VPS and GitHub Actions.
- The SSH host key is pinned once (`VPS_HOST_KEY` secret), never scanned live in CI.
