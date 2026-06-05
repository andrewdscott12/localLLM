# Roo Plugin and Claude Code Setup

## Shared endpoint and auth

All active models are exposed via one OpenAI-compatible endpoint:

- Base URL: `http://llm.local/v1`
- API key: `API_KEY` from secret `llm-api-key`

Anthropic-compatible clients (Claude Code) should use the LiteLLM translation path:

- Base URL: `http://llm.local/anthropic`
- Auth token: `API_KEY` from secret `llm-api-key`

Critical model alignment rule:

- LiteLLM can present multiple model aliases, but `llm-active` still forwards to one live vLLM model at a time.
- The model Claude requests must exist on the currently active vLLM backend.
- If not, requests fail with `404 The model <name> does not exist`.

Always check active model ids before choosing a Claude model:

```bash
curl -s http://llm.local/v1/models -H "Authorization: Bearer <your-api-key>" | jq -r '.data[].id'
```

If your client runs on a different machine, map `llm.local` to your DGX LAN IP in hosts.

## Tested model limitations

Current practical status from local testing:

- `Qwen/Qwen2.5-Coder-7B-Instruct`
	- Good plain chat and coding quality
	- Roo and Claude can fall into tool-loop or malformed tool-response behavior
- `google/gemma-4-E4B-it`
	- Fast for chat
	- Tool-use compatibility has not been reliable enough for agent workflows
- `google/gemma-4-31B-it`
    - **Preferred model for Claude Code in this repo**
    - Deployment now works with Claude tool-use flow when `claude-code.model` matches the active served id
    - Use served model id `gemma-4-31B-it` (case-sensitive)
- `deepseek-ai/deepseek-coder-33b-instruct`
	- Not yet tested for agentic use
	- Uses `hermes` tool call parser; tool use compatibility unconfirmed
    - Using a conservative 32K context profile for better stability
- `Qwen/Qwen3-Coder-30B-A3B-Instruct`
    - **Recommended model for Roo agentic use.** Demonstrated reliable file read/write and command execution.
    - Streaming format validated: clean `delta.tool_calls`, no thinking tokens, correct `finish_reason: tool_calls`.
    - **Claude Code: tool calls hallucinated.** The model emits well-formed tool call JSON for simple prompts, but under Claude Code's full multi-tool system prompt it falls back to describing actions in natural language instead of calling tools (e.g. `/debug` reports "created debug_log_analysis.md" but no file is written). This is a fine-tuning gap — the model does not reliably follow Claude Code's bespoke tool schema at 30B scale.

Recommendation:

- Prefer `google/gemma-4-31B-it` for Claude Code
- Prefer Roo with `Qwen/Qwen3-Coder-30B-A3B-Instruct` for local agentic workflows

## Roo plugin
The roo plugin does not behave well with local models and smallish context windows. YMMV here.  
1. Open Roo model/provider settings
2. Select OpenAI-compatible mode
3. Set base URL: `http://llm.local/v1`
4. Set API key: your `API_KEY`
5. Set model ID from list above
6. Save and run connection test

## Claude Code terminal app

**Claude is very picky. Models must have particular capabilities or it spits garbage**

As of this writing, the preferred deployment for Claude Code is `google/gemma-4-31B-it` (served id `gemma-4-31B-it`).

If your Claude Code build supports OpenAI-compatible backends, set:

```bash
export ANTHROPIC_BASE_URL=http://llm.local/anthropic
export ANTHROPIC_AUTH_TOKEN=<your-api-key>
export CLAUDE_CODE_CONTEXT_WINDOW_SIZE=32000
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75
```

Launch claude with:
```
claude --model <modelname>
```

Use an exact id returned from `/v1/models` (case-sensitive).

If your Claude setup supports `settings.json`, use values equivalent to:

```json
{
	"env": {
        "ANTHROPIC_BASE_URL": "http://llm.local/anthropic",
		"ANTHROPIC_AUTH_TOKEN": "<your-api-key>",
		"CLAUDE_CODE_CONTEXT_WINDOW_SIZE": "32768",
		"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "75"
	},
    "model": "gemma-4-31B-it"
}
```

For using the VSCode plugin, you need to open the vscode settings.json (File->Preferences->Settings, then click the icon in the upper right for the JSON version) and add this block:

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
Modify the BASE_URL and Token to match your deployment.  

If Claude continues to send an older model name, reload the VS Code window and start a new chat/session.

If your Claude Code build is Anthropic-only, use Roo/OpenWebUI for local models or place a gateway in front to translate requests.

## Sanity check

```bash
curl -s http://llm.local/v1/models -H "Authorization: Bearer <your-api-key>"
```
