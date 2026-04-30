# Deploy and Switch Models

## Model Source of Truth

`modellist.txt` is the source of truth for available models.

- One Hugging Face model path per line
- Blank lines and lines starting with `#` are ignored
- `doDeployment.sh` only accepts models present in this file

Example:

```txt
Qwen/Qwen2.5-Coder-7B-Instruct
Qwen/Qwen2.5-14B-Instruct
mistralai/Codestral-22B-v0.1
```

## Generate Missing Model Manifests

Use `genModelDeployment.sh` to create manifests for new entries in `modellist.txt`.

```bash
./genModelDeployment.sh
```

Behavior:
- Reads `modellist.txt`
- Creates `model-*.yaml` only for entries that do not already exist
- Skips entries already present in an existing manifest
- Keeps existing manifests unchanged

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
./doDeployment.sh Qwen/Qwen2.5-Coder-7B-Instruct
./doDeployment.sh Qwen/Qwen2.5-14B-Instruct
./doDeployment.sh mistralai/Codestral-22B-v0.1
```

## Safe mode

Use lower memory/concurrency profile:

```bash
./doDeployment.sh --safe Qwen/Qwen2.5-14B-Instruct
```

## Check-only mode

Validate without changing resources:

```bash
./doDeployment.sh --check-only mistralai/Codestral-22B-v0.1
./doDeployment.sh --safe --check-only Qwen/Qwen2.5-Coder-7B-Instruct
```

## Configure OpenWebUI

1. Open OpenWebUI
2. Go to Admin Settings -> Connections
3. Add OpenAI-compatible connection with:
   - URL: `http://llm-active.llm.svc.cluster.local/v1`
   - Bearer token: value of `API_KEY` from secret `llm-api-key`
4. Verify and save

Important: use the internal cluster URL above in OpenWebUI.
