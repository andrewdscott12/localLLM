#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELLIST_FILE="$ROOT_DIR/modellist.txt"

list_available_models() {
  awk '
    {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || substr(line, 1, 1) == "#") {
        next
      }
      print line
    }
  ' "$MODELLIST_FILE"
}

is_model_listed() {
  local model="$1"

  awk -v model="$model" '
    {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || substr(line, 1, 1) == "#") {
        next
      }
      if (line == model) {
        found=1
      }
    }
    END {
      if (found) {
        exit 0
      }
      exit 1
    }
  ' "$MODELLIST_FILE"
}

find_manifest_for_model() {
  local model="$1"
  local manifest=""
  local match_count=0

  while IFS= read -r file_path; do
    if grep -Fq -- "--model=$model" "$file_path"; then
      manifest="$file_path"
      match_count=$((match_count + 1))
    fi
  done < <(find "$ROOT_DIR" -maxdepth 1 -type f -name "model-*.yaml" | sort)

  if [[ "$match_count" -gt 1 ]]; then
    echo "Multiple manifests match model $model. Keep only one model-*.yaml with this --model value." >&2
    return 2
  fi

  if [[ "$match_count" -eq 1 ]]; then
    echo "$manifest"
    return 0
  fi

  return 1
}

get_deployment_name_from_manifest() {
  local manifest="$1"

  awk '
    /^metadata:/ { in_metadata=1; next }
    in_metadata && /^  name:/ { print $2; exit }
  ' "$manifest"
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--safe] [--check-only] <model>

Optional environment overrides:
  MAX_MODEL_LEN_OVERRIDE=32768
  GPU_MEMORY_UTILIZATION_OVERRIDE=0.82
  MAX_NUM_SEQS_OVERRIDE=1

Models are read from:
  $MODELLIST_FILE

Examples:
  $(basename "$0") Qwen/Qwen2.5-Coder-7B-Instruct
  $(basename "$0") Qwen/Qwen2.5-14B-Instruct
  $(basename "$0") --safe mistralai/Codestral-22B-v0.1
  $(basename "$0") --check-only mistralai/Codestral-22B-v0.1
  $(basename "$0") --safe --check-only Qwen/Qwen2.5-Coder-7B-Instruct
  MAX_MODEL_LEN_OVERRIDE=32768 MAX_NUM_SEQS_OVERRIDE=1 $(basename "$0") Qwen/Qwen2.5-Coder-7B-Instruct
EOF

  if [[ -f "$MODELLIST_FILE" ]]; then
    echo
    echo "Available models:"
    while IFS= read -r model_line; do
      echo "  $model_line"
    done < <(list_available_models)
  fi
}

SAFE_MODE=false
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --safe)
      SAFE_MODE=true
      shift
      ;;
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

MODEL="$1"
MODEL_MANIFEST=""
MODEL_DEPLOYMENT=""
SAFE_GPU_MEMORY_UTILIZATION="0.74"
SAFE_MAX_MODEL_LEN="32768"
SAFE_MAX_NUM_SEQS="1"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not installed or not in PATH"
  exit 1
fi

if [[ ! -f "$MODELLIST_FILE" ]]; then
  echo "Model list not found: $MODELLIST_FILE"
  echo "Create it with one Hugging Face model path per line."
  exit 1
fi

if ! is_model_listed "$MODEL"; then
  echo "Model is not listed in $MODELLIST_FILE: $MODEL"
  usage
  exit 1
fi

if ! MODEL_MANIFEST="$(find_manifest_for_model "$MODEL")"; then
  lookup_status=$?
  if [[ "$lookup_status" -eq 2 ]]; then
    exit 1
  fi

  echo "No deployment manifest found for model: $MODEL"
  echo "Run ./genModelDeployment.sh to generate missing model manifests."
  exit 1
fi

MODEL_DEPLOYMENT="$(get_deployment_name_from_manifest "$MODEL_MANIFEST")"
if [[ -z "$MODEL_DEPLOYMENT" ]]; then
  echo "Failed to determine deployment name from manifest: $MODEL_MANIFEST"
  exit 1
fi

if [[ ! -f "$MODEL_MANIFEST" ]]; then
  echo "Model manifest not found: $MODEL_MANIFEST"
  exit 1
fi

for required_file in \
  "$MODELLIST_FILE" \
  "$ROOT_DIR/llm-model-cache-pvc.yaml" \
  "$ROOT_DIR/nvidia-time-slicing.yaml" \
  "$ROOT_DIR/llm-ingress.yaml" \
  "$ROOT_DIR/openwebui-deployment.yaml" \
  "$ROOT_DIR/openwebui-ingress.yaml"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Required file not found: $required_file"
    exit 1
  fi
done

require_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  local value_b64=""

  if ! value_b64="$(kubectl get secret "$secret_name" -n "$namespace" -o "jsonpath={.data.$key_name}" 2>/dev/null)"; then
    echo "Missing required secret: $secret_name in namespace $namespace"
    echo "Create it before running deployment."
    exit 1
  fi

  if [[ -z "$value_b64" ]]; then
    echo "Secret $secret_name exists, but key $key_name is missing or empty"
    exit 1
  fi
}

