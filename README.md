# LocalLLM Multi-Model Stack

Local Kubernetes inference stack for DGX Spark using:
- vLLM for OpenAI-compatible inference
- TensorRT OSS demo runtime for Stable Diffusion 3.5 text-to-image
- OpenWebUI for chat UI
- Minikube + nginx ingress for routing
- One active model at a time via `doDeployment.sh`

Usage of these models as chat endpoints seems to work well. Use of these with agentic tools like Claude or Roo is proving problematic. YMMV and if you figure it out, let me know.

## Table of Contents

- [Quick Start](#quick-start)
- [Model Switch Commands](#model-switch-commands)
- [Image Generation](#image-generation)
- [Client Endpoints](#client-endpoints)
- [Documentation Index](#documentation-index)

## Quick Start

1. Install prerequisites and start Minikube:
   - See [docs/setup-minikube.md](docs/setup-minikube.md)
2. Create namespaces + secrets (`HF_TOKEN`, `API_KEY`):
   - See [docs/secrets-and-auth.md](docs/secrets-and-auth.md)
3. Validate prerequisites without deploying:

```bash
./doDeployment.sh --check-only Qwen/Qwen2.5-14B-Instruct
```

4. Deploy a model:

```bash
./doDeployment.sh --safe Qwen/Qwen2.5-Coder-7B-Instruct
```

Model choices are sourced from `modellist.txt`.

When you add a new model path to `modellist.txt`, generate missing deployment manifests with:

```bash
./genModelDeployment.sh
```

5. Configure OpenWebUI connection:
   - URL: `http://llm-active.llm.svc.cluster.local/v1`
   - Bearer token: your `API_KEY`
   - Full steps: [docs/deploy-and-switch-models.md](docs/deploy-and-switch-models.md)

[Back to top](#table-of-contents)

## Model Switch Commands

```bash
./doDeployment.sh Qwen/Qwen2.5-Coder-7B-Instruct
./doDeployment.sh deepseek-ai/deepseek-coder-33b-instruct
./doDeployment.sh stabilityai/stable-diffusion-3.5-large-tensorrt
./doDeployment.sh --safe Qwen/Qwen2.5-14B-Instruct
./doDeployment.sh --check-only deepseek-ai/deepseek-coder-33b-instruct
./doDeployment.sh --safe --check-only Qwen/Qwen2.5-Coder-7B-Instruct
```

[Back to top](#table-of-contents)

## Image Generation

Stable Diffusion 3.5 Large is deployed separately from the vLLM model-switching flow. It uses NVIDIA's TensorRT OSS diffusion demo inside a custom image.

How this differs from vLLM model deployments:

- Runtime is TensorRT OSS diffusion scripts, not `vllm/vllm-openai`
- You must build and load a custom image first (`localllm/sd35-trt:latest`)
- First generation is much slower than later runs because ONNX and TensorRT engines are built on demand
- API surface is image-focused (`/v1/images/generations` and `/generate`) instead of chat completions
- vLLM-safe overrides in `doDeployment.sh` (`--safe`, max model len, seq count patches) do not apply to this image runtime

Build the image from the repo root:

```bash
docker build -f sd35-trt.dockerfile -t localllm/sd35-trt:latest .
```

Load it into Minikube and deploy via `doDeployment.sh`:

```bash
minikube image load localllm/sd35-trt:latest
./doDeployment.sh stabilityai/stable-diffusion-3.5-large-tensorrt
```

When deploying the SD3.5 image model, the script also deploys a companion chat model (`meta-llama/Llama-3.2-3B-Instruct`) so OpenWebUI has a conversational model available alongside image generation.

The first request will be slow because ONNX assets and TensorRT engines are downloaded and built under `/data/sd35` on the shared PVC.

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

### Connecting OpenWebUI to the Image Generator

OpenWebUI supports image generation backends via **Settings → Images**. This service does **not** require a bearer token — the server has no auth middleware. Use these values:

| Field | Value |
|---|---|
| **Image Generation Engine** | OpenAI |
| **Base URL** | `http://image.local/v1` (LAN) or `http://sd35-svc.llm.svc.cluster.local/v1` (in-cluster) |
| **API Key** | any non-empty string (e.g. `none`) — the server ignores it |
| **Image Generation Model** | `sd35-large-tensorrt` |
| **Image Size** | `1024x1024` |

> **This is separate from the LLM connection.** The LLM connection (Settings → Connections) uses `http://llm-active.llm.svc.cluster.local/v1` with your actual `API_KEY` bearer token. The image connection uses a different URL, a different settings page, and no real auth.

After saving, an image icon will appear in the OpenWebUI chat input bar. Click it to toggle image generation mode.

[Back to top](#table-of-contents)

## Client Endpoints

- Internal cluster endpoint (OpenWebUI): `http://llm-active.llm.svc.cluster.local/v1`
- LAN/client endpoint (Roo, external tools): `http://llm.local/v1`
- LAN OpenWebUI endpoint: `http://openwebui.local:8080`
- LAN image endpoint (native): `http://image.local/generate`
- LAN image endpoint (OpenAI-compatible): `http://image.local/v1/images/generations`

If using LAN clients, map `llm.local`, `openwebui.local`, and `image.local` to your DGX LAN IP in your host file.

[Back to top](#table-of-contents)

## Documentation Index

- Setup and Minikube bootstrap: [docs/setup-minikube.md](docs/setup-minikube.md)
- Secrets and auth (`HF_TOKEN`, `API_KEY`): [docs/secrets-and-auth.md](docs/secrets-and-auth.md)
- Deploying, switching, and OpenWebUI setup: [docs/deploy-and-switch-models.md](docs/deploy-and-switch-models.md)
- Stable Diffusion 3.5 TensorRT service assets: [sd35-trt.dockerfile](sd35-trt.dockerfile), [sd35-trt-server.py](sd35-trt-server.py), [deploymentFiles/stable-diffusion-3-5-tensorrt.yaml](deploymentFiles/stable-diffusion-3-5-tensorrt.yaml)
- Model list source: [modellist.txt](modellist.txt)
- Model manifest generator: [genModelDeployment.sh](genModelDeployment.sh)
- Roo plugin and Claude Code configuration: [docs/roo-and-claude-code.md](docs/roo-and-claude-code.md)
- Networking and LAN port 8080 forwarding: [docs/networking-lan-access.md](docs/networking-lan-access.md)
- Tuning profiles and model defaults: [docs/model-tuning.md](docs/model-tuning.md)
- Troubleshooting checks and common errors: [docs/troubleshooting.md](docs/troubleshooting.md)

[Back to top](#table-of-contents)
