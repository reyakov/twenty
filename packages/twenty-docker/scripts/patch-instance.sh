#!/usr/bin/env bash
#
# Backup, patch in place, and validate a live Twenty instance installed with the
# self-hosting docker-compose setup:
# https://docs.twenty.com/developers/self-host/capabilities/docker-compose
#
# "Patch in place" means the `server` and `worker` containers are recreated
# against a new image while `db` and `redis` keep running untouched: no volume is
# removed, no data is re-initialised, and `docker compose down` is never used.
#
# Commands:
#   all        backup + patch + validate (default)
#   backup     dump the database, verify the dump restores, archive local storage, copy config
#   patch      build (or pull) the new image, switch the deployment to it, recreate server + worker
#   validate   health, patch presence inside the running image, data invariants, running version
#   rollback   point server + worker back at the tag recorded by the last patch
#
# Run `./patch-instance.sh --help` for the environment variables that configure it.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

COMMAND=all

# Directory holding the live docker-compose.yml and .env.
COMPOSE_DIR=${COMPOSE_DIR:-$PWD}
# Twenty checkout the patched image is built from (defaults to the repo this script lives in).
REPO_ROOT=${REPO_ROOT:-$SCRIPT_DIR/../../..}
# Where backups and the patch record are written.
BACKUP_ROOT=${BACKUP_ROOT:-}
# build = build the image from REPO_ROOT; pull = fetch TAG from the registry.
PATCH_MODE=${PATCH_MODE:-build}
# Tag applied to the patched image. Defaults to patch-<git sha>-<timestamp>.
PATCH_TAG=${PATCH_TAG:-}
# Image repository the deployment resolves TAG against. Defaults to the repository
# of the image the server container is already running.
PATCH_IMAGE_REPO=${PATCH_IMAGE_REPO:-}
# docker build --platform value. Defaults to the host architecture.
PLATFORM=${PLATFORM:-}
# Guard rails.
SKIP_BUILD=${SKIP_BUILD:-0}
SKIP_RESTORE_DRILL=${SKIP_RESTORE_DRILL:-0}
SKIP_VOLUME_BACKUP=${SKIP_VOLUME_BACKUP:-0}
# Seconds to wait for the server container to report healthy after the patch.
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-600}

LOCAL_STORAGE_DEST=/app/packages/twenty-server/.local-storage
# Counted before the patch and again after it. The two rowLevelPermission* tables
# are the point: the removed billing-sync cleanup used to wipe them.
CORE_TABLES="workspace user rowLevelPermissionPredicate rowLevelPermissionPredicateGroup billingEntitlement"

DB_CID=
SERVER_CID=
WORKER_CID=
DB_IMAGE=
PG_USER=
PG_DB=
LOCAL_STORAGE_VOLUME=
BACKUP_DIR=
LAST_BACKUP_POINTER=
SCRATCH_CONTAINER=

