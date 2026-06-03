#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELLIST_FILE="$ROOT_DIR/modellist.txt"
DEPLOYMENT_DIR="$ROOT_DIR/deploymentFiles"
IMAGE_MODEL_ID="stabilityai/stable-diffusion-3.5-large-tensorrt"
IMAGE_COMPANION_MODEL_ID="meta-llama/Llama-3.2-3B-Instruct"

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
  done < <(find "$DEPLOYMENT_DIR" -maxdepth 1 -type f -name "model-*.yaml" | sort)

  if [[ "$match_count" -gt 1 ]]; then
    echo "Multiple manifests match model $model. Keep only one deploymentFiles/model-*.yaml with this --model value." >&2
    return 2
  fi

  if [[ "$match_count" -eq 1 ]]; then
    echo "$manifest"
    return 0
  fi

  while IFS= read -r file_path; do
    if grep -Fq -- "app.kubernetes.io/model-id: $model" "$file_path" || \
      grep -Fq -- "app.kubernetes.io/model-id: \"$model\"" "$file_path" || \
      grep -Fq -- "app.kubernetes.io/model-id-full: $model" "$file_path" || \
      grep -Fq -- "app.kubernetes.io/model-id-full: \"$model\"" "$file_path"; then
      manifest="$file_path"
      match_count=$((match_count + 1))
    fi
  done < <(find "$DEPLOYMENT_DIR" -maxdepth 1 -type f -name "*.yaml" | sort)

  if [[ "$match_count" -gt 1 ]]; then
    echo "Multiple manifests match model $model by app.kubernetes.io/model-id or app.kubernetes.io/model-id-full." >&2
    return 2
  fi

  if [[ "$match_count" -eq 1 ]]; then
    echo "$manifest"
    return 0
  fi

  return 1
}

manifest_kind() {
  local manifest="$1"

  if grep -Fq -- "app.kubernetes.io/part-of: localllm-image" "$manifest"; then
    echo "image"
  else
    echo "llm"
  fi
}

manifest_is_vllm() {
  local manifest="$1"
  grep -Fq -- "image: vllm/vllm-openai" "$manifest"
}

