#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELLIST_FILE="$ROOT_DIR/modellist.txt"
DEPLOYMENT_DIR="$ROOT_DIR/deploymentFiles"

if [[ ! -f "$MODELLIST_FILE" ]]; then
  echo "Model list not found: $MODELLIST_FILE"
  exit 1
fi

mkdir -p "$DEPLOYMENT_DIR"

slugify() {
  local input="$1"

  input="${input,,}"
  input="${input//\//-}"
  input="${input//./-}"
  input="${input//_/-}"
  input="${input// /-}"
  input="$(echo "$input" | sed -E 's/[^a-z0-9-]//g; s/-+/-/g; s/^-+//; s/-+$//')"

  echo "$input"
}

find_existing_manifest_for_model() {
  local model="$1"

  while IFS= read -r file_path; do
    if grep -Fq -- "--model=$model" "$file_path"; then
      echo "$file_path"
      return 0
    fi
  done < <(find "$DEPLOYMENT_DIR" -maxdepth 1 -type f -name "model-*.yaml" | sort)

  return 1
}

created=0
skipped=0

while IFS= read -r raw_line; do
  model="$(echo "$raw_line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

  if [[ -z "$model" || "${model:0:1}" == "#" ]]; then
    continue
  fi

  slug="$(slugify "$model")"
  if [[ -z "$slug" ]]; then
    echo "Skipping invalid model entry: $model"
    skipped=$((skipped + 1))
    continue
  fi

  if existing_manifest="$(find_existing_manifest_for_model "$model")"; then
    echo "Skipping existing model entry ($model) found in $(basename "$existing_manifest")"
    skipped=$((skipped + 1))
    continue
  fi

  manifest_file="$DEPLOYMENT_DIR/model-$slug.yaml"
  deployment_name="llm-$slug"
  served_name="${model##*/}"

  if [[ -f "$manifest_file" ]]; then
    echo "Skipping existing manifest: $(basename "$manifest_file")"
    skipped=$((skipped + 1))
    continue
  fi

  cat > "$manifest_file" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deployment_name
  namespace: llm
  labels:
    app.kubernetes.io/part-of: localllm-model
    app.kubernetes.io/name: $deployment_name
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: $deployment_name
  template:
    metadata:
      labels:
        app: $deployment_name
        app.kubernetes.io/part-of: localllm-model
    spec:
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        args:
          - "--model=$model"
          - "--served-model-name=$served_name"
          - "--host=0.0.0.0"
          - "--port=8000"
          - "--gpu-memory-utilization=0.78"
          - "--max-model-len=32768"
          - "--max-num-seqs=2"
          - "--enable-auto-tool-choice"
          - "--tool-call-parser"
          - "openai"
          - "--enable-prefix-caching"
          - "--enable-chunked-prefill"
          - "--dtype"
          - "bfloat16"
        ports:
          - containerPort: 8000
        resources:
          limits:
            nvidia.com/gpu: 1
        env:
          - name: VLLM_API_KEY
            valueFrom:
              secretKeyRef:
                name: llm-api-key
                key: API_KEY
          - name: HUGGING_FACE_HUB_TOKEN
            valueFrom:
              secretKeyRef:
                name: hf-token
                key: HF_TOKEN
          - name: HF_HOME
            value: "/data/hf"
          - name: HUGGINGFACE_HUB_CACHE
            value: "/data/hf/hub"
          - name: TRANSFORMERS_CACHE
            value: "/data/hf/transformers"
          - name: OMP_NUM_THREADS
            value: "8"
          - name: OMP_SCHEDULE
            value: "dynamic"
        volumeMounts:
          - name: hf-cache
            mountPath: /data/hf
      volumes:
        - name: hf-cache
          persistentVolumeClaim:
            claimName: llm-model-cache
---
apiVersion: v1
kind: Service
metadata:
  name: llm-active
  namespace: llm
  labels:
    app.kubernetes.io/part-of: localllm-model
spec:
  selector:
    app: $deployment_name
  ports:
    - port: 80
      targetPort: 8000
EOF

  echo "Created $(basename "$manifest_file") for $model"
  created=$((created + 1))
done < "$MODELLIST_FILE"

echo
echo "Generation complete."
echo "Created: $created"
echo "Skipped: $skipped"
