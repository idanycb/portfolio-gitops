#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

TARGET_PATH="$ROOT_DIR"
if [[ $# -gt 0 && "$1" != -* ]]; then
  TARGET_PATH="$1"
  shift
fi

if ! command -v yamllint >/dev/null 2>&1; then
  echo "Error: yamllint is not installed or not in PATH." >&2
  echo "Install it first (Fedora): sudo dnf install yamllint" >&2
  exit 1
fi

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Error: target path does not exist: $TARGET_PATH" >&2
  exit 1
fi

has_config_arg=false
for arg in "$@"; do
  if [[ "$arg" == "-c" || "$arg" == --config-file=* || "$arg" == "-d" || "$arg" == --config-data=* ]]; then
    has_config_arg=true
    break
  fi
done

cmd=(yamllint)
if [[ -f "$ROOT_DIR/.yamllint" && "$has_config_arg" == false ]]; then
  cmd+=("-c" "$ROOT_DIR/.yamllint")
fi

yaml_files=()
while IFS= read -r -d '' file; do
  yaml_files+=("$file")
done < <(
  find "$TARGET_PATH" -type f \( -name "*.yaml" -o -name "*.yml" \) \
    ! -path "*/.git/*" \
    ! -path "*/.terraform/*" \
    ! -path "*/clusters/prod/flux-system/gotk-*" \
    ! -path "*/bootstrap/*" \
    -print0
)

if [[ ${#yaml_files[@]} -eq 0 ]]; then
  echo "No YAML files found under: $TARGET_PATH"
  exit 0
fi

cmd+=("$@")
cmd+=("${yaml_files[@]}")

echo "Linting ${#yaml_files[@]} YAML files under: $TARGET_PATH"
"${cmd[@]}"