get_deployment_name_from_manifest() {
  local manifest="$1"

  awk '
    /^kind:[[:space:]]*Deployment$/ { in_deployment=1; next }
    in_deployment && /^metadata:/ { in_metadata=1; next }
    in_deployment && in_metadata && /^  name:/ { print $2; exit }
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
  COMPANION_GPU_MEMORY_UTILIZATION_OVERRIDE=0.35
  COMPANION_MAX_MODEL_LEN_OVERRIDE=8192
  COMPANION_MAX_NUM_SEQS_OVERRIDE=1

Models are read from:
  $MODELLIST_FILE

Examples:
  $(basename "$0") Qwen/Qwen2.5-Coder-7B-Instruct
  $(basename "$0") Qwen/Qwen2.5-14B-Instruct
  $(basename "$0") $IMAGE_MODEL_ID
  $(basename "$0") --safe deepseek-ai/deepseek-coder-33b-instruct
  $(basename "$0") --check-only deepseek-ai/deepseek-coder-33b-instruct
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
COMPANION_MODEL=""
COMPANION_MANIFEST=""
COMPANION_DEPLOYMENT=""

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
MODEL_KIND="llm"
MODEL_IS_VLLM="false"
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

if [[ ! -d "$DEPLOYMENT_DIR" ]]; then
  echo "Deployment manifest directory not found: $DEPLOYMENT_DIR"
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

if [[ "$MODEL" == "$IMAGE_MODEL_ID" ]]; then
  COMPANION_MODEL="$IMAGE_COMPANION_MODEL_ID"

  if ! is_model_listed "$COMPANION_MODEL"; then
    echo "Image model requires companion chat model to be listed: $COMPANION_MODEL"
    echo "Add it to $MODELLIST_FILE and generate manifests with ./genModelDeployment.sh"
    exit 1
  fi

  if ! COMPANION_MANIFEST="$(find_manifest_for_model "$COMPANION_MODEL")"; then
    lookup_status=$?
    if [[ "$lookup_status" -eq 2 ]]; then
      exit 1
    fi

    echo "No deployment manifest found for companion chat model: $COMPANION_MODEL"
    echo "Run ./genModelDeployment.sh to generate missing model manifests."
    exit 1
  fi

  COMPANION_DEPLOYMENT="$(get_deployment_name_from_manifest "$COMPANION_MANIFEST")"
  if [[ -z "$COMPANION_DEPLOYMENT" ]]; then
    echo "Failed to determine deployment name from companion manifest: $COMPANION_MANIFEST"
    exit 1
  fi
fi

MODEL_DEPLOYMENT="$(get_deployment_name_from_manifest "$MODEL_MANIFEST")"
if [[ -z "$MODEL_DEPLOYMENT" ]]; then
  echo "Failed to determine deployment name from manifest: $MODEL_MANIFEST"
  exit 1
fi

MODEL_KIND="$(manifest_kind "$MODEL_MANIFEST")"
if manifest_is_vllm "$MODEL_MANIFEST"; then
  MODEL_IS_VLLM="true"
fi

if [[ ! -f "$MODEL_MANIFEST" ]]; then
  echo "Model manifest not found: $MODEL_MANIFEST"
  exit 1
fi

for required_file in \
  "$MODELLIST_FILE" \
  "$DEPLOYMENT_DIR/llm-model-cache-pvc.yaml" \
  "$DEPLOYMENT_DIR/nvidia-time-slicing.yaml" \
  "$DEPLOYMENT_DIR/llm-ingress.yaml" \
  "$DEPLOYMENT_DIR/litellm-proxy.yaml" \
  "$DEPLOYMENT_DIR/litellm-anthropic-ingress.yaml" \
  "$DEPLOYMENT_DIR/openwebui-deployment.yaml" \
  "$DEPLOYMENT_DIR/openwebui-ingress.yaml"; do
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

apply_timeslicing_config() {
  echo "Applying NVIDIA GPU time-slicing config map..."
  kubectl apply -f "$DEPLOYMENT_DIR/nvidia-time-slicing.yaml"

  echo "Setting GPU Operator device plugin to use time-slicing config..."
  kubectl patch clusterpolicy cluster-policy --type='merge' -p '{"spec":{"devicePlugin":{"config":{"name":"nvidia-device-plugin-config","default":"default"}}}}'

  echo "Restarting NVIDIA device plugin daemonset..."
  kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator >/dev/null 2>&1 || true
  kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n gpu-operator --timeout=5m >/dev/null 2>&1 || true
}

restart_ingress_controller() {
  # Prefer the standard ingress-nginx deployment names and restart whichever exists.
  local restarted="false"

  if kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
    echo "Restarting ingress controller: deployment/ingress-nginx-controller (namespace ingress-nginx)..."
    kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
    kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=5m
    restarted="true"
  fi

  if kubectl get deployment nginx-ingress-controller -n ingress-nginx >/dev/null 2>&1; then
    echo "Restarting ingress controller: deployment/nginx-ingress-controller (namespace ingress-nginx)..."
    kubectl rollout restart deployment/nginx-ingress-controller -n ingress-nginx
    kubectl rollout status deployment/nginx-ingress-controller -n ingress-nginx --timeout=5m
    restarted="true"
  fi

  if [[ "$restarted" != "true" ]]; then
    echo "No ingress controller deployment found in namespace ingress-nginx. Skipping ingress controller restart."
  fi
}

patch_vllm_deployment() {
  local deployment_name="$1"
  local gpu_mem="$2"
  local max_model_len="$3"
  local max_num_seqs="$4"

  local patch_ops=()

  if [[ -n "$gpu_mem" ]]; then
    patch_ops+=("{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/4\",\"value\":\"--gpu-memory-utilization=$gpu_mem\"}")
  fi

  if [[ -n "$max_model_len" ]]; then
    patch_ops+=("{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/5\",\"value\":\"--max-model-len=$max_model_len\"}")
  fi

  if [[ -n "$max_num_seqs" ]]; then
    patch_ops+=("{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/6\",\"value\":\"--max-num-seqs=$max_num_seqs\"}")
  fi

  if [[ "${#patch_ops[@]}" -eq 0 ]]; then
    return 0
  fi

  echo "Applying vLLM overrides to deployment/$deployment_name..."
  kubectl patch deployment "$deployment_name" -n llm --type='json' -p="[$(IFS=,; echo "${patch_ops[*]}")]"
}

disable_vllm_tool_calling() {
  local deployment_name="$1"
  local model_id="$2"
  local served_name="${model_id##*/}"
  local gpu_mem="${COMPANION_GPU_MEMORY_UTILIZATION_OVERRIDE:-0.35}"
  local max_model_len="${COMPANION_MAX_MODEL_LEN_OVERRIDE:-8192}"
  local max_num_seqs="${COMPANION_MAX_NUM_SEQS_OVERRIDE:-1}"
  local kv_cache_dtype="${COMPANION_KV_CACHE_DTYPE_OVERRIDE:-fp8}"

  echo "Disabling vLLM tool-calling flags for deployment/$deployment_name..."
  kubectl patch deployment "$deployment_name" -n llm --type='json' -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[
      \"--model=$model_id\",
      \"--served-model-name=$served_name\",
      \"--host=0.0.0.0\",
      \"--port=8000\",
      \"--gpu-memory-utilization=$gpu_mem\",
      \"--max-model-len=$max_model_len\",
      \"--max-num-seqs=$max_num_seqs\",
      \"--enable-prefix-caching\",
      \"--enable-chunked-prefill\",
      "--enforce-eager",
      \"--dtype\",
      \"bfloat16\",
      \"--kv-cache-dtype=$kv_cache_dtype\"
    ]}
  ]"
}

