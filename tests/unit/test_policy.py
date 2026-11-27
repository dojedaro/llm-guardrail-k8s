import pytest
from gateway.policy import PolicyError, load_policy, parse_policy


def test_parse_minimal():
    p = parse_policy({"version": "v1"})
    assert p.version == "v1" and p.pii_mode == "redact" and p.redact_output


def test_parse_full():
    p = parse_policy(
        {
            "version": 7,
            "pii": {"mode": "block", "rules": ["email"]},
            "injection": {"enabled": False, "threshold": 5},
            "output": {"redact_pii": False},
        }
    )
    assert (p.version, p.pii_mode, p.pii_rules) == ("7", "block", ("email",))
    assert not p.injection_enabled and p.injection_threshold == 5 and not p.redact_output


@pytest.mark.parametrize(
    "bad",
    [None, {}, {"version": "x", "pii": {"mode": "maybe"}}, {"version": "x", "pii": {"rules": ["dna"]}}],
)
def test_parse_rejects_bad(bad):
    with pytest.raises(PolicyError):
        parse_policy(bad)


def test_load_from_file(tmp_path):
    f = tmp_path / "policy.yaml"
    f.write_text("version: from-file\npii:\n  mode: block\n")
    p = load_policy(f)
    assert p.version == "from-file" and p.pii_mode == "block"


def test_null_sections_use_defaults():
    p = parse_policy({"version": "v1", "pii": None, "injection": None, "output": None})
    assert p.pii_mode == "redact" and p.injection_enabled and p.redact_output


def test_load_rejects_bad_yaml_as_policy_error(tmp_path):
    f = tmp_path / "policy.yaml"
    f.write_text("version: [unclosed\n  pii: {")
    with pytest.raises(PolicyError, match="not valid YAML"):
        load_policy(f)


def test_load_rejects_wrong_types(tmp_path):
    f = tmp_path / "policy.yaml"
    f.write_text("version: v1\ninjection:\n  threshold: lots\n")
    with pytest.raises(PolicyError, match="wrong type"):
        load_policy(f)
