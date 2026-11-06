PROJECT ?= ZombieUprising
OUT_DIR ?= build
OUT_XML ?= $(OUT_DIR)/$(PROJECT).rbxlx
OUT_BIN ?= $(OUT_DIR)/$(PROJECT).rbxl

BIN := $(CURDIR)/tools/bin
ROJO := $(BIN)/rojo
RBXMK := $(BIN)/rbxmk
ANALYZE := $(BIN)/luau-analyze
COMPILE := $(BIN)/luau-compile

# rbxmk needs the Roblox type database to encode/decode place files.
RBXMK_ARGS := --cookies-file "$(CURDIR)/.cookies" 2>/dev/null || true

.PHONY: all setup lint syntax build clean roundtrip publish help

all: lint build

help:
	@echo "targets: setup, lint, syntax, build, roundtrip, publish"

## Fetch pinned tooling.
setup:
	@bash tools/setup.sh

## Static analysis gate: strict typecheck + lint over all Luau.
## Includes the Roblox global definitions so Vector3/Color3/Enum resolve offline.
lint: setup
	@bash tools/scripts/lint.sh

## Syntax-only gate (fast feedback).
syntax: setup
	@echo "== luau-compile (syntax) =="
	@for f in $$(find src -name '*.luau' -o -name '*.lua' | sort); do \
		$(COMPILE) "$$f" >/dev/null || { echo "syntax FAILED: $$f"; exit 1; }; \
	done
	@echo "syntax OK"

## Build the place file (XML + binary). Gate: must succeed.
build: setup
	@mkdir -p $(OUT_DIR)
	@echo "== rojo build =="
	@$(ROJO) build default.project.json -o "$(OUT_XML)"
	@ls -la $(OUT_DIR)
	@test -s "$(OUT_XML)" || { echo "build produced empty file"; exit 1; }
	@echo "build OK -> $(OUT_XML)"

## Verify the built place actually contains our systems (playtest substitute).
roundtrip: build
	@echo "== place structure verification =="
	@python3 tools/scripts/verify_place.py "$(OUT_XML)"

## Upload/update the experience on Roblox. Requires a cookie in .cookies
## or ROBLOSECURITY env. First run creates a new asset and prints its id.
publish: build
	@bash tools/publish.sh "$(OUT_XML)"

clean:
	rm -rf $(OUT_DIR) tools/.work