cleanup() {
  if [ -n "$SCRATCH_CONTAINER" ]; then
    docker rm -f "$SCRATCH_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Backup, patch in place, and validate a live Twenty docker-compose instance.

Usage: patch-instance.sh [command] [options]

Commands:
  all        backup + patch + validate (default)
  backup     dump database, verify the dump restores, archive local storage, copy config
  patch      build/pull the new image and recreate server + worker
  validate   health, patch presence, data invariants, running version
  rollback   switch server + worker back to the tag recorded by the last patch

Options:
  --tag=TAG            patched image tag (default: patch-<git sha>-<timestamp>)
  --mode=build|pull    where the patched image comes from (default: build)
  --compose-dir=DIR    directory with docker-compose.yml and .env (default: $PWD)
  --repo-root=DIR      Twenty checkout used to build the image
  --backup-root=DIR    where backups are written (default: <compose-dir>/backups)
  -h, --help           this message

Environment variables: COMPOSE_DIR, REPO_ROOT, BACKUP_ROOT, PATCH_MODE, PATCH_TAG,
PATCH_IMAGE_REPO, PLATFORM, SKIP_BUILD, SKIP_RESTORE_DRILL, SKIP_VOLUME_BACKUP,
HEALTH_TIMEOUT.

--mode=build (default) builds an image from your working tree, so a local
modification such as the removed row-level-permission gate ships with it.
--mode=pull switches the deployment to a published release tag instead, which
replaces any locally built image and does not contain local changes.

What it never does: `docker compose down`, volume removal, or `docker compose up`
without an explicit service list. Only `server` and `worker` are ever recreated.
EOF
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '  ..   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

die() {
  printf '\n\033[31mERROR\033[0m %s\n' "$1" >&2
  exit 1
}

# Runs docker compose from the deployment directory so that its .env is the one
# that gets read, whatever directory this script is invoked from.
compose() { (cd "$COMPOSE_DIR" && docker compose "$@"); }
compose_exec() { (cd "$COMPOSE_DIR" && docker compose exec -T "$@"); }

require_running() {
  [ -n "$SERVER_CID" ] || die "the server container is not running; start the stack first"
}

parse_args() {
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    COMMAND=$1
    shift
  fi

  for arg in "$@"; do
    case "$arg" in
      --tag=*) PATCH_TAG=${arg#--tag=} ;;
      --mode=*) PATCH_MODE=${arg#--mode=} ;;
      --compose-dir=*) COMPOSE_DIR=${arg#--compose-dir=} ;;
      --repo-root=*) REPO_ROOT=${arg#--repo-root=} ;;
      --backup-root=*) BACKUP_ROOT=${arg#--backup-root=} ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $arg (try --help)" ;;
    esac
  done

  case "$COMMAND" in
    all | backup | patch | validate | rollback) ;;
    *) die "unknown command: $COMMAND (try --help)" ;;
  esac
}

preflight() {
  step "Preflight"

  local cmd
  for cmd in docker curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed or not in PATH"
  done
  docker info >/dev/null 2>&1 || die "docker is not running"
  docker compose version >/dev/null 2>&1 ||
    die "'docker compose' (v2) is not available; docker-compose v1 is not supported"

  COMPOSE_DIR=$(cd "$COMPOSE_DIR" && pwd)
  [ -f "$COMPOSE_DIR/docker-compose.yml" ] ||
    die "no docker-compose.yml in $COMPOSE_DIR (set COMPOSE_DIR or --compose-dir)"
  [ -f "$COMPOSE_DIR/.env" ] ||
    die "no .env in $COMPOSE_DIR; the deployment's database password and ENCRYPTION_KEY live there"

  BACKUP_ROOT=${BACKUP_ROOT:-$COMPOSE_DIR/backups}
  mkdir -p "$BACKUP_ROOT"
  LAST_BACKUP_POINTER="$BACKUP_ROOT/last-backup-dir"

  DB_CID=$(compose ps -q db || true)
  [ -n "$DB_CID" ] || die "the db container is not running"
  SERVER_CID=$(compose ps -q server || true)
  WORKER_CID=$(compose ps -q worker || true)

  DB_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$DB_CID")

  # The db container's own environment is authoritative: it is what Postgres is
  # actually running with, regardless of what the .env says today.
  PG_USER=$(container_env "$DB_CID" POSTGRES_USER)
  PG_DB=$(container_env "$DB_CID" POSTGRES_DB)
  [ -n "$PG_USER" ] || PG_USER=postgres
  [ -n "$PG_DB" ] || PG_DB=default

  if [ -z "$PLATFORM" ]; then
    case "$(docker info -f '{{.Architecture}}' 2>/dev/null || uname -m)" in
      aarch64 | arm64) PLATFORM=linux/arm64 ;;
      *) PLATFORM=linux/amd64 ;;
    esac
  fi

  if [ -z "$PATCH_IMAGE_REPO" ] && [ -n "$SERVER_CID" ]; then
    # Derived from the running container, so switching TAG alone is enough for
    # docker compose to resolve the patched image.
    PATCH_IMAGE_REPO=$(service_image_ref "$SERVER_CID")
    PATCH_IMAGE_REPO=${PATCH_IMAGE_REPO%:*}
  fi
  [ -n "$PATCH_IMAGE_REPO" ] || PATCH_IMAGE_REPO=twentycrm/twenty

  if [ -z "$PATCH_TAG" ]; then
    local sha
    sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)
    PATCH_TAG="patch-$sha-$(date +%Y%m%d-%H%M%S)"
  fi

  # The image build runs the front-end build with an 8GB heap, which a small
  # self-hosted box will not survive. Better to say so now than 10 minutes in.
  if [ "$PATCH_MODE" = "build" ] && [ "$SKIP_BUILD" != "1" ] && [ -r /proc/meminfo ]; then
    local mem_gb
    mem_gb=$(awk '/^MemTotal:/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    case "$mem_gb" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$mem_gb" -lt 8 ]; then
          warn "this host reports ${mem_gb}GB RAM; the in-image front-end build uses an 8GB heap"
          warn "pre-build packages/twenty-front/build on a bigger machine, or expect the build to OOM"
        fi
        ;;
    esac
  fi

  info "compose dir:  $COMPOSE_DIR"
  info "database:     $PG_DB (user $PG_USER, image $DB_IMAGE)"
  info "image repo:   $PATCH_IMAGE_REPO"
  info "patch tag:    $PATCH_TAG"
  info "patch mode:   $PATCH_MODE"
  info "backups:      $BACKUP_ROOT"
}

