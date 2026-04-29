# LocalLLM Multi-Model Stack

Local Kubernetes LLM stack for DGX Spark using:
- vLLM for OpenAI-compatible inference
- OpenWebUI for chat UI
- Minikube + nginx ingress for routing
- One active model at a time via `doDeployment.sh`

## Table of Contents

- [Quick Start](#quick-start)
- [Model Switch Commands](#model-switch-commands)
- [Client Endpoints](#client-endpoints)
- [Documentation Index](#documentation-index)

## Quick Start

1. Install prerequisites and start Minikube:
   - See [docs/setup-minikube.md](docs/setup-minikube.md)
2. Create namespaces + secrets (`HF_TOKEN`, `API_KEY`):
   - See [docs/secrets-and-auth.md](docs/secrets-and-auth.md)
3. Validate prerequisites without deploying:

```bash
./doDeployment.sh --check-only DeepSeek-Coder
```

4. Deploy a model:

```bash
./doDeployment.sh --safe Qwen3-Coder-8B
```

5. Configure OpenWebUI connection:
   - URL: `http://llm-active.llm.svc.cluster.local/v1`
   - Bearer token: your `API_KEY`
   - Full steps: [docs/deploy-and-switch-models.md](docs/deploy-and-switch-models.md)

[Back to top](#table-of-contents)

## Model Switch Commands

```bash
./doDeployment.sh Qwen3-Coder-8B
./doDeployment.sh DeepSeek-Coder
./doDeployment.sh Codestral-22B
./doDeployment.sh --safe DeepSeek-Coder
./doDeployment.sh --check-only DeepSeek-Coder
./doDeployment.sh --safe --check-only Qwen3-Coder-8B
```

[Back to top](#table-of-contents)

## Client Endpoints

- Internal cluster endpoint (OpenWebUI): `http://llm-active.llm.svc.cluster.local/v1`
- LAN/client endpoint (Roo, external tools): `http://llm.local/v1`

If using LAN clients, map `llm.local` to your DGX LAN IP in your host file.

[Back to top](#table-of-contents)

## Documentation Index

- Setup and Minikube bootstrap: [docs/setup-minikube.md](docs/setup-minikube.md)
- Secrets and auth (`HF_TOKEN`, `API_KEY`): [docs/secrets-and-auth.md](docs/secrets-and-auth.md)
- Deploying, switching, and OpenWebUI setup: [docs/deploy-and-switch-models.md](docs/deploy-and-switch-models.md)
- Roo plugin and Claude Code configuration: [docs/roo-and-claude-code.md](docs/roo-and-claude-code.md)
- Networking and LAN port 8080 forwarding: [docs/networking-lan-access.md](docs/networking-lan-access.md)
- Tuning profiles and model defaults: [docs/model-tuning.md](docs/model-tuning.md)
- Troubleshooting checks and common errors: [docs/troubleshooting.md](docs/troubleshooting.md)

[Back to top](#table-of-contents)
