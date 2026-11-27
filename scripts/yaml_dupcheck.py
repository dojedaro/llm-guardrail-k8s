#!/usr/bin/env python3
"""Fail if any mapping in a (multi-document) YAML stream repeats a key.

PyYAML, kubectl and Helm silently keep the last duplicate, so a template that emits the same label
twice "works" until a strict consumer (kubeconform -strict, some admission controllers) rejects it.

    helm template t charts/llm-guardrail | python scripts/yaml_dupcheck.py
"""

import sys

import yaml


class DupCheckLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader: yaml.SafeLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    seen: set = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(None, None, f"duplicate key {key!r}", key_node.start_mark)
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


DupCheckLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)

if __name__ == "__main__":
    try:
        docs = [d for d in yaml.load_all(sys.stdin, Loader=DupCheckLoader) if d]
    except yaml.YAMLError as exc:
        print(f"FAIL: {exc}")
        sys.exit(1)
    print(f"ok: {len(docs)} documents, no duplicate keys")
