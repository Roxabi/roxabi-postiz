# Postiz Deployment — Quadlet (Podman + systemd)

Self-hosted Postiz on M1 (`roxabituwer`) via Podman Quadlet user units.

## Stack

| Service | Image | Purpose |
|---------|-------|---------|
| postiz-app | `ghcr.io/gitroomhq/postiz-app@sha256:…` | NextJS + NestJS — **digest pin** in `deploy/images.lock.env` (bump via `converge.sh`) |
| postiz-db | `docker.io/library/postgres:17-alpine` | App database |
| postiz-redis | `docker.io/library/redis:7.2` | Cache / queue |
| postiz-temporal | `docker.io/temporalio/auto-setup:1.28.1` | Workflow engine |
| postiz-temporal-db | `docker.io/library/postgres:16` | Temporal database |
| postiz-temporal-es | `docker.io/library/elasticsearch:7.17.27` | Temporal search index |
| postiz-temporal-ui | `docker.io/temporalio/ui:2.34.0` | Temporal web UI |

Never pin `postiz-app` to old semver tags (e.g. `v1.47.0`) — stale Node + unpinned Prisma at boot causes 502.

## Data dirs

```
~/.roxabi/postiz/
├── data/
│   ├── postgres/           # postiz-db
│   ├── redis/              # postiz-redis
│   ├── temporal-postgres/  # temporal-db
│   ├── temporal-es/        # elasticsearch
│   ├── uploads/            # local media storage
│   └── config/             # app config
└── env/
    └── postiz.env          # runtime env vars (NOT_SECURED=true for Tailscale)
```

## Install (first boot on M1)

```bash
git clone https://github.com/Roxabi/roxabi-postiz.git ~/projects/roxabi-postiz
cd ~/projects/roxabi-postiz

mkdir -p ~/.roxabi/postiz/data/{postgres,redis,temporal-postgres,temporal-es,uploads,config,dynamicconfig}
mkdir -p ~/.roxabi/postiz/env
cp deploy/quadlet/postiz.env.example ~/.roxabi/postiz/env/postiz.env
# Edit JWT_SECRET, FRONTEND_URL, MAIN_URL

make install-quadlet
deploy/converge.sh          # pull :latest, validate, pin digest, restart app
make start                  # full stack if not already running
```

## Converge (routine operator sync)

```bash
cd ~/projects/roxabi-postiz
make converge                 # git pull + converge.sh (postiz-app only)
make converge-all             # git pull + converge.sh --all (full stack)
deploy/converge.sh --check    # health check only, no restart
```

Remote from devbox:

```bash
ssh roxabituwer 'cd ~/projects/roxabi-postiz && make converge-all'
```

Weekly timer: `postiz-converge.timer` (runs `deploy/converge.sh`).

## URLs

- Postiz app (Tailscale): `https://roxabituwer.goose-logarithm.ts.net:4007`
- Postiz app (LAN): `http://192.168.1.16:4007`
- Temporal UI: `http://192.168.1.16:8080`

## Auto-start

Enabled via `[Install] WantedBy=default.target` in each `.container` + `loginctl enable-linger $USER`.