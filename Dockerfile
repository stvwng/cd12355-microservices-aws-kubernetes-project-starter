# Slim Debian-based Python image: small footprint, and psycopg2-binary ships
# manylinux wheels that work on glibc (unlike Alpine/musl, which forces a source build).
FROM public.ecr.aws/docker/library/python:3.10-slim-bookworm

# Unbuffered stdout/stderr so the scheduler's health logs reach CloudWatch immediately.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_PORT=5153

WORKDIR /app

# Install dependencies before copying source so this layer stays cached
# when only application code changes.
COPY analytics/requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY analytics/ .

# Run as an unprivileged user; the app needs no root privileges.
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 5153

CMD ["python", "app.py"]
