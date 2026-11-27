# Convenience targets. On Windows without `make`, run the underlying commands (they are all
# plain scripts/ or pytest calls) from Git Bash; every target below is one line.
PY ?= python
RELEASE ?= guardrail
NS ?= guardrail

.PHONY: help venv lint test chart-lint cluster-up cluster-up-calico cluster-down images install \
        helm-test integration preflight drills upgrade-demo bundle airgap diag uninstall

help:           ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

venv:           ## local virtualenv with test dependencies
	$(PY) -m venv .venv && .venv/bin/pip install -r app/gateway/requirements.txt pytest pytest-asyncio ruff

lint:           ## ruff
	ruff check . && ruff format --check .

test:           ## unit tests (no cluster needed)
	pytest tests/unit -q

chart-lint:     ## helm lint + render with every values file (needs helm)
	helm lint charts/llm-guardrail
	helm template $(RELEASE) charts/llm-guardrail > /dev/null
	helm template $(RELEASE) charts/llm-guardrail -f charts/llm-guardrail/values-airgapped.yaml > /dev/null
	helm template $(RELEASE) charts/llm-guardrail -f charts/llm-guardrail/values-external-llm.yaml \
	  --set 'networkPolicy.externalLLM.cidrs={203.0.113.10/32}' > /dev/null

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

install:        ## install the chart with default values (mock LLM)
	helm upgrade --install $(RELEASE) charts/llm-guardrail -n $(NS) --create-namespace --wait --timeout 180s

helm-test:      ## run the chart's smoke-test hook
	helm test $(RELEASE) -n $(NS) --logs

integration:    ## pytest against the running release
	pytest tests/integration -v -rs

drills:         ## NetworkPolicy enforcement proof (the other drills are run one at a time, see drills/)
	drills/06-networkpolicy-enforcement.sh

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
