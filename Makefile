# Local build and checks (the same steps CI runs). Needs podman (or
# ENGINE=docker) and grype.
SHELL := /bin/bash
ENGINE ?= podman
IMAGE  ?= localhost/hermes-patched:dev
include upstream.env

build: ## Build the image on the pinned upstream
	$(ENGINE) build --pull=missing --build-arg BASE=$(BASE) -t $(IMAGE) .

test: ## Versions, tools, boot, browser end to end
	ENGINE=$(ENGINE) tests/run.sh $(IMAGE)

scan: ## grype + the release gate
	grype -q -o json $(IMAGE) > scan.json && python3 ci/gate.py scan.json

upstream: ## Is there a newer stable Hermes?
	python3 ci/upstream.py --check || true

.PHONY: build test scan upstream
