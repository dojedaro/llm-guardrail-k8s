"""Input/output guardrails: PII detection and prompt-injection heuristics.

These are heuristics. They catch common, well-formed patterns and obvious
injection phrasing. They do NOT catch paraphrased, encoded, translated or
multi-turn attacks, and they are not a substitute for a real security review.
"""

from __future__ import annotations

import re
from bisect import bisect_right
from dataclasses import dataclass
from typing import Literal

from .policy import PiiRule, Policy

Decision = Literal["allow", "redacted", "blocked"]


@dataclass(frozen=True)
class Finding:
    rule: PiiRule
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
# "a.a.a.a." (0.4 s per 20 kB measured), and guardrails sit on the request path. There is no lookbehind:
# with one, a local part longer than 64 characters (or glued to a long token) was never matched at all.
# Now the 64 characters before the "@" are redacted, which is the longest local part RFC 5321 allows.
EMAIL = re.compile(r"[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24}")
# A run of digit groups separated by one or two spaces, dots, hyphens or line breaks, however long. Card detection then tries
# Luhn on runs of 1-5 consecutive groups, so "order 12345 4111 1111 1111 1111" and a card after a
# date, a phone number or any amount of other digits are still found. Linear: a separator is required
# between groups, so the engine never re-reads a group.
DIGIT_RUN = re.compile(r"(?<!\d)\d+(?:[ .\-\r\n]{1,2}\d+)*(?!\d)")
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
    # A PEM key: everything up to its END line (or the end of the text if it is cut off). The body may not
    # contain a run of 4+ dashes, so the scan stops at the next marker instead of rescanning the whole text
    # from every BEGIN, and no key length limit is needed beyond the 20,000-character message limit.
    r"|-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----(?:[^-]|-(?!-{4})){0,20000}(?:-----END [A-Z ]{0,20}PRIVATE KEY-----)?"
)

PLACEHOLDER: dict[PiiRule, str] = {
    "email": "[REDACTED_EMAIL]",
    "phone": "[REDACTED_PHONE]",
    "credit_card": "[REDACTED_CARD]",
    "kr_rrn": "[REDACTED_KR_RRN]",
    "secret": "[REDACTED_SECRET]",
}


def card_issuer_plausible(digits: str) -> bool:
    """Does the number start like a real card scheme and have a length that scheme issues?

    Luhn alone passes one random number in ten; requiring a known prefix and length removes most of
    those. Schemes: Visa, Mastercard (51-55, 2221-2720), American Express, Discover, UnionPay, JCB,
    Diners Club and Maestro. A card from another scheme can slip through: the check trades a few
    misses for far fewer false positives.
    """
    n, p2, p3, p4 = len(digits), int(digits[:2]), int(digits[:3]), int(digits[:4])
    if digits[0] == "4":
        return n in (13, 16, 19)
    if 51 <= p2 <= 55 or 2221 <= p4 <= 2720:
        return n == 16
    if p2 in (34, 37):
        return n == 15
    if p2 in (36, 38, 39) or 300 <= p3 <= 305:
        return 14 <= n <= 19
    if p2 == 35:
        return 16 <= n <= 19
    if digits[0] == "6" or p2 == 50 or 56 <= p2 <= 58:
        return 12 <= n <= 19
    return False


def _cards_in_run(run: str, offset: int) -> list[Finding]:
    """Find card numbers made of 1-5 consecutive digit groups in a run: Luhn-valid, plausible issuer."""
    groups = [(g.start(), g.end()) for g in re.finditer(r"\d+", run)]
    found: list[Finding] = []
    i = 0
    while i < len(groups):
        hit = None
        for j in range(min(len(groups), i + 5), i, -1):  # longest candidate first
            digits = re.sub(r"\D", "", run[groups[i][0] : groups[j - 1][1]])
            if 13 <= len(digits) <= 19 and luhn_valid(digits) and card_issuer_plausible(digits):
                hit = j
                break
        if hit:
            found.append(Finding("credit_card", offset + groups[i][0], offset + groups[hit - 1][1]))
            i = hit
        else:
            i += 1
    return found


def _scan(rule: PiiRule, text: str) -> list[Finding]:
    if rule == "email":
        return [Finding(rule, m.start(), m.end()) for m in EMAIL.finditer(text)]
    if rule == "secret":
        return [Finding(rule, m.start(), m.end()) for m in SECRET.finditer(text)]
    if rule == "credit_card":
        return [f for m in DIGIT_RUN.finditer(text) for f in _cards_in_run(m.group(), m.start())]
    if rule == "kr_rrn":
        return [
            Finding(rule, m.start(), m.end()) for m in RRN.finditer(text) if rrn_valid(m.group(1), m.group(2))
        ]
    return [Finding(rule, m.start(), m.end()) for m in PHONE.finditer(text)]


