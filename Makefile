# throttle-bench — Benchmark: ghc-throttle vs -jsem vs baselines
#
# Usage:
#   make              Show this help
#   make setup        One-time setup (build ghc-throttle)
#   make bench        Run all benchmarks (lens + pandoc)
#   make bench-lens   Benchmark lens only
#   make bench-pandoc Benchmark pandoc only
#
# Configuration (override via command line):
#   make bench CONCURRENCY=4,8,16 RUNS=3 APPROACHES=throttle,jsem
#
# Copyright (c) 2026, Moritz Angermann <moritz.angermann@iohk.io>
# Licensed under Apache-2.0

.DEFAULT_GOAL := help

# ── Configuration ─────────────────────────────────────────────────────────────

CONCURRENCY  ?= 2,4
APPROACHES   ?= baseline,unlimited,throttle,jsem
RUNS         ?= 1
COOLDOWN     ?= 15
RESULTS_DIR  ?= results

# nix develop wrapper — all GHC/cabal commands run through this
DEVX         ?= nix develop github:input-output-hk/devx\#ghc98-minimal-ghc -c

# Throttle binary
THROTTLE_BIN := $(CURDIR)/_build/ghc-throttle
STATUS_BIN   := $(CURDIR)/_build/ghc-throttle-status

# Detect platform for source selection
ifeq ($(OS),Windows_NT)
  THROTTLE_SRC := ghc-throttle-win.c
  STATUS_SRC   := ghc-throttle-status-win.c
else
  THROTTLE_SRC := ghc-throttle.c
  STATUS_SRC   := ghc-throttle-status.c
endif

export THROTTLE_BIN

# ── Colours ───────────────────────────────────────────────────────────────────

