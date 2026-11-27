# Convenience targets. On Windows without `make`, run the underlying commands (they are all
# plain scripts/ or pytest calls) from Git Bash; every target below is one line.
PY ?= python
RELEASE ?= guardrail
NS ?= guardrail

.PHONY: help venv lint test chart-lint cluster-up cluster-up-calico cluster-down images install         helm-test integration preflight drills eval upgrade-demo bundle airgap diag uninstall

help:           ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/	/'

venv:           ## local virtualenv with test dependencies (use Python 3.12 to match the image)
	$(PY) -m venv .venv && .venv/bin/pip install -r app/gateway/requirements.txt -r requirements-dev.txt

lint:           ## ruff
	ruff check . && ruff format --check .

test:           ## unit tests and the redaction test (no cluster needed)
	pytest tests/unit -q && tests/scripts/test-redact.sh

chart-lint:     ## helm lint, template for every values file, strict duplicate-key check, kubeconform -strict, bad-values tests
	scripts/chart-check.sh

cluster-up:     ## kind cluster + ingress-nginx + images
	scripts/cluster-up.sh

cluster-up-calico: ## same, with Calico so NetworkPolicy is guaranteed enforced
	CNI=calico scripts/cluster-up.sh

cluster-down:   ## delete cluster and local registry
	scripts/cluster-down.sh

images:         ## build images and load them into kind
	scripts/build-images.sh

preflight:      ## environment assessment report
	scripts/preflight.sh

install:        ## install on the kind cluster (mock LLM, ingress on)
	helm upgrade --install $(RELEASE) charts/llm-guardrail -n $(NS) --create-namespace 	  -f charts/llm-guardrail/values-kind.yaml --wait --timeout 180s

helm-test:      ## run the chart's smoke-test hook
	helm test $(RELEASE) -n $(NS) --logs

integration:    ## pytest against the running release (fails instead of skipping when there is no cluster)
	REQUIRE_CLUSTER=1 pytest tests/integration -v -rs

drills:         ## NetworkPolicy enforcement proof (the other drills are run one at a time, see drills/)
	drills/06-networkpolicy-enforcement.sh

eval:           ## labelled guardrail corpus against the deployed gateway: false-positive / false-negative rates
	python scripts/eval_guardrails.py

upgrade-demo:   ## upgrade, verify, rollback, verify
	scripts/upgrade-rollback-demo.sh

bundle:         ## air-gap tarball in dist/
	scripts/airgap-bundle.sh

airgap:         ## install from the bundle through a local registry
	scripts/airgap-install.sh dist/llm-guardrail-airgap-*.tar.gz

diag:           ## support bundle
	scripts/collect-diagnostics.sh

uninstall:
	helm uninstall $(RELEASE) -n $(NS)
