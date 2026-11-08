#!/usr/bin/env bash
set -euo pipefail

# Daily logical database backup plus local file storage for a Docker Compose
# Twenty deployment. Intended to run from root's cron.

COMPOSE_DIR="${COMPOSE_DIR:-/root/crm}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/twenty-backups/daily}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DESTINATION="$BACKUP_ROOT/$TIMESTAMP"
STAGING="$BACKUP_ROOT/.tmp-$TIMESTAMP"

log() {
  printf '%s [twenty-backup] %s\n' "$(date -Is)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v flock >/dev/null 2>&1 || die "flock is required"
command -v gzip >/dev/null 2>&1 || die "gzip is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
[[ -f "$COMPOSE_DIR/docker-compose.yml" ]] || die "missing $COMPOSE_DIR/docker-compose.yml"
[[ -f "$COMPOSE_DIR/.env" ]] || die "missing $COMPOSE_DIR/.env"

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

exec 9>"$BACKUP_ROOT/.backup.lock"
flock -n 9 || {
  log "another backup is already running"
  exit 0
}

AVAILABLE_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR == 2 { print $4 }')"
if [[ -n "$AVAILABLE_KB" ]] && (( AVAILABLE_KB < 2 * 1024 * 1024 )); then
  die "less than 2 GB free on $BACKUP_ROOT"
fi

cd "$COMPOSE_DIR"

DB_CONTAINER="$(docker compose ps -q db || true)"
SERVER_CONTAINER="$(docker compose ps -q server || true)"
[[ -n "$DB_CONTAINER" ]] || die "the db container is not running"
[[ -n "$SERVER_CONTAINER" ]] || die "the server container is not running"

FILES_VOLUME="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/packages/twenty-server/.local-storage"}}{{.Name}}{{end}}{{end}}' "$SERVER_CONTAINER")"

mkdir -p "$STAGING"
chmod 700 "$STAGING"

log "backing up Postgres to $DESTINATION"
docker exec -i "$DB_CONTAINER" sh -lc 'pg_dumpall -U "$POSTGRES_USER"' |
  gzip -9 > "$STAGING/db.sql.gz"
[[ -s "$STAGING/db.sql.gz" ]] || die "Postgres dump is empty"
gzip -t "$STAGING/db.sql.gz"

tar czf "$STAGING/config.tgz" -C "$COMPOSE_DIR" docker-compose.yml .env
tar tzf "$STAGING/config.tgz" >/dev/null

if [[ -n "$FILES_VOLUME" ]]; then
  FILES_PATH="/var/lib/docker/volumes/$FILES_VOLUME/_data"
  [[ -d "$FILES_PATH" ]] || die "local files volume path not found: $FILES_PATH"
  log "backing up local files volume $FILES_VOLUME"
  tar czf "$STAGING/files.tgz" -C "$FILES_PATH" .
  tar tzf "$STAGING/files.tgz" >/dev/null
fi

docker compose ls -a > "$STAGING/docker-compose-ls.txt" 2>/dev/null || true
docker ps --format '{{.Names}} {{.Image}} {{.Status}}' > "$STAGING/docker-ps.txt"

(
  cd "$STAGING"
  sha256sum db.sql.gz config.tgz ${FILES_VOLUME:+files.tgz} > SHA256SUMS
  chmod 600 ./*
)

mv "$STAGING" "$DESTINATION"
chmod 700 "$DESTINATION"

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' \
  -mtime +"$RETENTION_DAYS" -exec rm -rf {} +

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.tmp-*' \
  -mtime +2 -exec rm -rf {} +

du -sh "$DESTINATION"
log "backup complete: $DESTINATION"
