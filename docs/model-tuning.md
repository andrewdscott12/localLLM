# Model Tuning Profiles

Current default manifest profile is conservative for DGX Spark unified memory:

- Qwen2.5-Coder-7B-Instruct
  - `gpu-memory-utilization=0.80`
  - `max-model-len=32768`
  - `max-num-seqs=2`
- deepseek-ai/deepseek-coder-33b-instruct
  - `gpu-memory-utilization=0.78`
  - `max-model-len=32768`
  - `max-num-seqs=1`
- Qwen/Qwen3-Coder-30B-A3B-Instruct
  - `gpu-memory-utilization=0.78`
  - `max-model-len=32768`
  - `max-num-seqs=1`

## Image runtime profile (non-vLLM)

`stabilityai/stable-diffusion-3.5-large-tensorrt` is not a vLLM deployment and does not use the same tuning knobs.

- Runtime: custom TensorRT OSS image (`localllm/sd35-trt:latest`)
- Controls: `SD35_PRECISION`, `denoising_steps`, `guidance_scale`, output size
- Cache/build path: `/data/sd35` on shared PVC
- Shared memory mount: `/dev/shm` backed by memory `emptyDir`

`doDeployment.sh --safe` and vLLM override env vars do not tune this image runtime.

## Safe mode

Use `--safe` for lower memory pressure and single-sequence behavior:

```bash
./doDeployment.sh --safe Qwen/Qwen2.5-Coder-7B-Instruct
```

## Notes

- Keep extra headroom for OS + Docker + Minikube + Kubernetes pods.
- Large models can still fail to load or perform poorly on constrained unified memory.
