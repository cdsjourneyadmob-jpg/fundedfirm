# Minimal image with bash, curl, and python3 for the register/verify loop.
FROM python:3.12-slim

# curl is the only extra system package we need; python3 + bash come with the base.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the scripts
COPY register_verify.sh run_loop.sh /app/
RUN chmod +x /app/register_verify.sh /app/run_loop.sh

# Persist accounts to the mounted disk at /data (configured in render.yaml)
ENV DATA_DIR=/data

# Default cadence (overridable via Render env vars): 90s base + up to 60s jitter
ENV BASE_DELAY=90
ENV JITTER=60

# Run the loop forever
CMD ["bash", "/app/run_loop.sh"]
