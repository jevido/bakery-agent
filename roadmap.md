# bakery-agent

A lightweight deployment agent that lets you deploy multiple containerized apps to a single VPS.

---

## Vision

Users should be able to install bakery-agent on any Debian 13 VPS with a single command, then deploy any Containerized app by pushing to GitHub. No managed platform, no vendor lock-in — just your VPS.

---

## Technical Decisions

| Decision              | Choice                        | Rationale                                              |
|-----------------------|-------------------------------|--------------------------------------------------------|
| Language              | Pure Bash                     | No build step, native on Debian, zero dependencies     |
| Containerization      | Podman                        | Daemonless, rootless-capable, drop-in Docker compat    |
| Reverse proxy         | Nginx                         | Battle-tested, simple config generation                |
| SSL                   | Certbot (standalone)          | Free certs, user points DNS to VPS IP manually         |
| State storage         | Flat JSON files               | One file per app, human-inspectable, no extra deps     |
| Secrets               | OpenSSL-encrypted .env files  | No extra dependencies on Debian                        |
| Port assignment       | Auto-assign from range        | Agent picks next free port from 3001–4000              |
| Reverse proxy toggle  | Auto-detect via EXPOSE        | If no EXPOSE in Dockerfile, skip Nginx/SSL entirely    |
| Private repo support  | GitHub PAT                    | Stored in the encrypted secrets store                  |
| Self-update           | Git pull + reinstall          | Agent pulls latest from its repo, re-runs install      |
| Target OS             | Debian 13                     | Stable, widely available on VPS providers              |

---

## Directory Structure on the VPS

```
/etc/bakery/
├── bakery.conf                  # Global agent config (port range, update repo, etc.)
├── secrets.key                  # OpenSSL encryption key for secrets
├── apps/
│   └── <domain>/
│       ├── state.json           # Container ID, port, status, image hash, timestamps
│       ├── .env.enc             # OpenSSL-encrypted environment variables
│       └── nginx.conf           # Generated Nginx site config
└── agent/
    └── ...                      # The bakery-agent source (cloned repo)

/var/log/bakery/
├── agent.log                    # Agent service log
└── deploys/
    └── <domain>-<timestamp>.log # Per-deployment log
```

---

## CLI Commands (Core Set)

| Command                     | Description                                      |
|-----------------------------|--------------------------------------------------|
| `bakery deploy <domain>`    | Deploy an app (clone, build, run, route)         |
| `bakery status [domain]`    | Show status of one or all apps                   |
| `bakery logs <domain>`      | Tail container logs for an app                   |
| `bakery stop <domain>`      | Stop a running app container                     |
| `bakery restart <domain>`   | Restart an app container                         |
| `bakery list`               | List all deployed apps with status and ports     |
| `bakery env set <domain>`   | Set/update encrypted env vars for an app         |
| `bakery env get <domain>`   | Decrypt and display env vars for an app          |
| `bakery update`             | Self-update the agent from GitHub                |

---

## Deployment Pipeline

```
┌─────────────────────────────────────────────────────────┐
│ Stage 0: PUSHING                                        │
│ └─ A push occurs on a git repo                          │
│ └─ A GitHub workflow is executed                        │
│ └─ SSH connection is established                        │
│ └─ bakery deploy $APP_DOMAIN is executed                │
└─────────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────────┐
│ Stage 1: PULLING                                        │
│ └─ Clone git repo (using PAT if private)                │
│ └─ Verify Dockerfile or Containerfile exists            │
└─────────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────────┐
│ Stage 2: BUILDING                                       │
│ └─ Build image with Podman                              │
│ └─ Tag as bakery/<domain>:latest                        │
│ └─ Check cache (skip rebuild if image hash unchanged)   │
└─────────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────────┐
│ Stage 3: DESTROYING                                     │
│ └─ Delete cloned source directory                       │
└─────────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────────┐
│ Stage 4: RUNNING                                        │
│ └─ Auto-assign port from 3001–4000 range               │
│ └─ Decrypt .env.enc and pass vars to container          │
│ └─ Run container with Podman                            │
│ └─ Label container with bakery metadata                 │
│ └─ Write state.json (container ID, port, timestamp)     │
└─────────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────────┐
│ Stage 5: HEALTHCHECK                                    │
│ └─ If EXPOSE detected: poll http://localhost:<port>/    │
│    up to 10 times at 5-second intervals                 │
│ └─ If no EXPOSE: check container is still running       │
│    after 10 seconds                                     │
│ └─ Fail deployment if checks exhausted                  │
└─────────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────────┐
│ Stage 6: ROUTING (skipped if no EXPOSE)                 │
│ └─ Generate Nginx reverse proxy config                  │
│ └─ Provision SSL via Certbot if needed                  │
│ └─ Reload Nginx                                         │
└─────────────────────────────────────────────────────────┘
              ↓
┌──────────────────────┬──────────────────────────────────┐
│ Stage 7a: SUCCESS    │ Stage 7b: FAILED                 │
│ └─ Update state.json │ └─ Log error to deploy log       │
│ └─ Stop old container│ └─ Keep failed container for     │
│    (keep previous 1) │    debugging                     │
│ └─ Log success       │ └─ Clean up cloned source        │
└──────────────────────┴──────────────────────────────────┘
```

