"""Upstream LLM adapters. Both raise the same two exceptions so the API layer
can map them to HTTP codes without knowing which provider is configured."""

from __future__ import annotations

from typing import Any, Protocol

import httpx


class UpstreamTimeout(Exception):
    """Upstream did not answer in time -> HTTP 504."""


class UpstreamUnavailable(Exception):
    """Connection refused, DNS failure, or upstream returned an error -> HTTP 502."""


class Upstream(Protocol):
    name: str

    async def complete(self, messages: list[dict[str, str]]) -> str: ...

    async def ping(self) -> bool: ...


async def _post(client: httpx.AsyncClient, url: str, **kw: Any) -> httpx.Response:
    try:
        resp = await client.post(url, **kw)
    except httpx.TimeoutException as exc:
        raise UpstreamTimeout(str(exc) or "timeout") from exc
    except httpx.TransportError as exc:  # connect error, DNS failure, reset...
        raise UpstreamUnavailable(f"{type(exc).__name__}: {exc}") from exc
    if resp.status_code >= 400:
        raise UpstreamUnavailable(f"upstream returned HTTP {resp.status_code}")
    return resp


class MockAdapter:
    """Talks to app/mock-llm: POST {url}/v1/chat -> {"reply": "..."}."""

    name = "mock"

    def __init__(self, url: str, client: httpx.AsyncClient) -> None:
        self.url, self.client = url.rstrip("/"), client

    async def complete(self, messages: list[dict[str, str]]) -> str:
        resp = await _post(self.client, f"{self.url}/v1/chat", json={"messages": messages})
        return str(resp.json()["reply"])

    async def ping(self) -> bool:
        try:
            return (await self.client.get(f"{self.url}/healthz", timeout=2.0)).status_code == 200
        except httpx.HTTPError:
            return False


class AnthropicAdapter:
    """Anthropic Messages API. The API key comes from the environment (a K8s Secret)."""

    name = "anthropic"

    def __init__(
        self, url: str, api_key: str, model: str, client: httpx.AsyncClient, max_tokens: int = 512
    ) -> None:
        self.url, self.api_key, self.model = url.rstrip("/"), api_key, model
        self.client, self.max_tokens = client, max_tokens

    async def complete(self, messages: list[dict[str, str]]) -> str:
        system = "\n".join(m["content"] for m in messages if m["role"] == "system")
        convo = [m for m in messages if m["role"] != "system"]
        body: dict[str, Any] = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "messages": convo,
        }
        if system:
            body["system"] = system
        headers = {"x-api-key": self.api_key, "anthropic-version": "2023-06-01"}
        resp = await _post(self.client, f"{self.url}/v1/messages", json=body, headers=headers)
        blocks = resp.json().get("content", [])
        return "".join(b.get("text", "") for b in blocks if b.get("type") == "text")

    async def ping(self) -> bool:
        # Reachability only: any HTTP response (even 404) proves DNS + egress + TLS work.
        # We do not call the model here, so readiness probes cost no tokens.
        try:
            await self.client.get(self.url, timeout=3.0)
            return True
        except httpx.HTTPError:
            return False
