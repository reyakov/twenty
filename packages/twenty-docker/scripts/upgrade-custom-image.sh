#!/usr/bin/env bash
set -euo pipefail

# Upgrades an existing Docker Compose Twenty instance to a prebuilt image.
# Run this on the remote Docker host, from anywhere. It does not build anything.

usage() {
  cat <<'USAGE'
Usage:
  upgrade-custom-image.sh --image IMAGE [options]

Required:
  --image IMAGE             Prebuilt image to deploy, e.g. ghcr.io/reyakov/twenty:2.56.0-915187c

Options:
  --tag TAG                 Local Compose tag (default: local-YYYYmmdd-HHMMSS)
  --compose-dir DIR         Directory containing the Compose file (default: current directory)
  --compose-file FILE       Compose file (default: DIR/docker-compose.yml)
  --env-file FILE           Environment file (default: DIR/.env)
  --backup-dir DIR          Backup directory (default: DIR/backups/twenty-upgrade-TIMESTAMP)
  --compose-image REPO      Compose application repository (default: twentycrm/twenty)
  --health-url URL          Health endpoint (default: http://127.0.0.1:SERVER_PORT/healthz)
  --health-timeout SECONDS  Health wait timeout (default: 1800)
  --yes                     Skip the confirmation prompt
  --help                    Show this help

The script:
  1. Pulls and architecture-checks the image.
  2. Backs up Postgres, the DB volume, server-local-data, and .env.
  3. Stops server and worker; runs the server entrypoint upgrade.
  4. Waits for /healthz and checks upgrade errors.
  5. Starts the worker.
  6. Writes backups/.../rollback.sh with the exact restore commands.
USAGE
}

IMAGE=""
TAG="local-$(date +%Y%m%d-%H%M%S)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
COMPOSE_DIR="$PWD"
COMPOSE_FILE=""
ENV_FILE=""
BACKUP_DIR=""
COMPOSE_IMAGE="twentycrm/twenty"
HEALTH_URL=""
HEALTH_TIMEOUT=1800
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE="${2:?--image requires a value}"
      shift 2
      ;;
    --tag)
      TAG="${2:?--tag requires a value}"
      shift 2
      ;;
    --compose-dir)
      COMPOSE_DIR="${2:?--compose-dir requires a value}"
      shift 2
      ;;
    --compose-file)
      COMPOSE_FILE="${2:?--compose-file requires a value}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:?--env-file requires a value}"
      shift 2
      ;;
    --backup-dir)
      BACKUP_DIR="${2:?--backup-dir requires a value}"
      shift 2
      ;;
    --compose-image)
      COMPOSE_IMAGE="${2:?--compose-image requires a value}"
      shift 2
      ;;
    --health-url)
      HEALTH_URL="${2:?--health-url requires a value}"
      shift 2
      ;;
    --health-timeout)
      HEALTH_TIMEOUT="${2:?--health-timeout requires a value}"
      shift 2
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -n "$IMAGE" ]] || {
  usage
  exit 2
}
[[ -d "$COMPOSE_DIR" ]] || die "Compose directory does not exist: $COMPOSE_DIR"
COMPOSE_DIR="$(cd "$COMPOSE_DIR" && pwd)"

