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
deepseek-ai/deepseek-coder-33b-instruct
stabilityai/stable-diffusion-3.5-large-tensorrt
```

## Generate Missing Model Manifests

Use `genModelDeployment.sh` to create manifests for new entries in `modellist.txt`.

```bash
./genModelDeployment.sh
```

Behavior:
- Reads `modellist.txt`
- Creates `deploymentFiles/model-*.yaml` only for entries that do not already exist
- Skips entries already present in an existing manifest
- Keeps existing manifests unchanged

## Script behavior

`doDeployment.sh` manages one active model at a time.

It will:
- validate required prerequisites and secrets
- remove old model resources
- apply the selected model manifest
- apply shared manifests from `deploymentFiles/` (`nvidia-time-slicing.yaml`, `llm-ingress.yaml`, OpenWebUI)
- wait for rollout completion

## Supported model commands

```bash
./doDeployment.sh Qwen/Qwen2.5-Coder-7B-Instruct
./doDeployment.sh Qwen/Qwen2.5-14B-Instruct
./doDeployment.sh deepseek-ai/deepseek-coder-33b-instruct
./doDeployment.sh stabilityai/stable-diffusion-3.5-large-tensorrt
```

## Safe mode

Use lower memory/concurrency profile:

```bash
./doDeployment.sh --safe Qwen/Qwen2.5-14B-Instruct
```

## Check-only mode

Validate without changing resources:

```bash
./doDeployment.sh --check-only deepseek-ai/deepseek-coder-33b-instruct
./doDeployment.sh --safe --check-only Qwen/Qwen2.5-Coder-7B-Instruct
```

## Stable Diffusion 3.5 Large TensorRT Deployment

`deploymentFiles/stable-diffusion-3-5-tensorrt.yaml` is mapped to model id `stabilityai/stable-diffusion-3.5-large-tensorrt` and can be deployed through `doDeployment.sh` like other entries in `modellist.txt`.

This deployment path is intentionally different from vLLM model manifests:

- Uses custom image `localllm/sd35-trt:latest` built from `sd35-trt.dockerfile`
- Runs TensorRT OSS diffusion scripts via `sd35-trt-server.py`
- Exposes image generation APIs, not chat-completion APIs
- Performs first-run ONNX download and TensorRT engine build on the shared PVC
- Ignores vLLM patch overrides in `doDeployment.sh` (`gpu-memory-utilization`, `max-model-len`, `max-num-seqs`)

Build the service image from the repo root:

```bash
docker build -f sd35-trt.dockerfile -t localllm/sd35-trt:latest .
```

Load it into Minikube and deploy the service:

```bash
minikube image load localllm/sd35-trt:latest
./doDeployment.sh stabilityai/stable-diffusion-3.5-large-tensorrt
```

Behavior:
- Uses secret `hf-token` for `HF_TOKEN`
- Stores downloaded ONNX assets and TensorRT engines on the shared `llm-model-cache` PVC under `/data/sd35`
- Exposes HTTP generation endpoints at `http://image.local/generate` and `http://image.local/v1/images/generations`
- First request is expected to be slow while engines are downloaded and built

Example request:

```bash
curl -s http://image.local/generate \
   -H "Content-Type: application/json" \
   -d '{
      "prompt": "a cinematic photo of a rainy neon alley",
      "height": 1024,
      "width": 1024,
      "denoising_steps": 30,
      "guidance_scale": 3.5
   }'
```

OpenAI-compatible image request:

```bash
curl -s http://image.local/v1/images/generations \
   -H "Content-Type: application/json" \
   -d '{
      "model": "sd35-large-tensorrt",
      "prompt": "a cinematic photo of a rainy neon alley",
      "size": "1024x1024",
      "response_format": "b64_json",
      "denoising_steps": 30,
      "guidance_scale": 3.5
   }'
```

You can switch precision in `deploymentFiles/stable-diffusion-3-5-tensorrt.yaml` by changing `SD35_PRECISION` from `bf16` to `fp8` if your GPU and TensorRT stack support it.

## Configure OpenWebUI

1. Open OpenWebUI
2. Go to Admin Settings -> Connections
3. Add OpenAI-compatible connection with:
   - URL: `http://llm-active.llm.svc.cluster.local/v1`
   - Bearer token: value of `API_KEY` from secret `llm-api-key`
4. Verify and save

Important: use the internal cluster URL above in OpenWebUI.

For image generation in OpenWebUI using this model runtime:

1. Add a second OpenAI-compatible connection
2. Set Base URL to `http://image.local/v1`
3. Use any non-empty API key value if required by the UI
4. Select image model id `sd35-large-tensorrt`

## Configure Claude Code (Anthropic-compatible via LiteLLM)

`doDeployment.sh` now deploys a LiteLLM proxy service that translates Anthropic-style requests to your active OpenAI-compatible vLLM model.

Important model-routing nuance:

- `llm-active` points to one active backend model deployment at a time.
- Claude Code must send that same model id (exact case/spelling).
- If Claude sends a different model name, vLLM returns `404 The model <name> does not exist` even when pods are healthy.

Before setting `claude-code.model`, check the currently served id:

```bash
curl -s http://llm.local/v1/models -H "Authorization: Bearer <your-api-key>" | jq -r '.data[].id'
```

Use one of the returned ids exactly as `claude-code.model`.

Use these values in Claude Code:

- `ANTHROPIC_BASE_URL`: `http://llm.local/anthropic`
- `ANTHROPIC_AUTH_TOKEN`: value of `API_KEY` from secret `llm-api-key`

Example VS Code settings snippet:

```json
"claude-code.environmentVariables": [
   {
      "name": "ANTHROPIC_BASE_URL",
      "value": "http://llm.local/anthropic"
   },
   {
      "name": "ANTHROPIC_AUTH_TOKEN",
      "value": "<your-api-key>"
   }
],
"claude-code.model": "<exact-id-from-/v1/models>",
"claude-code.disableLoginPrompt": true
```

If the extension keeps using a stale model after settings changes, reload the VS Code window and start a new Claude session.
