# Mock LLM image. Build context: app/mock-llm
FROM python:3.12.16-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Same base-image fix as the gateway image (libpam CVE-2025-6020); remove with it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends --only-upgrade \
       libpam0g libpam-modules libpam-modules-bin libpam-runtime \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY mock_llm ./mock_llm

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s \
  CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"]

CMD ["uvicorn", "mock_llm.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
