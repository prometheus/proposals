include .bingo/Variables.mk

MD_FILES_TO_FORMAT=$(shell find . -name "*.md" | grep -v ".bingo/README.md")

help: ## Displays help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: fmt
fmt: ## Format docs, ensure GitHub format.
fmt: $(MDOX)
	@echo "Formatting markdown files..."
	$(MDOX) fmt --soft-wraps --links.validate --links.validate.config-file=.github/.mdox.validator.yaml $(MD_FILES_TO_FORMAT)

.PHONY: check
check: ## Checks if doc is formatter and links are correct (don't check external links).
check: $(MDOX)
	@echo "Checking markdown file formatting and basic links."
	$(MDOX) fmt --soft-wraps --links.validate --links.validate.config-file=.github/.mdox.validator.yaml --check $(MD_FILES_TO_FORMAT) || (echo "🔥 Validation failed, files not formatted or links are broken. Try running 'make fmt' to fix formatting!" && exit 1)
	@echo "✅ Markdown files correctly formatted"
	bash ./scripts/proposals-filename-check.sh
