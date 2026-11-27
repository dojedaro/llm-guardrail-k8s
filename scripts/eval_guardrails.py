#!/usr/bin/env python3
"""Run the labelled guardrail corpus (eval/corpus.jsonl) against a DEPLOYED gateway and report
measured false-positive and false-negative rates, per split and overall.

    python scripts/eval_guardrails.py                  # port-forwards svc/guardrail-gateway itself
    python scripts/eval_guardrails.py --url http://127.0.0.1:18080 --json reports/eval.json

Definitions (per prompt, using the gateway's real HTTP answer):
  benign     pass = HTTP 200 and decision "allow".  Blocked or redacted = false positive.
  pii        pass = no sensitive substring survives in the response, and decision is redacted/blocked.
             Anything else = false negative.
  injection  pass = HTTP 403 with reason prompt_injection.  Anything else = false negative.
Standard library only, so it runs anywhere kubectl and Python run.
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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Credential-shaped strings are generated here, not stored in the corpus, so the repo holds no key-like literals.
SUBST = {
    "{SK_PROJ}": "sk-proj-" + "Ab3dEf6hIj9kLm2nOp5qRs8tUv1w",
    "{AKIA}": "AKIA" + "IOSFODNN7EXAMPLE",
    "{GHP}": "ghp_" + "0123456789abcdefghijklmnopqrstuvwxyz",
}


def sub(s: str) -> str:
    for k, v in SUBST.items():
        s = s.replace(k, v)
    return s


def load(corpus: Path, split: str) -> list[dict]:
    rows = [json.loads(ln) for ln in corpus.read_text(encoding="utf-8").splitlines() if ln.strip()]
    return [r for r in rows if split == "all" or r["split"] == split]


def call(url: str, messages: list[dict]) -> tuple[int, dict]:
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


def judge(row: dict, status: int, body: dict) -> tuple[bool, str]:
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


def summarise(results: list[dict]) -> dict:
    out = {}
    for label, name in (
        ("benign", "false_positive"),
        ("pii", "false_negative_pii"),
        ("injection", "false_negative_injection"),
    ):
        rows = [r for r in results if r["label"] == label]
        out[name] = {"failed": sum(not r["pass"] for r in rows), "total": len(rows)}
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", help="gateway base URL; default: start a kubectl port-forward")
    ap.add_argument("--corpus", default=str(ROOT / "eval" / "corpus.jsonl"))
    ap.add_argument("--split", default="all", choices=["all", "dev", "heldout", "fresh"])
    ap.add_argument("--json", help="also write full per-prompt results to this file")
    ap.add_argument("--ns", default=os.getenv("NS", "guardrail"))
    ap.add_argument("--release", default=os.getenv("RELEASE", "guardrail"))
    args = ap.parse_args()

    pf = None
    url = args.url
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
    try:
        results = []
        for row in load(Path(args.corpus), args.split):
            msgs = row.get("messages") or [{"role": "user", "content": row["text"]}]
            msgs = [{"role": m["role"], "content": sub(m["content"])} for m in msgs]
            status, body = call(url, msgs)
            ok, detail = judge(row, status, body)
            results.append(
                {**{k: row[k] for k in ("id", "split", "label", "tag")}, "pass": ok, "detail": detail}
            )
        try:
            health = json.load(urllib.request.urlopen(url + "/readyz", timeout=5))
        except OSError:
            health = {}
    finally:
        if pf:
            pf.terminate()

    for r in results:
        if not r["pass"]:
            print(f"MISS {r['id']:4} {r['split']:8} {r['label']:9} {r['tag']:18} {r['detail']}")
    print()
    for split in ("dev", "heldout", "fresh", "all"):
        if args.split not in ("all", split):
            continue
        sub_rows = [r for r in results if split == "all" or r["split"] == split]
        s = summarise(sub_rows)
        print(f"[{split}] {len(sub_rows)} prompts")
        print(
            f"  false positives (benign blocked or redacted): {pct(s['false_positive']['failed'], s['false_positive']['total'])}"
        )
        print(
            f"  false negatives, PII not redacted:            {pct(s['false_negative_pii']['failed'], s['false_negative_pii']['total'])}"
        )
        print(
            f"  false negatives, injection not blocked:       {pct(s['false_negative_injection']['failed'], s['false_negative_injection']['total'])}"
        )
    if args.json:
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(
            json.dumps({"gateway": health, "results": results}, indent=1), encoding="utf-8"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
