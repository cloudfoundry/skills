# Cloud Foundry Skills — CI / local checks
#
# Run `make` (or `make check`) to run everything CI runs.
# Individual targets are useful while iterating locally.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := check

# All shipped scripts and JSON files in the working tree, including untracked
# files introduced by a change under review.
SCRIPTS := $(shell git ls-files -co --exclude-standard -- '*.sh' | while IFS= read -r f; do [ -f "$$f" ] && printf '%s ' "$$f"; done)
JSON := $(shell git ls-files -co --exclude-standard -- '*.json' | while IFS= read -r f; do [ -f "$$f" ] && printf '%s ' "$$f"; done)
PY := $(shell git ls-files -co --exclude-standard -- '*.py' | while IFS= read -r f; do [ -f "$$f" ] && printf '%s ' "$$f"; done)

.PHONY: check validate shellcheck json ruff ty help

## check: run all CI checks (default)
check: validate shellcheck json ruff ty
	@echo "All checks passed."

## validate: validate the Claude marketplace and each skill plugin (strict — warnings fail)
validate:
	@echo ">> claude plugin validate --strict marketplace"
	claude plugin validate --strict .
	@echo ">> claude plugin validate --strict skills/cf-kind-verify"
	claude plugin validate --strict skills/cf-kind-verify

## shellcheck: lint every tracked shell script (all severities must pass)
shellcheck:
	@echo ">> shellcheck ($(words $(SCRIPTS)) scripts)"
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SCRIPTS); \
	else \
		echo "shellcheck not installed" >&2; \
		exit 1; \
	fi

## json: check every tracked JSON file parses
json:
	@echo ">> jq parse ($(words $(JSON)) files)"
	@for f in $(JSON); do \
		jq empty "$$f" || { echo "invalid JSON: $$f" >&2; exit 1; }; \
	done

## ruff: lint Python helper scripts
ruff:
	@echo ">> ruff ($(words $(PY)) files)"
	@if [ -n "$(strip $(PY))" ]; then uv run --group dev ruff check $(PY); else echo "(no python files)"; fi

## ty: type-check Python helper scripts
ty:
	@echo ">> ty ($(words $(PY)) files)"
	@if [ -n "$(strip $(PY))" ]; then uv run --group dev ty check $(PY); else echo "(no python files)"; fi

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
