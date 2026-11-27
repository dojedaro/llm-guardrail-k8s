"""FastAPI app: /v1/chat with guardrails, plus health, readiness and metrics."""

from __future__ import annotations

import logging
import re
import time
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel, Field, model_validator
from starlette.types import ASGIApp, Receive, Scope, Send
from starlette.types import Message as AsgiMessage

from .config import Settings
from .guardrails import check_input, check_output
from .logging_setup import setup_logging
from .policy import Policy, load_policy
from .upstream import (
    AnthropicAdapter,
    MockAdapter,
    Upstream,
    UpstreamRefused,
    UpstreamTimeout,
    UpstreamUnavailable,
)

MAX_MESSAGE_CHARS = 20_000
MAX_TOTAL_CHARS = 100_000  # bounds the work one request can cause in the guardrails
MAX_BODY_BYTES = (
    1 << 20
)  # 1 MiB: room for 100,000 characters in any encoding, far below the pod's memory limit
REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

# Upstream failure -> (kind used in metrics and the error code, HTTP status).
UPSTREAM_FAILURES: dict[type[Exception], tuple[str, int]] = {
    UpstreamTimeout: ("timeout", 504),
    UpstreamUnavailable: ("unavailable", 502),
    UpstreamRefused: ("refused", 502),
}


class Message(BaseModel):
    role: str = Field(pattern="^(system|user|assistant)$")
    content: str = Field(max_length=MAX_MESSAGE_CHARS)


class ChatRequest(BaseModel):
    messages: list[Message] = Field(min_length=1, max_length=50)

    @model_validator(mode="after")
    def _bounded(self) -> ChatRequest:
        if sum(len(m.content) for m in self.messages) > MAX_TOTAL_CHARS:
            raise ValueError(f"total message length exceeds {MAX_TOTAL_CHARS} characters")
        return self


class _BodyTooLarge(Exception):
    """Raised inside the receive channel when a streamed body crosses the limit."""


class BodyLimit:
    """Reject oversized bodies before they are read into memory.

    A declared Content-Length over the limit is refused at once. A body that is streamed (chunked, or a lying
    Content-Length) is counted as it arrives and aborted when it crosses the limit. FastAPI turns an error raised
    while it reads the body into its own 400, so the response it sends is replaced with the 413.
    """

    def __init__(self, app: ASGIApp, limit: int, refuse: Callable[[Request], JSONResponse]) -> None:
        self.app, self.limit, self.refuse = app, limit, refuse

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        declared = dict(scope["headers"]).get(b"content-length", b"")
        if declared.isdigit() and int(declared) > self.limit:
            await self.refuse(Request(scope))(scope, receive, send)
            return
        seen, tripped = 0, False

        async def counting_receive() -> AsgiMessage:
            nonlocal seen, tripped
            message = await receive()
            if message["type"] == "http.request":
                seen += len(message.get("body", b""))
                if seen > self.limit:
                    tripped = True
                    raise _BodyTooLarge
            return message

        async def guarded_send(message: AsgiMessage) -> None:
            if not tripped:
                await send(message)
            elif message["type"] == "http.response.start":
                await self.refuse(Request(scope))(
                    scope, receive, send
                )  # sends the whole 413; the app's error is dropped

        try:
            await self.app(scope, counting_receive, guarded_send)
        except _BodyTooLarge:
            await guarded_send({"type": "http.response.start"})


def build_upstream(s: Settings, client: httpx.AsyncClient) -> Upstream:
    if s.upstream_kind == "anthropic":
        if not s.anthropic_api_key:
            raise RuntimeError("UPSTREAM_KIND=anthropic but ANTHROPIC_API_KEY is empty")
        return AnthropicAdapter(
            s.upstream_url,
            s.anthropic_api_key,
            s.upstream_model,
            client,
            max_tokens=s.max_tokens,
            effort=s.effort,
        )
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


