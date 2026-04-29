# Troubleshooting

## Quick checks

```bash
kubectl get pods -n llm
kubectl get pods -n openwebui
kubectl get ingress -A
kubectl logs -n llm -l app.kubernetes.io/part-of=localllm-model -f
kubectl logs -n openwebui -l app=openwebui -f
```

## Check deployment prerequisites without changes

```bash
./doDeployment.sh --check-only DeepSeek-Coder
```

## Missing HF token or API key

Ensure required secrets exist in namespace `llm`:
- `hf-token` key `HF_TOKEN`
- `llm-api-key` key `API_KEY`

## OpenWebUI verifies but model does not show

- Ensure OpenWebUI URL is internal: `http://llm-active.llm.svc.cluster.local/v1`
- Refresh connection and model list after switching models
- Confirm `/v1/models` output:

```bash
curl -s http://llm.local/v1/models -H "Authorization: Bearer <your-api-key>"
```

## DeepSeek gibberish output

Use instruct model profile (`DeepSeek-Coder`) rather than base checkpoints.
