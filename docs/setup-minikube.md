# Setup Minikube and kubectl

## Install kubectl (Linux)

```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

## Install Minikube (Linux)

### For AMD64 architecture
```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube version
```

### For ARM64/aarch64 architecture
```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-arm64
sudo install minikube-linux-arm64 /usr/local/bin/minikube
minikube version
```

## Install Helm (Linux)

`doDeployment.sh` uses Helm to install the NVIDIA GPU Operator automatically if it is not already present.

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## Start Minikube for DGX Spark

```bash
minikube start --driver=docker --cpus=no-limit --memory=no-limit --gpus=all
```

## Enable nginx ingress

```bash
minikube addons enable ingress
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx
```

## GPU Operator

You do not need to install the NVIDIA GPU Operator manually before first deployment.

- `doDeployment.sh` checks whether `gpu-operator` is installed
- If missing, it installs it automatically with Helm
- The script then applies the time-slicing ConfigMap in namespace `gpu-operator`
