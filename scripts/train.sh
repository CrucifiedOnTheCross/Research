#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${RUNS_DIR:-./runs}" "${MODEL_CACHE_DIR:-./.cache/torch}"
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"
docker compose build
docker compose run --rm trainer "$@"