container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null |
    grep "^$2=" | head -n1 | cut -d= -f2- || true
}

# Reads one KEY= from the deployment .env without exporting the rest of it.
env_value() {
  local line
  line=$(grep -E "^$1=" "$COMPOSE_DIR/.env" 2>/dev/null | head -n1 || true)
  printf '%s' "${line#"$1"=}"
}

# TAG is the compose file's own version pin, so writing it is what makes the patch
# survive a later `docker compose up -d`, `restart`, or host reboot.
set_env_tag() {
  local content had_tag
  if grep -qE '^TAG=' "$COMPOSE_DIR/.env"; then
    had_tag=1
    content=$(sed -E "s|^TAG=.*$|TAG=$1|" "$COMPOSE_DIR/.env")
  else
    had_tag=0
    content=$(cat "$COMPOSE_DIR/.env")
  fi

  # Rewritten through the same inode on purpose: this file holds ENCRYPTION_KEY,
  # so it keeps whatever mode and owner it was given.
  if [ "$had_tag" = "1" ]; then
    printf '%s\n' "$content" >"$COMPOSE_DIR/.env"
  else
    printf '%s\nTAG=%s\n' "$content" "$1" >"$COMPOSE_DIR/.env"
  fi
}

service_image_ref() {
  [ -n "$1" ] || return 0
  docker inspect -f '{{.Config.Image}}' "$1"
}

service_image_id() {
  [ -n "$1" ] || return 0
  docker inspect -f '{{.Image}}' "$1"
}

db_counts() {
  local container=$1 table count
  for table in $CORE_TABLES; do
    count=$(docker exec "$container" psql -U "$PG_USER" -d "$PG_DB" -tAc \
      "SELECT count(*) FROM core.\"$table\"" 2>/dev/null) || count=unavailable
    printf '%s=%s\n' "$table" "${count:-unavailable}"
  done
  count=$(docker exec "$container" psql -U "$PG_USER" -d "$PG_DB" -tAc \
    'SELECT pg_database_size(current_database())' 2>/dev/null) || count=unavailable
  printf 'db_size_bytes=%s\n' "${count:-unavailable}"
}

wait_for_health() {
  local container=$1 waited=0 status
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    status=$(docker inspect -f \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
      "$container" 2>/dev/null || echo missing)
    case "$status" in
      healthy | no-healthcheck) return 0 ;;
      unhealthy) return 1 ;;
    esac
    sleep 3
    waited=$((waited + 3))
    if [ $((waited % 30)) -eq 0 ]; then
      info "still waiting ($waited/${HEALTH_TIMEOUT}s, health: $status)"
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------

