"""Runtime configuration from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    upstream_kind: str  # "mock" or "anthropic"
    upstream_url: str
    upstream_model: str
    upstream_timeout_s: float
    anthropic_api_key: str
    policy_path: str
    log_level: str
    # Anthropic's thinking tokens count against max_tokens, so this leaves room for the answer too.
    max_tokens: int = 4096
    effort: str = "low"
    version: str = "dev"

    @classmethod
    def from_env(cls) -> Settings:
        kind = os.getenv("UPSTREAM_KIND", "mock")
        default_url = "http://mock-llm:8080" if kind == "mock" else "https://api.anthropic.com"
        return cls(
            upstream_kind=kind,
            upstream_url=os.getenv("UPSTREAM_URL", default_url),
            upstream_model=os.getenv("UPSTREAM_MODEL", "claude-haiku-5-5"),
            upstream_timeout_s=float(os.getenv("UPSTREAM_TIMEOUT_S", "10")),
            anthropic_api_key=os.getenv("ANTHROPIC_API_KEY", ""),
            policy_path=os.getenv("POLICY_PATH", "/etc/guardrail/policy.yaml"),
            log_level=os.getenv("LOG_LEVEL", "INFO"),
            max_tokens=int(os.getenv("UPSTREAM_MAX_TOKENS", "4096")),
            effort=os.getenv("UPSTREAM_EFFORT", "low"),
            version=os.getenv("GATEWAY_VERSION", "dev"),
        )