def _request_id(request: Request) -> str:
    """Client-supplied X-Request-ID if it is short and boring, else a fresh one (it ends up in logs and headers)."""
    given = request.headers.get("x-request-id", "")
    return given if REQUEST_ID.match(given) else uuid.uuid4().hex[:16]


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

    def refuse_too_large(request: Request) -> JSONResponse:
        rid = _request_id(request)
        log.info("request", extra={"request_id": rid, "decision": "too_large", "status": 413})
        body = {"request_id": rid, "error": "request_too_large", "max_bytes": MAX_BODY_BYTES}
        return _reply(rid, "-", 413, body)

    app = FastAPI(title="llm-guardrail-gateway", lifespan=lifespan)
    app.add_middleware(BodyLimit, limit=MAX_BODY_BYTES, refuse=refuse_too_large)

    def respond(
        rid: str,
        policy_version: str,
        status: int,
        decision: str,
        body: dict[str, Any],
        level: int = logging.INFO,
        **log_fields: Any,
    ) -> JSONResponse:
        """Count, log and answer one chat request: the single place a request's outcome is recorded."""
        metrics.requests.labels(decision).inc()
        log.log(
            level,
            "request",
            extra={
                "request_id": rid,
                "policy_version": policy_version,
                "decision": decision,
                "status": status,
                **log_fields,
            },
        )
        return _reply(
            rid, policy_version, status, {"request_id": rid, "policy_version": policy_version, **body}
        )

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request: Request, exc: RequestValidationError) -> JSONResponse:
        rid = _request_id(request)
        # Only locations and messages: pydantic's default body would echo the (possibly sensitive) input.
        problems = [{"loc": list(e["loc"]), "msg": e["msg"]} for e in exc.errors()]
        log.info(
            "request", extra={"request_id": rid, "decision": "invalid", "status": 422, "problems": problems}
        )
        return _reply(rid, "-", 422, {"request_id": rid, "error": "invalid_request", "problems": problems})

    @app.exception_handler(Exception)
    async def unexpected(request: Request, exc: Exception) -> JSONResponse:
        rid = _request_id(request)
        log.error("request", exc_info=exc, extra={"request_id": rid, "decision": "error", "status": 500})
        return _reply(rid, "-", 500, {"request_id": rid, "error": "internal_error"})

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}  # liveness: process is up; deliberately checks nothing else

    @app.get("/readyz")
    async def readyz(request: Request) -> Response:
        pol: Policy | None = request.app.state.policy
        up_ok = await request.app.state.upstream.ping()
        body = {
            "version": s.version,
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
        rid = _request_id(request)
        pol: Policy | None = request.app.state.policy
        if pol is None:
            return _reply(rid, "-", 503, {"request_id": rid, "error": "policy_not_loaded"})

        # Regex work is CPU-bound: keep it off the event loop so /healthz stays responsive.
        res = await run_in_threadpool(check_input, [m.model_dump() for m in req.messages], pol)
        for rule, n in res.hits.items():
            metrics.rule_hits.labels(rule, "input").inc(n)
        if res.decision == "blocked":
            return respond(
                rid,
                pol.version,
                403,
                "blocked",
                {"decision": "blocked", "reason": res.reason, "rules": res.hits},
                reason=res.reason,
                rules=res.hits,
                upstream_ms=None,
            )

        t0 = time.perf_counter()
        try:
            text = await request.app.state.upstream.complete(res.messages)
        except tuple(UPSTREAM_FAILURES) as exc:
            kind, status = UPSTREAM_FAILURES[type(exc)]
            metrics.upstream_errors.labels(kind).inc()
            # The raw exception text stays in the log; the caller gets only the class of failure.
            return respond(
                rid,
                pol.version,
                status,
                "upstream_error",
                {"error": f"upstream_{kind}"},
                level=logging.WARNING,
                error=kind,
                detail=str(exc)[:200],
                upstream_ms=round((time.perf_counter() - t0) * 1000),
            )
        elapsed = time.perf_counter() - t0
        metrics.upstream_latency.observe(elapsed)

        text, out_hits = await run_in_threadpool(check_output, text, pol)
        for rule, n in out_hits.items():
            metrics.rule_hits.labels(rule, "output").inc(n)
        decision = "redacted" if (res.decision == "redacted" or out_hits) else "allow"
        return respond(
            rid,
            pol.version,
            200,
            decision,
            {"decision": decision, "reply": text, "rules": res.hits, "output_rules": out_hits},
            rules=res.hits,
            output_rules=out_hits,
            upstream_ms=round(elapsed * 1000),
        )

    return app


def app_factory() -> FastAPI:
    """Entry point for `uvicorn gateway.main:app_factory --factory`."""
    return create_app()
