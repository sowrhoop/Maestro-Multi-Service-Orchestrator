#!/usr/bin/env bash
set -euo pipefail

# Create PRs in project-1 and project-2 to add dispatch workflows that
# trigger the orchestrator merge build after successful builds.
# Requires: GitHub CLI (gh), with repo access to target repos.

OWNER=${1:-}
ORCH_REPO=${2:-Supervisor-Image-Combination}
BRANCH=${3:-ci/add-dispatch-merge}

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI 'gh' is required. Install https://cli.github.com/" >&2
  exit 1
fi

if [ -z "$OWNER" ]; then
  echo "Usage: $0 <github_owner_or_org> [orchestrator_repo_name] [branch]" >&2
  exit 1
fi

work() {
  local repo="$1"; shift
  echo "Processing $OWNER/$repo ..."
  tmp=$(mktemp -d)
  gh repo clone "$OWNER/$repo" "$tmp" -- --quiet
  pushd "$tmp" >/dev/null
  git checkout -b "$BRANCH"
  mkdir -p .github/workflows
  if [[ "$repo" == "project-1" ]]; then
    cp -f ../../templates/dispatch/project-1-dispatch.yml .github/workflows/dispatch-merge.yml
  else
    cp -f ../../templates/dispatch/project-2-dispatch.yml .github/workflows/dispatch-merge.yml
  fi
  git add .github/workflows/dispatch-merge.yml
  git commit -m "CI: add dispatch to $ORCH_REPO merge workflow"
  git push -u origin "$BRANCH"
  gh pr create --title "CI: add dispatch to $ORCH_REPO merge workflow" \
               --body "Adds a workflow that dispatches to $OWNER/$ORCH_REPO after successful builds." || true
  popd >/dev/null
}

work project-1
work project-2

echo "Done. Create secrets ORCH_PAT in both repos (PAT with 'repo' scope)."

