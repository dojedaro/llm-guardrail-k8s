"""Integration tests run against a real cluster. They skip cleanly when there is none, unless
REQUIRE_CLUSTER=1 (set in CI), in which case a missing cluster is a FAILURE: a green run must mean
the tests ran, not that they were skipped.

Either set GATEWAY_URL (e.g. you already ran `kubectl port-forward`), or let this fixture
start a port-forward to svc/$RELEASE-gateway in namespace $NS. Defaults match scripts/lib.sh.
"""

from __future__ import annotations

import contextlib
import os
import shutil
import subprocess
import time
from collections.abc import Iterator

import httpx
import pytest

NS = os.getenv("NS", "guardrail")
RELEASE = os.getenv("RELEASE", "guardrail")
LOCAL_PORT = int(os.getenv("IT_PORT", "18090"))
REQUIRE_CLUSTER = os.getenv("REQUIRE_CLUSTER") == "1"


def skip_or_fail(reason: str) -> None:
    if REQUIRE_CLUSTER:
        pytest.fail(f"REQUIRE_CLUSTER=1 but: {reason}")
    pytest.skip(reason)


def pytest_collection_modifyitems(items):
    for item in items:
        if "integration" in str(item.fspath).replace("\\", "/"):
            item.add_marker(pytest.mark.integration)


def kubectl(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=120, check=check)


def wait_healthy(url: str, timeout_s: float = 30.0) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if httpx.get(f"{url}/healthz", timeout=1).status_code == 200:
                return True
        except httpx.HTTPError:
            time.sleep(1)
    return False


@contextlib.contextmanager
def forward(port: int) -> Iterator[str]:
    """kubectl port-forward to the gateway Service. A forward is bound to ONE pod, so it dies when that pod is
    replaced (rollout, drain): tests that roll the gateway open a fresh one afterwards."""
    proc = subprocess.Popen(
        ["kubectl", "-n", NS, "port-forward", f"svc/{RELEASE}-gateway", f"{port}:80"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    url = f"http://127.0.0.1:{port}"
    try:
        if not wait_healthy(url):
            skip_or_fail(f"gateway at {url} not reachable")
        yield url
    finally:
        proc.terminate()


@pytest.fixture(scope="session")
def gateway_url() -> Iterator[str]:
    url = os.getenv("GATEWAY_URL")
    if url:
        if not wait_healthy(url):
            skip_or_fail(f"gateway at {url} not reachable")
        yield url
        return
    if not shutil.which("kubectl"):
        skip_or_fail("kubectl not installed and GATEWAY_URL not set")
    probe = kubectl("-n", NS, "get", "svc", f"{RELEASE}-gateway", check=False)
    if probe.returncode != 0:
        skip_or_fail(
            f"no cluster or release found (svc/{RELEASE}-gateway in {NS}): {probe.stderr.strip()[:120]}"
        )
    with forward(LOCAL_PORT) as forwarded:
        yield forwarded


@pytest.fixture()
def client(gateway_url):
    with httpx.Client(base_url=gateway_url, timeout=25) as c:
        yield c
