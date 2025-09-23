#!/usr/bin/env bash
set -euo pipefail

# Bootstrap two GitHub repos from the provided templates and push them.
# Requires: GitHub CLI (gh) authenticated with repo:create permission.

OWNER=${1:-}
VISIBILITY=${2:-public}

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI 'gh' is required. Install from https://cli.github.com/" >&2
  exit 1
fi

if [ -z "$OWNER" ]; then
  echo "Usage: $0 <github_owner_or_org> [public|private]" >&2
  exit 1
fi

tmp=$(mktemp -d)

bootstrap() {
  local name="$1"; shift
  local src_dir="$1"; shift
  local repo="$OWNER/$name"
  local dir="$tmp/$name"
  echo "Creating $repo from $src_dir ..."
  mkdir -p "$dir"
  cp -a "$src_dir/." "$dir/"
  (cd "$dir" && \
    git init -q && \
    git add . && \
    git commit -q -m "Initial commit: $name" && \
    gh repo create "$repo" --$VISIBILITY --source=. --push)
}

bootstrap project-1 templates/project-1-python
bootstrap project-2 templates/project-2-node

echo "Done. Repos created under https://github.com/$OWNER"

