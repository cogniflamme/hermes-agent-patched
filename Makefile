# Local build and checks (the same steps CI runs). Needs podman (or
# ENGINE=docker) and grype.
SHELL := /bin/bash
ENGINE ?= podman
IMAGE  ?= localhost/hermes-patched:dev
include upstream.env
include chrome.env
CFT_ARGS = --build-arg CFT_VERSION=$(CFT_VERSION) --build-arg CFT_SHA256_AMD64=$(CFT_SHA256_AMD64) --build-arg CFT_SHA256_ARM64=$(CFT_SHA256_ARM64)

build: ## Build the image on the pinned upstream
	$(ENGINE) build --pull=missing -f Containerfile --build-arg BASE=$(BASE) $(CFT_ARGS) -t $(IMAGE) .

test: ## Versions, tools, boot, browser end to end
	ENGINE=$(ENGINE) tests/run.sh $(IMAGE)

scan: ## grype + the release gate
	grype -q -o json $(IMAGE) > scan.json && python3 ci/gate.py scan.json

upstream: ## Is there a newer stable Hermes?
	python3 ci/upstream.py --check || true

chrome: ## Is there a newer Chrome for Testing stable than chrome.env?
	python3 ci/chrome.py --check || true

.PHONY: build test scan upstream chrome
