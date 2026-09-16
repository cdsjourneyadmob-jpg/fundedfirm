# Minimal image with bash, curl, and python3 for the register/verify loop.
FROM python:3.12-slim

# curl for API calls, git so the worker can commit accounts.txt back to GitHub.
# python3 + bash come with the base image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates bash git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Baked-in copy (fallback if the runtime git clone fails)
COPY register_verify.sh run_loop.sh entrypoint.sh server.py /app/
RUN chmod +x /app/register_verify.sh /app/run_loop.sh /app/entrypoint.sh

# Commit accounts back to GitHub (free persistence). Set token/slug in Render env.
ENV GIT_PUSH=1

# Default cadence (overridable via Render env vars): 90s base + up to 60s jitter
ENV BASE_DELAY=90
ENV JITTER=60

# Entrypoint clones the repo, then runs the loop from the checkout
CMD ["bash", "/app/entrypoint.sh"]
