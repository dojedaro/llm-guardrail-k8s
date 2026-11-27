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


async def test_one_retry_on_connect_error_then_success():
    calls = []

    def handler(req):
        calls.append(1)
        if len(calls) == 1:
            raise httpx.ConnectError("stale endpoint")
        return httpx.Response(200, json={"reply": "ok"})

    a = MockAdapter("http://m", client_with(handler))
    assert await a.complete([]) == "ok" and len(calls) == 2


async def test_no_retry_on_timeout():
    calls = []

    def handler(req):
        calls.append(1)
        raise httpx.ReadTimeout("slow")

    with pytest.raises(UpstreamTimeout):
        await MockAdapter("http://m", client_with(handler)).complete([])
    assert len(calls) == 1


async def test_empty_exception_text_falls_back():
    def handler(req):
        raise httpx.ConnectTimeout("")

    a = MockAdapter("http://m", client_with(handler))
    assert not await a.ping() and a.last_error.endswith("timed out")


async def test_anthropic_error_message_kept_for_logs_and_empty_reply_rejected():
    err = httpx.Response(
        401, json={"error": {"type": "authentication_error", "message": "invalid x-api-key"}}
    )
    a = AnthropicAdapter("https://x", "k", "m", client_with(lambda r: err))
    with pytest.raises(UpstreamUnavailable, match="invalid x-api-key"):
        await a.complete([{"role": "user", "content": "hi"}])
    empty = httpx.Response(200, json={"content": [], "stop_reason": "end_turn"})
    b = AnthropicAdapter("https://x", "k", "m", client_with(lambda r: empty))
    with pytest.raises(UpstreamUnavailable, match="empty completion"):
        await b.complete([{"role": "user", "content": "hi"}])
