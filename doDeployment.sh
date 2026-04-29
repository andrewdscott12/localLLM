#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--safe] [--check-only] <model>

Models:
  Qwen3-Coder-8B
  DeepSeek-Coder
  Codestral-22B

Examples:
  $(basename "$0") DeepSeek-Coder
  $(basename "$0") Qwen3-Coder-8B
  $(basename "$0") --safe Codestral-22B
  $(basename "$0") --check-only DeepSeek-Coder
  $(basename "$0") --safe --check-only Qwen3-Coder-8B
EOF
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
SAFE_GPU_MEMORY_UTILIZATION=""
SAFE_MAX_MODEL_LEN=""
SAFE_MAX_NUM_SEQS=""

case "$MODEL" in
  Qwen3-Coder-8B)
    MODEL_MANIFEST="$ROOT_DIR/model-qwen3-coder-8b.yaml"
    MODEL_DEPLOYMENT="llm-qwen3-coder-8b"
    SAFE_GPU_MEMORY_UTILIZATION="0.78"
    SAFE_MAX_MODEL_LEN="3072"
    SAFE_MAX_NUM_SEQS="1"
    ;;
  DeepSeek-Coder)
    MODEL_MANIFEST="$ROOT_DIR/model-deepseek-coder-v3-moe.yaml"
    MODEL_DEPLOYMENT="llm-deepseek-coder-v3-moe"
    SAFE_GPU_MEMORY_UTILIZATION="0.72"
    SAFE_MAX_MODEL_LEN="2048"
    SAFE_MAX_NUM_SEQS="1"
    ;;
  Codestral-22B)
    MODEL_MANIFEST="$ROOT_DIR/model-codestral-22b.yaml"
    MODEL_DEPLOYMENT="llm-codestral-22b"
    SAFE_GPU_MEMORY_UTILIZATION="0.74"
    SAFE_MAX_MODEL_LEN="1536"
    SAFE_MAX_NUM_SEQS="1"
    ;;
  *)
    echo "Unsupported model: $MODEL"
    usage
    exit 1
    ;;
esac

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not installed or not in PATH"
  exit 1
fi

if [[ ! -f "$MODEL_MANIFEST" ]]; then
  echo "Model manifest not found: $MODEL_MANIFEST"
  exit 1
fi

for required_file in \
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

echo "Removing currently deployed model resources..."
kubectl delete deployment,service -n llm -l app.kubernetes.io/part-of=localllm-model --ignore-not-found=true
kubectl delete deployment -n llm qwen-coder llm-qwen3-coder-8b llm-deepseek-coder-v3-moe llm-codestral-22b --ignore-not-found=true
kubectl delete service -n llm qwen-coder llm-active --ignore-not-found=true

echo "Applying selected model: $MODEL"
kubectl apply -f "$MODEL_MANIFEST"

if [[ "$SAFE_MODE" == "true" ]]; then
  echo "Applying safe overrides for constrained unified memory..."
  kubectl patch deployment "$MODEL_DEPLOYMENT" -n llm --type='json' -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/4\",\"value\":\"--gpu-memory-utilization=$SAFE_GPU_MEMORY_UTILIZATION\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/5\",\"value\":\"--max-model-len=$SAFE_MAX_MODEL_LEN\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/6\",\"value\":\"--max-num-seqs=$SAFE_MAX_NUM_SEQS\"}
  ]"
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

Note: DeepSeek-Coder-V3-MoE and Codestral-22B are large and may run slowly or fail to load on single-GPU systems.
EOF
