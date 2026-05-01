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

`deploymentFiles/stable-diffusion-3-5-tensorrt.yaml` is separate from the vLLM model-switching flow. It deploys a custom image generation service built from NVIDIA's TensorRT OSS Stable Diffusion 3.5 demo.

Build the service image from the repo root:

```bash
docker build -f sd35-trt.dockerfile -t localllm/sd35-trt:latest .
```

Load it into Minikube and deploy the service:

```bash
minikube image load localllm/sd35-trt:latest
kubectl apply -f deploymentFiles/stable-diffusion-3-5-tensorrt.yaml
kubectl rollout status deployment/t2i-stable-diffusion-3-5-large-tensorrt -n llm --timeout=20m
```

Behavior:
- Uses secret `hf-token` for `HF_TOKEN`
- Stores downloaded ONNX assets and TensorRT engines on the shared `llm-model-cache` PVC under `/data/sd35`
- Exposes HTTP generation endpoint at `http://image.local/generate`
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

You can switch precision in `deploymentFiles/stable-diffusion-3-5-tensorrt.yaml` by changing `SD35_PRECISION` from `bf16` to `fp8` if your GPU and TensorRT stack support it.

## Configure OpenWebUI

1. Open OpenWebUI
2. Go to Admin Settings -> Connections
3. Add OpenAI-compatible connection with:
   - URL: `http://llm-active.llm.svc.cluster.local/v1`
   - Bearer token: value of `API_KEY` from secret `llm-api-key`
4. Verify and save

Important: use the internal cluster URL above in OpenWebUI.