if [[ -z "$COMPOSE_FILE" ]]; then
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
fi
if [[ "$COMPOSE_FILE" != /* ]]; then
  COMPOSE_FILE="$COMPOSE_DIR/$COMPOSE_FILE"
fi
[[ -f "$COMPOSE_FILE" ]] || die "Compose file does not exist: $COMPOSE_FILE"

if [[ -z "$ENV_FILE" ]]; then
  ENV_FILE="$COMPOSE_DIR/.env"
fi
if [[ "$ENV_FILE" != /* ]]; then
  ENV_FILE="$COMPOSE_DIR/$ENV_FILE"
fi
[[ -f "$ENV_FILE" ]] || die "Environment file does not exist: $ENV_FILE"

if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="$COMPOSE_DIR/backups/twenty-upgrade-$TIMESTAMP"
fi
mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"

compose() {
  docker compose \
    --project-directory "$COMPOSE_DIR" \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    "$@"
}

compose config --quiet >/dev/null

SERVICES="$(compose config --services)"
printf '%s\n' "$SERVICES" | grep -qx "server" || die "Compose service 'server' is required"
printf '%s\n' "$SERVICES" | grep -qx "worker" || die "Compose service 'worker' is required"

HAS_DB=false
if printf '%s\n' "$SERVICES" | grep -qx "db"; then
  HAS_DB=true
else
  die "No db service in this Compose project; back up the external database separately before using this script"
fi

SERVER_CONTAINER="$(compose ps -q server || true)"
[[ -n "$SERVER_CONTAINER" ]] || die "The server container is not running; start the current stack first"

CURRENT_SERVER_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$SERVER_CONTAINER")"
CURRENT_SERVER_REPOSITORY="${CURRENT_SERVER_IMAGE%:*}"
[[ "$CURRENT_SERVER_REPOSITORY" == "$COMPOSE_IMAGE" ]] || die "Server image is $CURRENT_SERVER_IMAGE but Compose is expected to use $COMPOSE_IMAGE; pass --compose-image with the correct repository"

DISABLE_MIGRATIONS="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$SERVER_CONTAINER" | awk -F= '/^DISABLE_DB_MIGRATIONS=/{print $2; exit}')"
if [[ "$DISABLE_MIGRATIONS" == "true" ]]; then
  die "DISABLE_DB_MIGRATIONS=true for the server; unset it or set it to false before upgrading"
fi

DB_CONTAINER=""
if [[ "$HAS_DB" == "true" ]]; then
  DB_CONTAINER="$(compose ps -q db || true)"
  [[ -n "$DB_CONTAINER" ]] || die "The db container is not running; start the current stack first"
fi

DB_VOLUME=""
if [[ -n "$DB_CONTAINER" ]]; then
  DB_VOLUME="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$DB_CONTAINER")"
  [[ -n "$DB_VOLUME" ]] || die "Could not resolve the Postgres volume for the db container"
fi

FILES_VOLUME="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/packages/twenty-server/.local-storage"}}{{.Name}}{{end}}{{end}}' "$SERVER_CONTAINER")"

PREVIOUS_TAG="$(awk -F= '/^TAG=/ {print $2; exit}' "$ENV_FILE")"
COMPOSE_REF="$COMPOSE_IMAGE:$TAG"

echo "==> Target image: $IMAGE"
echo "==> Compose tag: $COMPOSE_REF"
echo "==> Backup directory: $BACKUP_DIR"

if [[ "$ASSUME_YES" != "true" ]]; then
  printf 'Stop the stack, back it up, and upgrade to %s? [y/N] ' "$IMAGE"
  read -r REPLY
  case "$REPLY" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

echo "==> Pulling image"
docker pull "$IMAGE"

IMAGE_ARCH="$(docker image inspect -f '{{.Architecture}}' "$IMAGE")"
DAEMON_ARCH="$(docker version -f '{{.Server.Arch}}')"
case "$DAEMON_ARCH" in
  x86_64) DAEMON_ARCH="amd64" ;;
  aarch64|arm64) DAEMON_ARCH="arm64" ;;
esac
[[ "$IMAGE_ARCH" == "$DAEMON_ARCH" ]] || die "Image architecture is $IMAGE_ARCH but Docker is $DAEMON_ARCH"

docker tag "$IMAGE" "$COMPOSE_REF"

cp "$ENV_FILE" "$BACKUP_DIR/env.before"
compose images > "$BACKUP_DIR/compose-images.before.txt"
printf 'previous_tag=%s\nnew_tag=%s\nimage=%s\n' "$PREVIOUS_TAG" "$TAG" "$IMAGE" > "$BACKUP_DIR/metadata.txt"

ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "cd \"$COMPOSE_DIR\""
  echo "docker compose --project-directory \"$COMPOSE_DIR\" -f \"$COMPOSE_FILE\" --env-file \"$ENV_FILE\" down"
  if [[ -n "$DB_VOLUME" ]]; then
    echo "docker run --rm -v \"$DB_VOLUME\":/var/lib/postgresql/data -v \"$BACKUP_DIR\":/backup alpine sh -c 'rm -rf /var/lib/postgresql/data/* && tar xzf /backup/db-volume.tgz -C /var/lib/postgresql/data'"
  fi
  if [[ -n "$FILES_VOLUME" ]]; then
    echo "docker run --rm -v \"$FILES_VOLUME\":/data -v \"$BACKUP_DIR\":/backup alpine sh -c 'rm -rf /data/* && tar xzf /backup/files.tgz -C /data'"
  fi
  echo "cp \"$BACKUP_DIR/env.before\" \"$ENV_FILE\""
  echo "docker compose --project-directory \"$COMPOSE_DIR\" -f \"$COMPOSE_FILE\" --env-file \"$ENV_FILE\" up -d"
} > "$ROLLBACK_SCRIPT"
chmod +x "$ROLLBACK_SCRIPT"

echo "==> Stopping writers"
compose stop worker server

if [[ "$HAS_DB" == "true" ]]; then
  echo "==> Dumping Postgres"
  compose exec -T db sh -lc 'pg_dumpall -U "$POSTGRES_USER"' > "$BACKUP_DIR/db.sql"
  [[ -s "$BACKUP_DIR/db.sql" ]] || die "Postgres dump is empty"
  compose stop db
fi

echo "==> Stopping the stack"
compose down

if [[ -n "$DB_VOLUME" ]]; then
  echo "==> Archiving Postgres volume $DB_VOLUME"
  docker run --rm \
    -v "$DB_VOLUME":/var/lib/postgresql/data:ro \
    -v "$BACKUP_DIR":/backup \
    alpine tar czf /backup/db-volume.tgz -C /var/lib/postgresql/data .
fi

if [[ -n "$FILES_VOLUME" ]]; then
  echo "==> Archiving local files volume $FILES_VOLUME"
  docker run --rm \
    -v "$FILES_VOLUME":/data:ro \
    -v "$BACKUP_DIR":/backup \
    alpine tar czf /backup/files.tgz -C /data .
fi

awk -v tag="$TAG" 'BEGIN { replaced = 0 } /^TAG=/ { print "TAG=" tag; replaced = 1; next } { print } END { if (!replaced) print "TAG=" tag }' "$ENV_FILE" > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"

if [[ "$HAS_DB" == "true" ]]; then
  compose up -d db
fi
if printf '%s\n' "$SERVICES" | grep -qx "redis"; then
  compose up -d redis
fi
compose up -d server

if [[ -z "$HEALTH_URL" ]]; then
  SERVER_PORT="$(compose port server 3000 2>/dev/null | tail -n 1 | awk -F: '{print $NF}')"
  HEALTH_URL="http://127.0.0.1:${SERVER_PORT:-3000}/healthz"
fi

echo "==> Waiting for $HEALTH_URL"
SERVER_ID="$(compose ps -q server)"
START_TIME=$(date +%s)
HEALTHY=false
while true; do
  if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    HEALTHY=true
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$SERVER_ID" 2>/dev/null || echo false)" != "true" ]]; then
    compose logs --tail=200 server
    die "Server container exited during upgrade. Rollback: bash $ROLLBACK_SCRIPT"
  fi
  if [[ "$(($(date +%s) - START_TIME))" -ge "$HEALTH_TIMEOUT" ]]; then
    compose logs --tail=200 server
    die "Timed out waiting for health. Rollback: bash $ROLLBACK_SCRIPT"
  fi
  sleep 5
done

if compose logs server | grep -qE 'Upgrade completed with errors|Upgrade failed'; then
  compose logs --tail=200 server
  die "Upgrade reported errors. Rollback: bash $ROLLBACK_SCRIPT"
fi

UPGRADE_STATUS="$(compose exec -T server timeout 120 yarn command:prod upgrade:status 2>&1 || true)"
printf '%s\n' "$UPGRADE_STATUS" > "$BACKUP_DIR/upgrade-status.txt"
printf '%s\n' "$UPGRADE_STATUS"

if printf '%s\n' "$UPGRADE_STATUS" | grep -qE 'Status:[[:space:]]+(Behind|Failed)|Workspaces:.*[1-9][0-9]* (behind|failed)|Instance:[[:space:]]+(Behind|Failed)'; then
  die "upgrade:status reports unfinished migrations. Rollback: bash $ROLLBACK_SCRIPT"
fi

echo "==> Starting worker"
compose up -d worker
compose ps

echo
echo "Upgrade complete."
echo "Image:  $IMAGE"
echo "Tag:    $TAG"
echo "Backup: $BACKUP_DIR"
echo "Rollback: bash $ROLLBACK_SCRIPT"
