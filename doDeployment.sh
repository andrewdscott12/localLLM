#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--safe] [--roo] [--check-only] <model>

Optional environment overrides:
  MAX_MODEL_LEN_OVERRIDE=16384
  GPU_MEMORY_UTILIZATION_OVERRIDE=0.82
  MAX_NUM_SEQS_OVERRIDE=1

Models:
  Qwen2.5-Coder-7B
  DeepSeek-Coder
  Codestral-22B
  GPT-OSS-20B

Examples:
  $(basename "$0") DeepSeek-Coder
  $(basename "$0") Qwen2.5-Coder-7B
  $(basename "$0") --safe Codestral-22B
  $(basename "$0") --roo Qwen2.5-Coder-7B
  $(basename "$0") --check-only DeepSeek-Coder
  $(basename "$0") --safe --check-only Qwen2.5-Coder-7B
  $(basename "$0") GPT-OSS-20B
  MAX_MODEL_LEN_OVERRIDE=16384 MAX_NUM_SEQS_OVERRIDE=1 $(basename "$0") Qwen2.5-Coder-7B
EOF
}

SAFE_MODE=false
ROO_MODE=false
CHECK_ONLY=false

ROO_MAX_MODEL_LEN="16384"
ROO_MAX_NUM_SEQS="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --safe)
      SAFE_MODE=true
      shift
      ;;
    --roo)
      ROO_MODE=true
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
ROO_MEMORY_WARNING=""

case "$MODEL" in
  Qwen2.5-Coder-7B)
    MODEL_MANIFEST="$ROOT_DIR/model-qwen2-5-coder-7b.yaml"
    MODEL_DEPLOYMENT="llm-qwen2-5-coder-7b"
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
    ROO_MEMORY_WARNING="DeepSeek-Coder with a 16K Roo context may need more unified memory headroom than usual. If startup slows, requests fail, or the pod restarts, redeploy with a lower MAX_MODEL_LEN_OVERRIDE or lower GPU_MEMORY_UTILIZATION_OVERRIDE."
    ;;
  Codestral-22B)
    MODEL_MANIFEST="$ROOT_DIR/model-codestral-22b.yaml"
    MODEL_DEPLOYMENT="llm-codestral-22b"
    SAFE_GPU_MEMORY_UTILIZATION="0.74"
    SAFE_MAX_MODEL_LEN="1536"
    SAFE_MAX_NUM_SEQS="1"
    ROO_MEMORY_WARNING="Codestral-22B is likely to feel memory pressure with a 16K Roo context on a single-GPU Spark. Expect slower startup or possible OOM unless you reduce context or GPU memory utilization."
    ;;
  GPT-OSS-20B)
    MODEL_MANIFEST="$ROOT_DIR/model-gpt-oss-20b.yaml"
    MODEL_DEPLOYMENT="llm-gpt-oss-20b"
    SAFE_GPU_MEMORY_UTILIZATION="0.74"
    SAFE_MAX_MODEL_LEN="2048"
    SAFE_MAX_NUM_SEQS="1"
    ROO_MEMORY_WARNING="GPT-OSS-20B at a 16K Roo context may run close to the memory edge on this hardware. If rollout stalls or throughput collapses, try a smaller context or lower GPU memory utilization."
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
Roo mode: $ROO_MODE
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
kubectl delete deployment -n llm qwen-coder llm-qwen2-5-coder-7b llm-deepseek-coder-v3-moe llm-codestral-22b llm-gpt-oss-20b --ignore-not-found=true
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

if [[ "$ROO_MODE" == "true" ]]; then
  PATCH_MAX_MODEL_LEN="$ROO_MAX_MODEL_LEN"
  PATCH_MAX_NUM_SEQS="$ROO_MAX_NUM_SEQS"
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
Roo mode: $ROO_MODE
Check-only: $CHECK_ONLY
Active model service: llm-active.llm.svc.cluster.local
OpenWebUI model endpoint URL: http://llm-active.llm.svc.cluster.local/v1

If model pull is slow on first startup, check logs:
  kubectl logs -n llm deployment/$MODEL_DEPLOYMENT -f

Note: DeepSeek-Coder-V3-MoE and Codestral-22B are large and may run slowly or fail to load on single-GPU systems.
EOF

if [[ "$ROO_MODE" == "true" && -n "$ROO_MEMORY_WARNING" ]]; then
  cat <<EOF

Roo warning:
$ROO_MEMORY_WARNING
EOF
fi
