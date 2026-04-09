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

if ! command -v flux >/dev/null 2>&1; then
  echo "Error: flux is not installed or not in PATH." >&2
  exit 1
fi

targets=()
while IFS= read -r -d '' file; do
  if grep -Eq '^apiVersion:[[:space:]]*kustomize\.toolkit\.fluxcd\.io/' "$file" \
    && grep -Eq '^kind:[[:space:]]*Kustomization' "$file"; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      targets+=("$file|$name")
    done < <(
      awk '
        function flush_doc() {
          if (is_flux_api && is_ks_kind && ks_name != "") {
            print ks_name
          }
          is_flux_api = 0
          is_ks_kind = 0
          in_metadata = 0
          ks_name = ""
        }

        /^---[[:space:]]*$/ {
          flush_doc()
          next
        }

        /^apiVersion:[[:space:]]*kustomize\.toolkit\.fluxcd\.io\// {
          is_flux_api = 1
          next
        }

        /^kind:[[:space:]]*Kustomization[[:space:]]*$/ {
          is_ks_kind = 1
          next
        }

        /^metadata:[[:space:]]*$/ {
          in_metadata = 1
          next
        }

        in_metadata && /^[^[:space:]]/ {
          in_metadata = 0
        }

        in_metadata && /^[[:space:]]+name:[[:space:]]*/ && ks_name == "" {
          line = $0
          sub(/^[[:space:]]*name:[[:space:]]*/, "", line)
          sub(/[[:space:]]+$/, "", line)
          ks_name = line
        }

        END {
          flush_doc()
        }
      ' "$file"
    )
  fi
done < <(
  find "$TARGET_PATH" -type f \( -name "*.yaml" -o -name "*.yml" \) \
    ! -path "*/.git/*" \
    ! -path "*/.terraform/*" \
    -print0 | sort -z
)

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "No Flux Kustomization files found under: $TARGET_PATH"
  exit 0
fi

echo "Checking ${#targets[@]} Flux Kustomization target(s) under: $TARGET_PATH"

total=${#targets[@]}
passed=0
failed=0

for target in "${targets[@]}"; do
  file="${target%%|*}"
  name="${target#*|}"
  dir="$(dirname "$file")"
  rel_file="$file"
  if [[ "$file" == "$ROOT_DIR"/* ]]; then
    rel_file="${file#"$ROOT_DIR"/}"
  fi

  if flux build kustomization "$name" --dry-run --path "$dir" --kustomization-file "$file" "$@" >/dev/null; then
    printf "%b\n" "[CHECK] $rel_file (name=$name) ${C_GREEN}[✓]${C_RESET}"
    passed=$((passed + 1))
  else
    printf "%b\n" "[CHECK] $rel_file (name=$name) ${C_RED}[✗]${C_RESET}"
    failed=$((failed + 1))
  fi
done

echo
echo "Summary: total=$total passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
  exit 1
fi
