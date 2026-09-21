#!/usr/bin/env bash
#
# Build the patched Twenty image on a machine that can afford it, verify that the
# patch is really inside it, and write a transferable archive for the host that
# runs the deployment.
#
# This is the counterpart to patch-instance.sh: that script patches a live
# instance in place and can build the image itself, but the in-image front-end
# build wants an 8GB heap and a small self-hosted box will OOM. Run this on a
# bigger machine, copy the archive over, then run:
#
#   patch-instance.sh patch --mode=load --tag=<tag> --compose-dir=<deploy dir>
#
# Nothing but docker and git is needed here: the build runs yarn, lingui and the
# front-end compiler inside the image, so this host needs no node toolchain.
#
# The build needs roughly 12GB of daemon memory: the front-end step asks node for
# an 8GB heap and buildkit runs the server chain beside it. Below that it fails as
# "cannot allocate memory" from inside a yarn install, which reads like a
# dependency problem and is not one. Raise the memory, pass --serial, or both.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Twenty checkout to build. Defaults to the repository this script lives in.
REPO_ROOT=${REPO_ROOT:-$SCRIPT_DIR/../../..}
# Repository the image is tagged under; must match what the deployment's TAG resolves to.
IMAGE_REPO=${IMAGE_REPO:-twentycrm/twenty}
# Tag for the built image. Defaults to patch-<git sha>-<timestamp>.
PATCH_TAG=${PATCH_TAG:-}
# Architecture of the host that runs the deployment. Override only if it differs.
PLATFORM=${PLATFORM:-linux/amd64}
# Archive to write.
OUT=${OUT:-}
# Optional user@host to stream the archive to, where docker load picks it up.
SHIP=${SHIP:-}
# Optional user@host to deploy to: implies SHIP, then runs the remote backup,
# patch --mode=load and validate, so building and deploying are one command.
DEPLOY=${DEPLOY:-}
# Deployment directory on the remote host: docker-compose.yml and .env live there.
REMOTE_COMPOSE_DIR=${REMOTE_COMPOSE_DIR:-/root/crm}
# Remote checkout carrying patch-instance.sh.
REMOTE_REPO=${REMOTE_REPO:-/root/git/twenty-2.41.0}
# Set once --platform is given by hand, so the remote probe does not overrule it.
PLATFORM_SET=0
# Skip the confirmation asked before the live instance is touched.
ASSUME_YES=${ASSUME_YES:-0}
# Build the two Dockerfile chains one after the other instead of at the same time.
SERIAL=${SERIAL:-0}
# Run only the remote half, against a tag that is already loaded on the target.
DEPLOY_ONLY=${DEPLOY_ONLY:-0}
# Version the image reports as its own. Must be semver and is NOT the image tag:
# the server validates it at boot and exits when semver.parse returns null, which
# turns a non-semver value into a crash loop instead of a running container.
APP_VERSION=${APP_VERSION:-}

# The gate this patch removes. Any of them surviving into the compiled server code
# means the wrong tree was built, which an expensive transfer would hide.
GATE_MARKERS="hasRowLevelPermissionFeature|deleteAllRowLevelPermissionPredicateGroups|ROW_LEVEL_PERMISSION_FEATURE_DISABLED"
# The build must still contain row-level permissions at all, or the greps above
# could pass because the path is wrong. Same positive control as run_validate.
RLS_MARKER=upsertRowLevelPermissionPredicates

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '  ..   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }

die() {
  printf '\n\033[31mERROR\033[0m %s\n' "$1" >&2
  exit 1
}

# Docker and the kernel report the same two architectures under four spellings, so
# both sides of a comparison go through this first.
normalize_platform() {
  case "$1" in
    x86_64 | amd64) printf 'linux/amd64' ;;
    aarch64 | arm64) printf 'linux/arm64' ;;
    *) printf '%s' "$1" ;;
  esac
}

docker_host_arch() { docker info -f '{{.Architecture}}' 2>/dev/null || uname -m; }

