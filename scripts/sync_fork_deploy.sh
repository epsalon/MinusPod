#!/usr/bin/env bash
# Sync this fork with upstream, rebuild the Docker image, and redeploy.
#
#   1. Fast-forward local main to upstream/main and push it to origin.
#   2. Rebase the deploy branch (default: the current branch) onto main and
#      force-push it to origin (with lease) if it is tracked there. A local
#      merge driver (scripts/changelog_merge.py) keeps the fork's
#      "## [Unreleased]" CHANGELOG entries from conflicting with upstream's.
#   3. Build ttlequals0/minuspod:local from that branch. By default this is a
#      fast overlay build (Dockerfile.overlay): the app code and web UI laid
#      on top of the published upstream image for the version in version.py.
#      The image it replaces is kept as ttlequals0/minuspod:previous.
#   4. Recreate the minuspod container and wait for it to report healthy.
#
# Usage: scripts/sync_fork_deploy.sh [options]
#   -b, --branch NAME   Branch to deploy (default: current branch)
#   --no-rebase         Deploy the branch as-is, without rebasing onto main
#   --no-push           Don't push anything to origin
#   --skip-sync         Skip the git steps; just rebuild and redeploy
#   --full              Full build from Dockerfile instead of the overlay
#                       (slow: compiles patched system packages from source)
#   --no-cache          Build the image without the Docker layer cache
#   --claude-fix        On rebase conflicts, have Claude Code resolve them
#                       (claude -p), then continue the rebase
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

  local branch="" rebase=1 push=1 sync=1 claude_fix=0 full=0 build_flags=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--branch) branch="$2"; shift 2 ;;
      --no-rebase) rebase=0; shift ;;
      --no-push) push=0; shift ;;
      --skip-sync) sync=0; shift ;;
      --full) full=1; shift ;;
      --no-cache) build_flags+=(--no-cache); shift ;;
      --claude-fix) claude_fix=1; shift ;;
      -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
      install_changelog_driver
      step "Rebasing $branch onto $MAIN"
      if ! git rebase "$MAIN"; then
        if [[ $claude_fix -eq 0 ]] || ! claude_resolve_rebase "$branch" "$MAIN"; then
          git rebase --abort || true
          die "Rebase of $branch onto $MAIN hit conflicts and was aborted. Rebase by hand, then rerun with --skip-sync."
        fi
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

  if [[ $full -eq 0 ]]; then
    local base="$IMAGE:$version"
    # The overlay only replaces app code, so anything that feeds the
    # dependency stages must match the base image's release.
    if git rev-parse --verify --quiet "refs/tags/v$version" >/dev/null; then
      local drift
      drift="$(git diff --name-only "v$version" HEAD -- Dockerfile requirements.txt requirements.in \
        scripts/build_media_security_packages.py 'scripts/*-security/')"
      [[ -z "$drift" ]] || die "These dependency files differ from v$version, so the overlay base image won't include them:
$drift
Rerun with --full."
    else
      echo "Note: no v$version tag to check dependency files against." >&2
    fi
    step "Pulling base image $base"
    docker pull "$base" || docker image inspect "$base" >/dev/null 2>&1 \
      || die "Base image $base isn't available. Rerun with --full."
    build_flags+=(-f Dockerfile.overlay --build-arg "BASE_IMAGE=$base")
  fi

  step "Building $IMAGE:$TAG ($build_version from $(git symbolic-ref --short HEAD), $([[ $full -eq 1 ]] && echo full || echo overlay) build)"
  # Tag the current image first: once the build takes the tag, Docker may
  # delete the untagged old image.
  if docker image inspect "$IMAGE:$TAG" >/dev/null 2>&1; then
    docker tag "$IMAGE:$TAG" "$IMAGE:previous"
    echo "Current image kept as $IMAGE:previous"
  fi
  docker build "${build_flags[@]}" \
    --build-arg "MINUSPOD_VERSION=$build_version" \
    -t "$IMAGE:$TAG" .

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

