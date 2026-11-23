CWD = $(shell pwd -P)
ROOT ?= $(realpath $(CWD)/../..)
PROJECT = stir

## applications/stir is a Gleam OTP application, so this Makefile does
## not include make/kz.mk: there is no .app.src to expand, no erlc invocation
## and no eunit suite. It answers to the target names applications/Makefile
## calls so a top-level `make apps`, `make clean` or `make eunit` still works.
##
## `gleam export erlang-shipment` writes one directory per OTP application --
## this one and every hex dependency -- under build/erlang-shipment, named
## after the application, not the package, and without the test-only
## dependencies. `install` then puts them where the
## release already looks: this application's ebin in applications/stir
## (rel/relx.config.script takes every applications/* directory that has one)
## and each dependency in deps/<app>, the directory erlang.mk fetches into and
## vendored code is copied to (dep_amqp_dist in make/deps.mk). Nothing under
## rel/ has to know that any of this is Gleam.
##
## Ordering is given by the top level: `apps` depends on `core`, which depends
## on `deps`, so deps/ exists and has been left alone by the time this runs.
##
## Without the gleam binary the application is skipped instead of failing the
## build: `make compile`/`make eunit` in CI run in a plain erlang:28 image and
## a release without STIR/SHAKEN is a working release.

GLEAM ?= gleam
HAS_GLEAM := $(shell command -v $(GLEAM) 2>/dev/null)

DEPS_DIR = $(ROOT)/deps
SHIPMENT = build/erlang-shipment

## Marks a deps/ directory as installed from here, so that a future Gleam
## package sharing a name with an erlang.mk dependency fails loudly instead of
## overwriting it.
MARKER = .gleam-shipment

.PHONY: all compile compile-lean compile-test compile-test-direct install \
	clean clean-test clean-build eunit test format format-check

all: compile

ifeq ($(HAS_GLEAM),)

compile compile-lean test format format-check:
	@echo "$(PROJECT): no gleam binary, skipping $@"

else

compile:
	$(GLEAM) export erlang-shipment
	@$(MAKE) install

## debug_info is not optional here: it is kept in the release (see the relx
## config and docker/reprise/Dockerfile) and the Gleam compiler emits it
## unconditionally, so a lean build is the same build.
compile-lean: compile

test:
	$(GLEAM) test

format:
	$(GLEAM) format

format-check:
	$(GLEAM) format --check

endif

install:
	@rm -rf ebin
	@cp -a $(SHIPMENT)/$(PROJECT)/ebin ebin
	@mkdir -p $(DEPS_DIR)
	@for dir in $(SHIPMENT)/*/; do \
	    app=$$(basename "$$dir"); \
	    [ -d "$$dir/ebin" ] || continue; \
	    if [ "$$app" = "$(PROJECT)" ]; then continue; fi; \
	    target="$(DEPS_DIR)/$$app"; \
	    if [ -d "$$target" ] && [ ! -f "$$target/$(MARKER)" ]; then \
	        echo "$(PROJECT): deps/$$app is not a gleam shipment, refusing to overwrite" >&2; \
	        exit 1; \
	    fi; \
	    rm -rf "$$target"; \
	    mkdir -p "$$target"; \
	    touch "$$target/$(MARKER)"; \
	    cp -a "$$dir/ebin" "$$target/ebin"; \
	    if [ -d "$$dir/priv" ]; then cp -a "$$dir/priv" "$$target/priv"; fi; \
	 done

## Removes what `install` wrote: this application's ebin and the dependency
## copies in deps/. The hex packages under build/ stay, so the next build does
## not go back to hex; `clean-build` drops those too.
clean: clean-test
	@rm -rf ebin
	@for dir in $(DEPS_DIR)/*/$(MARKER); do \
	    [ -f "$$dir" ] && rm -rf "$$(dirname "$$dir")" || true; \
	 done

clean-test:
	@:

clean-build: clean
	@rm -rf build

## The Gleam tests are run by `make test`, not by eunit; there is no eunit
## suite to compile.
compile-test compile-test-direct eunit:
	@:
