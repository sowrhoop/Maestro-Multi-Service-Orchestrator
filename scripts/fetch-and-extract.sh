#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "fetch-and-extract: URL required" >&2
  exit 64
fi

url="$1"

umask 0027

tmp_file=$(mktemp "${TMPDIR:-/tmp}/maestro.fetch.XXXXXX")
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/maestro.unpack.XXXXXX")

cleanup() {
  rm -f "$tmp_file"
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT HUP TERM

if ! curl -fsSL "$url" -o "$tmp_file"; then
  echo "fetch-and-extract: failed to download $url" >&2
  exit 1
fi

lower_url="${url,,}"
if [[ "$lower_url" == *.zip ]]; then
  if ! unzip -q "$tmp_file" -d "$tmp_dir"; then
    echo "fetch-and-extract: failed to unzip archive" >&2
    exit 1
  fi
else
  if ! tar -xaf "$tmp_file" -C "$tmp_dir" --warning=no-unknown-keyword --no-same-owner --no-same-permissions; then
    echo "fetch-and-extract: failed to untar archive" >&2
    exit 1
  fi
fi

shopt -s dotglob nullglob
entries=("$tmp_dir"/*)
shopt -u dotglob

if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
  src="${entries[0]}"
else
  src="$tmp_dir"
fi

if ! cp -a "${src}/." "./"; then
  echo "fetch-and-extract: failed to copy project files" >&2
  exit 1
fi