---

## Secrets Management

Environment variables are stored encrypted on disk using OpenSSL.

```bash
# Encrypt
openssl enc -aes-256-cbc -pbkdf2 -in .env -out .env.enc -pass file:/etc/bakery/secrets.key

# Decrypt (at deploy time)
openssl enc -aes-256-cbc -pbkdf2 -d -in .env.enc -out /tmp/.env -pass file:/etc/bakery/secrets.key
```

The `bakery env set <domain>` command decrypts the current file, opens an editor, then re-encrypts on save. The GitHub PAT (for private repos) is stored as a global secret in `/etc/bakery/.github-pat.enc`.

---

## Installation

A single command installs the agent:

```bash
curl -fsSL https://raw.githubusercontent.com/jevido/bakery-agent/main/install.sh | sh
```

The install script:
1. Checks for Debian 13
2. Installs dependencies: `podman`, `nginx`, `certbot`, `openssl`, `jq`, `git`
3. Creates the `bakery` system user
4. Clones the agent repo to `/etc/bakery/agent/`
5. Generates the OpenSSL secrets key
6. Installs the `bakery` CLI to `/usr/local/bin/bakery`
7. Installs and enables the `bakery-agent.service` systemd unit
8. Creates the directory structure under `/etc/bakery/` and `/var/log/bakery/`

---

## Self-Update

```bash
bakery update
```

Pulls the latest `main` branch from the agent repo and re-runs the install script in update mode (skips key generation, preserves config).

---

## Reference GitHub Workflow

Users add this to their app repo at `.github/workflows/deploy.yml`:

```yaml
name: Deploy to VPS

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy via bakery-agent
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: bakery
          key: ${{ secrets.VPS_SSH_KEY }}
          script: |
            bakery deploy ${{ secrets.APP_DOMAIN }}
```

**Required GitHub Secrets:**
| Secret         | Description                                       |
|----------------|---------------------------------------------------|
| `VPS_HOST`     | IP address or hostname of the VPS                 |
| `VPS_SSH_KEY`  | SSH private key for the `bakery` user             |
| `APP_DOMAIN`   | Domain the app will be served on (e.g. `app.example.com`) |

The agent determines the git repo URL from the domain's `state.json` (set during first deploy or via `bakery env set`).

---

## state.json Schema

```json
{
  "domain": "app.example.com",
  "repo": "https://github.com/user/app.git",
  "container_id": "abc123...",
  "image": "bakery/app.example.com:latest",
  "port": 3001,
  "status": "running",
  "expose": true,
  "deployed_at": "2026-02-21T14:30:00Z",
  "previous_container_id": "def456..."
}
```

---

## Milestones

### Phase 1 — MVP (Foundation)
Goal: deploy one public repo to one Debian 13 VPS with HTTPS and recoverable state.

Deliverables:
- [x] Project scaffolding (`/etc/bakery`, `/var/log/bakery`, systemd unit)
- [x] `install.sh` script (dependency install, `bakery` user, key generation)
- [x] `bakery deploy <domain>` for public repos (pipeline stages 0–7)
- [x] Nginx config generation and Certbot SSL provisioning
- [x] Port assignment from configured range (`3001`–`4000` default)
- [x] `state.json` read/write helpers
- [x] Per-deployment logs in `/var/log/bakery/deploys/`
- [x] Reference GitHub Actions workflow in project docs

