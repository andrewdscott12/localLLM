# Model Tuning Profiles

Current default manifest profile is conservative for DGX Spark unified memory:

- Qwen2.5-Coder-7B-Instruct
  - `gpu-memory-utilization=0.80`
  - `max-model-len=4096`
  - `max-num-seqs=2`
- DeepSeek-Coder-V2-Lite-Instruct
  - `gpu-memory-utilization=0.78`
  - `max-model-len=2048`
  - `max-num-seqs=2`
- Codestral-22B
  - `gpu-memory-utilization=0.80`
  - `max-model-len=2048`
  - `max-num-seqs=2`

## Safe mode

Use `--safe` for lower memory pressure and single-sequence behavior:

```bash
./doDeployment.sh --safe DeepSeek-Coder
```

## Notes

- Keep extra headroom for OS + Docker + Minikube + Kubernetes pods.
- Large models can still fail to load or perform poorly on constrained unified memory.