is_semver() {
  printf '%s' "$1" |
    grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

# Only this generated constant is bumped by `nx version:bump twenty-server`, so it is
# the checkout's own answer to which version it is.
discover_app_version() {
  local constant="$REPO_ROOT/packages/twenty-server/src/engine/core-modules/upgrade/constants/twenty-current-version.constant.ts"
  [ -f "$constant" ] || return 0
  sed -n "s/.*TWENTY_CURRENT_VERSION *= *'\([^']*\)'.*/\1/p" "$constant" | head -n 1
}

# The failure this prevents is reported by buildkit as "ResourceExhausted: process
# ... cannot allocate memory" from inside a yarn install, which reads like a
# dependency problem and is not one: it is the daemon's memory limit.
check_build_memory() {
  local bytes gb
  bytes=$(docker info -f '{{.MemTotal}}' 2>/dev/null || echo 0)
  case "$bytes" in '' | *[!0-9]*) return 0 ;; esac
  gb=$((bytes / 1024 / 1024 / 1024))

  if [ "$gb" -ge 12 ]; then
    info "the daemon has ${gb}GB of memory for the build"
  elif [ "$SERIAL" = "1" ]; then
    warn "the daemon has only ${gb}GB of memory; --serial halves the peak, but 12GB is the safe figure"
  else
    warn "the daemon has only ${gb}GB of memory, and the two build chains want about 12GB"
    warn "raise it in Docker Desktop > Settings > Resources > Memory, and/or pass --serial"
  fi
}

usage() {
  cat <<'EOF'
Build the patched Twenty image, verify it, and package it for transfer.

Usage: build-image.sh [options]

Options:
  --tag=TAG            image tag (default: patch-<git sha>-<timestamp>)
  --app-version=SEMVER version the image reports (default: the checkout's own)
  --repo-root=DIR      Twenty checkout to build (default: this script's repository)
  --image-repo=REPO    repository to tag under (default: twentycrm/twenty)
  --platform=PLATFORM  docker build --platform (default: probed from --deploy,
                       else linux/amd64)
  --out=FILE           archive path (default: <compose-free cwd>/<tag>.tar.gz)
  --ship=USER@HOST     stream the archive to this host, which runs docker load
  --deploy=USER@HOST   also back up, patch and validate there (implies --ship)
  --compose-dir=DIR    deployment directory on that host (default: /root/crm)
  --remote-repo=DIR    checkout on that host holding patch-instance.sh
                       (default: /root/git/twenty-2.41.0)
  --yes                do not ask before touching the live instance
  --serial             build the server and front-end chains one after the other
                       instead of concurrently (halves peak memory)
  --deploy-only        skip the build and the transfer; deploy --tag as it is
                       already loaded on the target
  -h, --help           this message

Environment variables: REPO_ROOT, IMAGE_REPO, PATCH_TAG, PLATFORM, OUT, SHIP,
DEPLOY, REMOTE_COMPOSE_DIR, REMOTE_REPO, ASSUME_YES, SERIAL, DEPLOY_ONLY,
APP_VERSION.

The account used with --ship is taken as-is and runs docker load over ssh: make
sure it can reach the docker socket there. Without --ship the archive is only
written, and you copy it yourself.

--deploy exists for the machine that cannot build. It probes the target's
architecture before building, so an emulated build is never spent on the wrong
one, and then drives patch-instance.sh there over ssh. Nothing is compiled on the
target, and the database and redis are never touched.

--deploy-only runs just that remote half, for picking up after a transfer that
already landed: the image is on the target, only the backup, patch and validate
are left. It needs --tag, because there is no build here to name one.

--tag and --app-version are different things and must not be confused. --tag is a
docker tag and may be anything; --app-version is compiled in and is parsed by the
server at boot, which exits unless it is semantic versioning such as 2.41.0.
EOF
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --tag=*) PATCH_TAG=${arg#--tag=} ;;
      --app-version=*) APP_VERSION=${arg#--app-version=} ;;
      --repo-root=*) REPO_ROOT=${arg#--repo-root=} ;;
      --image-repo=*) IMAGE_REPO=${arg#--image-repo=} ;;
      --platform=*) PLATFORM=${arg#--platform=}; PLATFORM_SET=1 ;;
      --out=*) OUT=${arg#--out=} ;;
      --ship=*) SHIP=${arg#--ship=} ;;
      --deploy=*) DEPLOY=${arg#--deploy=} ;;
      --compose-dir=*) REMOTE_COMPOSE_DIR=${arg#--compose-dir=} ;;
      --remote-repo=*) REMOTE_REPO=${arg#--remote-repo=} ;;
      --yes) ASSUME_YES=1 ;;
      --serial) SERIAL=1 ;;
      --deploy-only) DEPLOY_ONLY=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $arg (try --help)" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# source checks
# ---------------------------------------------------------------------------

