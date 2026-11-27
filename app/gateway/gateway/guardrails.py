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

# Quantifiers are bounded on purpose: an unbounded local-part scan is quadratic on input such as
# "a.a.a.a." (0.4 s per 20 kB measured before the fix), and guardrails sit on the request path.
EMAIL = re.compile(
    r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24}"
)
# A run of digit groups separated by single spaces or hyphens. Card detection then tries Luhn on
# the whole run and on runs of 1-5 consecutive groups, so "order 12345 4111 1111 1111 1111" and a
# card after a date or phone number are still found.
DIGIT_RUN = re.compile(r"(?<!\d)\d+(?:[ -]\d+){0,11}(?!\d)")
RRN = re.compile(r"(?<!\d)(\d{6})[- ]?([1-8]\d{6})(?!\d)")
# Korean mobile/landline (010-1234-5678, 010.1234.5678, 02-123-4567, +82 10 1234 5678) and
# generic international numbers written with a leading + (optionally with (area) parentheses).
_SEP = r"[ .-]?"
PHONE = re.compile(
    r"(?<![\d-])(?:\+82[ -]?0?\d{1,2}" + _SEP + r"\d{3,4}" + _SEP + r"\d{4}"
    r"|0(?:1[016-9]|2|[3-6]\d)" + _SEP + r"\d{3,4}" + _SEP + r"\d{4}"
    r"|\+\d{1,3}[ -]?\(?\d{2,4}\)?[ -]?\d{3,4}[ -]?\d{3,4})(?![\d-])"
)
SECRET = re.compile(
    r"\b(?:sk-ant-[A-Za-z0-9_-]{20,}|sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}"
    r"|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"
    r"|-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----.{0,4000}?(?:-----END [A-Z ]{0,20}PRIVATE KEY-----|\Z)",
    re.S,
)

PLACEHOLDER = {
    "email": "[REDACTED_EMAIL]",
    "phone": "[REDACTED_PHONE]",
    "credit_card": "[REDACTED_CARD]",
    "kr_rrn": "[REDACTED_KR_RRN]",
    "secret": "[REDACTED_SECRET]",
}


def _cards_in_run(run: str, offset: int) -> list[Finding]:
    """Find Luhn-valid 13-19 digit card numbers made of 1-5 consecutive digit groups in a run."""
    groups = [(g.start(), g.end()) for g in re.finditer(r"\d+", run)]
    found: list[Finding] = []
    i = 0
    while i < len(groups):
        hit = None
        for j in range(min(len(groups), i + 5), i, -1):  # longest candidate first
            digits = re.sub(r"\D", "", run[groups[i][0] : groups[j - 1][1]])
            if 13 <= len(digits) <= 19 and luhn_valid(digits):
                hit = j
                break
        if hit:
            found.append(Finding("credit_card", offset + groups[i][0], offset + groups[hit - 1][1]))
            i = hit
        else:
            i += 1
    return found


def _scan(rule: str, text: str) -> list[Finding]:
    out: list[Finding] = []
    if rule == "email":
        out = [Finding(rule, m.start(), m.end()) for m in EMAIL.finditer(text)]
    elif rule == "secret":
        out = [Finding(rule, m.start(), m.end()) for m in SECRET.finditer(text)]
    elif rule == "credit_card":
        for m in DIGIT_RUN.finditer(text):
            out += _cards_in_run(m.group(), m.start())
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

