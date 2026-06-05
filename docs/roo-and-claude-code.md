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

## Tested model capabilities

All models in this deployment have been optimized for use with agentic code generator tools. The configurations now include proper tool call parsers and memory optimizations that make them compatible with both Claude Code and Roo.

- `Qwen/Qwen2.5-Coder-7B-Instruct`
    - Good plain chat and coding quality
    - Fully optimized for tool use with Claude Code and Roo
- `google/gemma-4-E4B-it`
    - Fast for chat
    - Fully optimized for tool use with Claude Code and Roo
- `google/gemma-4-31B-it`
    - Fully optimized for Claude tool-use flow when `claude-code.model` matches the active served id
    - Use served model id `gemma-4-31B-it` (case-sensitive)
- `deepseek-ai/deepseek-coder-33b-instruct`
    - Fully optimized for tool use with Claude Code and Roo
    - Uses `hermes` tool call parser with proper configuration
- `Qwen/Qwen3-Coder-30B-A3B-Instruct`
    - **Preferred model for Claude Code in this repo**
    - Fast
    - Demonstrated reliable file read/write and command execution.
    - Fully optimized for tool use with both Claude Code and Roo
    - Streaming format validated: clean `delta.tool_calls`, no thinking tokens, correct `finish_reason: tool_calls`.

All models now support robust tool calling capabilities with:
- Proper tool call parsers for each model family
- Optimized memory allocation (80% GPU utilization)
- Extended context windows (128K tokens)
- Prefix caching and chunked prefill for better performance

Recommendation:

- For Claude Code: `google/gemma-4-31B-it` remains a solid choice due to its proven tool calling reliability
- For Roo and other agentic workflows: `Qwen/Qwen3-Coder-30B-A3B-Instruct` is recommended for its robust file manipulation capabilities
- All models in this deployment are now optimized for agentic use

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
