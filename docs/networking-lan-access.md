# Networking and LAN Access

This runbook documents the simplest way to expose OpenWebUI on host port 8080 when Minikube runs with the Docker driver.

## Endpoints

- Internal cluster LLM API: `http://llm-active.llm.svc.cluster.local/v1`
- LAN OpenWebUI ingress: `http://openwebui.local:8080`

For LAN clients, map `openwebui.local` to the Kubernetes host LAN IP.

## Fresh setup (repeatable)

### 0. Start a direct port-forward on 8080

Run this on the Kubernetes node. It forwards host port 8080 directly to the OpenWebUI service in the cluster:

```bash
kubectl -n openwebui port-forward --address 0.0.0.0 svc/openwebui-service 8080:8080
```

Keep that command running. If you close it, the port-forward stops.

To verify it is working on the node:

```bash
curl -i http://127.0.0.1:8080/
```

### 1. Ensure OpenWebUI service exists

```bash
kubectl apply -f deploymentFiles/openwebui-deployment.yaml
kubectl get svc -n openwebui openwebui-service
```

## Validation

### From Kubernetes host

```bash
curl -i http://127.0.0.1:8080/
```

### From another LAN machine

```bash
curl -i http://openwebui.local:8080/
```

If that does not respond, the port-forward is not running on the Kubernetes node or `openwebui.local` is not pointing at that node's LAN IP.
