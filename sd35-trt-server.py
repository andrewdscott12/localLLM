import base64
import logging
import os
import signal
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
logger = logging.getLogger("sd35")


class ImageRequest(BaseModel):
    prompt: str = Field(min_length=1)
    negative_prompt: str | None = None
    height: int = 1024
    width: int = 1024
    denoising_steps: int = 30
    guidance_scale: float = 3.5


class OpenAIImageRequest(BaseModel):
    prompt: str = Field(min_length=1)
    model: str | None = None
    n: int = 1
    size: str = "1024x1024"
    response_format: str = "b64_json"
    negative_prompt: str | None = None
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


def run_generation(request: ImageRequest) -> tuple[str, str]:
    work_dir = Path("/opt/TensorRT/demo/Diffusion")
    with tempfile.TemporaryDirectory(prefix="sd35-out-") as output_dir:
        command = build_command(request, output_dir)
        logger.info(
            "generation start size=%dx%d steps=%d guidance=%.1f",
            request.width, request.height, request.denoising_steps, request.guidance_scale,
        )
        process = subprocess.Popen(
            command,
            cwd=work_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        output_lines: list[str] = []
        if process.stdout is not None:
            for line in process.stdout:
                logger.info("[trt] %s", line.rstrip())
                output_lines.append(line)

        return_code = process.wait()
        combined_output = "".join(output_lines)

        if return_code != 0:
            signal_num = -return_code if return_code < 0 else None
            signal_name = signal.Signals(signal_num).name if signal_num is not None else None
            logger.error(
                "generation failed rc=%d signal=%s",
                return_code,
                signal_name or "none",
            )
            raise HTTPException(
                status_code=500,
                detail={
                    "return_code": return_code,
                    "signal": signal_name,
                    "stdout": combined_output[-4000:],
                    "stderr": "",
                },
            )

        images = sorted(Path(output_dir).glob("*.png"))
        if not images:
            raise HTTPException(status_code=500, detail="No image was generated")

        logger.info("generation complete file=%s", images[0].name)
        return images[0].name, base64.b64encode(images[0].read_bytes()).decode("ascii")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    logger.info("GET /healthz")
    return {"status": "ok"}


@app.get("/v1/models")
def list_models() -> dict[str, object]:
    model_id = os.getenv("SD35_MODEL_ID", "sd35-large-tensorrt")
    logger.info("GET /v1/models -> %s", model_id)
    return {
        "object": "list",
        "data": [
            {
                "id": model_id,
                "object": "model",
                "owned_by": "local",
            }
        ],
    }


@app.post("/generate")
def generate(request: ImageRequest) -> dict[str, str]:
    logger.info("POST /generate prompt=%r", request.prompt[:80])
    filename, image_base64 = run_generation(request)
    logger.info("POST /generate 200 file=%s", filename)
    return {
        "filename": filename,
        "image_base64": image_base64,
    }


@app.post("/v1/images/generations")
def openai_generate(request: OpenAIImageRequest) -> dict[str, object]:
    logger.info("POST /v1/images/generations prompt=%r size=%s", request.prompt[:80], request.size)
    try:
        width_str, height_str = request.size.lower().split("x", 1)
        width = int(width_str)
        height = int(height_str)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="size must be in WIDTHxHEIGHT format") from exc

    if request.response_format not in {"b64_json", "url"}:
        raise HTTPException(status_code=400, detail="response_format must be 'b64_json' or 'url'")

    image_request = ImageRequest(
        prompt=request.prompt,
        negative_prompt=request.negative_prompt,
        width=width,
        height=height,
        denoising_steps=request.denoising_steps,
        guidance_scale=request.guidance_scale,
    )

    filename, image_base64 = run_generation(image_request)
    created = int(datetime.now(timezone.utc).timestamp())
    logger.info("POST /v1/images/generations 200 file=%s", filename)

    if request.response_format == "url":
        return {
            "created": created,
            "data": [{"url": f"data:image/png;base64,{image_base64}", "revised_prompt": request.prompt, "filename": filename}],
        }

    return {
        "created": created,
        "data": [{"b64_json": image_base64, "revised_prompt": request.prompt, "filename": filename}],
    }


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=os.getenv("SD35_HOST", "0.0.0.0"),
        port=int(os.getenv("SD35_PORT", "8000")),
        log_level="info",
    )