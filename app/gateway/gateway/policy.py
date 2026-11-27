"""Policy loading. The policy is a YAML file mounted from a ConfigMap."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, get_args

import yaml

PiiRule = Literal["email", "phone", "credit_card", "kr_rrn", "secret"]
PiiMode = Literal["redact", "block"]
ALL_PII_RULES: tuple[PiiRule, ...] = get_args(PiiRule)
_PII_MODES: tuple[PiiMode, ...] = get_args(PiiMode)


@dataclass(frozen=True)
class Policy:
    version: str = "builtin-default"
    pii_mode: PiiMode = "redact"
    pii_rules: tuple[PiiRule, ...] = ALL_PII_RULES
    injection_enabled: bool = True
    injection_threshold: int = 3  # the injection score one message needs to be blocked
    redact_output: bool = True


class PolicyError(ValueError):
    pass


def _mapping(raw: dict[str, Any], key: str) -> dict[str, Any]:
    section = raw.get(key) or {}
    if not isinstance(section, dict):
        raise PolicyError(f"'{key}' must be a mapping")
    return section


def _pii_rules(pii: dict[str, Any]) -> tuple[PiiRule, ...]:
    rules = pii.get("rules")
    if rules is None:
        return ALL_PII_RULES
    if not isinstance(rules, list) or not rules or not all(isinstance(r, str) for r in rules):
        raise PolicyError(f"pii.rules must be a non-empty list of {list(ALL_PII_RULES)}")
    unknown = sorted(set(rules) - set(ALL_PII_RULES))
    if unknown:
        raise PolicyError(f"unknown pii rules: {unknown}")
    return tuple(r for r in ALL_PII_RULES if r in rules)


def _threshold(inj: dict[str, Any]) -> int:
    value = inj.get("threshold", 3)
    # bool is an int subclass; a threshold of 0 or less would block every request.
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise PolicyError(f"injection.threshold must be an integer >= 1, got {value!r}")
    return value


def parse_policy(raw: Any) -> Policy:
    """Validate a parsed YAML document and turn it into a Policy."""
    if not isinstance(raw, dict) or "version" not in raw:
        raise PolicyError("policy must be a mapping with a 'version' key")
    pii, inj, out = _mapping(raw, "pii"), _mapping(raw, "injection"), _mapping(raw, "output")
    mode = pii.get("mode", "redact")
    if mode not in _PII_MODES:
        raise PolicyError(f"pii.mode must be 'redact' or 'block', got {mode!r}")
    return Policy(
        version=str(raw["version"]),
        pii_mode=mode,
        pii_rules=_pii_rules(pii),
        injection_enabled=bool(inj.get("enabled", True)),
        injection_threshold=_threshold(inj),
        redact_output=bool(out.get("redact_pii", True)),
    )


def load_policy(path: str | Path) -> Policy:
    with open(path, encoding="utf-8") as fh:
        try:
            return parse_policy(yaml.safe_load(fh))
        except yaml.YAMLError as exc:  # not a ValueError subclass: without this, bad YAML crashed startup
            raise PolicyError(f"policy file is not valid YAML: {exc}") from exc