# (rule id, weight, pattern). Weights are summed; policy.injection_threshold (default 3) decides.
# A single weight-3 rule blocks on its own, so those rules are written narrowly: they need the
# verb, the target ("previous instructions") and nothing that makes it ordinary text
# ("ignore the formatting rules in my previous email" must not match).
_TARGET = r"(?:instructions?|rules?|prompts?|guidelines?|directions?|messages?|context)"
_PRIOR = r"(?:previous|prior|above|earlier|preceding|former|original|system)"
INJECTION_RULES: tuple[tuple[str, int, re.Pattern[str]], ...] = (
    (
        "inj_ignore_previous",
        3,
        re.compile(
            r"\b(?:ignore|disregard|forget|override|bypass)\s+(?:all\s+|any\s+|every\s+)?(?:of\s+)?"
            r"(?:the\s+|your\s+|my\s+|these\s+|those\s+)?" + _PRIOR + r"\s+" + _TARGET + r"\b"
            r"|\b(?:ignore|disregard|forget)\s+(?:all\s+|any\s+)?(?:the\s+|your\s+)?"
            + _TARGET
            + r"\s+(?:above|before)\b"
            r"|\b(?:forget|ignore|disregard)\s+(?:everything|anything)\s+(?:above|before|you\s+(?:were|have\s+been)\s+told)\b",
            re.I,
        ),
    ),
    (
        "inj_reveal_system_prompt",
        3,
        re.compile(
            r"\b(?:reveal|show|print|repeat|leak|output|display|tell\s+me)\b(?:\s+me)?\s+(?:all\s+)?"
            r"(?:of\s+)?(?:your|the|its)\s+(?:system|hidden|initial|original|secret|internal)\s+"
            r"(?:prompt|instructions?|message)s?\b",
            re.I,
        ),
    ),
    (
        "inj_repeat_above",
        3,
        re.compile(r"\brepeat\s+(?:the\s+|all\s+)?(?:text|words|everything)\s+above\b", re.I),
    ),
    (
        "inj_no_restrictions",
        3,
        re.compile(
            r"\b(?:pretend|act|behave|imagine|respond)\b.{0,40}\b(?:no|without|free\s+(?:of|from))\s+"
            r"(?:any\s+)?(?:content\s+)?(?:restrictions?|rules|filters?|limits|limitations|guidelines|censorship)\b"
            r"|\b(?:act|behave|respond)\s+as\s+(?:an?\s+)?(?:unrestricted|unfiltered|uncensored)\b"
            r"|\banswer\s+without\s+(?:any\s+)?(?:restrictions?|filters?|limits|censorship)\b",
            re.I | re.S,
        ),
    ),
    (
        "inj_role_override",
        2,
        re.compile(
            r"\byou\s+are\s+now\b|\bact\s+as\s+(?:an?\s+)?(?:dan|unrestricted)\b"
            r"|\bfrom\s+now\s+on,?\s+you\s+(?:will|are|must)\b",
            re.I,
        ),
    ),
    (
        "inj_jailbreak_keywords",
        2,
        re.compile(r"\b(jailbreak|developer\s+mode|do\s+anything\s+now|DAN)\b", re.I),
    ),
    (
        "inj_fake_system_tag",
        2,
        re.compile(r"<\s*/?\s*system\s*>|\[\s*system\s*\]|###\s*system|\bnew\s+instructions\s*:", re.I),
    ),
    # Korean (no \b: Hangul is matched as substrings, with particles allowed after the noun).
    (
        "inj_ko_ignore_previous",
        3,
        re.compile(
            r"(?:이전|위의|앞의|기존|모든)\s*(?:모든\s*)?(?:지시|지침|명령|프롬프트|규칙)(?:사항|들)?[을를은는]?\s*(?:모두\s*)?(?:무시|잊어|따르지)"
        ),
    ),
    (
        "inj_ko_reveal_prompt",
        3,
        re.compile(
            r"(?:시스템\s*프롬프트|시스템\s*메시지|숨겨진\s*(?:지시|프롬프트)|초기\s*지시).{0,15}(?:알려|보여|출력|공개|말해)"
        ),
    ),
    (
        "inj_ko_role_override",
        2,
        re.compile(r"지금부터\s*(?:너는|넌|당신은).{0,15}(?:제한\s*없는|무제한|필터\s*없는)"),
    ),
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
        if policy.injection_enabled:  # every role: system/assistant text reaches the model too
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