C_RESET  := \033[0m
C_BOLD   := \033[1m
C_GREEN  := \033[32m
C_CYAN   := \033[36m
C_YELLOW := \033[33m
C_DIM    := \033[2m

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@printf '$(C_BOLD)throttle-bench$(C_RESET) — ghc-throttle vs -jsem benchmark\n\n'
	@printf '$(C_BOLD)Targets:$(C_RESET)\n'
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | sort | \
		awk -F ':.*## ' '{ printf "  $(C_GREEN)%-18s$(C_RESET) %s\n", $$1, $$2 }'
	@printf '\n$(C_BOLD)Configuration:$(C_RESET)\n'
	@printf '  $(C_CYAN)CONCURRENCY$(C_RESET)  = $(CONCURRENCY)\n'
	@printf '  $(C_CYAN)APPROACHES$(C_RESET)   = $(APPROACHES)\n'
	@printf '  $(C_CYAN)RUNS$(C_RESET)         = $(RUNS)\n'
	@printf '  $(C_CYAN)COOLDOWN$(C_RESET)     = $(COOLDOWN)\n'
	@printf '  $(C_CYAN)RESULTS_DIR$(C_RESET)  = $(RESULTS_DIR)\n'
	@printf '\n$(C_BOLD)Examples:$(C_RESET)\n'
	@printf '  $(C_DIM)make setup                                    # one-time setup$(C_RESET)\n'
	@printf '  $(C_DIM)make bench CONCURRENCY=2,4,8 RUNS=3           # full benchmark$(C_RESET)\n'
	@printf '  $(C_DIM)make bench-lens APPROACHES=throttle,jsem       # lens only$(C_RESET)\n'
	@printf '  $(C_DIM)make dry-run                                   # show what would run$(C_RESET)\n'

# ── Setup ─────────────────────────────────────────────────────────────────────

.PHONY: setup
setup: $(THROTTLE_BIN) $(STATUS_BIN) ## One-time setup (build ghc-throttle)
	@printf '$(C_GREEN)Setup complete.$(C_RESET)\n'
	@$(DEVX) bash -c 'printf "  GHC:   %s\n" "$$(ghc-9.8.4 --numeric-version)"; printf "  cabal: %s\n" "$$(cabal --numeric-version)"'
	@printf '  throttle: $(THROTTLE_BIN)\n'

$(THROTTLE_BIN): $(THROTTLE_SRC) | _build
	$(CC) -O2 -Wall -Wextra -pedantic -o $@ $<

$(STATUS_BIN): $(STATUS_SRC) | _build
	$(CC) -O2 -Wall -Wextra -pedantic -o $@ $<

_build:
	@mkdir -p _build

.PHONY: check
check: ## Verify all prerequisites
	@printf 'Checking prerequisites...\n'
	@command -v nix >/dev/null || { printf '$(C_YELLOW)FAIL$(C_RESET): nix not found\n'; exit 1; }
	@printf '  nix:       OK\n'
	@$(DEVX) ghc-9.8.4 --version >/dev/null 2>&1 || { printf '$(C_YELLOW)FAIL$(C_RESET): ghc-9.8.4 not available in devx\n'; exit 1; }
	@printf '  ghc-9.8.4: OK\n'
	@$(DEVX) cabal --version >/dev/null 2>&1 || { printf '$(C_YELLOW)FAIL$(C_RESET): cabal not available in devx\n'; exit 1; }
	@printf '  cabal:     OK\n'
	@$(DEVX) ghc-9.8.4 --show-options 2>/dev/null | grep -q '\-jsem' || { printf '$(C_YELLOW)FAIL$(C_RESET): ghc-9.8.4 does not support -jsem\n'; exit 1; }
	@printf '  -jsem:     OK\n'
	@test -x $(THROTTLE_BIN) || { printf '$(C_YELLOW)FAIL$(C_RESET): $(THROTTLE_BIN) not found (run: make setup)\n'; exit 1; }
	@printf '  throttle:  OK\n'
	@printf '$(C_GREEN)All checks passed.$(C_RESET)\n'

# ── Benchmarks ────────────────────────────────────────────────────────────────

BENCH_ARGS = \
	--approaches $(APPROACHES) \
	--concurrency $(CONCURRENCY) \
	--runs $(RUNS) \
	--cooldown $(COOLDOWN) \
	--output-dir $(RESULTS_DIR)

.PHONY: bench
bench: $(THROTTLE_BIN) ## Run all benchmarks (lens + pandoc)
	$(DEVX) bash bench.sh --packages lens,pandoc $(BENCH_ARGS)

.PHONY: bench-lens
bench-lens: $(THROTTLE_BIN) ## Benchmark lens only
	$(DEVX) bash bench.sh --packages lens $(BENCH_ARGS)

.PHONY: bench-pandoc
bench-pandoc: $(THROTTLE_BIN) ## Benchmark pandoc only
	$(DEVX) bash bench.sh --packages pandoc $(BENCH_ARGS)

.PHONY: dry-run
dry-run: $(THROTTLE_BIN) ## Show what would run (no actual builds)
	$(DEVX) bash bench.sh --packages lens,pandoc $(BENCH_ARGS) --dry-run

# ── Results ───────────────────────────────────────────────────────────────────

.PHONY: results
results: ## Print results summary from last run
	@test -f $(RESULTS_DIR)/results.csv || { printf 'No results found. Run: make bench\n'; exit 1; }
	@printf '$(C_BOLD)Results:$(C_RESET)\n\n'
	@column -t -s, $(RESULTS_DIR)/results.csv 2>/dev/null || cat $(RESULTS_DIR)/results.csv
	@printf '\n'

.PHONY: results-csv
results-csv: ## Print raw CSV from last run
	@cat $(RESULTS_DIR)/results.csv 2>/dev/null || printf 'No results found.\n'

# ── Cleanup ───────────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove benchmark results (keep setup)
	rm -rf $(RESULTS_DIR) _build/work

.PHONY: distclean
distclean: ## Remove everything (results + built binaries)
	rm -rf $(RESULTS_DIR) _build
