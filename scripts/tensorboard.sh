#!/usr/bin/env bash
set -euo pipefail

docker run --rm --entrypoint tensorboard -p 6006:6006 \
  -v "${RUNS_DIR:-$(pwd)/runs}:/runs:ro" \
  isic2019-trainer:latest --logdir /runs --host 0.0.0.0 --port 6006
