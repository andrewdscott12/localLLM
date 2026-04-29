# Deploy and Switch Models

## Script behavior

`doDeployment.sh` manages one active model at a time.

It will:
- validate required prerequisites and secrets
- remove old model resources
- apply the selected model manifest
- apply shared manifests (`nvidia-time-slicing.yaml`, `llm-ingress.yaml`, OpenWebUI)
- wait for rollout completion

## Supported model commands

```bash
./doDeployment.sh Qwen3-Coder-8B
./doDeployment.sh DeepSeek-Coder
./doDeployment.sh Codestral-22B
```

## Safe mode

Use lower memory/concurrency profile:

```bash
./doDeployment.sh --safe DeepSeek-Coder
```

## Check-only mode

Validate without changing resources:

```bash
./doDeployment.sh --check-only DeepSeek-Coder
./doDeployment.sh --safe --check-only Qwen3-Coder-8B
```

## Configure OpenWebUI

1. Open OpenWebUI
2. Go to Admin Settings -> Connections
3. Add OpenAI-compatible connection with:
   - URL: `http://llm-active.llm.svc.cluster.local/v1`
   - Bearer token: value of `API_KEY` from secret `llm-api-key`
4. Verify and save

Important: use the internal cluster URL above in OpenWebUI.
