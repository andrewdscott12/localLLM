# Networking and LAN Access

## Internal vs external endpoints

- Internal (inside cluster): `http://llm-active.llm.svc.cluster.local/v1`
- External (LAN clients): `http://llm.local/v1`

Ingress routes `llm.local/v1/...` to the active model service.

## OpenWebUI on LAN port 8080 (Minikube in Docker)

If Minikube runs in Docker and you need host port 8080 forwarded to ingress NodePort:

```bash
sudo nft add rule ip nat PREROUTING tcp dport 8080 dnat to 192.168.49.2:32043
sudo nft insert rule ip filter DOCKER ip daddr 192.168.49.2 iifname != "br-0f1fae97cfb7" oifname "br-0f1fae97cfb7" tcp dport 32043 counter accept
sudo nft list ruleset > /etc/nftables.conf
sudo systemctl enable nftables
```

Adjust bridge interface or Minikube IP if they differ in your environment.