# Register scripts/changelog_merge.py as the merge driver for CHANGELOG.md in
# this clone only (.git/config and .git/info/attributes). The driver is copied
# into .git/ because the working tree may not contain it mid-rebase.
install_changelog_driver() {
  local gitdir
  gitdir="$(git rev-parse --git-common-dir)"
  if [[ -f scripts/changelog_merge.py ]]; then
    cp scripts/changelog_merge.py "$gitdir/changelog_merge.py"
  fi
  [[ -f "$gitdir/changelog_merge.py" ]] || return 0
  git config merge.changelog.name "Keep fork Unreleased CHANGELOG entries on top"
  git config merge.changelog.driver "python3 \"$(cd "$gitdir" && pwd)/changelog_merge.py\" %O %A %B"
  mkdir -p "$gitdir/info"
  grep -qxF 'CHANGELOG.md merge=changelog' "$gitdir/info/attributes" 2>/dev/null \
    || echo 'CHANGELOG.md merge=changelog' >> "$gitdir/info/attributes"
}

# Resolve an in-progress rebase's conflicts with Claude Code, one stopped
# commit at a time. Claude only edits files; this function checks the result,
# stages it, and continues the rebase. Returns non-zero on any failure, leaving
# the rebase in progress for the caller to abort.
claude_resolve_rebase() {
  local branch="$1" onto="$2" rounds=0
  command -v claude >/dev/null || { echo "claude CLI not found on PATH." >&2; return 1; }

  while [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]; do
    rounds=$((rounds + 1))
    (( rounds <= 20 )) || { echo "Too many conflict rounds; giving up." >&2; return 1; }

    local files
    files="$(git diff --name-only --diff-filter=U)"
    if [[ -z "$files" ]]; then
      # Stopped without conflicts (for example, an empty commit).
      GIT_EDITOR=true git rebase --continue && continue
      return 1
    fi

    local commit
    commit="$(git log -1 --format='%h %s' REBASE_HEAD 2>/dev/null || echo unknown)"
    step "Asking Claude to resolve conflicts in commit: $commit"
    printf '  %s\n' $files

    local prompt
    prompt="A git rebase of branch '$branch' onto '$onto' stopped with merge conflicts while applying commit: $commit.
Conflicted files:
$files

Resolve every conflict in these files so the result keeps the intent of both sides: the upstream changes already on '$onto' and the changes from the commit being applied. Use 'git show REBASE_HEAD' to see what the commit changed and 'git log $onto' or 'git diff' for upstream context. For CHANGELOG-style files, keep both sides' entries in a sensible order.
Remove all conflict markers. Only edit the conflicted files. Do not run git add, git commit, git rebase or any other command that changes git state; the calling script does that.
Finish with a short summary of how you resolved each file."

    if ! claude -p "$prompt" \
        --permission-mode acceptEdits \
        --allowedTools "Read" "Edit" "Write" "Grep" "Glob" \
          "Bash(git diff:*)" "Bash(git show:*)" "Bash(git log:*)" "Bash(git status:*)"; then
      echo "Claude exited with an error." >&2
      return 1
    fi

    local f bad=0
    for f in $files; do
      if [[ -f "$f" ]] && grep -qE '^(<<<<<<< |>>>>>>> )' "$f"; then
        echo "Conflict markers remain in $f." >&2
        bad=1
      fi
    done
    (( bad == 0 )) || return 1

    # shellcheck disable=SC2086
    git add -- $files
    step "Claude's resolution (staged):"
    git diff --cached --stat

    if ! GIT_EDITOR=true git rebase --continue; then
      # Either the next commit conflicts (loop again) or something else broke.
      [[ -n "$(git diff --name-only --diff-filter=U)" ]] || return 1
    fi
  done
  return 0
}

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

main "$@"