# Earlier rules win when two matches overlap (a card number also looks like a phone).
_PRIORITY: tuple[PiiRule, ...] = ("secret", "credit_card", "kr_rrn", "email", "phone")


def detect_pii(text: str, rules: tuple[PiiRule, ...]) -> list[Finding]:
    """Return non-overlapping findings, sorted by position.

    `taken` stays sorted and non-overlapping, so a candidate can only collide with its two neighbours
    and one bisect per candidate decides it: O(n log n) overall, not the O(n^2) of comparing every pair.
    """
    taken: list[Finding] = []
    for rule in _PRIORITY:
        if rule not in rules:
            continue
        starts = [t.start for t in taken]
        ends = [t.end for t in taken]
        accepted = []
        for f in _scan(rule, text):
            k = bisect_right(starts, f.start)  # index of the first taken span that starts after f does
            before_ok = k == 0 or ends[k - 1] <= f.start
            after_ok = k == len(taken) or starts[k] >= f.end
            if before_ok and after_ok:
                accepted.append(f)
        taken = sorted(taken + accepted, key=lambda t: t.start)
    return taken


def redact(text: str, findings: list[Finding]) -> str:
    out, pos = [], 0
    for f in findings:
        out.append(text[pos : f.start])
        out.append(PLACEHOLDER[f.rule])
        pos = f.end
    out.append(text[pos:])
    return "".join(out)


# ---- prompt injection heuristics -----------------------------------------

