# ==============================================================================
# terraform-aws-serverless-pypi-index
# ==============================================================================

VENV           := .venv
PYTHON         := $(VENV)/bin/python
PIP            := $(VENV)/bin/pip
PYTEST         := $(VENV)/bin/pytest
BIN            := $(CURDIR)/bin
export PATH    := $(BIN):$(PATH)

# Platform detection for binary downloads
OS             := $(shell uname -s | tr '[:upper:]' '[:lower:]')
UNAME_M        := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
  ARCH := amd64
else ifeq ($(UNAME_M),amd64)
  ARCH := amd64
else ifeq ($(UNAME_M),arm64)
  ARCH := arm64
else ifeq ($(UNAME_M),aarch64)
  ARCH := arm64
else
  $(error Unsupported architecture: $(UNAME_M))
endif

# Tool versions
TFLINT_VERSION  := 0.64.0
TFDOCS_VERSION  := 0.24.0

TFLINT          := $(BIN)/tflint
TFDOCS          := $(BIN)/terraform-docs

.DEFAULT_GOAL   := help

# ==============================================================================
# Setup
# ==============================================================================

.PHONY: venv
venv: ## Create Python virtual environment
	@test -d $(VENV) || python3 -m venv $(VENV)
	@$(PIP) install --upgrade pip

.PHONY: install-python
install-python: venv ## Install Python dev dependencies
	@echo "==> Installing Python requirements..."
	@$(PIP) install -r requirements-dev.txt

.PHONY: install-devops
install-devops: $(TFLINT) $(TFDOCS) ## Download tflint and terraform-docs into ./bin
	@echo "==> DevOps tools ready ($(OS)-$(ARCH))"
	@$(TFLINT) --version
	@$(TFDOCS) --version

.PHONY: install-hooks
install-hooks: install-python ## Install git pre-commit hooks
	@echo "==> Installing pre-commit git hooks..."
	@$(VENV)/bin/pre-commit install

$(TFLINT):
	@echo "==> Installing TFLint v$(TFLINT_VERSION)..."
	@mkdir -p $(BIN)
	@curl -sSLo /tmp/tflint.zip \
		"https://github.com/terraform-linters/tflint/releases/download/v$(TFLINT_VERSION)/tflint_$(OS)_$(ARCH).zip"
	@unzip -o /tmp/tflint.zip tflint -d $(BIN)
	@chmod +x $(TFLINT)
	@rm -f /tmp/tflint.zip

$(TFDOCS):
	@echo "==> Installing terraform-docs v$(TFDOCS_VERSION)..."
	@mkdir -p $(BIN)
	@curl -sSLo /tmp/tfdocs.tar.gz \
		"https://github.com/terraform-docs/terraform-docs/releases/download/v$(TFDOCS_VERSION)/terraform-docs-v$(TFDOCS_VERSION)-$(OS)-$(ARCH).tar.gz"
	@tar -xzf /tmp/tfdocs.tar.gz -C $(BIN) terraform-docs
	@chmod +x $(TFDOCS)
	@rm -f /tmp/tfdocs.tar.gz

.PHONY: install
install: install-python install-devops install-hooks ## Bootstrap full local toolchain
	@echo "==> Install complete"

# ==============================================================================
# Terraform quality
# ==============================================================================

.PHONY: fmt
fmt: ## Format Terraform files
	@terraform fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Check Terraform formatting (CI)
	@terraform fmt -check -recursive -diff .

.PHONY: tflint
tflint: $(TFLINT) ## Run TFLint
	@echo "==> Running TFLint..."
	@$(TFLINT) --init
	@$(TFLINT) -f compact

.PHONY: validate
validate: ## Run terraform init + validate
	@echo "==> Validating Terraform..."
	@terraform init -backend=false -input=false
	@terraform validate

.PHONY: docs
docs: $(TFDOCS) ## Generate Terraform docs into README.md
	@echo "==> Generating terraform-docs..."
	@$(TFDOCS) .

.PHONY: docs-check
docs-check: docs ## Fail if README docs are out of date (CI)
	@git diff --exit-code -- README.md || \
		(echo "ERROR: README.md terraform docs are stale. Run 'make docs' and commit." && exit 1)

.PHONY: lint
lint: fmt-check tflint ## Format-check + TFLint

.PHONY: pre-commit
pre-commit: install-python ## Run all pre-commit hooks on every file
	@echo "==> Running pre-commit..."
	@$(VENV)/bin/pre-commit run --all-files --show-diff-on-failure

# ==============================================================================
# Python
# ==============================================================================

.PHONY: test
test: install-python ## Run pytest
	@echo "==> Running pytest..."
	@PYTHONPATH=src $(PYTEST) -v src/

.PHONY: format
format: install-python ## Format Python with Black
	@$(PYTHON) -m black src/

# ==============================================================================
# Meta
# ==============================================================================

.PHONY: check
check: pre-commit validate test ## Run full local CI suite

.PHONY: clean
clean: ## Remove caches, venv, and downloaded binaries
	@rm -rf $(VENV) $(BIN) .pytest_cache .coverage htmlcov .terraform
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@echo "==> Cleaned"

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'