run_backup() {
  step "Backup"

  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR/config"
  printf '%s\n' "$BACKUP_DIR" >"$LAST_BACKUP_POINTER"

  local previous_tag
  previous_tag=$(env_value TAG)
  [ -n "$previous_tag" ] || previous_tag=latest

  local dump_in_container="/tmp/twenty-backup-$$.dump"
  local dump_path="$BACKUP_DIR/database.dump"

  info "dumping database $PG_DB (custom format)"
  # No -T here: that flag is compose-only. `docker exec` allocates no TTY unless
  # asked with -t, which is exactly what these non-interactive calls want.
  docker exec "$DB_CID" pg_dump -U "$PG_USER" -d "$PG_DB" \
    --format=custom --no-owner --no-privileges -f "$dump_in_container"
  docker cp "$DB_CID:$dump_in_container" "$dump_path"
  docker exec "$DB_CID" rm -f "$dump_in_container"

  info "dumping roles"
  docker exec "$DB_CID" pg_dumpall -U "$PG_USER" --globals-only >"$BACKUP_DIR/globals.sql"

  # Reading the archive back through pg_restore is what proves the dump is usable,
  # so a truncated or unreadable file stops the run here and not months later.
  if docker exec -i "$DB_CID" pg_restore --list <"$dump_path" >"$BACKUP_DIR/dump-contents.txt"; then
    ok "database dump is readable ($(wc -c <"$dump_path" | tr -d ' ') bytes, $(wc -l <"$BACKUP_DIR/dump-contents.txt" | tr -d ' ') archive entries)"
  else
    die "the dump cannot be read back by pg_restore; aborting before anything is patched"
  fi

  db_counts "$DB_CID" >"$BACKUP_DIR/counts-before.txt"
  ok "recorded pre-patch row counts"

  info "copying docker-compose.yml, .env and overrides"
  cp "$COMPOSE_DIR/docker-compose.yml" "$BACKUP_DIR/config/"
  cp "$COMPOSE_DIR/.env" "$BACKUP_DIR/config/.env"
  local override
  for override in "$COMPOSE_DIR"/docker-compose.*.yml; do
    if [ -f "$override" ]; then
      cp "$override" "$BACKUP_DIR/config/"
    fi
  done
  ok "configuration copied (it holds ENCRYPTION_KEY: treat it as secret as the .env)"

  # The local storage can be a named volume or a bind mount, and the two need
  # different archiving, so both the name and the host path are read out.
  local mount_info mount_name mount_source
  if [ -n "$SERVER_CID" ]; then
    mount_info=$(docker inspect -f \
      "{{range .Mounts}}{{if eq .Destination \"$LOCAL_STORAGE_DEST\"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}" \
      "$SERVER_CID" 2>/dev/null || true)
    mount_name=$(printf '%s' "$mount_info" | cut -d'|' -f2)
    mount_source=$(printf '%s' "$mount_info" | cut -d'|' -f3)
  fi

  if [ "$SKIP_VOLUME_BACKUP" = "1" ]; then
    info "skipping local-storage archive (SKIP_VOLUME_BACKUP=1)"
  elif [ -n "$mount_name" ]; then
    LOCAL_STORAGE_VOLUME=$mount_name
    info "archiving volume $LOCAL_STORAGE_VOLUME (uploaded files)"
    # Reuse the already-pulled db image so archiving needs no network access.
    docker run --rm -v "$LOCAL_STORAGE_VOLUME":/data:ro -v "$BACKUP_DIR":/backup \
      "$DB_IMAGE" tar czf /backup/server-local-data.tar.gz -C /data .
    ok "local storage archived ($(wc -c <"$BACKUP_DIR/server-local-data.tar.gz" | tr -d ' ') bytes)"
  elif [ -n "$mount_source" ]; then
    LOCAL_STORAGE_VOLUME="bind:$mount_source"
    if command -v tar >/dev/null 2>&1; then
      info "archiving bind mount $mount_source (uploaded files)"
      tar czf "$BACKUP_DIR/server-local-data.tar.gz" -C "$mount_source" .
      ok "local storage archived ($(wc -c <"$BACKUP_DIR/server-local-data.tar.gz" | tr -d ' ') bytes)"
    else
      warn "local storage is a bind mount at $mount_source and tar is not installed here"
      warn "archive that directory yourself; it holds uploaded files"
    fi
  elif [ -n "$SERVER_CID" ]; then
    warn "nothing is mounted at $LOCAL_STORAGE_DEST; skipping local-storage archive (S3 storage?)"
  fi

  {
    printf 'backed_up_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'compose_dir=%s\n' "$COMPOSE_DIR"
    printf 'repo_commit=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'previous_env_tag=%s\n' "$previous_tag"
    printf 'previous_server_image=%s\n' "$(service_image_ref "$SERVER_CID")"
    printf 'previous_server_image_id=%s\n' "$(service_image_id "$SERVER_CID")"
    printf 'previous_worker_image=%s\n' "$(service_image_ref "$WORKER_CID")"
    printf 'db_image=%s\n' "$DB_IMAGE"
    printf 'pg_database=%s\n' "$PG_DB"
    printf 'local_storage=%s\n' "${LOCAL_STORAGE_VOLUME:-none}"
  } >"$BACKUP_DIR/manifest.txt"
  cp "$BACKUP_DIR/manifest.txt" "$BACKUP_ROOT/last-manifest.txt"
  ok "manifest written to $BACKUP_DIR/manifest.txt"

  run_restore_drill "$dump_path"
}

