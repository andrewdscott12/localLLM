# Roo Plugin and Claude Code Setup

## Shared endpoint and auth

All active models are exposed via one OpenAI-compatible endpoint:

- Base URL: `http://llm.local/v1`
- API key: `API_KEY` from secret `llm-api-key`

If your client runs on a different machine, map `llm.local` to your DGX LAN IP in hosts.

## Model IDs

- Qwen profile: `Qwen2.5-Coder-7B`
- DeepSeek profile: `DeepSeek-Coder-V2-Lite-Instruct`
- Codestral profile: `Codestral-22B`

## Roo plugin

1. Open Roo model/provider settings
2. Select OpenAI-compatible mode
3. Set base URL: `http://llm.local/v1`
4. Set API key: your `API_KEY`
5. Set model ID from list above
6. Save and run connection test

## Claude Code terminal app

If your Claude Code build supports OpenAI-compatible backends, set:

```bash
export OPENAI_BASE_URL=http://llm.local/v1
export OPENAI_API_KEY=<your-api-key>
export OPENAI_MODEL=Qwen2.5-Coder-7B
```

Switch model by changing `OPENAI_MODEL`.

If your Claude Code build is Anthropic-only, use Roo/OpenWebUI for local models or place a gateway in front to translate requests.

## Sanity check

```bash
curl -s http://llm.local/v1/models -H "Authorization: Bearer <your-api-key>"
```