# Cheap, and it is the failure that costs the most: a build from a tree with
# conflict markers either fails loudly or, when the marker sits in a file the
# compiler ignores, ships stock code behind a patch-shaped tag.
check_sources() {
  step "Source"

  local dockerfile="$REPO_ROOT/packages/twenty-docker/twenty/Dockerfile"
  [ -f "$dockerfile" ] || die "no Dockerfile at $dockerfile (set --repo-root)"
  [ -f "$REPO_ROOT/yarn.lock" ] || die "$REPO_ROOT does not look like a Twenty checkout (set --repo-root)"
  [ -f "$REPO_ROOT/.yarnrc.yml" ] || die "$REPO_ROOT has no .yarnrc.yml; the image build needs the repo root"

  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    local unmerged branch sha subject dirty
    unmerged=$(git -C "$REPO_ROOT" diff --name-only --diff-filter=U)
    [ -z "$unmerged" ] || die "unresolved merge conflicts: $(printf '%s ' $unmerged)"

    branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
    sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
    subject=$(git -C "$REPO_ROOT" log -1 --format=%s)
    dirty=$(git -C "$REPO_ROOT" status --porcelain | wc -l)
    info "checkout: $branch @ $sha ($subject)"
    [ "$dirty" -eq 0 ] || info "$dirty uncommitted path(s); the build uses the working tree, not $sha"
  else
    warn "$REPO_ROOT is not a git checkout; the branch and revision cannot be recorded"
  fi

  local src_server="$REPO_ROOT/packages/twenty-server/src"
  local src_front="$REPO_ROOT/packages/twenty-front/src"
  [ -d "$src_server" ] || die "no $src_server; is $REPO_ROOT the Twenty repository root?"

  local markers
  markers=$(grep -rIl --exclude-dir=node_modules '^<<<<<<< ' "$src_server" "$src_front" 2>/dev/null || true)
  [ -z "$markers" ] || die "conflict markers left in: $(printf '%s ' $markers)"

  # Both halves are checked: a server-only patch would still show the front-end
  # Upgrade card, and a front-end-only patch would still reject the request.
  local gate
  gate=$(grep -rIlE "$GATE_MARKERS" "$src_server" "$src_front" 2>/dev/null || true)
  [ -z "$gate" ] || die "the entitlement gate is still in the source: $(printf '%s ' $gate)"

  grep -rIlq "$RLS_MARKER" "$src_server" 2>/dev/null ||
    die "no $RLS_MARKER in $src_server; this does not look like a tree that has row-level permissions"

  ok "no conflicts, gate removed, row-level permission code present"
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

build_image() {
  local image="$IMAGE_REPO:$PATCH_TAG"
  local dockerfile="$REPO_ROOT/packages/twenty-docker/twenty/Dockerfile"
  local host_platform

  step "Build"

  check_build_memory

  host_platform=$(normalize_platform "$(docker_host_arch)")
  # Not fatal: buildx can build the other architecture, but only through qemu,
  # which turns a 15 minute build into an hour or an OOM.
  if [ "$host_platform" != "$PLATFORM" ]; then
    warn "this host is $host_platform and the image is built for $PLATFORM"
    warn "that needs emulation and a lot more time and memory"
    warn "on Docker Desktop, enable 'Use Rosetta for x86_64/amd64 emulation' first"
  fi

  info "building $image from $REPO_ROOT"
  info "dependencies, lingui and the front-end build all run inside it: expect 10-30 minutes"

  # server-deps -> twenty-server-build and front-deps -> twenty-front-build are
  # independent, so buildkit runs them side by side. Building the server chain
  # first on its own leaves it in the layer cache, and the pass below then has
  # only the front-end left to do. Same work, half the peak.
  if [ "$SERIAL" = "1" ]; then
    info "serial mode: server chain first, untagged, so it only lands in the cache"
    docker build \
      --target twenty-server \
      -f "$dockerfile" \
      --platform "$PLATFORM" \
      --build-arg "APP_VERSION=$APP_VERSION" \
      "$REPO_ROOT" || die "docker build failed on the server chain"
    info "server chain cached; the front-end chain now runs on its own"
  fi

  # --target twenty is the server + frontend image the compose file expects.
  # APP_VERSION is what /client-config reports, so validate can confirm the tag.
  docker build \
    --target twenty \
    -f "$dockerfile" \
    --platform "$PLATFORM" \
    --build-arg "APP_VERSION=$APP_VERSION" \
    -t "$image" \
    "$REPO_ROOT" || die "docker build failed"

  ok "built $image ($(docker image inspect -f '{{.Id}}' "$image" | cut -c8-19))"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

# Runs inside the image, before the transfer: catching an unpatched build here
# costs a minute, catching it after the deploy costs a rollback.
verify_image() {
  local image="$IMAGE_REPO:$PATCH_TAG"

  step "Verify inside the image"
  info "the assertions patch-instance.sh validate makes, run against the fresh build"

  docker run --rm --entrypoint sh "$image" -c "
    fail() { echo \"FAIL \$1\"; exit 1; }

    dist=/app/packages/twenty-server/dist
    [ -f \"\$dist/main.js\" ] || fail \"no \$dist/main.js: this image has no server build\"
    [ -f \"\$dist/front/index.html\" ] || fail \"no \$dist/front/index.html: this image has no front-end\"

    # The server parses this at boot and exits when it is not semver. Catching it
    # here costs a second; catching it after the transfer costs a rollback.
    case \"\$APP_VERSION\" in
      [0-9]*.[0-9]*.[0-9]*) ;;
      *) fail \"APP_VERSION is not a semantic version, so the server will not boot: \$APP_VERSION\" ;;
    esac

    # dist/front is a separate bundle, and a source map can quote any identifier
    # from the sources it was built from, so only the server build is judged here.
    grep -rlqE '$RLS_MARKER' \"\$dist\" \\
      || fail \"positive control: no row-level permission code under \$dist\"

    # Absolute paths, so the front bundle can be excluded from the results.
    hits=\$(grep -rlE '$GATE_MARKERS' \"\$dist\" 2>/dev/null | grep -v '^\$dist/front/' || true)
    [ -z \"\$hits\" ] || fail \"the entitlement gate is still compiled in: \$hits\"

    echo 'patch present, entitlement gate absent'
  " || die "the image failed verification; not shipping it"
}

# ---------------------------------------------------------------------------
# package and ship
# ---------------------------------------------------------------------------

package_image() {
  local image="$IMAGE_REPO:$PATCH_TAG" bytes

  step "Archive"

  if [ -z "$OUT" ]; then
    if command -v zstd >/dev/null 2>&1; then
      OUT="$PWD/$PATCH_TAG.tar.zst"
    else
      OUT="$PWD/$PATCH_TAG.tar.gz"
    fi
  fi
  mkdir -p "$(dirname "$OUT")"

  info "writing $OUT (a Twenty image is 1-3GB; this takes a few minutes)"
  case "$OUT" in
    *.zst) command -v zstd >/dev/null 2>&1 || die "no zstd on PATH; use --out=<file>.tar.gz" ;;
    *.tar) ;;
    *) command -v gzip >/dev/null 2>&1 || die "no gzip on PATH" ;;
  esac

  case "$OUT" in
    *.zst) docker save "$image" | zstd -T0 -6 >"$OUT" ;;
    *.tar) docker save "$image" -o "$OUT" ;;
    *) docker save "$image" | gzip -1 >"$OUT" ;;
  esac

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$OUT" | awk '{print $1}' >"$OUT.sha256"
  else
    shasum -a 256 "$OUT" | awk '{print $1}' >"$OUT.sha256"
  fi

  bytes=$(wc -c <"$OUT" | tr -d ' ')
  ok "$OUT ($((bytes / 1024 / 1024))MB), checksum in $OUT.sha256"
}

