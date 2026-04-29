# LocalLLM Multi-Model Stack (Minikube + OpenWebUI + vLLM)

This repository runs a local Kubernetes-based coding model stack on DGX Spark:
- OpenWebUI for chat and model selection
- vLLM as the OpenAI-compatible model backend
- Minikube + nginx ingress for cluster and routing
- A model switch script so only one model runs at a time

## Files in this repository

- README.md
  - Setup and operations guide for this stack.

- doDeployment.sh
  - Model switch script.
  - Removes old model deployments/services in namespace llm.
  - Deploys the selected model plus shared ingress/OpenWebUI manifests.

- model-qwen3-coder-8b.yaml
  - Deployment + Service for Qwen3-Coder-8B.
  - Exposes active backend as service llm-active in namespace llm.

- model-deepseek-coder-v3-moe.yaml
  - Deployment + Service for DeepSeek-Coder V3 MoE.
  - Exposes active backend as service llm-active in namespace llm.

- model-codestral-22b.yaml
  - Deployment + Service for Codestral 22B.
  - Exposes active backend as service llm-active in namespace llm.

- llm-ingress.yaml
  - nginx ingress for model API path routing.
  - Routes llm.local/v1/... to service llm-active.

- openwebui-deployment.yaml
  - OpenWebUI Deployment + Service in namespace openwebui.

- openwebui-ingress.yaml
  - nginx ingress for OpenWebUI web traffic.

- nvidia-time-slicing.yaml
  - GPU Operator ConfigMap enabling time slicing.

- qwen.yaml
  - Legacy single-model deployment file from earlier setup.
  - Not used by doDeployment.sh.

## Install kubectl and Minikube (Linux)

1) Install kubectl

curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client

2) Install Minikube

curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube version

3) Start Minikube

minikube start --driver=docker --cpus=no-limit --memory=no-limit --gpus=all

4) Enable nginx ingress

minikube addons enable ingress
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx

## One-time Kubernetes setup

1) Create namespaces

kubectl create namespace llm
kubectl create namespace openwebui

2) Create secrets for llm namespace

kubectl create secret generic hf-token --from-literal=HF_TOKEN=<your-hf-token> -n llm
kubectl create secret generic llm-api-key --from-literal=API_KEY=<your-api-key> -n llm

## Create a Hugging Face token and set HF_TOKEN in Minikube

1) Create a token in Hugging Face

- Sign in at https://huggingface.co
- Open Settings -> Access Tokens
- Create a new token with at least Read permissions
- Copy the token value (starts with `hf_`)

2) Create the Kubernetes secret in Minikube

kubectl create secret generic hf-token --from-literal=HF_TOKEN=<your-hf-token> -n llm

3) If the secret already exists, update it safely

kubectl create secret generic hf-token --from-literal=HF_TOKEN=<your-hf-token> -n llm --dry-run=client -o yaml | kubectl apply -f -

4) Verify the secret exists

kubectl get secret hf-token -n llm

5) Restart the active model deployment to pick up the new token

kubectl rollout restart deployment -n llm -l app.kubernetes.io/part-of=localllm-model

Notes:
- The key name must be exactly HF_TOKEN because model manifests reference that key.
- If downloads still fail, confirm the token has access to the target model repository.

## Choose and set API_KEY for model access

The vLLM backend is protected by a bearer token stored in secret llm-api-key with key name API_KEY.

1) Choose a strong API key value

- Use a long random string.
- Example generation command:

openssl rand -hex 32

2) Create the API key secret

kubectl create secret generic llm-api-key --from-literal=API_KEY=<your-api-key> -n llm

3) If the secret already exists, update it safely

kubectl create secret generic llm-api-key --from-literal=API_KEY=<your-api-key> -n llm --dry-run=client -o yaml | kubectl apply -f -

4) Verify the secret exists

kubectl get secret llm-api-key -n llm

5) Restart active model deployment after key rotation

kubectl rollout restart deployment -n llm -l app.kubernetes.io/part-of=localllm-model

6) Use the same API key in OpenWebUI connection settings

- OpenWebUI -> Admin Settings -> Connections
- For the model endpoint, keep URL as http://llm-active.llm.svc.cluster.local/v1
- Set Bearer token to your API_KEY value

## Deploy and switch models

Use doDeployment.sh with one of the supported model names:

./doDeployment.sh Qwen3-Coder-8B
./doDeployment.sh DeepSeek-Coder
./doDeployment.sh Codestral-22B
./doDeployment.sh --safe DeepSeek-Coder
./doDeployment.sh --check-only DeepSeek-Coder
./doDeployment.sh --safe --check-only Qwen3-Coder-8B

What the script does:
- Deletes model deployments/services not needed for the selected model
- Applies the selected model manifest
- Applies nvidia-time-slicing.yaml
- Applies llm ingress + OpenWebUI deployment + OpenWebUI ingress
- Waits for rollout completion

Check-only mode:
- Add --check-only to validate prerequisites without changing cluster resources.
- Verifies kubectl cluster connectivity, required namespaces, required files, and required secret keys (HF_TOKEN, API_KEY).
- Example: ./doDeployment.sh --check-only DeepSeek-Coder

Safe mode:
- Add --safe to force lower memory/concurrency settings at deploy time.
- Recommended first run on 128 GB unified-memory systems.
- Example: ./doDeployment.sh --safe Codestral-22B
- You can combine with check-only: ./doDeployment.sh --safe --check-only Codestral-22B

## Configure OpenWebUI to use the internal model URL

After OpenWebUI is up:

1) Open OpenWebUI in browser
2) Go to Admin Settings -> Connections
3) Add OpenAI-compatible connection
4) Use:
   - URL: http://llm-active.llm.svc.cluster.local/v1
   - Bearer token: value of API_KEY from secret llm-api-key (namespace llm)
5) Verify and save

Important: use the internal service URL above, not the host LAN IP path for model traffic.

## Default tuning profile

Current manifest defaults are conservative for DGX Spark unified memory:
- Qwen3-Coder-8B: gpu-memory-utilization=0.80, max-model-len=4096, max-num-seqs=2
- DeepSeek-Coder-V3-MoE: gpu-memory-utilization=0.78, max-model-len=2048, max-num-seqs=2
- Codestral-22B: gpu-memory-utilization=0.80, max-model-len=2048, max-num-seqs=2

Use --safe for an even lower profile (single-sequence and lower context) if startup or stability issues occur.

## Optional: expose OpenWebUI on LAN port 8080 (Minikube-in-Docker)

If Minikube runs in Docker and you want host:8080 forwarded to ingress NodePort:

sudo nft add rule ip nat PREROUTING tcp dport 8080 dnat to 192.168.49.2:32043
sudo nft insert rule ip filter DOCKER ip daddr 192.168.49.2 iifname != "br-0f1fae97cfb7" oifname "br-0f1fae97cfb7" tcp dport 32043 counter accept
sudo nft list ruleset > /etc/nftables.conf
sudo systemctl enable nftables

## Useful checks

kubectl get pods -n llm
kubectl get pods -n openwebui
kubectl get ingress -A
kubectl logs -n llm -l app.kubernetes.io/part-of=localllm-model -f
kubectl logs -n openwebui -l app=openwebui -f
