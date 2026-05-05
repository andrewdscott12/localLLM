# Networking and LAN Access

This runbook documents a repeatable way to expose OpenWebUI on host LAN port 8080 when Minikube runs with the Docker driver.

## Endpoints

- Internal cluster LLM API: `http://llm-active.llm.svc.cluster.local/v1`
- LAN LLM API ingress: `http://llm.local/v1`
- LAN OpenWebUI ingress: `http://openwebui.local:8080`

For LAN clients, map `llm.local`, `openwebui.local`, and `image.local` to the Kubernetes host LAN IP.

## Fresh setup (repeatable)

### 1. Capture a pre-change firewall snapshot

Run this once on a fresh machine before adding LocalLLM-specific forwarding:

```bash
sudo nft list ruleset | sudo tee /etc/nftables.pre-localllm.conf >/dev/null
```

### 2. Collect runtime values

```bash
LAN_IF="enP7s7"
MINIKUBE_IP="$(minikube ip)"
INGRESS_HTTP_NODEPORT="$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')"
MINIKUBE_BRIDGE="$(docker network inspect minikube -f '{{ index .Options "com.docker.network.bridge.name" }}')"

echo "LAN_IF=$LAN_IF"
echo "MINIKUBE_IP=$MINIKUBE_IP"
echo "INGRESS_HTTP_NODEPORT=$INGRESS_HTTP_NODEPORT"
echo "MINIKUBE_BRIDGE=$MINIKUBE_BRIDGE"
```

Expected today: `INGRESS_HTTP_NODEPORT=32043`.

### 3. Ensure OpenWebUI ingress exists

```bash
kubectl apply -f deploymentFiles/openwebui-deployment.yaml
kubectl apply -f deploymentFiles/openwebui-ingress.yaml
kubectl get ingress -n openwebui openwebui-ingress
```

### 4. Add OpenWebUI forwarding rules

Use comments so rules are easy to find/remove later.

```bash
sudo nft add rule ip nat PREROUTING iifname "$LAN_IF" tcp dport 8080 dnat to "$MINIKUBE_IP:$INGRESS_HTTP_NODEPORT" comment "localllm-openwebui-8080"

sudo nft add rule ip filter DOCKER-USER iifname "$LAN_IF" oifname "$MINIKUBE_BRIDGE" ip daddr "$MINIKUBE_IP" tcp dport "$INGRESS_HTTP_NODEPORT" accept comment "localllm-openwebui-fwd"

sudo nft add rule ip filter DOCKER-USER iifname "$MINIKUBE_BRIDGE" oifname "$LAN_IF" ct state established,related accept comment "localllm-openwebui-return"
```

### 5. Persist rules

```bash
sudo nft list ruleset | sudo tee /etc/nftables.conf >/dev/null
sudo systemctl enable nftables
sudo systemctl restart nftables
```

## Validation

### From Kubernetes host

```bash
curl -i -H "Host: openwebui.local" "http://$(minikube ip):$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')/"
```

### From another LAN machine

```bash
curl -i http://openwebui.local:8080/
curl -i http://<K8S_HOST_LAN_IP>:8080/
```

### Counter checks during a failed/successful attempt

```bash
sudo nft list chain ip nat PREROUTING
sudo nft list chain ip filter DOCKER-USER
```

If the 8080 DNAT counter does not increase, traffic is not reaching this host/interface.

## Restore to stock (pre-LocalLLM) and re-apply cleanly

### Option A (preferred): restore saved snapshot

```bash
sudo nft -f /etc/nftables.pre-localllm.conf
sudo nft list ruleset | sudo tee /etc/nftables.conf >/dev/null
sudo systemctl restart nftables
```

Then re-run the Fresh setup section.

### Option B: remove only LocalLLM rules by comment

```bash
sudo nft -a list chain ip nat PREROUTING
sudo nft -a list chain ip filter DOCKER-USER
```

Delete handles for rules containing these comments:

- `localllm-openwebui-8080`
- `localllm-openwebui-fwd`
- `localllm-openwebui-return`

Example:

```bash
sudo nft delete rule ip nat PREROUTING handle <HANDLE>
sudo nft delete rule ip filter DOCKER-USER handle <HANDLE>
```

Persist after cleanup:

```bash
sudo nft list ruleset | sudo tee /etc/nftables.conf >/dev/null
sudo systemctl restart nftables
```

## Notes

- `table ip nat` and parts of `table ip filter` are Docker-managed. Manual rules can be duplicated by repeated applies. Prefer rule comments and handle-based cleanup.
- `sudo nft -c -f <file>` only validates syntax. It does not apply rules. Use `sudo nft -f <file>` to apply.