# Restores the dump into a throwaway Postgres container. Runs before the patch so
# that an unusable backup stops the run while the old version is still live.
run_restore_drill() {
  local dump_path=$1 log_file="$BACKUP_DIR/restore-drill.log"

  if [ "$SKIP_RESTORE_DRILL" = "1" ]; then
    info "skipping restore drill (SKIP_RESTORE_DRILL=1)"
    return 0
  fi

  step "Backup verification (restore drill)"

  SCRATCH_CONTAINER="twenty-restore-drill-$$"
  docker run -d --rm --name "$SCRATCH_CONTAINER" \
    -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD=restore-drill -e POSTGRES_DB="$PG_DB" \
    "$DB_IMAGE" >/dev/null || die "could not start the scratch Postgres container"

  local waited=0
  while [ "$waited" -lt 60 ]; do
    if docker exec "$SCRATCH_CONTAINER" pg_isready -U "$PG_USER" -q >/dev/null 2>&1; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  [ "$waited" -lt 60 ] || die "the scratch Postgres container never became ready"

  # No --exit-on-error: a dumped database can legitimately trip on an orphaned
  # foreign key that already exists in production, and that is not a reason to
  # withhold a patch. The row counts below are what decide whether the restore is
  # actually complete.
  if docker exec -i "$SCRATCH_CONTAINER" pg_restore -U "$PG_USER" -d "$PG_DB" \
    --no-owner --no-privileges <"$dump_path" >"$log_file" 2>&1; then
    ok "dump restores cleanly into an empty Postgres"
  else
    warn "pg_restore reported errors; see $log_file"
    tail -n 15 "$log_file" | sed 's/^/       /'
  fi

  db_counts "$SCRATCH_CONTAINER" >"$BACKUP_DIR/counts-restored.txt"
  if diff -u "$BACKUP_DIR/counts-before.txt" "$BACKUP_DIR/counts-restored.txt" \
    >"$BACKUP_DIR/counts-restored.diff"; then
    ok "restored row counts match the live database"
  else
    warn "restored counts differ from the live database (see counts-restored.diff):"
    sed 's/^/       /' "$BACKUP_DIR/counts-restored.diff"
    warn "a few rows of drift is normal on a busy instance; a large gap is not"
  fi

  docker rm -f "$SCRATCH_CONTAINER" >/dev/null 2>&1 || true
  SCRATCH_CONTAINER=
}

# ---------------------------------------------------------------------------
# patch
# ---------------------------------------------------------------------------

build_patch_image() {
  local image="$PATCH_IMAGE_REPO:$PATCH_TAG"
  local dockerfile="$REPO_ROOT/packages/twenty-docker/twenty/Dockerfile"

  [ -f "$dockerfile" ] || die "no Dockerfile at $dockerfile (set REPO_ROOT)"
  [ -f "$REPO_ROOT/yarn.lock" ] || die "$REPO_ROOT does not look like a Twenty checkout (set REPO_ROOT)"

  if [ "$SKIP_BUILD" = "1" ] && docker image inspect "$image" >/dev/null 2>&1; then
    ok "reusing the existing local image $image"
    return 0
  fi

  info "building $image from $REPO_ROOT"
  info "(dependencies, lingui and the front-end build all run inside it: expect several minutes)"
  # --target twenty is the server + frontend image the compose file expects.
  docker build \
    --target twenty \
    -f "$dockerfile" \
    --platform "$PLATFORM" \
    --build-arg "APP_VERSION=$PATCH_TAG" \
    -t "$image" \
    "$REPO_ROOT" || die "docker build failed"
  ok "built $image ($(docker image inspect -f '{{.Id}}' "$image" | cut -c8-19))"
}