ship_archive() {
  step "Transfer to $SHIP"

  local decompress
  case "$OUT" in
    *.zst) decompress="zstd -dc" ;;
    *.tar) decompress="cat" ;;
    *) decompress="gzip -dc" ;;
  esac

  info "decompressing locally and letting ssh do the compressing on the wire"
  info "the remote needs room for the image in its docker root before docker load starts"
  # docker load cannot be relied on to sniff zstd, so the stream is decompressed
  # here and stays a plain tar all the way to the daemon on the other end.
  $decompress "$OUT" | ssh -C "$SHIP" 'docker load' || die "the transfer failed; the archive is intact at $OUT"

  ok "the target now has $IMAGE_REPO:$PATCH_TAG"
}

# The image has to match the machine that runs it. Asking the target is worth one
# ssh round trip: the wrong --platform costs a full build under emulation and, on
# the far side, a container that crash-loops exactly like a broken patch would.
probe_remote_arch() {
  [ -n "$DEPLOY" ] || return 0
  [ "$PLATFORM_SET" = "0" ] || return 0

  step "Target architecture"

  local remote_arch platform
  remote_arch=$(ssh "$DEPLOY" 'uname -m' 2>/dev/null | tr -d '\r') ||
    die "cannot reach $DEPLOY over ssh"
  [ -n "$remote_arch" ] || die "$DEPLOY answered nothing to 'uname -m'"

  platform=$(normalize_platform "$remote_arch")
  case "$platform" in
    linux/amd64 | linux/arm64) PLATFORM=$platform ;;
    *) die "$DEPLOY reports '$remote_arch', an architecture this script does not know" ;;
  esac
  ok "$DEPLOY is $remote_arch, so the image is built for $PLATFORM"
}

