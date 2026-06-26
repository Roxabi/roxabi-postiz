#!/usr/bin/env bash
# Postiz image converge — pull upstream, validate runtime, pin digest, restart.
#
# Prevents the v1.47.0 class of failure: old Node + unpinned `pnpx prisma` at boot.
#
# Usage (on M1):
#   ./deploy/converge.sh              # pull :latest, validate, pin, restart postiz-app
#   ./deploy/converge.sh --all        # same + pull/restart full stack (db, redis, temporal…)
#   ./deploy/converge.sh --check      # validate running container only
#   POSTIZ_APP_REF=ghcr.io/.../postiz-app:latest ./deploy/converge.sh
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
LOCK="${DEPLOY_DIR}/images.lock.env"
QUADLET_SRC="${DEPLOY_DIR}/quadlet"
QUADLET_DST="${HOME}/.config/containers/systemd"
APP_UNIT="${QUADLET_DST}/postiz-app.container"
APP_SERVICE="postiz-app.service"
REF="${POSTIZ_APP_REF:-ghcr.io/gitroomhq/postiz-app:latest}"
MIN_NODE_MAJOR=20
MIN_NODE_MINOR=19
CHECK_ONLY=false
CONVERGE_ALL=false
STARTUP_TIMEOUT_SEC=180
INFRA_SERVICES=(postiz-db postiz-redis postiz-temporal-db postiz-temporal-es)
TEMPORAL_SERVICES=(postiz-temporal postiz-temporal-ui)

usage() {
  sed -n '2,10p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) CHECK_ONLY=true; shift ;;
    --all) CONVERGE_ALL=true; shift ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

semver_ge() {
  # args: current required_major required_minor
  local ver="${1#v}"
  local need_major="$2"
  local need_minor="$3"
  local major minor
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  if (( major > need_major )); then return 0; fi
  if (( major < need_major )); then return 1; fi
  (( minor >= need_minor ))
}

validate_image() {
  local image="$1"
  local node_ver prisma_script

  node_ver="$(podman run --rm "${image}" node -v)"
  if ! semver_ge "${node_ver}" "${MIN_NODE_MAJOR}" "${MIN_NODE_MINOR}"; then
    echo "FAIL: ${image} has Node ${node_ver}; need >= ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR}" >&2
    return 1
  fi

  prisma_script="$(podman run --rm "${image}" sh -c "node -e \"const p=require('/app/package.json'); process.stdout.write(p.scripts['prisma-db-push']||'')\"")"
  if [[ -z "${prisma_script}" ]]; then
    echo "FAIL: ${image} missing scripts.prisma-db-push" >&2
    return 1
  fi
  if [[ "${prisma_script}" == *"pnpx prisma db push"* ]] || [[ "${prisma_script}" == *"pnpm dlx prisma db push"* ]]; then
    echo "FAIL: ${image} uses unpinned prisma at boot: ${prisma_script}" >&2
    return 1
  fi
  if [[ "${prisma_script}" != *"prisma@"* ]]; then
    echo "FAIL: ${image} prisma-db-push must pin prisma@<version>: ${prisma_script}" >&2
    return 1
  fi

  echo "OK: ${image} node=${node_ver} prisma-db-push pinned"
}

wait_for_http() {
  local url="$1"
  local deadline=$((SECONDS + STARTUP_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "${url}" 2>/dev/null || echo 000)"
    if [[ "${code}" =~ ^[23] ]]; then
      echo "OK: ${url} -> HTTP ${code}"
      return 0
    fi
    sleep 5
  done
  echo "FAIL: ${url} not healthy within ${STARTUP_TIMEOUT_SEC}s (last HTTP ${code:-000})" >&2
  podman logs --tail 30 postiz-app >&2 || true
  return 1
}

pull_stack_images() {
  local quadlet image
  for quadlet in "${QUADLET_SRC}"/postiz-*.container; do
    [[ -f "${quadlet}" ]] || continue
    [[ "$(basename "${quadlet}")" == "postiz-app.container" ]] && continue
    image="$(grep '^Image=' "${quadlet}" | head -1 | cut -d= -f2-)"
    [[ -n "${image}" ]] || continue
    echo "==> Pull ${image}"
    podman pull "${image}"
  done
}

wait_for_container_health() {
  local name="$1"
  local timeout="${2:-120}"
  local deadline=$((SECONDS + timeout))
  local status
  while (( SECONDS < deadline )); do
    status="$(podman inspect "${name}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo missing)"
    case "${status}" in
      healthy|none) echo "OK: ${name} health=${status}"; return 0 ;;
      unhealthy)
        echo "FAIL: ${name} unhealthy" >&2
        podman logs --tail 20 "${name}" >&2 || true
        return 1
        ;;
    esac
    sleep 3
  done
  echo "WARN: ${name} health=${status} after ${timeout}s (continuing)" >&2
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local timeout="${3:-120}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if podman run --rm --network postiz docker.io/library/busybox:1.36 \
      sh -c "nc -z ${host} ${port}" >/dev/null 2>&1; then
      echo "OK: ${host}:${port} reachable"
      return 0
    fi
    sleep 3
  done
  echo "FAIL: ${host}:${port} not reachable within ${timeout}s" >&2
  return 1
}

