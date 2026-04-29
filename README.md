# LocalLLM — Kubernetes LLM Stack for NVIDIA DGX Spark

A self-hosted LLM inference and chat stack running on Minikube, purpose-built for the NVIDIA DGX Spark (GB10 GPU, 128 GB unified memory). Provides a [vLLM](https://github.com/vllm-project/vllm) inference backend for Qwen2.5-14B-Instruct and an [Open WebUI](https://github.com/open-webui/open-webui) frontend, exposed on the local network.

---

## File Descriptions

| File | Description |
|---|---|
| `qwen.yaml` | Deployment + Service for the Qwen2.5-14B-Instruct model served via vLLM. Tuned for single-GPU throughput: 90% GPU memory utilization, 8192 token context, prefix caching, chunked prefill, and bfloat16. Reads `llm-api-key` and `hf-token` Secrets from the `llm` namespace. |
| `llm-ingress.yaml` | nginx Ingress in the `llm` namespace. Routes `llm.local/qwen/*` to the Qwen vLLM service with path rewriting. Restricts access to LAN and Minikube subnets. |
| `openwebui-deployment.yaml` | Deployment + Service for Open WebUI in the `openwebui` namespace. Exposes the web UI on port 8080 as a ClusterIP service. Uses `Recreate` rollout strategy to avoid port conflicts on a single-node cluster. |
| `openwebui-ingress.yaml` | nginx Ingress in the `openwebui` namespace. Routes all traffic (`/`) to the OpenWebUI service. Disables proxy buffering and sets long timeouts for streaming responses. |
| `nvidia-time-slicing.yaml` | ConfigMap for the NVIDIA GPU Operator that enables GPU time-slicing with 2 virtual replicas. Allows more than one workload to share the single physical GB10 GPU. |

---

## Prerequisites

- Ubuntu 22.04 / 24.04 (DGX OS)
- NVIDIA GPU Operator already installed in the cluster (for GPU scheduling)
- `curl`, `apt` available

---

## Installation

### 1. Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### 2. Install Minikube

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube version
```

### 3. Start Minikube with Docker driver

```bash
minikube start \
  --driver=docker \
  --cpus=no-limit \
  --memory=no-limit \
  --gpus=all
```

### 4. Enable the nginx Ingress addon

```bash
minikube addons enable ingress
# Wait for the controller to be ready
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx
```

### 5. Create namespaces

```bash
kubectl create namespace llm
kubectl create namespace openwebui
```

### 6. Create required Secrets

```bash
# Hugging Face token (for model download)
kubectl create secret generic hf-token \
  --from-literal=HF_TOKEN=<your-hf-token> \
  -n llm

# vLLM API key (used by OpenWebUI to authenticate)
kubectl create secret generic llm-api-key \
  --from-literal=API_KEY=<your-chosen-api-key> \
  -n llm
```

### 7. Apply the manifests

```bash
kubectl apply -f nvidia-time-slicing.yaml
kubectl apply -f qwen.yaml
kubectl apply -f llm-ingress.yaml
kubectl apply -f openwebui-deployment.yaml
kubectl apply -f openwebui-ingress.yaml
```

### 8. Wait for pods to be ready

```bash
kubectl rollout status deployment/qwen-coder -n llm
kubectl rollout status deployment/openwebui-deployment -n openwebui
```

The Qwen pod will take several minutes on first start while the model downloads from Hugging Face.

---

## Exposing OpenWebUI on LAN port 8080

Minikube runs inside Docker with its own bridge network (`192.168.49.0/24`). The nginx ingress controller NodePort for port 80 is `32043`. To forward LAN traffic on port 8080 through to it, add nftables rules on the DGX host:

```bash
# DNAT inbound :8080 to the Minikube nginx NodePort
sudo nft add rule ip nat PREROUTING tcp dport 8080 dnat to 192.168.49.2:32043

# Allow forwarded traffic through the Docker bridge
sudo nft insert rule ip filter DOCKER \
  ip daddr 192.168.49.2 \
  iifname != "br-0f1fae97cfb7" \
  oifname "br-0f1fae97cfb7" \
  tcp dport 32043 counter accept

# Persist across reboots
sudo nft list ruleset > /etc/nftables.conf
sudo systemctl enable nftables
```

> **Note:** The bridge interface name (`br-0f1fae97cfb7`) may differ on your system. Confirm with `ip link show | grep br-`.

OpenWebUI is then reachable at `http://<dgx-lan-ip>:8080` from any host on the LAN.

---

## Configuring OpenWebUI to use the Qwen model

Once OpenWebUI is running, connect it to the vLLM backend using the **internal Kubernetes DNS name** rather than the LAN IP. Routing through the LAN IP and back into the cluster via nginx is unnecessary and unreliable.

1. Open OpenWebUI at `http://<dgx-lan-ip>:8080`
2. Go to **Settings → Admin Settings → Connections**
3. Under **OpenAI API**, add a new connection:
   - **URL:** `http://qwen-coder.llm.svc.cluster.local/v1`
   - **API Key:** the value you set for `API_KEY` in the `llm-api-key` secret
4. Click **Verify** — the connection should succeed
5. Click **Save**

The Qwen2.5-14B-Instruct model will appear in the model selector dropdown.

---

## Useful Commands

```bash
# Check pod status
kubectl get pods -n llm
kubectl get pods -n openwebui

# Stream vLLM inference logs
kubectl logs -n llm -l app=qwen-coder -f

# Stream OpenWebUI logs
kubectl logs -n openwebui -l app=openwebui -f

# Stream nginx ingress logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f

# Test the vLLM API directly from the DGX host
curl http://192.168.1.157/qwen/v1/models \
  -H "Authorization: Bearer <your-api-key>"
```
