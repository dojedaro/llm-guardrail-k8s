from fastapi.testclient import TestClient
from mock_llm.main import app

c = TestClient(app)
MSG = {"messages": [{"role": "user", "content": "hello"}]}


def test_deterministic_reply():
    a, b = c.post("/v1/chat", json=MSG).json(), c.post("/v1/chat", json=MSG).json()
    assert a == b and a["reply"] == "[mock-llm] You said: hello"


def test_leak_trigger():
    body = {"messages": [{"role": "user", "content": "MOCK_LEAK please"}]}
    assert "leaked.user@example.com" in c.post("/v1/chat", json=body).json()["reply"]


def test_error_injection(monkeypatch):
    monkeypatch.setenv("MOCK_ERROR_RATE", "1")
    assert c.post("/v1/chat", json=MSG).status_code == 500
    assert c.get("/healthz").status_code == 200  # health is never faulted


def test_latency_injection(monkeypatch):
    import time

    monkeypatch.setenv("MOCK_LATENCY_MS", "200")
    t0 = time.perf_counter()
    c.post("/v1/chat", json=MSG)
    assert time.perf_counter() - t0 >= 0.19