apply_patch() {
  step "Patch"

  require_running

  local previous_tag previous_server_image record
  previous_tag=$(env_value TAG)
  [ -n "$previous_tag" ] || previous_tag=latest
  previous_server_image=$(service_image_ref "$SERVER_CID")

  record="$BACKUP_ROOT/last-patch.txt"
  [ -n "$BACKUP_DIR" ] || BACKUP_DIR=$(cat "$LAST_BACKUP_POINTER" 2>/dev/null || true)
  {
    printf 'patched_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'patched_to_tag=%s\n' "$PATCH_TAG"
    printf 'patched_to_image=%s\n' "$PATCH_IMAGE_REPO:$PATCH_TAG"
    printf 'previous_env_tag=%s\n' "$previous_tag"
    printf 'previous_server_image=%s\n' "$previous_server_image"
    printf 'previous_server_image_id=%s\n' "$(service_image_id "$SERVER_CID")"
    printf 'previous_worker_image=%s\n' "$(service_image_ref "$WORKER_CID")"
    printf 'backup_dir=%s\n' "$BACKUP_DIR"
  } >"$record"
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    cp "$record" "$BACKUP_DIR/patch.txt"
  else
    warn "no backup directory found; only $record records what to roll back to"
  fi
  ok "rollback information written to $record"

  if [ "$PATCH_MODE" = "build" ]; then
    build_patch_image
  elif [ "$PATCH_MODE" = "pull" ]; then
    info "pulling $PATCH_IMAGE_REPO:$PATCH_TAG"
    compose pull server worker || die "docker compose pull failed"
  else
    die "unsupported PATCH_MODE: $PATCH_MODE (expected build or pull)"
  fi

  info "switching TAG to $PATCH_TAG in $COMPOSE_DIR/.env (was $previous_tag)"
  set_env_tag "$PATCH_TAG"

  # db and redis are not part of this up, and compose only recreates containers
  # whose configuration actually changed, so their volumes are never remounted.
  info "recreating server and worker against $PATCH_IMAGE_REPO:$PATCH_TAG"
  compose up -d server worker ||
    die "docker compose up failed; check 'docker compose ps' and the server logs"

  SERVER_CID=$(compose ps -q server)
  WORKER_CID=$(compose ps -q worker)

  info "the server is briefly unavailable while it boots and runs upgrades"
  if wait_for_health "$SERVER_CID"; then
    ok "server container is healthy"
  else
    warn "the server did not report healthy within ${HEALTH_TIMEOUT}s; last 50 log lines:"
    compose logs --tail=50 server || true
    die "the patch is applied but the server is unhealthy; 'rollback' reverts the image"
  fi

  ok "patch applied (previous image: $previous_server_image)"
}

# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

