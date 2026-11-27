"""Upstream LLM adapters. Both raise the same exceptions so the API layer
can map them to HTTP codes without knowing which provider is configured."""

from __future__ import annotations

from typing import Any, Protocol

import httpx


class UpstreamTimeout(Exception):
    """Upstream did not answer in time -> HTTP 504."""


class UpstreamUnavailable(Exception):
    """Connection refused, DNS failure, or upstream returned an error -> HTTP 502."""


class UpstreamRefused(Exception):
    """The model declined to answer (Anthropic stop_reason "refusal") -> HTTP 502, reported as its own kind."""


class Upstream(Protocol):
    name: str

    async def complete(self, messages: list[dict[str, str]]) -> str: ...

    async def ping(self) -> bool: ...

    last_error: str | None


async def _post(client: httpx.AsyncClient, url: str, **kw: Any) -> httpx.Response:
    try:
        try:
            resp = await client.post(url, **kw)
        except httpx.ConnectError:
            # Nothing was sent, so one retry is safe. It rides out a pod that is being replaced
            # (stale endpoint) during a rolling update, which is the zero-downtime case.
            resp = await client.post(url, **kw)
    except httpx.TimeoutException as exc:
        raise UpstreamTimeout(str(exc) or "timeout") from exc
    except httpx.TransportError as exc:  # connect error, DNS failure, reset...
        raise UpstreamUnavailable(f"{type(exc).__name__}: {exc}") from exc
    if resp.status_code >= 400:
        raise UpstreamUnavailable(f"upstream returned HTTP {resp.status_code}{_error_hint(resp)}")
    return resp


def _error_hint(resp: httpx.Response) -> str:
    """Short provider error text (e.g. Anthropic's error.message) for the logs; never the request body."""
    try:
        err = resp.json().get("error", {})
        msg = err.get("message") if isinstance(err, dict) else None
    except ValueError:
        msg = None
    return f": {msg[:160]}" if isinstance(msg, str) and msg else ""


class MockAdapter:
    """Talks to app/mock-llm: POST {url}/v1/chat -> {"reply": "..."}."""

    name = "mock"

    def __init__(self, url: str, client: httpx.AsyncClient) -> None:
        self.url, self.client = url.rstrip("/"), client
        self.last_error: str | None = None  # why the last ping failed; logged by /readyz

    async def complete(self, messages: list[dict[str, str]]) -> str:
        resp = await _post(self.client, f"{self.url}/v1/chat", json={"messages": messages})
        return str(resp.json()["reply"])

    async def ping(self) -> bool:
        try:
            status = (await self.client.get(f"{self.url}/healthz", timeout=2.0)).status_code
            self.last_error = None if status == 200 else f"HTTP {status}"
        except httpx.HTTPError as exc:
            self.last_error = f"{type(exc).__name__}: {str(exc) or 'timed out'}"
        return self.last_error is None


class AnthropicAdapter:
    """Anthropic Messages API. The API key comes from the environment (a K8s Secret)."""

    name = "anthropic"

    def __init__(
        self,
        url: str,
        api_key: str,
        model: str,
        client: httpx.AsyncClient,
        max_tokens: int = 4096,
        effort: str = "low",
    ) -> None:
        self.url, self.api_key, self.model = url.rstrip("/"), api_key, model
        self.client, self.max_tokens, self.effort = client, max_tokens, effort
        self.last_error: str | None = None

    async def complete(self, messages: list[dict[str, str]]) -> str:
        system = "\n".join(m["content"] for m in messages if m["role"] == "system")
        convo = [m for m in messages if m["role"] != "system"]
        body: dict[str, Any] = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "messages": convo,
        }
        if self.effort:
            # Current Claude models think by default and thinking tokens count against max_tokens;
            # a low effort keeps a short chat answer from being spent on reasoning.
            body["output_config"] = {"effort": self.effort}
        if system:
            body["system"] = system
        headers = {"x-api-key": self.api_key, "anthropic-version": "2023-06-01"}
        resp = await _post(self.client, f"{self.url}/v1/messages", json=body, headers=headers)
        data = resp.json()
        stop = data.get("stop_reason")
        if stop == "refusal":
            category = (data.get("stop_details") or {}).get("category")
            raise UpstreamRefused(f"model refused (category={category})")
        text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
        if not text:
            hint = " - raise UPSTREAM_MAX_TOKENS: reasoning can use all of it" if stop == "max_tokens" else ""
            raise UpstreamUnavailable(f"empty completion (stop_reason={stop}){hint}")
        if stop == "max_tokens":
            text += " [truncated: max_tokens reached]"
        return text

    async def ping(self) -> bool:
        # Reachability only: any HTTP response (even 404) proves DNS + egress + TLS work.
        # We do not call the model here, so readiness probes cost no tokens.
        try:
            await self.client.get(self.url, timeout=3.0)
            self.last_error = None
        except httpx.HTTPError as exc:
            self.last_error = f"{type(exc).__name__}: {str(exc) or 'timed out'}"
        return self.last_error is None
