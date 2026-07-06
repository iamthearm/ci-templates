# VPS setup & onboarding checklist

This covers three things: setting the VPS up once, onboarding a new app repo, and testing the
whole pipeline safely before it ever touches a real deploy.

Your VPS (`srv1056273.hstgr.cloud`) already runs **Pi-hole** (owns port 443 for its own admin UI)
and two **Minecraft** servers (ports 25565/25566). None of the steps below touch those — the new
stack uses port 80 (free) and a new port, **8443**, for its own HTTPS traffic. Apps are reached at
`https://srv1056273.hstgr.cloud:8443/<app_name>/...`.

---

## 1. VPS setup (once, total — not per app)

Run these as root or with `sudo` on the VPS.

**1.1 Confirm Docker is installed** (the original brief says it already is):
```bash
docker --version
docker compose version
```

**1.2 Double-check nothing new collides with the ports this stack needs** (80 and 8443):
```bash
sudo ss -tlnp | grep -E ':80 |:8443 '
```
This should print nothing. If it does, stop and figure out what's there before continuing —
don't proceed past this step with a port conflict.

**1.3 Create the shared Docker network** that the proxy and every app will join:
```bash
sudo docker network create edge
```

**1.4 Bring up the shared Caddy edge stack.** Copy `ci-templates/edge/` from this workspace to the
VPS as `/opt/edge/`:
```bash
sudo mkdir -p /opt/edge
# from your local machine:
scp ci-templates/edge/docker-compose.edge.yml your-user@srv1056273.hstgr.cloud:/opt/edge/docker-compose.yml
scp ci-templates/edge/Caddyfile.base your-user@srv1056273.hstgr.cloud:/opt/edge/Caddyfile.base

# back on the VPS:
cd /opt/edge
sudo docker compose up -d
sudo docker compose logs -f   # watch for "certificate obtained successfully" once an app registers
```
Note: Caddy doesn't request a TLS certificate until at least one app is actually routed through
it, so `docker compose logs` will look quiet until you complete step 3 below for your first app.

**1.5 Log the VPS in to GHCR once**, so `docker compose pull` works on every future deploy without
CI ever handling a registry credential:
- On GitHub: create a [Personal Access Token](https://github.com/settings/tokens) (classic) with
  only the `read:packages` scope.
- On the VPS:
  ```bash
  echo '<the PAT>' | sudo docker login ghcr.io -u <your-github-username> --password-stdin
  ```
  This persists in the VPS's Docker credential store. CI never sees or transmits this token.

**1.6 Create a dedicated deploy user**, SSH-key-only, scoped to app directories:
```bash
sudo adduser --disabled-password deploy
sudo usermod -aG docker deploy   # so it can run docker compose without sudo
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
```
Generate a dedicated deploy key pair **on your own machine** (not reused from your personal key):
```bash
ssh-keygen -t ed25519 -f ./ci-deploy-key -C "ci-templates-deploy" -N ""
```
Put the public key on the VPS:
```bash
cat ci-deploy-key.pub | sudo tee -a /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```
Keep `ci-deploy-key` (the private half) — it becomes the `VPS_SSH_KEY` secret below.

**1.7 Create the apps directory:**
```bash
sudo mkdir -p /opt/apps
sudo chown deploy:deploy /opt/apps
```

**1.8 Capture the VPS's SSH host key** (once, from a network/machine you trust — this becomes the
`VPS_HOST_KEY` secret, and is how CI verifies it's really talking to your VPS instead of blindly
disabling host-key checking):
```bash
ssh-keyscan -t ed25519 srv1056273.hstgr.cloud
```
Save the exact output (one or more lines) — you'll paste it verbatim into a secret in step 2.

---

## 2. Per-repo GitHub secrets (once per repo that opts in)

Repo → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `VPS_HOST` | `srv1056273.hstgr.cloud` (used both for SSH and as the Caddy routing hostname) |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Contents of the `ci-deploy-key` private key file from step 1.6 |
| `VPS_HOST_KEY` | The exact output of `ssh-keyscan` from step 1.8 |
| `UNITY_LICENSE` | Only needed if a repo sets `unity.enabled: true` in its config |

You can reuse the same `VPS_SSH_KEY`/`VPS_HOST_KEY`/`VPS_HOST`/`VPS_USER` values across every repo
that deploys to this same VPS — they aren't per-app.

**After the first push of a new app**, check its GHCR package's visibility
(`github.com/<you>?tab=packages` → the package → Package settings) and confirm it's **Private**.
`GITHUB_TOKEN` pushes are usually private by default, but this isn't guaranteed under every org
policy — worth a 10-second check the first time, not something to assume silently works.

---

## 3. Onboarding a new app repo

1. Add `.github/deploy.config.yml` (copy `ci-templates/examples/deploy.config.node.yml` as a
   starting point) and the caller workflow from the main `ci-templates/README.md`.
2. Pick a `path_prefix` that isn't already used by another app on this VPS — nothing enforces
   uniqueness automatically today, so this is on you as long as you're the only one onboarding
   apps. (Worth adding a check if that ever changes.)
3. On the VPS, create the app's directory and its `.env` **before the first push**:
   ```bash
   sudo -u deploy mkdir -p /opt/apps/<app_name>
   sudo -u deploy nano /opt/apps/<app_name>/.env
   ```
   Fill in real values for every name listed under that app's `deploy.env.required` /
   `deploy.env.optional` in its config. CI validates these names exist before every deploy and
   fails loudly (before touching the running container) if one is missing.
4. Set the four secrets on the repo (step 2 above), if not already set.
5. Push to `main` and watch the Actions run.

If the app serves browser content (not just a JSON API), read the path-prefix caveat in the main
README/deploy action comments first: **apps that emit root-relative asset URLs (SPAs, WebGL
builds) break under path-based routing unless they support a configurable base path.** This
doesn't affect `example-node-app`'s health endpoint, but it will bite the first browser-facing app
you onboard if you don't check for it first.

---

## 4. Testing the pipeline safely before a real deploy matters

Do this with `example-node-app` (in this workspace) before wiring up anything you actually care
about, including Gridlock:

1. Push `example-node-app` to its own throwaway GitHub repo with the caller workflow + config from
   this workspace. Complete steps 1–3 above for it (`path_prefix: /example-node-app`).
2. Watch the Actions run go green through test → build → smoke-test → deploy.
3. `curl -k https://srv1056273.hstgr.cloud:8443/example-node-app/health` — expect `{"status":"ok"}`.
4. **Deliberately break rollback once**, on purpose, while it's still a throwaway app:
   - Ship a second version whose `/health` returns a non-200 (edit `server.js` temporarily).
     Confirm the workflow fails and the app is still serving the *first* good version.
   - Then simulate a first-deploy failure: `sudo rm -rf /opt/apps/example-node-app` on the VPS to
     reset it to a clean slate, push a version with a deliberately broken health check, and
     confirm the deploy stops the container instead of leaving a broken one publicly routable
     (see [`ROLLBACK.md`](ROLLBACK.md) for exactly what should happen in each case).
5. Only once that round-trips the way `ROLLBACK.md` describes, onboard Gridlock — starting from
   `examples/deploy.config.gridlock.yml`, which ships with `deploy.enabled: false` and
   `unity.enabled: false` so it won't need a Unity CI license or attempt a VPS deploy on day one.

## See also

- [`ROLLBACK.md`](ROLLBACK.md) — exactly what the pipeline does on a failed health check
- [`../README.md`](../README.md) — repo layout, versioning policy, how a repo opts in
