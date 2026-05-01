import base64
import os
import subprocess
import tempfile
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
import uvicorn


class ImageRequest(BaseModel):
    prompt: str = Field(min_length=1)
    negative_prompt: str | None = None
    height: int = 1024
    width: int = 1024
    denoising_steps: int = 30
    guidance_scale: float = 3.5


app = FastAPI(title="SD3.5 TensorRT Service")


def build_command(request: ImageRequest, output_dir: str) -> list[str]:
    command = [
        "python3",
        "demo_txt2img_sd35.py",
        request.prompt,
        f"--version={os.getenv('SD35_VERSION', '3.5-large')}",
        f"--hf-token={os.environ['HF_TOKEN']}",
        f"--height={request.height}",
        f"--width={request.width}",
        f"--denoising-steps={request.denoising_steps}",
        f"--guidance-scale={request.guidance_scale}",
        f"--onnx-dir={os.getenv('SD35_ONNX_DIR', '/data/sd35/onnx')}",
        f"--engine-dir={os.getenv('SD35_ENGINE_DIR', '/data/sd35/engine')}",
        f"--output-dir={output_dir}",
        "--download-onnx-models",
    ]

    precision = os.getenv("SD35_PRECISION", "bf16")
    if precision == "fp8":
        command.append("--fp8")
    else:
        command.append("--bf16")

    if request.negative_prompt:
        command.append(f"--negative-prompt={request.negative_prompt}")

    return command


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/generate")
def generate(request: ImageRequest) -> dict[str, str]:
    work_dir = Path("/opt/TensorRT/demo/Diffusion")
    with tempfile.TemporaryDirectory(prefix="sd35-out-") as output_dir:
        result = subprocess.run(
            build_command(request, output_dir),
            cwd=work_dir,
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail={
                    "stdout": result.stdout[-4000:],
                    "stderr": result.stderr[-4000:],
                },
            )

        images = sorted(Path(output_dir).glob("*.png"))
        if not images:
            raise HTTPException(status_code=500, detail="No image was generated")

        return {
            "filename": images[0].name,
            "image_base64": base64.b64encode(images[0].read_bytes()).decode("ascii"),
        }


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=os.getenv("SD35_HOST", "0.0.0.0"),
        port=int(os.getenv("SD35_PORT", "8000")),
    )