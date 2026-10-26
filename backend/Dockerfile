# ---- Build the primary Flutter web client ----
FROM ghcr.io/cirruslabs/flutter:stable AS web-build

WORKDIR /repo/mobile
COPY mobile/pubspec.yaml mobile/pubspec.lock ./
RUN flutter pub get
COPY mobile /repo/mobile
RUN flutter build web --release

# ---- Kavach web + backend image ----
FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# system deps for scientific wheels
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl && rm -rf /var/lib/apt/lists/*

# ---- dependencies ----
COPY backend/requirements.txt /app/backend/requirements.txt
RUN pip install --extra-index-url https://download.pytorch.org/whl/cpu -r /app/backend/requirements.txt

# ---- application code (backend + ml package it imports) ----
COPY backend /app/backend
COPY ml /app/ml
COPY --from=web-build /repo/mobile/build/web /app/web

WORKDIR /app/backend
ENV PYTHONPATH=/app/backend:/app/ml/src

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8000}/api/health || exit 1

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