restart_full_stack() {
  local svc
  echo "==> Restart infra"
  systemctl --user restart postiz-temporal-es.service
  sleep 45
  wait_for_tcp postiz-temporal-es 9200 180 || true
  for svc in postiz-db postiz-redis postiz-temporal-db; do
    systemctl --user restart "${svc}.service"
  done
  sleep 15
  for svc in postiz-db postiz-redis postiz-temporal-db postiz-temporal-es; do
    wait_for_container_health "${svc}" 90 || true
  done

  echo "==> Restart temporal"
  systemctl --user restart postiz-temporal.service
  sleep 45
  wait_for_tcp postiz-temporal 7233 180 || true
  if ! systemctl --user is-active --quiet postiz-temporal.service; then
    echo "FAIL: postiz-temporal.service not active" >&2
    systemctl --user status postiz-temporal.service --no-pager -l | tail -20 >&2 || true
    return 1
  fi

  echo "==> Restart ui + app"
  systemctl --user restart postiz-temporal-ui.service postiz-app.service
}

check_running() {
  if ! podman ps --format '{{.Names}}' | grep -qx postiz-app; then
    echo "FAIL: postiz-app container not running" >&2
    return 1
  fi
  local node_ver
  node_ver="$(podman exec postiz-app node -v)"
  if ! semver_ge "${node_ver}" "${MIN_NODE_MAJOR}" "${MIN_NODE_MINOR}"; then
    echo "FAIL: running postiz-app has Node ${node_ver}" >&2
    return 1
  fi
  wait_for_http "http://127.0.0.1:4007/auth"
}

render_app_quadlet() {
  local image="$1"
  local src="${QUADLET_SRC}/postiz-app.container"
  local dst="${APP_UNIT}"
  mkdir -p "${QUADLET_DST}"
  sed "s|^Image=.*|Image=${image}|" "${src}" >"${dst}"
}

update_lock() {
  local ref="$1"
  local image="$2"
  local node_ver="$3"
  local today
  today="$(date +%F)"
  cat >"${LOCK}" <<EOF
# Pinned container images for M1 Postiz stack.
# Bump postiz-app via: deploy/converge.sh
# Never hand-edit Image= in postiz-app.container — converge updates both.

POSTIZ_APP_REF=${ref}
POSTIZ_APP_IMAGE=${image}
POSTIZ_APP_NODE=${node_ver}
POSTIZ_APP_PINNED_AT=${today}
EOF
}

if [[ "${CHECK_ONLY}" == true ]]; then
  check_running
  exit 0
fi

echo "==> Pull ${REF}"
podman pull "${REF}"

digest_image="$(podman inspect "${REF}" --format '{{range .RepoDigests}}{{if eq (printf "%.18s" .) "ghcr.io/gitroomhq/p"}}{{.}}{{end}}{{end}}')"
if [[ -z "${digest_image}" ]]; then
  digest_image="$(podman inspect "${REF}" --format '{{index .RepoDigests 0}}')"
fi
if [[ -z "${digest_image}" || "${digest_image}" != *@sha256:* ]]; then
  id="$(podman inspect "${REF}" --format '{{.Id}}')"
  digest_image="ghcr.io/gitroomhq/postiz-app@${id}"
fi

echo "==> Validate ${digest_image}"
validate_image "${digest_image}"

node_ver="$(podman run --rm "${digest_image}" node -v)"

echo "==> Sync quadlets + converge timer"
rsync -av "${QUADLET_SRC}/" "${QUADLET_DST}/"
render_app_quadlet "${digest_image}"
mkdir -p "${HOME}/.config/systemd/user"
rsync -av "${DEPLOY_DIR}/systemd/" "${HOME}/.config/systemd/user/"
update_lock "${REF}" "${digest_image}" "${node_ver}"

if [[ "${CONVERGE_ALL}" == true ]]; then
  pull_stack_images
fi

echo "==> Reload systemd"
systemctl --user daemon-reload
systemctl --user enable postiz-converge.timer

if [[ "${CONVERGE_ALL}" == true ]]; then
  restart_full_stack
else
  systemctl --user restart "${APP_SERVICE}"
fi

wait_for_http "http://127.0.0.1:4007/auth"
if [[ "${CONVERGE_ALL}" == true ]]; then
  wait_for_http "http://127.0.0.1:8080/" || true
fi
echo "==> Converge complete: ${digest_image} (${node_ver})${CONVERGE_ALL:+, full stack}"