# Prints the base URL of the server as reachable from this host: the published
# port first, then the container's own address when the port is bound elsewhere.
resolve_base_url() {
  local port ip code
  port=$(compose port server 3000 2>/dev/null | head -n1 || true)
  port=${port##*:}
  [ -n "$port" ] || port=3000

  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$port/healthz" || true)
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    printf 'http://127.0.0.1:%s' "$port"
    return 0
  fi

  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$SERVER_CID" 2>/dev/null || true)
  if [ -n "$ip" ]; then
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$ip:3000/healthz" || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      printf 'http://%s:3000' "$ip"
      return 0
    fi
  fi

  warn "the server answered on neither 127.0.0.1:$port nor its container address"
  printf 'http://127.0.0.1:%s' "$port"
}

# Returns 0 when the needle is still present in the container's build output.
contains_in_dist() {
  compose_exec server sh -c "grep -rq '$1' '${2:-dist}'" >/dev/null 2>&1
}

run_validate() {
  step "Validate"

  local failures=0 base_url config_body app_version
  require_running

  # A container still booting has no usable dist/ and no API yet.
  if [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$SERVER_CID" 2>/dev/null)" = "starting" ]; then
    info "server is still starting; waiting for it"
    wait_for_health "$SERVER_CID" || true
  fi

  info "containers"
  compose ps

  base_url=$(resolve_base_url)

  # 1. Health: the doc's smoke test against the container's own healthcheck.
  if curl -fsS "$base_url/healthz" >/dev/null 2>&1; then
    ok "GET $base_url/healthz responded"
  else
    fail "GET $base_url/healthz failed"
    failures=$((failures + 1))
  fi

  # 2. The running container is the image that was just built.
  local running_id wanted_id
  running_id=$(service_image_id "$SERVER_CID")
  wanted_id=$(docker image inspect -f '{{.Id}}' "$PATCH_IMAGE_REPO:$PATCH_TAG" 2>/dev/null || true)
  if [ -z "$wanted_id" ]; then
    warn "local image $PATCH_IMAGE_REPO:$PATCH_TAG not found; cannot compare image ids"
  elif [ "$running_id" = "$wanted_id" ]; then
    ok "the server container runs $PATCH_IMAGE_REPO:$PATCH_TAG"
  else
    fail "the server container runs $running_id, expected $wanted_id"
    failures=$((failures + 1))
  fi

  # 3. The patch is inside the shipped server build. The positive control guards
  #    against greps that match nothing because the path is wrong.
  if contains_in_dist 'upsertRowLevelPermissionPredicates'; then
    ok "positive control: row-level permission code is present in dist/"
  else
    fail "row-level permission code is missing from dist/; the checks below prove nothing"
    failures=$((failures + 1))
  fi

  local removed
  for removed in ROW_LEVEL_PERMISSION_FEATURE_DISABLED hasRowLevelPermissionFeature deleteAllRowLevelPermissionPredicateGroups; do
    if contains_in_dist "$removed"; then
      fail "'$removed' is still in the server build: the entitlement gate was not removed"
      failures=$((failures + 1))
    else
      ok "'$removed' is gone from the server build"
    fi
  done

  if compose_exec server sh -c 'test -f dist/front/index.html' >/dev/null 2>&1; then
    ok "the front-end build is present in the image"
  else
    fail "dist/front/index.html is missing: the image was built without the front-end"
    failures=$((failures + 1))
  fi

  # 4. The removed front-end "Upgrade to access" card has lingui id ggd+Ee. Soft
  #    check: if extraction ever stops dropping the obsolete catalog entry this
  #    only warns, and the UI checklist stays authoritative.
  if compose_exec server sh -c 'grep -rq "ggd+Ee" dist/front' >/dev/null 2>&1; then
    warn "the record-level 'Upgrade to access' message id is still in the front-end bundle"
  else
    ok "the record-level 'Upgrade to access' message id is gone from the front-end bundle"
  fi

  # 5. Running version, from the public client-config endpoint.
  if config_body=$(curl -fsS "$base_url/client-config" 2>/dev/null); then
    app_version=$(printf '%s' "$config_body" | sed -n 's/.*"appVersion":"\([^"]*\)".*/\1/p')
    if [ -z "$app_version" ]; then
      info "client-config exposes no appVersion (the image was built without APP_VERSION)"
    elif [ "$app_version" = "$PATCH_TAG" ]; then
      ok "client-config reports appVersion=$app_version"
    else
      warn "client-config reports appVersion=$app_version, expected $PATCH_TAG"
    fi
  else
    warn "could not fetch /client-config"
  fi

  # 6. Data invariants. The patch touches no schema, so the row-level permission
  #    tables in particular must come out of the deploy exactly as they went in.
  local pointer=${BACKUP_DIR:-}
  if [ -z "$pointer" ]; then
    pointer=$(cat "$LAST_BACKUP_POINTER" 2>/dev/null || true)
  fi

  if [ -n "$pointer" ] && [ -f "$pointer/counts-before.txt" ]; then
    db_counts "$DB_CID" >"$pointer/counts-after.txt"
    if diff -u "$pointer/counts-before.txt" "$pointer/counts-after.txt" \
      >"$pointer/counts-after.diff"; then
      ok "row counts are unchanged across the patch"
    else
      warn "row counts changed across the patch:"
      sed 's/^/       /' "$pointer/counts-after.diff"
      warn "a drop in rowLevelPermissionPredicate/Group is the billing-sync wipe this patch removes"
      warn "an increase is normal if someone edited roles while the image was building or pulling"
    fi
  else
    warn "no pre-patch counts found; run the backup command first to enable this check"
  fi

  info "recent server log (the upgrade output lives here)"
  compose logs --tail=20 server || true

  if [ "$failures" -gt 0 ]; then
    printf '\n\033[31m%d automated validation check(s) failed.\033[0m\n' "$failures"
    return 1
  fi

  printf '\n\033[32mAutomated validation passed.\033[0m\n'
  cat <<'EOF'

Confirm by hand in the UI:
  1. Settings -> Roles -> <role> -> <object> -> Record-level shows the filter
     builder, with no "Upgrade to access" card, on a workspace that does not have
     the row-level-permission entitlement.
  2. Add filter -> field "Created by" -> sub-field "Workspace Member" -> Me ->
     "Me (User ID)", then save.
  3. Create one record as two different members; each member should see only their
     own record.
  4. Records created by API keys, workflows or imports carry no workspace member in
     createdBy, so such a rule hides them. That is the behaviour this patch takes.
EOF
}

# ---------------------------------------------------------------------------
# rollback
# ---------------------------------------------------------------------------

run_rollback() {
  step "Rollback"

  require_running

  local record="$BACKUP_ROOT/last-patch.txt"
  [ -f "$record" ] || die "no $record; run the patch command first so there is something to revert"

  local previous_tag previous_image
  previous_tag=$(grep '^previous_env_tag=' "$record" | head -n1 | cut -d= -f2- || true)
  [ -n "$previous_tag" ] || previous_tag=latest
  previous_image=$(grep '^previous_server_image=' "$record" | head -n1 | cut -d= -f2- || true)

  info "switching TAG back to $previous_tag in $COMPOSE_DIR/.env"
  set_env_tag "$previous_tag"

  # The previous image may be a published tag that is not on this host at all.
  if ! docker image inspect "$PATCH_IMAGE_REPO:$previous_tag" >/dev/null 2>&1; then
    info "$PATCH_IMAGE_REPO:$previous_tag is not available locally; pulling it"
    compose pull server worker || warn "docker compose pull failed; continuing with local images"
  fi

  compose up -d server worker || die "docker compose up failed"

  SERVER_CID=$(compose ps -q server)
  if wait_for_health "$SERVER_CID"; then
    ok "TAG is back at $previous_tag${previous_image:+, previously running $previous_image}"
  else
    warn "the server did not report healthy within ${HEALTH_TIMEOUT}s after the rollback"
    compose logs --tail=50 server || true
    return 1
  fi

  local backup_dir
  backup_dir=$(grep '^backup_dir=' "$record" | head -n1 | cut -d= -f2- || true)

  printf '\nThe patch never touched the database, so no data rollback is needed.\n'
  printf 'If you do need to restore the dump, stop the writers first:\n'
  printf '  docker compose stop server worker\n'
  printf '  docker exec -i "$(docker compose ps -q db)" psql -U %s -d %s < %s/globals.sql\n' \
    "$PG_USER" "$PG_DB" "${backup_dir:-<backup-dir>}"
  printf '  docker exec -i "$(docker compose ps -q db)" pg_restore -U %s -d %s --clean --if-exists --no-owner < %s/database.dump\n' \
    "$PG_USER" "$PG_DB" "${backup_dir:-<backup-dir>}"
  printf '  docker compose up -d\n'
}

# ---------------------------------------------------------------------------

parse_args "$@"

case "$COMMAND" in
  all)
    preflight
    run_backup
    apply_patch
    run_validate
    ;;
  backup)
    preflight
    run_backup
    ;;
  patch)
    preflight
    apply_patch
    ;;
  validate)
    preflight
    run_validate
    ;;
  rollback)
    preflight
    run_rollback
    ;;
esac
