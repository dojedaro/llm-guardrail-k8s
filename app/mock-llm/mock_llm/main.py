"""A tiny deterministic fake LLM so the whole stack runs offline.

Fault injection (for incident drills), set via environment variables:
  MOCK_LATENCY_MS   extra delay per request, e.g. 3000
  MOCK_ERROR_RATE   fraction 0..1 of requests that return HTTP 500
"""

from __future__ import annotations

import asyncio
import os
import random

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="mock-llm")


class Message(BaseModel):
    role: str
    content: str


class ChatIn(BaseModel):
    messages: list[Message]


def make_reply(messages: list[Message]) -> str:
    """Deterministic: echoes the last user message. The magic word MOCK_LEAK makes
    the reply contain an email, so the gateway's output guardrail can be tested."""
    last = next((m.content for m in reversed(messages) if m.role == "user"), "")
    reply = f"[mock-llm] You said: {last[:200]}"
    if "MOCK_LEAK" in last:
        reply += " | contact: leaked.user@example.com"
    return reply


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}  # never faulted, so drills break the service, not the pod


@app.post("/v1/chat")
async def chat(body: ChatIn) -> dict[str, str]:
    delay_ms = float(os.getenv("MOCK_LATENCY_MS", "0"))
    if delay_ms > 0:
        await asyncio.sleep(delay_ms / 1000)
    if random.random() < float(os.getenv("MOCK_ERROR_RATE", "0")):
        raise HTTPException(status_code=500, detail="injected fault")
    return {"reply": make_reply(body.messages), "model": "mock-1"}
