FROM nvcr.io/nvidia/pytorch:25.08-py3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    git-lfs \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN git clone --branch release/sd35 --single-branch https://github.com/NVIDIA/TensorRT.git /opt/TensorRT

WORKDIR /opt/TensorRT/demo/Diffusion

RUN bash -lc "source setup.sh"

RUN pip install fastapi "uvicorn[standard]" pillow

COPY sd35-trt-server.py /opt/TensorRT/demo/Diffusion/sd35-trt-server.py

EXPOSE 8000

CMD ["python3", "/opt/TensorRT/demo/Diffusion/sd35-trt-server.py"]