# Asked once and up front: a build is long enough that learning the answer
# afterwards wastes it, and the transfer that follows is gigabytes.
confirm_deploy() {
  [ -n "$DEPLOY" ] || return 0
  [ "$ASSUME_YES" != "1" ] || return 0

  printf '\n\033[33mDeploying to %s recreates server and worker on that live instance.\033[0m\n' "$DEPLOY"
  printf 'The database and redis keep running, and the backup taken there is what makes this reversible.\n'
  printf 'Continue? [y/N] '
  read -r reply || reply=
  case "$reply" in
    y | Y | yes | YES) ;;
    *) die "stopped before building anything" ;;
  esac
}

# patch-instance.sh travels with the branch and a host can hold more than one
# checkout of it, so the path is resolved rather than assumed: assuming it fails
# the deploy at the very end of a long build and a multi-gigabyte transfer.
resolve_remote_script() {
  local configured="$REMOTE_REPO/packages/twenty-docker/scripts/patch-instance.sh"
  local alt_git=/root/git/twenty/packages/twenty-docker/scripts/patch-instance.sh
  local alt_root=/root/twenty/packages/twenty-docker/scripts/patch-instance.sh
  local found

  # ls answers with whichever of these exist, in order, in one round trip.
  found=$(ssh "$DEPLOY" "ls -d '$configured' '$alt_git' '$alt_root' 2>/dev/null | head -n 1" 2>/dev/null || true)
  [ -n "$found" ] ||
    die "no patch-instance.sh on $DEPLOY (tried $configured, $alt_git, $alt_root); point --remote-repo at a checkout that has it"

  # A checkout can hold an older copy, and one that predates --mode=load is a
  # different script: it would try to compile the image on a host picked precisely
  # because it cannot. Ask it what it supports instead of trusting the path.
  # stdout is captured by the caller, so this probe must not print: only the
  # printf at the end of the function may reach it.
  ssh "$DEPLOY" "bash '$found' --help 2>&1 | grep -q -- '--mode='" >/dev/null ||
    die "$found on $DEPLOY predates --mode=load; update that checkout with 'git fetch && git reset --hard origin/<branch>'"

  printf '%s' "$found"
}

# Drives patch-instance.sh over ssh instead of reimplementing it: that script
# already knows how to back up this instance, switch TAG, and health-check the
# server afterwards.
deploy_remote() {
  local script

  step "Deploy on $DEPLOY"

  script=$(resolve_remote_script)
  info "script:      $script"
  info "compose dir: $REMOTE_COMPOSE_DIR"

  ssh "$DEPLOY" "test -f '$REMOTE_COMPOSE_DIR/docker-compose.yml' && test -f '$REMOTE_COMPOSE_DIR/.env'" ||
    die "$REMOTE_COMPOSE_DIR on $DEPLOY has no docker-compose.yml or .env"
  # patch-instance.sh points TAG at an image that must already be local, so this
  # is also the check that the transfer landed rather than merely finished.
  ssh "$DEPLOY" "docker image inspect '$IMAGE_REPO:$PATCH_TAG' >/dev/null 2>&1" ||
    die "$IMAGE_REPO:$PATCH_TAG is not on $DEPLOY; the transfer did not land"

  info "backup (also what validate compares row counts against)"
  ssh "$DEPLOY" "cd '$REMOTE_COMPOSE_DIR' && bash '$script' backup" ||
    die "the backup failed; nothing on the instance was touched"

  info "patch --mode=load: only server and worker are recreated"
  ssh "$DEPLOY" "cd '$REMOTE_COMPOSE_DIR' && bash '$script' patch --mode=load --tag='$PATCH_TAG'" ||
    die "the patch failed; 'patch-instance.sh rollback' on $DEPLOY reverts the image"

  info "validate"
  ssh "$DEPLOY" "cd '$REMOTE_COMPOSE_DIR' && bash '$script' validate --tag='$PATCH_TAG'" ||
    warn "validate reported a problem: read its output above before calling this done"

  ok "deployed $IMAGE_REPO:$PATCH_TAG on $DEPLOY"
}

