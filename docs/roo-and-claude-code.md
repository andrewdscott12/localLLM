# Roo Plugin and Claude Code Setup

## Shared endpoint and auth

All active models are exposed via one OpenAI-compatible endpoint:

- Base URL: `http://llm.local/v1`
- API key: `API_KEY` from secret `llm-api-key`

If your client runs on a different machine, map `llm.local` to your DGX LAN IP in hosts.

## Roo plugin
The roo plugin does not behave well with local models and smallish context windows. YMMV here.  
1. Open Roo model/provider settings
2. Select OpenAI-compatible mode
3. Set base URL: `http://llm.local/v1`
4. Set API key: your `API_KEY`
5. Set model ID from list above
6. Save and run connection test

## Claude Code terminal app

If your Claude Code build supports OpenAI-compatible backends, set:

```bash
export ANTHROPIC_BASE_URL=http://llm.local  # Replace with your local server URL
export ANTHROPIC_AUTH_TOKEN=<token>         # Value doesn't matter for most local servers
export CLAUDE_CODE_CONTEXT_WINDOW_SIZE=32000
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75
```

Launch claude with:
```
claude --model <modelname>
```

For this Llama deployment, use model name:

```bash
claude --model Llama-3.1-8B-Instruct
```

If your Claude setup supports `settings.json`, use values equivalent to:

```json
{
	"env": {
		"ANTHROPIC_BASE_URL": "http://llm.local",
		"ANTHROPIC_AUTH_TOKEN": "<your-api-key>",
		"CLAUDE_CODE_CONTEXT_WINDOW_SIZE": "32768",
		"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "75"
	},
	"model": "Llama-3.1-8B-Instruct"
}
```

The Claude VSCode plugin is hard-wired to the Anthropic authentication infrastructure. This author doesn't have an athropic account, so I could not test it.  

If your Claude Code build is Anthropic-only, use Roo/OpenWebUI for local models or place a gateway in front to translate requests.

## Sanity check

```bash
curl -s http://llm.local/v1/models -H "Authorization: Bearer <your-api-key>"
```
