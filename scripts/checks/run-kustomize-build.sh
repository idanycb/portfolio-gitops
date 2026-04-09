#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if [[ -z "${NO_COLOR:-}" && ( -t 1 || "${FORCE_COLOR:-0}" == "1" ) ]]; then
  C_RESET='\033[0m'
  C_GREEN='\033[32m'
  C_RED='\033[31m'
else
  C_RESET=''
  C_GREEN=''
  C_RED=''
fi

TARGET_PATH="$ROOT_DIR"
if [[ $# -gt 0 && "$1" != -* ]]; then
  TARGET_PATH="$1"
  shift
fi

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Error: target path does not exist: $TARGET_PATH" >&2
  exit 1
fi

if command -v kustomize >/dev/null 2>&1; then
  build_cmd=(kustomize build)
elif command -v kubectl >/dev/null 2>&1; then
  build_cmd=(kubectl kustomize)
else
  echo "Error: neither kustomize nor kubectl is installed." >&2
  exit 1
fi

kustomization_dirs=()
while IFS= read -r -d '' file; do
  kustomization_dirs+=("$(dirname "$file")")
done < <(
  find "$TARGET_PATH" -type f -name "kustomization.yaml" \
    ! -path "*/.git/*" \
    ! -path "*/.terraform/*" \
    -print0 | sort -z
)

if [[ ${#kustomization_dirs[@]} -eq 0 ]]; then
  echo "No kustomization.yaml files found under: $TARGET_PATH"
  exit 0
fi

echo "Building ${#kustomization_dirs[@]} kustomize target(s) under: $TARGET_PATH"

total=${#kustomization_dirs[@]}
passed=0
failed=0

for dir in "${kustomization_dirs[@]}"; do
  rel_dir="$dir"
  if [[ "$dir" == "$ROOT_DIR"/* ]]; then
    rel_dir="${dir#"$ROOT_DIR"/}"
  fi

  if "${build_cmd[@]}" "$dir" "$@" >/dev/null; then
    printf "%b\n" "[BUILD] $rel_dir ${C_GREEN}[✓]${C_RESET}"
    passed=$((passed + 1))
  else
    printf "%b\n" "[BUILD] $rel_dir ${C_RED}[✗]${C_RESET}"
    failed=$((failed + 1))
  fi
done

echo
echo "Summary: total=$total passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
  exit 1
fi
