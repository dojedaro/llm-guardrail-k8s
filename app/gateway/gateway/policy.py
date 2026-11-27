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
    pii = raw.get("pii") or {}
    if not isinstance(pii, dict):
        raise PolicyError("'pii' must be a mapping")
    mode = pii.get("mode", "redact")
    if mode not in ("redact", "block"):
        raise PolicyError(f"pii.mode must be 'redact' or 'block', got {mode!r}")
    rules = tuple(pii.get("rules") or ALL_PII_RULES)
    unknown = set(rules) - set(ALL_PII_RULES)
    if unknown:
        raise PolicyError(f"unknown pii rules: {sorted(unknown)}")
    inj = raw.get("injection") or {}
    out = raw.get("output") or {}
    if not isinstance(inj, dict) or not isinstance(out, dict):
        raise PolicyError("'injection' and 'output' must be mappings")
    return Policy(
        version=str(raw["version"]),
        pii_mode=mode,
        pii_rules=rules,
        injection_enabled=bool(inj.get("enabled", True)),
        injection_threshold=int(inj.get("threshold", 3)),
        redact_output=bool(out.get("redact_pii", True)),
    )


def load_policy(path: str | Path) -> Policy:
    with open(path, encoding="utf-8") as fh:
        try:
            return parse_policy(yaml.safe_load(fh))
        except yaml.YAMLError as exc:  # not a ValueError subclass: without this, bad YAML crashed startup
            raise PolicyError(f"policy file is not valid YAML: {exc}") from exc
        except (TypeError, ValueError) as exc:
            raise PolicyError(f"policy value has the wrong type: {exc}") from exc