Acceptance criteria:
- [x] Fresh Debian 13 VM can install with one command
- [x] Push to `main` deploys app and serves valid HTTPS cert
- [x] Redeploy replaces old container and updates `state.json`
- [x] Failed deploy keeps previous healthy container running

### Phase 2 — Usability (Day-to-day Operations)
Goal: make multi-app operations predictable without manual VPS access.

Deliverables:
- [x] `bakery list` (domain, status, port, deployed_at)
- [x] `bakery status <domain>` (detailed app state + health)
- [x] `bakery logs <domain>` (pass-through podman logs)
- [x] `bakery stop <domain>` and `bakery restart <domain>`
- [x] `bakery env set/get <domain>` encrypted env management
- [x] Auto-detect `EXPOSE` to skip Nginx/SSL for worker apps
- [x] `Containerfile` support alongside `Dockerfile`

Acceptance criteria:
- [x] Operators can manage app lifecycle with CLI only
- [x] Non-web apps deploy without proxy/cert steps
- [x] Secret edits persist and are visible on next deploy

### Phase 3 — Private Repos & Secrets
Goal: support private GitHub repos with secure credentials handling.

Deliverables:
- [x] GitHub PAT storage in encrypted secrets store
- [x] Private clone flow via PAT-authenticated HTTPS
- [x] `bakery update` self-update command
- [x] Actionable SSL failure output (DNS fix instructions)

Acceptance criteria:
- [x] Private repo deploy works from GitHub Actions
- [x] PAT never appears in logs, process list, or plaintext files
- [x] `bakery update` preserves existing config and keys

### Phase 4 — Hardening
Goal: improve resilience, resource safety, and long-run operability.

Deliverables:
- [x] Rollback to previous container on failed deploy
- [x] Resource limits (CPU/memory) via app or global config
- [x] Deploy lock per domain (prevent concurrent deploys)
- [x] Image cleanup policy (keep latest 2 successful images)
- [x] systemd watchdog integration for agent health
- [x] Log rotation for `/var/log/bakery/*`

Acceptance criteria:
- [ ] Concurrent deploy attempts are rejected with clear error
- [ ] OOM/noisy app cannot starve host resources
- [ ] Logs and images remain bounded over time

---

## Execution Order (Recommended)

1. Build Phase 1 completely before any Phase 2 command work.
2. Add lifecycle commands (`list/status/logs/stop/restart`) before env UX polish.
3. Implement private repo auth before self-update to reduce support risk.
4. Ship rollback and deploy locks before introducing resource tuning flags.

---

## Task Breakdown (Immediate Next Work)

### Sprint A — Installer + Deploy Spine
- [x] Add `install.sh` with idempotent dependency/install steps
- [x] Add `bakery` CLI entrypoint and subcommand routing
- [x] Add config loader for `/etc/bakery/bakery.conf`
- [x] Implement deploy stages 1–4 (clone/build/run/state write)
- [x] Add deploy log file creation and tee output

### Sprint B — Routing + Health + Failure Behavior
- [x] Implement stage 5 health checks (web and non-web modes)
- [x] Implement stage 6 Nginx config + cert provisioning
- [x] Add stage 7 success/failure handling with old container retention
- [x] Add integration smoke test script for single-app deploy

### Sprint C — Operator Commands
- [x] Implement `list`, `status`, `logs`, `stop`, `restart`
- [x] Implement `env set/get` encrypted editor workflow
- [x] Add schema validation for `state.json`
- [x] Add CLI error contract (exit codes and stderr format)

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Certbot challenge fails due to DNS timing | Deploy appears broken | Print explicit DNS checks and retry path |
| Port collisions or stale state after crash | App unreachable | Validate port availability at runtime; reconcile state from podman labels |
| Secret leakage in logs | Security incident | Redact env/PAT values and avoid command echo with secrets |
| Partial deploy leaves inconsistent resources | Hard-to-debug failures | Transactional deploy flow with cleanup traps in every stage |
| Concurrent deploys race on same domain | Downtime risk | File lock per domain and lock timeout with clear message |

---

## Definition of Done (Per Feature)

- [ ] Command has usage/help text and non-zero exit on invalid input
- [ ] Writes structured logs with timestamp + domain + stage
- [ ] Updates `state.json` atomically (`mv` temp file)
- [ ] Includes at least one happy-path and one failure-path test
- [ ] Documented in README with example command
