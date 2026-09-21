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

usage() {
  cat <<'EOF'
Build the patched Twenty image, verify it, and package it for transfer.

Usage: build-image.sh [options]

Options:
  --tag=TAG            image tag (default: patch-<git sha>-<timestamp>)
  --repo-root=DIR      Twenty checkout to build (default: this script's repository)
  --image-repo=REPO    repository to tag under (default: twentycrm/twenty)
  --platform=PLATFORM  docker build --platform (default: linux/amd64)
  --out=FILE           archive path (default: <compose-free cwd>/<tag>.tar.gz)
  --ship=USER@HOST     stream the archive to this host, which runs docker load
  -h, --help           this message

Environment variables: REPO_ROOT, IMAGE_REPO, PATCH_TAG, PLATFORM, OUT, SHIP.

The account used with --ship is taken as-is and runs docker load over ssh: make
sure it can reach the docker socket there. Without --ship the archive is only
written, and you copy it yourself.
EOF
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --tag=*) PATCH_TAG=${arg#--tag=} ;;
      --repo-root=*) REPO_ROOT=${arg#--repo-root=} ;;
      --image-repo=*) IMAGE_REPO=${arg#--image-repo=} ;;
      --platform=*) PLATFORM=${arg#--platform=} ;;
      --out=*) OUT=${arg#--out=} ;;
      --ship=*) SHIP=${arg#--ship=} ;;
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
  local host_arch

  step "Build"

  host_arch=$(docker info -f '{{.Architecture}}' 2>/dev/null || uname -m)
  case "$host_arch:$PLATFORM" in
    x86_64:linux/amd64 | amd64:linux/amd64 | aarch64:linux/arm64 | arm64:linux/arm64) ;;
    *)
      # Not fatal: buildx can build the other architecture, but only through
      # qemu, which turns a 15 minute build into an hour or an OOM.
      warn "this host is $host_arch and the image is built for $PLATFORM"
      warn "that needs emulation and a lot more time and memory"
      ;;
  esac

  info "building $image from $REPO_ROOT"
  info "dependencies, lingui and the front-end build all run inside it: expect 10-30 minutes"
  # --target twenty is the server + frontend image the compose file expects.
  # APP_VERSION is what /client-config reports, so validate can confirm the tag.
  docker build \
    --target twenty \
    -f "$dockerfile" \
    --platform "$PLATFORM" \
    --build-arg "APP_VERSION=$PATCH_TAG" \
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

if [ -z "$PATCH_TAG" ]; then
  sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)
  PATCH_TAG="patch-$sha-$(date +%Y%m%d-%H%M%S)"
fi

step "Plan"
info "repo:     $REPO_ROOT"
info "image:    $IMAGE_REPO:$PATCH_TAG"
info "platform: $PLATFORM"

check_sources
build_image
verify_image
package_image
[ -z "$SHIP" ] || ship_archive
next_steps
