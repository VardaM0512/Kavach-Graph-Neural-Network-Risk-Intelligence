#!/usr/bin/env bash
# Kavach deployment helper.
#   ./scripts/deploy.sh local     -> docker compose up (Postgres + Neo4j + API)
#   ./scripts/deploy.sh image     -> build & tag the backend image
#   ./scripts/deploy.sh push REG  -> push the image to a registry REG
set -euo pipefail

CMD="${1:-local}"
IMAGE="${IMAGE:-kavach-api}"
TAG="${TAG:-latest}"

case "$CMD" in
  local)
    echo ">> starting full local stack"
    docker compose up --build
    ;;
  image)
    echo ">> building backend image ${IMAGE}:${TAG}"
    docker build -f backend/Dockerfile -t "${IMAGE}:${TAG}" .
    ;;
  push)
    REG="${2:?usage: deploy.sh push <registry>}"
    docker tag "${IMAGE}:${TAG}" "${REG}/${IMAGE}:${TAG}"
    docker push "${REG}/${IMAGE}:${TAG}"
    ;;
  *)
    echo "unknown command: $CMD"; exit 1;;
esac
