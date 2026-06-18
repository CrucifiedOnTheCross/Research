FROM pytorch/pytorch:2.7.1-cuda12.8-cudnn9-runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

WORKDIR /workspace

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade pip && pip install -r requirements.txt

COPY . .
RUN pip install --no-deps -e .

RUN useradd --create-home --uid 1000 --shell /bin/bash trainer \
    && mkdir -p /cache/torch /workspace/runs \
    && chown -R trainer:trainer /cache /workspace/runs

ENV HOME=/home/trainer
USER trainer

ENTRYPOINT ["python", "-m", "isic_train.train"]
CMD ["--config", "configs/train.yaml"]
