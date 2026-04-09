#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CHECKS_DIR="$SCRIPT_DIR/checks"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_RED='\033[31m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_CYAN='\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_CYAN=''
fi

TARGET_PATH="$ROOT_DIR"
FAIL_FAST=true
VERBOSE=true
PASSTHROUGH_ARGS=()

print_help() {
  cat <<EOF
Usage: ./scripts/run-verify.sh [TARGET_PATH] [options] [-- passthrough_args]

Run repository verification checks:
  1. YAML Lint
  2. Kubeconform
  3. Kustomize Build
  4. Flux Kustomization Validate

Options:
  --fail-fast         Stop on first failed step (default)
  --continue-on-fail  Run all steps even if one fails
  --verbose           Show full output from each check (default)
  --quiet             Show compact output
  -h, --help          Show this help text

Arguments:
  TARGET_PATH         Optional path to validate (default: repo root)
  --                 Pass remaining args to all check scripts

Examples:
  ./scripts/run-verify.sh
  ./scripts/run-verify.sh clusters/prod
  ./scripts/run-verify.sh --quiet
  ./scripts/run-verify.sh --continue-on-fail
  ./scripts/run-verify.sh -- --strict
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --fail-fast)
      FAIL_FAST=true
      shift
      ;;
    --continue-on-fail)
      FAIL_FAST=false
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --quiet)
      VERBOSE=false
      shift
      ;;
    --)
      shift
      PASSTHROUGH_ARGS+=("$@")
      break
      ;;
    -*)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    *)
      if [[ "$TARGET_PATH" == "$ROOT_DIR" ]]; then
        TARGET_PATH="$1"
      else
        PASSTHROUGH_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Error: target path does not exist: $TARGET_PATH" >&2
  exit 1
fi

checks=(
  "YAML Lint|$CHECKS_DIR/run-yamllint.sh"
  "Kubeconform|$CHECKS_DIR/run-kubeconform.sh"
  "Kustomize Build|$CHECKS_DIR/run-kustomize-build.sh"
  "Flux Kustomization Validate|$CHECKS_DIR/run-flux-validate-kustomization.sh"
)

total=${#checks[@]}
passed=0
failed=0

if [[ ! -d "$CHECKS_DIR" ]]; then
  echo "Error: checks directory not found: $CHECKS_DIR" >&2
  exit 1
fi

mode_label="$([[ "$FAIL_FAST" == true ]] && echo "fail-fast" || echo "continue-on-fail")"
child_color_env=()
if [[ -n "$C_RESET" ]]; then
  child_color_env=(FORCE_COLOR=1)
fi

printf "%b\n" "${C_BOLD}${C_CYAN}==== Verification Run ====${C_RESET}"
printf "Target: %s\n" "$TARGET_PATH"
printf "%b\n" "Mode:   ${C_DIM}${mode_label}${C_RESET}"
printf "Verbose: %s\n" "$([[ "$VERBOSE" == true ]] && echo "on" || echo "off")"
printf "Steps:  %s\n" "$total"

for check in "${checks[@]}"; do
  name="${check%%|*}"
  script="${check#*|}"

  if [[ ! -x "$script" ]]; then
    chmod +x "$script"
  fi

  echo
  printf "%b\n" "${C_BOLD}${C_CYAN}--> ${name}${C_RESET}"
  output_file="$(mktemp)"
  if env "${child_color_env[@]}" "$script" "$TARGET_PATH" "${PASSTHROUGH_ARGS[@]}" >"$output_file" 2>&1; then
    if [[ "$VERBOSE" == true ]]; then
      sed 's/^/    /' "$output_file"
    else
      summary_line="$(grep -E 'Summary:|Verification summary:' "$output_file" | tail -n 1 || true)"
      if [[ -n "$summary_line" ]]; then
        printf "    %b\n" "${C_DIM}${summary_line}${C_RESET}"
      fi
    fi
    printf "%b\n" "${C_GREEN}[PASS]${C_RESET} $name"
    passed=$((passed + 1))
  else
    sed 's/^/    /' "$output_file"
    printf "%b\n" "${C_RED}[FAIL]${C_RESET} $name"
    failed=$((failed + 1))
    rm -f "$output_file"
    if [[ "$FAIL_FAST" == true ]]; then
      echo
      printf "%b\n" "${C_BOLD}${C_YELLOW}==== Verification Summary ====${C_RESET}"
      printf "total=%d passed=%d failed=%d\n" "$total" "$passed" "$failed"
      exit 1
    fi
    continue
  fi
  rm -f "$output_file"
done

echo
printf "%b\n" "${C_BOLD}${C_YELLOW}==== Verification Summary ====${C_RESET}"
printf "total=%d passed=%d failed=%d\n" "$total" "$passed" "$failed"

if [[ $failed -gt 0 ]]; then
  exit 1
fi
