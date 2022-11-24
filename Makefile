include .bingo/Variables.mk

.DEFAULT_GOAL := fmt
MD_FILES_TO_FORMAT=$(shell find . -name "*.md")

help: ## Displays help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: fmt
fmt: ## Format docs, ensure GitHub format.
fmt: $(MDOX)
	@echo "Formatting markdown files..."
	$(MDOX) fmt --soft-wraps $(MD_FILES_TO_FORMAT)

.PHONY: check
check: ## Checks if doc is formatter and links are correct (don't check external links).
check: $(MDOX)
	@echo "Checking markdown files. If changes are detected, try running `make` and trying again."
	$(MDOX) fmt --soft-wraps --check --links.validate.config-file=.github/.mdox.validator.yaml *.md $(MD_FILES_TO_FORMAT)
