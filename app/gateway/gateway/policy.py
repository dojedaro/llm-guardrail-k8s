"""Policy loading. The policy is a YAML file mounted from a ConfigMap."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

ALL_PII_RULES = ("email", "phone", "credit_card", "kr_rrn", "secret")


@dataclass(frozen=True)
class Policy:
    version: str = "builtin-default"
    pii_mode: str = "redact"  # "redact" or "block"
    pii_rules: tuple[str, ...] = ALL_PII_RULES
    injection_enabled: bool = True
    injection_threshold: int = 3  # sum of rule weights that triggers a block
    redact_output: bool = True


class PolicyError(ValueError):
    pass


def parse_policy(raw: Any) -> Policy:
    """Validate a parsed YAML document and turn it into a Policy."""
    if not isinstance(raw, dict) or "version" not in raw:
        raise PolicyError("policy must be a mapping with a 'version' key")
    pii = raw.get("pii", {})
    mode = pii.get("mode", "redact")
    if mode not in ("redact", "block"):
        raise PolicyError(f"pii.mode must be 'redact' or 'block', got {mode!r}")
    rules = tuple(pii.get("rules", ALL_PII_RULES))
    unknown = set(rules) - set(ALL_PII_RULES)
    if unknown:
        raise PolicyError(f"unknown pii rules: {sorted(unknown)}")
    inj = raw.get("injection", {})
    return Policy(
        version=str(raw["version"]),
        pii_mode=mode,
        pii_rules=rules,
        injection_enabled=bool(inj.get("enabled", True)),
        injection_threshold=int(inj.get("threshold", 3)),
        redact_output=bool(raw.get("output", {}).get("redact_pii", True)),
    )


def load_policy(path: str | Path) -> Policy:
    with open(path, encoding="utf-8") as fh:
        return parse_policy(yaml.safe_load(fh))
