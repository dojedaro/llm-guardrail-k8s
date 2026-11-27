import httpx
import pytest
from gateway.upstream import (
    AnthropicAdapter,
    MockAdapter,
    UpstreamTimeout,
    UpstreamUnavailable,
)


def client_with(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_mock_adapter_complete():
    def handler(req: httpx.Request) -> httpx.Response:
        assert req.url.path == "/v1/chat"
        return httpx.Response(200, json={"reply": "hi"})

    a = MockAdapter("http://mock:8080/", client_with(handler))
    assert await a.complete([{"role": "user", "content": "x"}]) == "hi"


async def test_mock_adapter_ping():
    ok = MockAdapter("http://m", client_with(lambda r: httpx.Response(200, json={})))
    bad = MockAdapter("http://m", client_with(lambda r: httpx.Response(500)))
    assert await ok.ping() and ok.last_error is None
    assert not await bad.ping() and bad.last_error == "HTTP 500"


async def test_ping_records_dns_failure_reason():
    def handler(req):
        raise httpx.ConnectError("[Errno -3] Temporary failure in name resolution")

    a = MockAdapter("http://typo", client_with(handler))
    assert not await a.ping()
    assert "name resolution" in a.last_error


async def test_timeout_maps_to_upstream_timeout():
    def handler(req):
        raise httpx.ReadTimeout("slow")

    with pytest.raises(UpstreamTimeout):
        await MockAdapter("http://m", client_with(handler)).complete([])


async def test_refused_maps_to_unavailable():
    def handler(req):
        raise httpx.ConnectError("refused")

    with pytest.raises(UpstreamUnavailable):
        await MockAdapter("http://m", client_with(handler)).complete([])


async def test_http_error_maps_to_unavailable():
    a = MockAdapter("http://m", client_with(lambda r: httpx.Response(500)))
    with pytest.raises(UpstreamUnavailable, match="500"):
        await a.complete([])


async def test_anthropic_request_shape_and_parsing():
    seen: dict = {}

    def handler(req: httpx.Request) -> httpx.Response:
        import json

        seen["path"], seen["headers"], seen["body"] = req.url.path, req.headers, json.loads(req.content)
        return httpx.Response(
            200, json={"content": [{"type": "text", "text": "Hello "}, {"type": "text", "text": "there"}]}
        )

    a = AnthropicAdapter("https://api.anthropic.com", "sk-test", "claude-haiku-5-5", client_with(handler))
    msgs = [
        {"role": "system", "content": "be brief"},
        {"role": "user", "content": "hi"},
    ]
    assert await a.complete(msgs) == "Hello there"
    assert seen["path"] == "/v1/messages"
    assert seen["headers"]["x-api-key"] == "sk-test"
    assert seen["headers"]["anthropic-version"] == "2023-06-01"
    assert seen["body"]["model"] == "claude-haiku-5-5"
    assert seen["body"]["system"] == "be brief"
    assert seen["body"]["messages"] == [{"role": "user", "content": "hi"}]


async def test_anthropic_ping_any_http_response_is_reachable():
    a = AnthropicAdapter("https://x", "k", "m", client_with(lambda r: httpx.Response(404)))
    assert await a.ping()

    def refuse(req):
        raise httpx.ConnectError("no route")

    assert not await AnthropicAdapter("https://x", "k", "m", client_with(refuse)).ping()
