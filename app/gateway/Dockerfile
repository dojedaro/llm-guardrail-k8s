# Gateway image. Build context: app/gateway
FROM python:3.12.8-slim-bookworm

# No .pyc writes and unbuffered logs: required for readOnlyRootFilesystem and `kubectl logs`.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY gateway ./gateway

# Numeric non-root UID so Kubernetes can verify runAsNonRoot without reading /etc/passwd.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

EXPOSE 8080
# Used by plain `docker run`; Kubernetes ignores HEALTHCHECK and uses its own probes.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s \
  CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"]

CMD ["uvicorn", "gateway.main:app_factory", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
