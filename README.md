# bakery-agent

A lightweight deployment agent for deploying multiple containerized apps to a single VPS.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jevido/bakery-agent/main/install.sh | bash
```

Then install runtime dependencies:

```bash
sudo bakery setup
sudo systemctl restart bakery-agent.service
```

## Core Commands

```bash
bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>]
bakery remove <domain>
bakery bootstrap <domain> [--repo <git-url>] [--branch <name>] [--host <vps-host>] [--ssh-user <user>]
bakery setup
bakery pat set
bakery pat get
bakery list
bakery status <domain>
bakery logs <domain>
bakery stop <domain>
bakery restart <domain>
bakery env set <domain>
bakery env get <domain>
bakery update
```

## Deployment from GitHub Actions

Create `.github/workflows/deploy.yml` in your app repo:

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

Required secrets:
- `VPS_HOST`
- `VPS_SSH_KEY`
- `APP_DOMAIN`

You can generate a deploy SSH key and a prefilled workflow template with:

```bash
sudo bakery bootstrap app.example.com --repo https://github.com/org/repo.git --branch main --host your.vps.host --ssh-user bakery
```

Note: the `bakery` user must have a valid login shell (for example `/bin/bash`) so GitHub SSH actions can execute `bakery ...` commands.

`bakery setup` also prepares rootless Podman for the `bakery` user by configuring:
- `/etc/subuid` and `/etc/subgid` ranges
- `/etc/containers/registries.conf.d/010-bakery.conf` with default unqualified registries
- required rootless helpers (`uidmap`, `slirp4netns`, `fuse-overlayfs`)

If you change domain names:
1. Deploy the new domain.
2. Remove old domain resources:

```bash
sudo bakery remove old.example.com
```

## Smoke Test

Run the integration smoke test for a single deploy:

```bash
scripts/smoke-single-app-deploy.sh
```

Optional flags:
- `--domain <domain>`
- `--keep` (preserves the temporary test workspace under `/tmp`)

## Resource Limits

You can set container CPU/memory limits at three levels (highest wins):
- CLI override: `bakery deploy app.example.com --cpu 1.5 --memory 768m`
- Per-app config: `/etc/bakery/apps/<domain>/app.conf`
- Global defaults: `/etc/bakery/bakery.conf`

Per-app config format:

```bash
CPU_LIMIT="1.0"
MEMORY_LIMIT="512m"
```

Global config defaults in `/etc/bakery/bakery.conf`:

```bash
BAKERY_BRANCH="main"
DEFAULT_CPU_LIMIT=""
DEFAULT_MEMORY_LIMIT=""
IMAGE_RETENTION_COUNT=2
```

Deploy from a different branch:

```bash
bakery deploy app.example.com --repo https://github.com/org/repo.git --branch develop
```

## Private Repos

Store your GitHub PAT in encrypted form:

```bash
bakery pat set
```

View the decrypted PAT (for debugging only):

```bash
bakery pat get
```

When deploying `https://github.com/...` repos, bakery uses the encrypted PAT through `GIT_ASKPASS` so the token is not passed in command arguments.

## Notes

- Default config path: `/etc/bakery/bakery.conf`
- App state path: `/etc/bakery/apps/<domain>/state.json`
- Deploy logs path: `/var/log/bakery/deploys/`
- Deploy lock file: `/etc/bakery/apps/<domain>/.deploy.lock` (controlled by `DEPLOY_LOCK_TIMEOUT`, default `0`)
- Failed deploys automatically roll back state/routing to the previous running container when one exists
- Successful deploys prune old managed images per domain (keeping `IMAGE_RETENTION_COUNT`, default `2`)
- Agent service uses systemd watchdog (`WatchdogSec=60s`) and sends heartbeat from `bakery daemon`
- Log rotation policy is installed at `/etc/logrotate.d/bakery-agent` for `agent.log` and deploy logs

## CLI Error Contract

All command errors are printed to stderr as:

`bakery: error: <message>`

Exit codes:
- `2` invalid usage or arguments
- `3` missing or invalid app state
- `4` missing prerequisites (for example missing key file or dependency)
- `5` runtime command failure
