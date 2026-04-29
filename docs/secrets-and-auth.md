# Secrets and Auth

The stack requires two secrets in namespace `llm`:
- `hf-token` with key `HF_TOKEN` (for model pulls)
- `llm-api-key` with key `API_KEY` (for OpenAI-compatible auth)

## Create namespaces

```bash
kubectl create namespace llm
kubectl create namespace openwebui
```

## Create Hugging Face token

1. Sign in at https://huggingface.co
2. Open Settings -> Access Tokens
3. Create token with at least Read permission
4. Copy token value (starts with `hf_`)

## Set HF_TOKEN secret

```bash
kubectl create secret generic hf-token --from-literal=HF_TOKEN=<your-hf-token> -n llm
```

Update if it already exists:

```bash
kubectl create secret generic hf-token --from-literal=HF_TOKEN=<your-hf-token> -n llm --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get secret hf-token -n llm
```

## Choose API_KEY

Generate a strong random value:

```bash
openssl rand -hex 32
```

Set secret:

```bash
kubectl create secret generic llm-api-key --from-literal=API_KEY=<your-api-key> -n llm
```

Update if it already exists:

```bash
kubectl create secret generic llm-api-key --from-literal=API_KEY=<your-api-key> -n llm --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get secret llm-api-key -n llm
```

## Rotate secrets

After updating either secret, restart active model deployments:

```bash
kubectl rollout restart deployment -n llm -l app.kubernetes.io/part-of=localllm-model
```
