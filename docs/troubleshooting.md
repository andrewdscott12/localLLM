# Troubleshooting

## Quick checks

```bash
kubectl get pods -n llm
kubectl get pods -n openwebui
kubectl get ingress -A
kubectl logs -n llm -l app.kubernetes.io/part-of=localllm-model -f
kubectl logs -n llm -l app.kubernetes.io/part-of=localllm-image -f
kubectl logs -n openwebui -l app=openwebui -f
```

## Check deployment prerequisites without changes

```bash
./doDeployment.sh --check-only deepseek-ai/deepseek-coder-33b-instruct
./doDeployment.sh --check-only stabilityai/stable-diffusion-3.5-large-tensorrt
```

## Missing HF token or API key

Ensure required secrets exist in namespace `llm`:
- `hf-token` key `HF_TOKEN`
- `llm-api-key` key `API_KEY`

## OpenWebUI verifies but model does not show

- Ensure OpenWebUI URL is internal: `http://llm-active.llm.svc.cluster.local/v1`
- Refresh connection and model list after switching models
- Confirm `/v1/models` output:

```bash
curl -s http://llm.local/v1/models -H "Authorization: Bearer <your-api-key>"
```

## Image generation request times out on first call

The first SD3.5 request can take a long time while ONNX artifacts are downloaded and TensorRT engines are built.

- Use a larger client timeout (`curl --max-time 1800 ...`)
- Watch image runtime logs:

```bash
kubectl logs -n llm deployment/t2i-stable-diffusion-3-5-large-tensorrt -f
```

- Verify health endpoint responds:

```bash
curl -i http://image.local/healthz
```

If logs show `GatedRepoError` for Stability AI models, ensure your `HF_TOKEN` has access to `stabilityai/stable-diffusion-3.5-large`.

## TensorRT static dimension mismatch (`setInputShape` errors)

The TensorRT engines are compiled for a fixed image resolution. If you see errors like:

```
[E] IExecutionContext::setInputShape: ... Static dimension mismatch ...
    Expected dimensions are [-1,16,64,64]. Set dimensions are [2,16,128,128].
```

The cached engine was built at a different resolution than the current request (e.g. engine built at 512×512, request sent 1024×1024). Delete the engine cache and let it rebuild on the next request:

```bash
kubectl exec -n llm -it \
  $(kubectl get pod -n llm -l app=t2i-stable-diffusion-3-5-large-tensorrt -o jsonpath='{.items[0].metadata.name}') \
  -- rm -rf /data/sd35/engine
```

The ONNX models under `/data/sd35/onnx` are reusable and do not need to be deleted. The next request will rebuild only the engine files, which is faster than a full first-time setup.

## No output from image API response

If the API returns JSON with `image_base64` or `b64_json`, decode it to a PNG file:

```bash
jq -r '.image_base64 // .data[0].b64_json' response.json | base64 -d > output.png
```

## DeepSeek gibberish output

Use instruct model profile (`DeepSeek-Coder`) rather than base checkpoints.
