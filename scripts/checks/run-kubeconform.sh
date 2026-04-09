#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
PINNED_SCHEMA_DIR="${KUBECONFORM_PINNED_SCHEMA_DIR:-$ROOT_DIR/schemas/kubeconform}"

TARGET_PATH="$ROOT_DIR"
if [[ $# -gt 0 && "$1" != -* ]]; then
  TARGET_PATH="$1"
  shift
fi

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "Error: kubeconform is not installed or not in PATH." >&2
  echo "Install it first: https://github.com/yannh/kubeconform" >&2
  exit 1
fi

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Error: target path does not exist: $TARGET_PATH" >&2
  exit 1
fi

threads="$(command -v nproc >/dev/null 2>&1 && nproc || echo 4)"

yaml_files=()
while IFS= read -r -d '' file; do
  yaml_files+=("$file")
done < <(
  find "$TARGET_PATH" -type f \( -name "*.yaml" -o -name "*.yml" \) \
    ! -name "kustomization.yaml" \
    ! -path "*/.git/*" \
    ! -path "*/.terraform/*" \
    ! -path "*/bootstrap/cloud-init.yaml" \
    ! -path "*/clusters/prod/flux-system/gotk-*" \
    -print0
)

if [[ ${#yaml_files[@]} -eq 0 ]]; then
  echo "No YAML files found under: $TARGET_PATH"
  exit 0
fi

if [[ ! -d "$PINNED_SCHEMA_DIR" ]]; then
  echo "Error: pinned schema directory not found: $PINNED_SCHEMA_DIR" >&2
  echo "Run scripts/checks/generate-kubeconform-schemas.sh first." >&2
  exit 1
fi

required_targets=()
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  required_targets+=("$entry")
done < <(
  for file in "${yaml_files[@]}"; do
    awk '
      function flush_doc() {
        if (api != "" && kind != "") {
          split(api, parts, "/")
          if (length(parts) == 2) {
            group = parts[1]
            version = parts[2]
            if (index(group, ".") > 0) {
              print group "|" tolower(kind) "|" version
            }
          }
        }
        api = ""
        kind = ""
      }

      /^---[[:space:]]*$/ {
        flush_doc()
        next
      }

      /^apiVersion:[[:space:]]*/ {
        api = $0
        sub(/^[[:space:]]*apiVersion:[[:space:]]*/, "", api)
        sub(/[[:space:]]+$/, "", api)
        next
      }

      /^kind:[[:space:]]*/ {
        kind = $0
        sub(/^[[:space:]]*kind:[[:space:]]*/, "", kind)
        sub(/[[:space:]]+$/, "", kind)
        next
      }

      END {
        flush_doc()
      }
    ' "$file"
  done | sort -u
)

missing_schemas=()
for entry in "${required_targets[@]}"; do
  group="${entry%%|*}"
  rest="${entry#*|}"
  kind="${rest%%|*}"
  version="${rest#*|}"

  case "$group" in
    admissionregistration.k8s.io|apiextensions.k8s.io|apiregistration.k8s.io|apps|authentication.k8s.io|authorization.k8s.io|autoscaling|batch|certificates.k8s.io|coordination.k8s.io|discovery.k8s.io|events.k8s.io|extensions|flowcontrol.apiserver.k8s.io|networking.k8s.io|node.k8s.io|policy|rbac.authorization.k8s.io|scheduling.k8s.io|storage.k8s.io|kustomize.config.k8s.io)
      continue
      ;;
  esac

  rel_path="$group/${kind}_${version}.json"
  if [[ ! -f "$PINNED_SCHEMA_DIR/$rel_path" ]]; then
    missing_schemas+=("$rel_path")
  fi
done

if [[ ${#missing_schemas[@]} -gt 0 ]]; then
  echo "Error: missing pinned schemas:" >&2
  printf '%s\n' "${missing_schemas[@]}" | sort -u | sed 's/^/  - /' >&2
  echo "Run scripts/checks/generate-kubeconform-schemas.sh to generate them." >&2
  exit 1
fi

cmd=(kubeconform -strict -summary -n "$threads")
cmd+=("-schema-location" "default")
cmd+=("-schema-location" "$PINNED_SCHEMA_DIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")
cmd+=("$@")
cmd+=("${yaml_files[@]}")

echo "Validating ${#yaml_files[@]} YAML files under: $TARGET_PATH"
"${cmd[@]}"
