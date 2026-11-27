"""Input/output guardrails: PII detection and prompt-injection heuristics.

These are heuristics. They catch common, well-formed patterns and obvious
injection phrasing. They do NOT catch paraphrased, encoded, translated or
multi-turn attacks, and they are not a substitute for a real security review.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .policy import Policy


@dataclass(frozen=True)
class Finding:
    rule: str
    start: int
    end: int


# ---- validators -----------------------------------------------------------


def luhn_valid(digits: str) -> bool:
    """Luhn checksum, used to cut false positives on 13-19 digit numbers."""
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def rrn_valid(front: str, back: str) -> bool:
    """Plausibility check for a Korean resident registration number.

    Checks month/day ranges and the century/sex digit. The official checksum
    is deliberately not enforced: numbers issued after 2020 are randomised and
    do not satisfy it, and redacting a false positive is the safer failure.
    """
    month, day = int(front[2:4]), int(front[4:6])
    return 1 <= month <= 12 and 1 <= day <= 31 and back[0] in "12345678"


# ---- PII patterns ---------------------------------------------------------

EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
CARD = re.compile(r"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)")
RRN = re.compile(r"(?<!\d)(\d{6})[- ]?([1-8]\d{6})(?!\d)")
# Korean mobile/landline (010-1234-5678, 02-123-4567, +82 10 1234 5678) and
# generic international numbers written with a leading +.
PHONE = re.compile(
    r"(?<![\d-])(?:\+82[ -]?0?\d{1,2}[ -]?\d{3,4}[ -]?\d{4}"
    r"|0(?:1[016-9]|2|[3-6]\d)[ -]?\d{3,4}[ -]?\d{4}"
    r"|\+\d{1,3}[ -]?\d{2,4}[ -]?\d{3,4}[ -]?\d{3,4})(?![\d-])"
)
SECRET = re.compile(
    r"\b(?:sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}"
    r"|gh[pousr]_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]{10,})"
)

PLACEHOLDER = {
    "email": "[REDACTED_EMAIL]",
    "phone": "[REDACTED_PHONE]",
    "credit_card": "[REDACTED_CARD]",
    "kr_rrn": "[REDACTED_KR_RRN]",
    "secret": "[REDACTED_SECRET]",
}


def _scan(rule: str, text: str) -> list[Finding]:
    out: list[Finding] = []
    if rule == "email":
        out = [Finding(rule, m.start(), m.end()) for m in EMAIL.finditer(text)]
    elif rule == "secret":
        out = [Finding(rule, m.start(), m.end()) for m in SECRET.finditer(text)]
    elif rule == "credit_card":
        for m in CARD.finditer(text):
            digits = re.sub(r"\D", "", m.group())
            if 13 <= len(digits) <= 19 and luhn_valid(digits):
                out.append(Finding(rule, m.start(), m.end()))
    elif rule == "kr_rrn":
        for m in RRN.finditer(text):
            if rrn_valid(m.group(1), m.group(2)):
                out.append(Finding(rule, m.start(), m.end()))
    elif rule == "phone":
        out = [Finding(rule, m.start(), m.end()) for m in PHONE.finditer(text)]
    return out


# Earlier rules win when two matches overlap (a card number also looks like a phone).
_PRIORITY = ("secret", "credit_card", "kr_rrn", "email", "phone")


def detect_pii(text: str, rules: tuple[str, ...]) -> list[Finding]:
    """Return non-overlapping findings, sorted by position."""
    taken: list[Finding] = []
    for rule in _PRIORITY:
        if rule not in rules:
            continue
        for f in _scan(rule, text):
            if not any(f.start < t.end and t.start < f.end for t in taken):
                taken.append(f)
    return sorted(taken, key=lambda f: f.start)


def redact(text: str, findings: list[Finding]) -> str:
    out, pos = [], 0
    for f in findings:
        out.append(text[pos : f.start])
        out.append(PLACEHOLDER[f.rule])
        pos = f.end
    out.append(text[pos:])
    return "".join(out)


# ---- prompt injection heuristics -----------------------------------------

# (rule id, weight, pattern). Weights are summed; policy.injection_threshold decides.
INJECTION_RULES: tuple[tuple[str, int, re.Pattern[str]], ...] = (
    (
        "inj_ignore_previous",
        3,
        re.compile(
            r"\b(ignore|disregard|forget|override)\b.{0,30}\b(previous|prior|above|earlier|all)\b"
            r".{0,30}\b(instructions?|rules?|prompts?|guidelines?)\b",
            re.I | re.S,
        ),
    ),
    (
        "inj_reveal_system_prompt",
        3,
        re.compile(
            r"\b(reveal|show|print|repeat|leak|output)\b.{0,40}\b(system|hidden|initial)\b"
            r".{0,10}\b(prompt|instructions?|message)\b",
            re.I | re.S,
        ),
    ),
    ("inj_role_override", 2, re.compile(r"\byou are now\b|\bact as (?:an? )?(?:dan|unrestricted)\b", re.I)),
    ("inj_jailbreak_keywords", 2, re.compile(r"\b(jailbreak|developer mode|do anything now)\b", re.I)),
    ("inj_fake_system_tag", 2, re.compile(r"<\s*/?\s*system\s*>|\[\s*system\s*\]|###\s*system", re.I)),
)


def detect_injection(text: str) -> list[tuple[str, int]]:
    return [(rid, w) for rid, w, pat in INJECTION_RULES if pat.search(text)]


# ---- top-level entry points ----------------------------------------------


@dataclass
class InputResult:
    decision: str  # "allow" | "redacted" | "blocked"
    messages: list[dict[str, str]]
    hits: dict[str, int]
    reason: str | None = None


def _count(rules: list[str]) -> dict[str, int]:
    hits: dict[str, int] = {}
    for r in rules:
        hits[r] = hits.get(r, 0) + 1
    return hits


def check_input(messages: list[dict[str, str]], policy: Policy) -> InputResult:
    """Apply policy to every message. Never mutates the caller's list."""
    rule_hits: list[str] = []
    cleaned: list[dict[str, str]] = []
    inj_score = 0
    for msg in messages:
        text = msg["content"]
        if policy.injection_enabled and msg["role"] == "user":
            inj = detect_injection(text)
            rule_hits += [rid for rid, _ in inj]
            inj_score += sum(w for _, w in inj)
        findings = detect_pii(text, policy.pii_rules)
        rule_hits += [f.rule for f in findings]
        cleaned.append({"role": msg["role"], "content": redact(text, findings)})

    hits = _count(rule_hits)
    if policy.injection_enabled and inj_score >= policy.injection_threshold:
        return InputResult("blocked", [], hits, "prompt_injection")
    pii_hit = any(not k.startswith("inj_") for k in hits)
    if pii_hit and policy.pii_mode == "block":
        return InputResult("blocked", [], hits, "pii")
    return InputResult("redacted" if pii_hit else "allow", cleaned, hits)


def check_output(text: str, policy: Policy) -> tuple[str, dict[str, int]]:
    if not policy.redact_output:
        return text, {}
    findings = detect_pii(text, policy.pii_rules)
    return redact(text, findings), _count([f.rule for f in findings])
