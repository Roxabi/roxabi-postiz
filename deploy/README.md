# Postiz Deployment — Quadlet (Podman + systemd)

Self-hosted Postiz on M1 (`roxabituwer`) via Podman Quadlet user units.

## Stack

| Service | Image | Purpose |
|---------|-------|---------|
| postiz-app | `ghcr.io/gitroomhq/postiz-app:latest` | NextJS frontend + NestJS backend |
| postiz-db | `docker.io/library/postgres:17-alpine` | App database |
| postiz-redis | `docker.io/library/redis:7.2` | Cache / queue |
| postiz-temporal | `docker.io/temporalio/auto-setup:1.28.1` | Workflow engine |
| postiz-temporal-db | `docker.io/library/postgres:16` | Temporal database |
| postiz-temporal-es | `docker.io/library/elasticsearch:7.17.27` | Temporal search index |
| postiz-temporal-ui | `docker.io/temporalio/ui:2.34.0` | Temporal web UI |

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
    └── postiz.env          # runtime env vars
```

## Install

```bash
# Copy Quadlet units
mkdir -p ~/.config/containers/systemd
rsync -av deploy/quadlet/ ~/.config/containers/systemd/

# Create data dirs
mkdir -p ~/.roxabi/postiz/data/{postgres,redis,temporal-postgres,temporal-es,uploads,config,dynamicconfig}
mkdir -p ~/.roxabi/postiz/env

# Copy env
cp deploy/quadlet/postiz.env.example ~/.roxabi/postiz/env/postiz.env
# Edit JWT_SECRET and URLs

# Reload + start
systemctl --user daemon-reload
systemctl --user start postiz-db postiz-redis postiz-temporal-db postiz-temporal-es
sleep 15
systemctl --user start postiz-temporal
sleep 30
systemctl --user start postiz-temporal-ui postiz-app
```

## URLs

- Postiz app: `http://192.168.1.16:4007`
- Temporal UI: `http://192.168.1.16:8080`

## Auto-start

Enabled via `[Install] WantedBy=default.target` in each `.container` + `loginctl enable-linger $USER`.
