"""FastAPI app: /v1/chat with guardrails, plus health, readiness and metrics."""

from __future__ import annotations

import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel, Field

from .config import Settings
from .guardrails import check_input, check_output
from .logging_setup import setup_logging
from .policy import Policy, load_policy
from .upstream import (
    AnthropicAdapter,
    MockAdapter,
    Upstream,
    UpstreamTimeout,
    UpstreamUnavailable,
)


class Message(BaseModel):
    role: str = Field(pattern="^(system|user|assistant)$")
    content: str = Field(max_length=20000)


class ChatRequest(BaseModel):
    messages: list[Message] = Field(min_length=1, max_length=50)


def build_upstream(s: Settings, client: httpx.AsyncClient) -> Upstream:
    if s.upstream_kind == "anthropic":
        if not s.anthropic_api_key:
            raise RuntimeError("UPSTREAM_KIND=anthropic but ANTHROPIC_API_KEY is empty")
        return AnthropicAdapter(s.upstream_url, s.anthropic_api_key, s.upstream_model, client)
    return MockAdapter(s.upstream_url, client)


class Metrics:
    def __init__(self) -> None:
        self.registry = CollectorRegistry()
        self.requests = Counter(
            "gateway_requests_total", "Chat requests by decision", ["decision"], registry=self.registry
        )
        self.rule_hits = Counter(
            "gateway_rule_hits_total", "Guardrail rule hits", ["rule", "direction"], registry=self.registry
        )
        self.upstream_errors = Counter(
            "gateway_upstream_errors_total", "Upstream failures", ["kind"], registry=self.registry
        )
        self.upstream_latency = Histogram(
            "gateway_upstream_latency_seconds", "Upstream call latency", registry=self.registry
        )


def _reply(rid: str, policy_version: str, status: int, body: dict[str, Any]) -> JSONResponse:
    return JSONResponse(
        body, status_code=status, headers={"X-Request-ID": rid, "X-Policy-Version": policy_version}
    )


def create_app(
    settings: Settings | None = None,
    upstream: Upstream | None = None,
    policy: Policy | None = None,
) -> FastAPI:
    """Factory so tests can inject settings, a fake upstream, or a policy."""
    s = settings or Settings.from_env()
    log = setup_logging(s.log_level)
    metrics = Metrics()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        client = httpx.AsyncClient(timeout=s.upstream_timeout_s)
        app.state.policy = policy
        if app.state.policy is None:
            try:
                app.state.policy = load_policy(s.policy_path)
            except (OSError, ValueError) as exc:
                # Fail soft: /readyz reports not-ready, so Kubernetes withholds traffic.
                log.error("policy load failed", extra={"path": s.policy_path, "error": str(exc)})
        app.state.upstream = upstream or build_upstream(s, client)
        log.info(
            "started",
            extra={
                "upstream": app.state.upstream.name,
                "upstream_url": s.upstream_url,
                "policy_version": getattr(app.state.policy, "version", None),
            },
        )
        yield
        await client.aclose()

    app = FastAPI(title="llm-guardrail-gateway", lifespan=lifespan)

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}  # liveness: process is up; deliberately checks nothing else

    @app.get("/readyz")
    async def readyz(request: Request) -> Response:
        pol: Policy | None = request.app.state.policy
        up_ok = await request.app.state.upstream.ping()
        body = {
            "policy_loaded": pol is not None,
            "upstream_reachable": up_ok,
            "policy_version": pol.version if pol else None,
        }
        if not (pol and up_ok):
            # The reason is what an operator needs at 3am: say it in the log, not only via the probe status.
            log.warning(
                "not ready",
                extra={
                    **body,
                    "upstream_url": s.upstream_url,
                    "upstream_error": getattr(request.app.state.upstream, "last_error", None),
                },
            )
        return JSONResponse(body, status_code=200 if pol and up_ok else 503)

    @app.get("/metrics")
    async def metrics_endpoint() -> Response:
        return Response(generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)

    @app.post("/v1/chat")
    async def chat(req: ChatRequest, request: Request) -> JSONResponse:
        rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:16]
        pol: Policy | None = request.app.state.policy
        if pol is None:
            return _reply(rid, "-", 503, {"request_id": rid, "error": "policy_not_loaded"})
        base: dict[str, Any] = {"request_id": rid, "policy_version": pol.version}

        res = check_input([m.model_dump() for m in req.messages], pol)
        for rule, n in res.hits.items():
            metrics.rule_hits.labels(rule, "input").inc(n)
        if res.decision == "blocked":
            metrics.requests.labels("blocked").inc()
            log.info(
                "request",
                extra={
                    **base,
                    "decision": "blocked",
                    "reason": res.reason,
                    "rules": res.hits,
                    "upstream_ms": None,
                    "status": 403,
                },
            )
            body = {**base, "decision": "blocked", "reason": res.reason, "rules": res.hits}
            return _reply(rid, pol.version, 403, body)

        t0 = time.perf_counter()
        try:
            text = await request.app.state.upstream.complete(res.messages)
        except (UpstreamTimeout, UpstreamUnavailable) as exc:
            kind, status = ("timeout", 504) if isinstance(exc, UpstreamTimeout) else ("unavailable", 502)
            metrics.upstream_errors.labels(kind).inc()
            metrics.requests.labels("upstream_error").inc()
            ms = round((time.perf_counter() - t0) * 1000)
            log.warning(
                "request",
                extra={
                    **base,
                    "decision": "upstream_error",
                    "error": kind,
                    "detail": str(exc)[:200],
                    "upstream_ms": ms,
                    "status": status,
                },
            )
            body = {**base, "error": f"upstream_{kind}", "detail": str(exc)[:200]}
            return _reply(rid, pol.version, status, body)
        elapsed = time.perf_counter() - t0
        metrics.upstream_latency.observe(elapsed)

        text, out_hits = check_output(text, pol)
        for rule, n in out_hits.items():
            metrics.rule_hits.labels(rule, "output").inc(n)
        decision = "redacted" if (res.decision == "redacted" or out_hits) else "allow"
        metrics.requests.labels(decision).inc()
        log.info(
            "request",
            extra={
                **base,
                "decision": decision,
                "rules": res.hits,
                "output_rules": out_hits,
                "upstream_ms": round(elapsed * 1000),
                "status": 200,
            },
        )
        body = {**base, "decision": decision, "reply": text, "rules": res.hits, "output_rules": out_hits}
        return _reply(rid, pol.version, 200, body)

    return app


def app_factory() -> FastAPI:
    """Entry point for `uvicorn gateway.main:app_factory --factory`."""
    return create_app()
