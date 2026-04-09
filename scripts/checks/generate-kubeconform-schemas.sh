#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

TARGET_PATH="$ROOT_DIR"
if [[ $# -gt 0 && "$1" != -* ]]; then
  TARGET_PATH="$1"
  shift
fi

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Error: target path does not exist: $TARGET_PATH" >&2
  exit 1
fi

for cmd in kubeconform helm python3 openapi2jsonschema; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

PINNED_SCHEMA_DIR="${KUBECONFORM_PINNED_SCHEMA_DIR:-$ROOT_DIR/schemas/kubeconform}"
TOOLS_DIR="$ROOT_DIR/.cache/tools"
CONVERTER="$TOOLS_DIR/openapi2jsonschema.py"

mkdir -p "$PINNED_SCHEMA_DIR" "$TOOLS_DIR"

if [[ ! -f "$CONVERTER" ]]; then
  curl -fsSL https://raw.githubusercontent.com/yannh/kubeconform/master/scripts/openapi2jsonschema.py -o "$CONVERTER"
fi

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

tmp_output="$(mktemp)"
set +e
kubeconform -strict -summary \
  -schema-location default \
  -schema-location "$PINNED_SCHEMA_DIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "${yaml_files[@]}" >"$tmp_output" 2>&1
kubeconform_exit=$?
set -e

missing_files=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  file_path="${line%% - *}"
  if [[ -f "$file_path" ]]; then
    missing_files+=("$file_path")
  fi
done < <(grep 'could not find schema for' "$tmp_output" | sort -u)

if [[ ${#missing_files[@]} -eq 0 ]]; then
  echo "No missing schemas detected. kubeconform exit code: $kubeconform_exit"
  rm -f "$tmp_output"
  exit 0
fi

mapfile -t missing_relpaths < <(
  python3 - "$PINNED_SCHEMA_DIR" "${missing_files[@]}" <<'PY'
import sys
from pathlib import Path
import yaml

pinned = Path(sys.argv[1])
files = [Path(p) for p in sys.argv[2:]]

builtin = {
    "admissionregistration.k8s.io","apiextensions.k8s.io","apiregistration.k8s.io",
    "apps","authentication.k8s.io","authorization.k8s.io","autoscaling","batch",
    "certificates.k8s.io","coordination.k8s.io","discovery.k8s.io","events.k8s.io",
    "extensions","flowcontrol.apiserver.k8s.io","networking.k8s.io","node.k8s.io",
    "policy","rbac.authorization.k8s.io","scheduling.k8s.io","storage.k8s.io",
    "kustomize.config.k8s.io",
}

missing = set()
for path in files:
    with path.open() as f:
        for doc in yaml.safe_load_all(f):
            if not isinstance(doc, dict):
                continue
            api = str(doc.get("apiVersion", ""))
            kind = str(doc.get("kind", "")).strip().lower()
            if "/" not in api or not kind:
                continue
            group, version = api.split("/", 1)
            if group in builtin:
                continue
            rel = f"{group}/{kind}_{version}.json"
            if not (pinned / rel).is_file():
                missing.add(rel)

for rel in sorted(missing):
    print(rel)
PY
)

if [[ ${#missing_relpaths[@]} -eq 0 ]]; then
  echo "No missing schema files remain after file inspection."
  rm -f "$tmp_output"
  exit 0
fi

declare -A group_source=()

group_source[cert-manager.io]=cert-manager
group_source[secrets.infisical.com]=infisical
group_source[gateway.networking.k8s.io]=traefik
group_source[source.toolkit.fluxcd.io]=flux2
group_source[helm.toolkit.fluxcd.io]=flux2
group_source[kustomize.toolkit.fluxcd.io]=flux2
group_source[notification.toolkit.fluxcd.io]=flux2
group_source[image.toolkit.fluxcd.io]=flux2

declare -A source_repo_name=()
declare -A source_repo_url=()
declare -A source_chart=()
declare -A source_version=()
declare -A source_extra_args=()

source_repo_name[cert-manager]=jetstack
source_repo_url[cert-manager]=https://charts.jetstack.io
source_chart[cert-manager]=jetstack/cert-manager
source_version[cert-manager]=1.20.0
source_extra_args[cert-manager]='--set crds.enabled=true'

source_repo_name[infisical]=infisical-helm-charts
source_repo_url[infisical]=https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
source_chart[infisical]=infisical-helm-charts/secrets-operator
source_version[infisical]=0.10.29
source_extra_args[infisical]=''

source_repo_name[traefik]=traefik
source_repo_url[traefik]=https://traefik.github.io/charts
source_chart[traefik]=traefik/traefik
source_version[traefik]=39.0.0
source_extra_args[traefik]=''

source_repo_name[flux2]=fluxcd-community
source_repo_url[flux2]=https://fluxcd-community.github.io/helm-charts
source_chart[flux2]=fluxcd-community/flux2
source_version[flux2]=2.18.2
source_extra_args[flux2]=''

needed_sources=()
unmapped=()
for rel in "${missing_relpaths[@]}"; do
  group="${rel%%/*}"
  src="${group_source[$group]:-}"
  if [[ -z "$src" ]]; then
    unmapped+=("$rel")
    continue
  fi
  needed_sources+=("$src")
done

if [[ ${#unmapped[@]} -gt 0 ]]; then
  echo "Error: missing schema groups without Helm source mapping:" >&2
  printf '%s\n' "${unmapped[@]}" | sed 's/^/  - /' >&2
  rm -f "$tmp_output"
  exit 1
fi

mapfile -t needed_sources < <(printf '%s\n' "${needed_sources[@]}" | sort -u)

echo "Missing schemas detected: ${#missing_relpaths[@]}"
printf '%s\n' "${missing_relpaths[@]}" | sed 's/^/  - /'

echo "Preparing Helm repos..."
for src in "${needed_sources[@]}"; do
  repo_name="${source_repo_name[$src]}"
  repo_url="${source_repo_url[$src]}"
  helm repo add "$repo_name" "$repo_url" >/dev/null 2>&1 || true
done
helm repo update >/dev/null

tmp_work="$(mktemp -d)"
trap 'rm -rf "$tmp_work" "$tmp_output"' EXIT

for src in "${needed_sources[@]}"; do
  chart="${source_chart[$src]}"
  version="${source_version[$src]}"
  extra_args="${source_extra_args[$src]}"
  rendered="$tmp_work/${src}.crds.yaml"

  echo "Generating CRDs from chart: $chart@$version"
  # shellcheck disable=SC2086
  helm template "$src" "$chart" --version "$version" --include-crds $extra_args > "$rendered"

  out_dir="$tmp_work/out-$src"
  mkdir -p "$out_dir"
  (
    cd "$out_dir"
    FILENAME_FORMAT="{fullgroup}__{kind}_{version}" python3 "$CONVERTER" "$rendered" >/dev/null
  )

  while IFS= read -r -d '' generated; do
    base="$(basename "$generated")"
    if [[ "$base" != *__* ]]; then
      continue
    fi
    group="${base%%__*}"
    rest="${base#*__}"
    mkdir -p "$PINNED_SCHEMA_DIR/$group"
    cp "$generated" "$PINNED_SCHEMA_DIR/$group/$rest"
  done < <(find "$out_dir" -type f -name '*.json' -print0)
done

echo "Pinned schemas updated at: $PINNED_SCHEMA_DIR"
