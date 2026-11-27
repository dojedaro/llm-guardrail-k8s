"""The evaluation gate has to fail when the rules get worse, or "regressions are caught" is only a claim."""

import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("eval_guardrails", ROOT / "scripts" / "eval_guardrails.py")
assert spec and spec.loader
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)


def results(**misses):
    """One result row per (split, label); `misses` maps 'split:label' to how many rows of it fail."""
    rows = []
    for split in ev.SPLITS:
        for label in ("benign", "pii", "injection"):
            n = misses.get(f"{split}:{label}", 0)
            rows += [{"split": split, "label": label, "pass": i >= n} for i in range(3)]
    return rows


def baseline(tmp_path, **allowed):
    base = {
        s: {"false_positive": 0, "false_negative_pii": 0, "false_negative_injection": 0}
        for s in (*ev.SPLITS, "all")
    }
    for key, n in allowed.items():
        split, metric = key.split("__")
        base[split][metric] = n
    path = tmp_path / "baseline.json"
    path.write_text(json.dumps(base))
    return path


def test_gate_passes_when_misses_stay_within_the_baseline(tmp_path):
    base = baseline(tmp_path, fresh__false_negative_injection=2, all__false_negative_injection=2)
    assert ev.gate(results(**{"fresh:injection": 2}), base) == []


def test_gate_fails_when_a_split_gets_worse(tmp_path):
    base = baseline(tmp_path, all__false_negative_injection=2)
    problems = ev.gate(results(**{"fresh:injection": 3}), base)
    assert any("[fresh] false_negative_injection: 3 misses" in p for p in problems)
    assert any(p.startswith("[all]") for p in problems)


def test_a_new_false_positive_fails_even_if_everything_else_is_better(tmp_path):
    assert ev.gate(results(**{"multiturn:benign": 1}), baseline(tmp_path))


def test_the_committed_baseline_covers_every_split_and_metric():
    base = json.loads((ROOT / "eval" / "baseline.json").read_text())
    names = {"false_positive", "false_negative_pii", "false_negative_injection"}
    assert set(base) == {*ev.SPLITS, "all"} and all(set(v) == names for v in base.values())