gpu_operator_installed() {
  kubectl get deployment gpu-operator -n gpu-operator >/dev/null 2>&1
}

ensure_gpu_operator() {
  if gpu_operator_installed; then
    echo "GPU Operator is already installed."
    return 0
  fi

  if ! command -v helm >/dev/null 2>&1; then
    echo "GPU Operator is not installed and helm is not available to install it."
    echo "Install helm, then rerun deployment."
    exit 1
  fi

  echo "GPU Operator not found. Installing with Helm..."

  if ! helm repo list | awk 'NR > 1 { print $1 }' | grep -Fxq nvidia; then
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
  fi

  helm repo update nvidia

  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    --wait \
    --timeout 20m \
    --set driver.enabled=false \
    --set toolkit.enabled=false

  kubectl rollout status deployment/gpu-operator -n gpu-operator --timeout=10m
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

  if gpu_operator_installed; then
    gpu_operator_status="installed"
  else
    gpu_operator_status="missing (will be installed during deployment)"
    if ! command -v helm >/dev/null 2>&1; then
      echo "GPU Operator is missing and helm is not installed."
      exit 1
    fi
  fi

  cat <<EOF

Check passed.

Selected model: $MODEL
Companion chat model: ${COMPANION_MODEL:-none}
Safe mode: $SAFE_MODE
Check-only: $CHECK_ONLY
GPU Operator: $gpu_operator_status
Model manifest: $MODEL_MANIFEST
EOF
  exit 0
fi

echo "Ensuring namespaces exist..."
kubectl create namespace llm --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace openwebui --dry-run=client -o yaml | kubectl apply -f -

ensure_gpu_operator

echo "Validating required secrets..."
require_secret_key llm hf-token HF_TOKEN
require_secret_key llm llm-api-key API_KEY

echo "Applying persistent model cache volume..."
kubectl apply -f "$DEPLOYMENT_DIR/llm-model-cache-pvc.yaml"

echo "Removing currently deployed model resources..."
kubectl delete deployment,service -n llm -l app.kubernetes.io/part-of=localllm-model --ignore-not-found=true
kubectl delete deployment,service -n llm -l app.kubernetes.io/part-of=localllm-image --ignore-not-found=true
kubectl delete service -n llm qwen-coder llm-active --ignore-not-found=true
kubectl delete service -n llm t2i-active --ignore-not-found=true

echo "Applying selected model: $MODEL"
kubectl apply -f "$MODEL_MANIFEST"

if [[ -n "$COMPANION_MODEL" ]]; then
  echo "Applying companion chat model: $COMPANION_MODEL"
  kubectl apply -f "$COMPANION_MANIFEST"
  disable_vllm_tool_calling "$COMPANION_DEPLOYMENT" "$COMPANION_MODEL"
fi

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

if [[ ( -n "$PATCH_GPU_MEMORY_UTILIZATION" || -n "$PATCH_MAX_MODEL_LEN" || -n "$PATCH_MAX_NUM_SEQS" ) && "$MODEL_IS_VLLM" == "true" ]]; then
  patch_vllm_deployment "$MODEL_DEPLOYMENT" "$PATCH_GPU_MEMORY_UTILIZATION" "$PATCH_MAX_MODEL_LEN" "$PATCH_MAX_NUM_SEQS"
elif [[ -n "$PATCH_GPU_MEMORY_UTILIZATION" || -n "$PATCH_MAX_MODEL_LEN" || -n "$PATCH_MAX_NUM_SEQS" ]]; then
  echo "Deployment overrides were requested, but selected manifest is not vLLM. Skipping override patch."
fi

if [[ -n "$COMPANION_DEPLOYMENT" ]]; then
  # Companion chat model should stay small when sharing one GB10 with image generation.
  companion_gpu_mem="${COMPANION_GPU_MEMORY_UTILIZATION_OVERRIDE:-0.35}"
  companion_max_model_len="${COMPANION_MAX_MODEL_LEN_OVERRIDE:-8192}"
  companion_max_num_seqs="${COMPANION_MAX_NUM_SEQS_OVERRIDE:-1}"
  patch_vllm_deployment "$COMPANION_DEPLOYMENT" "$companion_gpu_mem" "$companion_max_model_len" "$companion_max_num_seqs"
fi

echo "Applying shared ingress and OpenWebUI resources..."
apply_timeslicing_config
kubectl apply -f "$DEPLOYMENT_DIR/llm-ingress.yaml"
kubectl apply -f "$DEPLOYMENT_DIR/litellm-proxy.yaml"
kubectl apply -f "$DEPLOYMENT_DIR/litellm-anthropic-ingress.yaml"
kubectl apply -f "$DEPLOYMENT_DIR/openwebui-deployment.yaml"
kubectl apply -f "$DEPLOYMENT_DIR/openwebui-ingress.yaml"
restart_ingress_controller

echo "Waiting for model rollout..."
kubectl rollout status deployment/"$MODEL_DEPLOYMENT" -n llm --timeout=20m

if [[ -n "$COMPANION_DEPLOYMENT" ]]; then
  echo "Waiting for companion chat rollout..."
  kubectl rollout status deployment/"$COMPANION_DEPLOYMENT" -n llm --timeout=20m
fi

echo "Waiting for LiteLLM proxy rollout..."
kubectl rollout status deployment/litellm-proxy -n llm --timeout=10m

echo "Waiting for OpenWebUI rollout..."
kubectl rollout status deployment/openwebui-deployment -n openwebui --timeout=10m

cat <<EOF

Deployment complete.

Selected model: $MODEL
Companion chat model: ${COMPANION_MODEL:-none}
Model kind: $MODEL_KIND
Safe mode: $SAFE_MODE
Check-only: $CHECK_ONLY
Active model service: llm-active.llm.svc.cluster.local
Image generation service: t2i-active.llm.svc.cluster.local
OpenWebUI model endpoint URL: http://llm-active.llm.svc.cluster.local/v1
Anthropic-compatible proxy URL: http://llm.local/anthropic
Image endpoint URL: http://image.local/v1/images/generations

If model pull is slow on first startup, check logs:
  kubectl logs -n llm deployment/$MODEL_DEPLOYMENT -f

To update to a different model, run this script again with the new model name. It will remove the old deployment and create a new one.
EOF