# (rule id, weight, pattern). A request is blocked when any ONE message reaches policy.injection_threshold
# (default 3), counting each rule once per message. Scores are never added up across messages: a long benign
# conversation that touches the same topic in several turns must not add up to a block. A single weight-3
# rule blocks on its own, so those rules are written narrowly: they need the verb, the target ("previous
# instructions") and nothing that makes it ordinary text ("ignore the formatting rules in my previous
# email" must not match).
_TARGET = r"(?:instructions?|rules?|prompts?|guidelines?|directions?)"
_PRIOR = r"(?:previous|prior|above|earlier|preceding|former)"
# Verbs that drop instructions: "ignore", "do not follow", "stop following".
_DROP = r"(?:ignore|disregard|forget|override|bypass|(?:do\s+not|don'?t|stop)\s+follow(?:ing)?)"
# The model's own prompt, as an attack names it ("your system prompt", "your instructions").
_OWN_PROMPT = (
    r"(?:(?:system|hidden|initial|original|secret|internal|full|exact|developer)\s+)?"
    r"(?:prompt|instructions?|rules|guidelines)"
)
_MODEL_NOUN = r"(?:ai|assistant|model|chatbot|bot|llm|gpt)"
_NO_LIMITS = (
    r"(?:no|without|free\s+(?:of|from))\s+(?:any\s+)?(?:content\s+|safety\s+)?"
    r"(?:restrictions?|rules|filters?|limits|limitations|guidelines|censorship)\b"
)
INJECTION_RULES: tuple[tuple[str, int, re.Pattern[str]], ...] = (
    (
        "inj_ignore_previous",
        3,
        re.compile(
            # "ignore all previous instructions", "do not follow the prior rules"
            r"\b" + _DROP + r"\s+(?:all\s+|any\s+|every\s+)?(?:of\s+)?"
            r"(?:the\s+|your\s+|my\s+|these\s+|those\s+)?" + _PRIOR + r"\s+" + _TARGET + r"\b"
            # "ignore your instructions", "disregard your system prompt", "stop following your rules"
            r"|\b" + _DROP + r"\s+(?:all\s+|any\s+)?(?:of\s+)?your\s+" + _OWN_PROMPT + r"\b"
            # "ignore the system prompt"
            r"|\b"
            + _DROP
            + r"\s+(?:all\s+|any\s+)?(?:the\s+)?(?:system|developer)\s+(?:prompt|instructions?)\b"
            # "ignore all instructions above"
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
            # "reveal your system prompt", "repeat your instructions", "leak its hidden prompt"
            r"\b(?:reveal|show|print|repeat|leak|output|display|disclose|tell\s+me)\b(?:\s+me)?\s+(?:all\s+)?(?:of\s+)?"
            r"(?:your|its)\s+" + _OWN_PROMPT + r"\b"
            # "show the system prompt": "the" is accepted only with "prompt"; "the system message" and
            # "the internal instructions" are everyday phrases
            r"|\b(?:reveal|show|print|repeat|leak|output|display|disclose)\b(?:\s+me)?\s+(?:all\s+)?(?:of\s+)?"
            r"the\s+(?:system|hidden|initial|secret)\s+prompt\b"
            # "what is your system prompt?"
            r"|\bwhat(?:'s|\s+is|\s+are)\s+your\s+"
            r"(?:(?:system|hidden|initial|original|secret|full|exact)\s+(?:prompt|instructions?)|prompt)\b",
            re.I,
        ),
    ),
    (
        "inj_repeat_above",
        3,
        re.compile(
            r"\b(?:repeat|print|output|copy)\s+(?:the\s+|all\s+)?(?:text|words|everything)\s+above\b"
            r"|\b(?:repeat|print|output|copy)\s+everything\s+(?:above|before)\s+this\s+(?:line|point|message)\b",
            re.I,
        ),
    ),
    (
        "inj_no_restrictions",
        3,
        re.compile(
            # "pretend you have no restrictions", "act as if you were free of any rules": the subject is the model
            r"\b(?:pretend|act|behave|respond|answer)\b.{0,40}\byou\b.{0,30}\b"
            + _NO_LIMITS
            # "act as an AI with no restrictions"
            + r"|\b(?:act|behave|respond)\s+as\s+(?:an?\s+)?(?:\w+\s+)?"
            + _MODEL_NOUN
            + r"\b.{0,20}\b(?:with|having)\s+"
            + _NO_LIMITS
            + r"|\b(?:act|behave|respond)\s+as\s+(?:an?\s+)?(?:unrestricted|unfiltered|uncensored)\s+"
            + _MODEL_NOUN
            + r"\b"
            r"|\banswer\s+without\s+(?:any\s+)?(?:restrictions?|filters?|limits|censorship)\b",
            re.I | re.S,
        ),
    ),
    (
        "inj_role_override",
        2,
        # Case-insensitive except the persona name: "Dan, you are now the owner" is a person, "DAN" is the jailbreak.
        re.compile(
            r"(?i:\byou\s+are\s+now\b|\bact\s+as\s+(?:an?\s+)?unrestricted\b"
            r"|\bfrom\s+now\s+on,?\s+you\s+(?:will|are|must)\b)"
            r"|(?i:\b(?:act\s+as\s+(?:an?\s+)?|you\s+are\s+(?:now\s+)?))DAN\b"
        ),
    ),
    (
        "inj_jailbreak_keywords",
        2,
        re.compile(r"(?i:\bjailbreak\b|\bdeveloper\s+mode\b|\bdo\s+anything\s+now\b)|\bDAN\b"),
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
            r"(?:이전|위의|앞의|기존|모든)\s*(?:모든\s*)?(?:지시|지침|명령|프롬프트|규칙)(?:사항|들)?[을를은는]?\s*(?:모두\s*)?"
            r"(?:무시\s*(?:하세요|하십시오|하라|하고|해\s*(?:주세요|줘|라|요)?|해라)|잊어\s*(?:버려|버리세요|줘|라|주세요)|따르지\s*마)"
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
    decision: Decision
    messages: list[dict[str, str]]
    hits: dict[str, int]
    reason: Literal["prompt_injection", "pii"] | None = None


def _count(rules: list[str]) -> dict[str, int]:
    hits: dict[str, int] = {}
    for r in rules:
        hits[r] = hits.get(r, 0) + 1
    return hits


def check_input(messages: list[dict[str, str]], policy: Policy) -> InputResult:
    """Apply policy to every message. Never mutates the caller's list."""
    rule_hits: list[str] = []
    cleaned: list[dict[str, str]] = []
    worst_injection = 0  # highest score of any single message
    for msg in messages:
        text = msg["content"]
        if policy.injection_enabled:  # every role: system/assistant text reaches the model too
            inj = detect_injection(text)
            rule_hits += [rid for rid, _ in inj]
            worst_injection = max(worst_injection, sum(w for _, w in inj))
        findings = detect_pii(text, policy.pii_rules)
        rule_hits += [f.rule for f in findings]
        cleaned.append({"role": msg["role"], "content": redact(text, findings)})

    hits = _count(rule_hits)
    if policy.injection_enabled and worst_injection >= policy.injection_threshold:
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