next_steps() {
  local tag="$PATCH_TAG"

  cat <<EOF

Next, on the host that runs the deployment:

  # 1. Get the image onto it. With --ship that is already done; otherwise:
  scp $OUT root@<host>:/root/
  ssh root@<host> 'docker load < /root/$(basename "$OUT")'

  # 2. Confirm the tag resolves and is the right architecture.
  ssh root@<host> 'docker image inspect $IMAGE_REPO:$tag -f "{{.Architecture}} {{.Id}}"'

  # 3. Back up first: patch refuses nothing, but the backup is what validate
  #    compares row counts against.
  cd <deploy dir with docker-compose.yml and .env>
  bash $SCRIPT_DIR/patch-instance.sh backup

  # 4. Switch the deployment to the transferred image. --mode=load compiles and
  #    pulls nothing; only server and worker are recreated.
  bash $SCRIPT_DIR/patch-instance.sh patch --mode=load --tag=$tag

  # 5. Health, patch presence in the running container, row counts, then the
  #    by-hand UI checklist it prints.
  bash $SCRIPT_DIR/patch-instance.sh validate --tag=$tag

Rollback is unchanged: 'docker compose up -d server worker' after setting TAG back
in .env. Keep $IMAGE_REPO:$(basename "$tag") around until the UI checklist passes.

The image is not on a registry, so any 'docker compose pull' undoes the patch:
that is what --mode=pull is for, and it is the upgrade path, not this one.
EOF
}

# ---------------------------------------------------------------------------

parse_args "$@"

for cmd in docker git; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed or not in PATH"
done
docker info >/dev/null 2>&1 || die "docker is not running"

REPO_ROOT=$(cd "$REPO_ROOT" && pwd)

# --deploy-only builds nothing, so the tag has to name an image that is already
# on the target: defaulting one here would name a tag nobody has.
if [ "$DEPLOY_ONLY" = "1" ]; then
  [ -n "$DEPLOY" ] || die "--deploy-only needs --deploy=USER@HOST"
  [ -n "$PATCH_TAG" ] || die "--deploy-only needs --tag, naming the image already loaded on the target"
fi

if [ -z "$PATCH_TAG" ]; then
  sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)
  PATCH_TAG="patch-$sha-$(date +%Y%m%d-%H%M%S)"
fi

# Nothing is built in deploy-only mode, so the version is neither needed nor checked.
if [ "$DEPLOY_ONLY" != "1" ]; then
  if [ -z "$APP_VERSION" ]; then
    APP_VERSION=$(discover_app_version)
  fi
  [ -n "$APP_VERSION" ] ||
    die "cannot tell which version this checkout is; pass --app-version=<semver>"
  is_semver "$APP_VERSION" ||
    die "--app-version '$APP_VERSION' is not semantic versioning (e.g. 2.41.0); the server parses it at boot and will not start otherwise"
fi

# --deploy includes the transfer, so the two cannot name different hosts.
[ -z "$DEPLOY" ] || SHIP=${SHIP:-$DEPLOY}

# Before the plan is printed: the platform it names comes from the target.
probe_remote_arch

step "Plan"
info "repo:     $REPO_ROOT"
info "image:    $IMAGE_REPO:$PATCH_TAG"
info "platform: $PLATFORM"
[ "$DEPLOY_ONLY" = "1" ] || info "app ver:  $APP_VERSION"
[ -z "$DEPLOY" ] || info "deploy:   $DEPLOY:$REMOTE_COMPOSE_DIR"
if [ "$DEPLOY_ONLY" = "1" ]; then
  info "mode:     deploy only, no build and no transfer"
fi

confirm_deploy

if [ "$DEPLOY_ONLY" != "1" ]; then
  check_sources
  build_image
  verify_image
  package_image
  [ -z "$SHIP" ] || ship_archive
fi

if [ -z "$DEPLOY" ]; then
  next_steps
else
  deploy_remote
fi