require_namespace() {
  local namespace="$1"
  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    echo "Required namespace missing: $namespace"
    exit 1
  fi
}

echo "Checking cluster connectivity..."
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "Cannot reach Kubernetes cluster with current kubectl context"
  exit 1
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  echo "Check-only mode: validating prerequisites without applying changes..."
  require_namespace llm
  require_namespace openwebui
  require_secret_key llm hf-token HF_TOKEN
  require_secret_key llm llm-api-key API_KEY

  cat <<EOF

Check passed.

Selected model: $MODEL
Safe mode: $SAFE_MODE
Check-only: $CHECK_ONLY
Model manifest: $MODEL_MANIFEST
EOF
  exit 0
fi

echo "Ensuring namespaces exist..."
kubectl create namespace llm --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace openwebui --dry-run=client -o yaml | kubectl apply -f -

echo "Validating required secrets..."
require_secret_key llm hf-token HF_TOKEN
require_secret_key llm llm-api-key API_KEY

echo "Applying persistent model cache volume..."
kubectl apply -f "$ROOT_DIR/llm-model-cache-pvc.yaml"

echo "Removing currently deployed model resources..."
kubectl delete deployment,service -n llm -l app.kubernetes.io/part-of=localllm-model --ignore-not-found=true
kubectl delete service -n llm qwen-coder llm-active --ignore-not-found=true

echo "Applying selected model: $MODEL"
kubectl apply -f "$MODEL_MANIFEST"

PATCH_GPU_MEMORY_UTILIZATION=""
PATCH_MAX_MODEL_LEN=""
PATCH_MAX_NUM_SEQS=""

if [[ "$SAFE_MODE" == "true" ]]; then
  PATCH_GPU_MEMORY_UTILIZATION="$SAFE_GPU_MEMORY_UTILIZATION"
  PATCH_MAX_MODEL_LEN="$SAFE_MAX_MODEL_LEN"
  PATCH_MAX_NUM_SEQS="$SAFE_MAX_NUM_SEQS"
fi

if [[ -n "${GPU_MEMORY_UTILIZATION_OVERRIDE:-}" ]]; then
  PATCH_GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION_OVERRIDE"
fi

if [[ -n "${MAX_MODEL_LEN_OVERRIDE:-}" ]]; then
  PATCH_MAX_MODEL_LEN="$MAX_MODEL_LEN_OVERRIDE"
fi

if [[ -n "${MAX_NUM_SEQS_OVERRIDE:-}" ]]; then
  PATCH_MAX_NUM_SEQS="$MAX_NUM_SEQS_OVERRIDE"
fi

if [[ -n "$PATCH_GPU_MEMORY_UTILIZATION" || -n "$PATCH_MAX_MODEL_LEN" || -n "$PATCH_MAX_NUM_SEQS" ]]; then
  patch_ops=()

  if [[ -n "$PATCH_GPU_MEMORY_UTILIZATION" ]]; then
    patch_ops+=("{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/4\",\"value\":\"--gpu-memory-utilization=$PATCH_GPU_MEMORY_UTILIZATION\"}")
  fi

  if [[ -n "$PATCH_MAX_MODEL_LEN" ]]; then
    patch_ops+=("{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/5\",\"value\":\"--max-model-len=$PATCH_MAX_MODEL_LEN\"}")
  fi

  if [[ -n "$PATCH_MAX_NUM_SEQS" ]]; then
    patch_ops+=("{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/6\",\"value\":\"--max-num-seqs=$PATCH_MAX_NUM_SEQS\"}")
  fi

  echo "Applying deployment overrides..."
  kubectl patch deployment "$MODEL_DEPLOYMENT" -n llm --type='json' -p="[$(IFS=,; echo "${patch_ops[*]}")]"
fi

echo "Applying shared ingress and OpenWebUI resources..."
kubectl apply -f "$ROOT_DIR/nvidia-time-slicing.yaml"
kubectl apply -f "$ROOT_DIR/llm-ingress.yaml"
kubectl apply -f "$ROOT_DIR/openwebui-deployment.yaml"
kubectl apply -f "$ROOT_DIR/openwebui-ingress.yaml"

echo "Waiting for model rollout..."
kubectl rollout status deployment/"$MODEL_DEPLOYMENT" -n llm --timeout=20m

echo "Waiting for OpenWebUI rollout..."
kubectl rollout status deployment/openwebui-deployment -n openwebui --timeout=10m

cat <<EOF

Deployment complete.

Selected model: $MODEL
Safe mode: $SAFE_MODE
Check-only: $CHECK_ONLY
Active model service: llm-active.llm.svc.cluster.local
OpenWebUI model endpoint URL: http://llm-active.llm.svc.cluster.local/v1

If model pull is slow on first startup, check logs:
  kubectl logs -n llm deployment/$MODEL_DEPLOYMENT -f

Note: Codestral-22B is large and may run slowly or fail to load on single-GPU systems.
EOF
