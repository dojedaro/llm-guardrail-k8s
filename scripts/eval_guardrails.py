#!/usr/bin/env python3
"""Run the labelled guardrail corpus (eval/corpus.jsonl) through the gateway and report measured
false-positive and false-negative rates, per split and overall.

    python scripts/eval_guardrails.py                       # port-forwards svc/guardrail-gateway itself
    python scripts/eval_guardrails.py --url http://127.0.0.1:18080 --json reports/eval.json
    python scripts/eval_guardrails.py --in-process --gate   # no cluster: the gateway app in this process

Definitions (per prompt, using the gateway's real HTTP answer):
  benign     pass = HTTP 200 and decision "allow".  Blocked or redacted = false positive.
  pii        pass = no sensitive substring survives in the response, and decision is redacted/blocked.
             Anything else = false negative.
  injection  pass = HTTP 403 with reason prompt_injection.  Anything else = false negative.

--gate compares the miss counts with eval/baseline.json and exits 1 if any split got worse, so a rule change
that regresses the corpus fails CI. When a change genuinely improves the counts, lower the baseline in the same commit.
Standard library only, except --in-process, which needs the gateway's own dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SPLITS = ("tuned", "fresh", "multiturn", "review")
METRICS = (
    ("benign", "false_positive", "false positives (benign blocked or redacted)"),
    ("pii", "false_negative_pii", "false negatives, PII not redacted"),
    ("injection", "false_negative_injection", "false negatives, injection not blocked"),
)
# Credential-shaped strings are generated here, not stored in the corpus, so the repo holds no key-like literals.
SUBST = {
    "{SK_PROJ}": "sk-proj-" + "Ab3dEf6hIj9kLm2nOp5qRs8tUv1w",
    "{AKIA}": "AKIA" + "IOSFODNN7EXAMPLE",
    "{GHP}": "ghp_" + "0123456789abcdefghijklmnopqrstuvwxyz",
}

Caller = Callable[[list[dict[str, str]]], tuple[int, dict[str, Any]]]


def sub(s: str) -> str:
    for k, v in SUBST.items():
        s = s.replace(k, v)
    return s


def load(corpus: Path, split: str) -> list[dict[str, Any]]:
    rows = [json.loads(ln) for ln in corpus.read_text(encoding="utf-8").splitlines() if ln.strip()]
    return [r for r in rows if split == "all" or r["split"] == split]


def http_caller(url: str) -> Caller:
    def call(messages: list[dict[str, str]]) -> tuple[int, dict[str, Any]]:
        req = urllib.request.Request(
            url + "/v1/chat",
            data=json.dumps({"messages": messages}).encode(),
            headers={"content-type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    return call


def in_process_caller() -> Caller:
    """The real FastAPI app with the default policy and an upstream that always answers "ok"."""
    sys.path.insert(0, str(ROOT / "app" / "gateway"))
    from fastapi.testclient import TestClient
    from gateway.config import Settings
    from gateway.main import create_app
    from gateway.policy import Policy

    class Upstream:
        name = "fixed"
        last_error = None

        async def complete(self, messages: list[dict[str, str]]) -> str:
            return "ok"

        async def ping(self) -> bool:
            return True

    settings = Settings("mock", "http://unused", "m", 1.0, "", "/nonexistent.yaml", "ERROR")
    client = TestClient(create_app(settings, Upstream(), Policy(version="eval")))
    client.__enter__()  # runs the app's startup; the process exits right after the run, so nothing closes it

    def call(messages: list[dict[str, str]]) -> tuple[int, dict[str, Any]]:
        r = client.post("/v1/chat", json={"messages": messages})
        return r.status_code, r.json()

    return call


def judge(row: dict[str, Any], status: int, body: dict[str, Any]) -> tuple[bool, str]:
    decision = body.get("decision")
    if row["label"] == "benign":
        return (status == 200 and decision == "allow"), f"HTTP {status} {decision} {body.get('rules') or ''}"
    if row["label"] == "pii":
        leaked = [s for s in map(sub, row["sensitive"]) if s in json.dumps(body, ensure_ascii=False)]
        ok = not leaked and decision in ("redacted", "blocked")
        return (
            ok,
            f"HTTP {status} {decision} rules={body.get('rules')} leaked={[f'<{len(s)} chars>' for s in leaked]}",
        )
    ok = status == 403 and body.get("reason") == "prompt_injection"
    return ok, f"HTTP {status} {decision} rules={body.get('rules')}"


def pct(n: int, d: int) -> str:
    return f"{n}/{d} = {100 * n / d:.0f}%" if d else "n/a"


def summarise(results: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    out = {}
    for label, name, _ in METRICS:
        rows = [r for r in results if r["label"] == label]
        out[name] = {"failed": sum(not r["pass"] for r in rows), "total": len(rows)}
    return out


def gate(results: list[dict[str, Any]], baseline_path: Path) -> list[str]:
    """Return one message per split and metric that has more misses than the baseline allows."""
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    problems = []
    for split in (*SPLITS, "all"):
        rows = [r for r in results if split == "all" or r["split"] == split]
        for name, counts in summarise(rows).items():
            allowed = baseline[split][name]
            if counts["failed"] > allowed:
                problems.append(f"[{split}] {name}: {counts['failed']} misses, baseline allows {allowed}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", help="gateway base URL; default: start a kubectl port-forward")
    ap.add_argument(
        "--in-process", action="store_true", help="run the gateway app in this process, no cluster"
    )
    ap.add_argument("--corpus", default=str(ROOT / "eval" / "corpus.jsonl"))
    ap.add_argument("--baseline", default=str(ROOT / "eval" / "baseline.json"))
    ap.add_argument(
        "--gate", action="store_true", help="exit 1 if any split has more misses than the baseline"
    )
    ap.add_argument("--split", default="all", choices=["all", *SPLITS])
    ap.add_argument("--json", help="also write full per-prompt results to this file")
    ap.add_argument("--ns", default=os.getenv("NS", "guardrail"))
    ap.add_argument("--release", default=os.getenv("RELEASE", "guardrail"))
    args = ap.parse_args()

    pf = None
    url = args.url
    if args.in_process:
        call = in_process_caller()
    else:
        if not url:
            port = 18099
            pf = subprocess.Popen(
                ["kubectl", "-n", args.ns, "port-forward", f"svc/{args.release}-gateway", f"{port}:80"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            url = f"http://127.0.0.1:{port}"
            for _ in range(30):
                try:
                    urllib.request.urlopen(url + "/healthz", timeout=1)
                    break
                except OSError:
                    time.sleep(1)
        call = http_caller(url)
    try:
        results = []
        for row in load(Path(args.corpus), args.split):
            msgs = row.get("messages") or [{"role": "user", "content": row["text"]}]
            status, body = call([{"role": m["role"], "content": sub(m["content"])} for m in msgs])
            ok, detail = judge(row, status, body)
            results.append(
                {**{k: row[k] for k in ("id", "split", "label", "tag")}, "pass": ok, "detail": detail}
            )
        try:
            health = {} if args.in_process else json.load(urllib.request.urlopen(url + "/readyz", timeout=5))
        except OSError:
            health = {}
    finally:
        if pf:
            pf.terminate()

    for r in results:
        if not r["pass"]:
            print(f"MISS {r['id']:4} {r['split']:10} {r['label']:9} {r['tag']:18} {r['detail']}")
    print()
    for split in (*SPLITS, "all"):
        if args.split not in ("all", split):
            continue
        rows = [r for r in results if split == "all" or r["split"] == split]
        s = summarise(rows)
        print(f"[{split}] {len(rows)} prompts")
        for _, name, text in METRICS:
            print(f"  {text + ':':50}{pct(s[name]['failed'], s[name]['total'])}")
    if args.json:
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(
            json.dumps({"gateway": health, "results": results}, indent=1), encoding="utf-8"
        )
    if args.gate:
        if args.split != "all":
            print("--gate needs the whole corpus (--split all)")
            return 2
        problems = gate(results, Path(args.baseline))
        for p in problems:
            print(f"GATE FAIL {p}")
        print(
            "gate: " + ("FAILED" if problems else "passed (no split has more misses than eval/baseline.json)")
        )
        return 1 if problems else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
