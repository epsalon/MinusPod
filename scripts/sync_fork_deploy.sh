#!/usr/bin/env bash
# Sync this fork with upstream, rebuild the Docker image, and redeploy.
#
#   1. Fast-forward local main to upstream/main and push it to origin.
#   2. Rebase the deploy branch (default: the current branch) onto main and
#      force-push it to origin (with lease) if it is tracked there.
#   3. Build ttlequals0/minuspod:local from that branch. The image it replaces
#      is kept as ttlequals0/minuspod:previous for rollback.
#   4. Recreate the minuspod container and wait for it to report healthy.
#
# Usage: scripts/sync_fork_deploy.sh [options]
#   -b, --branch NAME   Branch to deploy (default: current branch)
#   --no-rebase         Deploy the branch as-is, without rebasing onto main
#   --no-push           Don't push anything to origin
#   --skip-sync         Skip the git steps; just rebuild and redeploy
#   --no-cache          Build the image without the Docker layer cache
#   -h, --help          Show this help
#
# Rollback:
#   docker tag ttlequals0/minuspod:previous ttlequals0/minuspod:local
#   MINUSPOD_VERSION=local docker compose up -d minuspod

set -euo pipefail

# Everything lives in main() so bash has read the whole file before git
# starts switching branches underneath it.
main() {
  local IMAGE=ttlequals0/minuspod
  local TAG=local
  local SERVICE=minuspod
  local UPSTREAM=upstream
  local ORIGIN=origin
  local MAIN=main
  local HEALTH_TIMEOUT=300

  local branch="" rebase=1 push=1 sync=1 build_flags=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--branch) branch="$2"; shift 2 ;;
      --no-rebase) rebase=0; shift ;;
      --no-push) push=0; shift ;;
      --skip-sync) sync=0; shift ;;
      --no-cache) build_flags+=(--no-cache); shift ;;
      -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done

  cd "$(git rev-parse --show-toplevel)"

  local current
  current="$(git symbolic-ref --short HEAD 2>/dev/null)" || die "Detached HEAD; check out a branch first."
  branch="${branch:-$current}"

  if [[ $sync -eq 1 ]]; then
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
      || die "Working tree has uncommitted changes; commit or stash them first."

    step "Fetching $UPSTREAM and $ORIGIN"
    git fetch --prune "$UPSTREAM"
    git fetch --prune "$ORIGIN"

    step "Fast-forwarding $MAIN to $UPSTREAM/$MAIN"
    if [[ "$current" == "$MAIN" ]]; then
      git merge --ff-only "$UPSTREAM/$MAIN" \
        || die "$MAIN has commits that aren't in $UPSTREAM/$MAIN; resolve by hand."
    else
      git fetch . "$UPSTREAM/$MAIN:$MAIN" \
        || die "$MAIN has commits that aren't in $UPSTREAM/$MAIN; resolve by hand."
    fi
    if [[ $push -eq 1 ]]; then
      git push "$ORIGIN" "$MAIN"
    fi

    if [[ "$branch" != "$current" ]]; then
      step "Checking out $branch"
      git checkout "$branch"
    fi

    if [[ "$branch" != "$MAIN" && $rebase -eq 1 ]]; then
      step "Rebasing $branch onto $MAIN"
      if ! git rebase "$MAIN"; then
        git rebase --abort || true
        die "Rebase of $branch onto $MAIN hit conflicts and was aborted. Rebase by hand, then rerun with --skip-sync."
      fi
      if [[ $push -eq 1 ]] && git rev-parse --verify --quiet "refs/remotes/$ORIGIN/$branch" >/dev/null; then
        git push --force-with-lease "$ORIGIN" "$branch"
      fi
    fi
  fi

  local version sha
  version="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' version.py)"
  sha="$(git rev-parse --short HEAD)"
  local build_version="${version:-dev}-${sha}"

  step "Building $IMAGE:$TAG ($build_version from $(git symbolic-ref --short HEAD))"
  local old_id=""
  old_id="$(docker image inspect --format '{{.Id}}' "$IMAGE:$TAG" 2>/dev/null || true)"
  docker build "${build_flags[@]}" \
    --build-arg "MINUSPOD_VERSION=$build_version" \
    -t "$IMAGE:$TAG" .
  local new_id
  new_id="$(docker image inspect --format '{{.Id}}' "$IMAGE:$TAG")"
  if [[ -n "$old_id" && "$old_id" != "$new_id" ]]; then
    docker tag "$old_id" "$IMAGE:previous"
    echo "Previous image kept as $IMAGE:previous"
  fi

  step "Redeploying $SERVICE"
  MINUSPOD_VERSION="$TAG" docker compose up -d "$SERVICE"

  step "Waiting for $SERVICE to become healthy (up to ${HEALTH_TIMEOUT}s)"
  local cid status="" waited=0
  cid="$(MINUSPOD_VERSION="$TAG" docker compose ps -q "$SERVICE")"
  [[ -n "$cid" ]] || die "Container for $SERVICE isn't running."
  while (( waited < HEALTH_TIMEOUT )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
    case "$status" in
      healthy) break ;;
      unhealthy|exited|dead) break ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done

  if [[ "$status" == "healthy" ]]; then
    step "Deployed $build_version: $SERVICE is healthy"
  else
    echo
    echo "$SERVICE status: ${status:-unknown}. Recent logs:" >&2
    docker logs --tail 40 "$cid" >&2 || true
    echo >&2
    echo "To roll back:" >&2
    echo "  docker tag $IMAGE:previous $IMAGE:$TAG && MINUSPOD_VERSION=$TAG docker compose up -d $SERVICE" >&2
    exit 1
  fi
}

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

main "$@"
