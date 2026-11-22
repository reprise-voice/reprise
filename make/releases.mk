RELX = $(ROOT)/scripts/build-release.escript

RELX_CONFIG = $(ROOT)/rel/relx.config
RELX_CONFIG_SCRIPT = $(RELX_CONFIG).script

.PHONY: clean-release
clean-release:
	$(if $(wildcard _rel/), rm -r _rel/)

## A test build (`make eunit`, `compile-test`) compiles core and applications
## with -DTEST into the same ebin/ the release ships from, and a later
## `make core apps` sees those beams as up to date. A release built from
## such a tree carries test doubles (a TEST kapps_config never persists
## configuration, which breaks auth tokens, among others). Every test compile
## leaves a stamp under .test-compiled/ that the project's clean removes;
## refuse to build a release while any stamp is present.
.PHONY: check-not-test-compiled
check-not-test-compiled:
	@if [ -n "$$(ls -A $(ROOT)/.test-compiled 2>/dev/null)" ]; then \
	    echo "build-release: this tree has test-compiled beams in:" >&2; \
	    ls -A $(ROOT)/.test-compiled | sed 's/^/    /' >&2; \
	    echo "run 'make clean-core clean-apps core apps' first, or build from a clean checkout" >&2; \
	    exit 1; \
	 fi

.PHONY: build-release
build-release: check-not-test-compiled $(RELX) clean-release $(RELX_CONFIG) $(RELX_CONFIG_SCRIPT) $(ROOT)/rel/sys.config $(ROOT)/rel/vm.args
	ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) $(RELX) --config $(RELX_CONFIG)

.PHONY: build-dev-release
build-dev-release: check-not-test-compiled $(RELX) clean-release $(ROOT)/rel/dev.relx.config $(ROOT)/rel/dev.relx.config.script $(ROOT)/rel/dev.vm.args $(ROOT)/rel/dev.sys.config
	ERL_LIBS=$(DEPS_DIR):$(CORE_DIR) $(RELX) --config $(ROOT)/rel/dev.relx.config

.PHONY: build-ci-release
build-ci-release: check-not-test-compiled $(RELX) clean-release $(ROOT)/rel/ci.relx.config $(ROOT)/rel/ci.relx.config.script $(ROOT)/rel/ci.sys.config $(ROOT)/rel/ci.vm.args
	ERL_LIBS=$(DEPS_DIR):$(CORE_DIR) $(RELX) --config $(ROOT)/rel/ci.relx.config

.PHONY: build-dist-release
build-dist-release: check-not-test-compiled $(RELX) clean-release $(ROOT)/rel/dist.relx.config $(ROOT)/rel/dist.relx.config.script $(ROOT)/rel/dist.vm.args $(ROOT)/rel/dist.sys.config
	ERL_LIBS=$(DEPS_DIR):$(CORE_DIR) $(RELX) --config $(ROOT)/rel/dist.relx.config

.PHONY: tar-release
tar-release: $(RELX) $(RELX_CONFIG) $(RELX_CONFIG_SCRIPT) $(ROOT)/rel/sys.config $(ROOT)/rel/vm.args
	$(RELX) --config $(RELX_CONFIG) -V 2 release tar --relname 'kazoo'

## More ACTs at //github.com/erlware/relx/priv/templates/extended_bin
.PHONY: release
release: ACT ?= console # start | attach | stop | console | foreground
release: REL ?= kazoo_apps # kazoo_apps | ecallmgr | …
release: COOKIE ?= change_me
release:
	NODE_NAME="$(REL)" COOKIE="$(COOKIE)" $(ROOT)/scripts/dev/kazoo.sh $(ACT) "$$@"

.PHONY: install
install: compile build-release
	cp -a _$(ROOT)/rel/kazoo /opt

.PHONY: read-release-cookie
read-release-cookie: REL ?= kazoo_apps
read-release-cookie:
	@NODE_NAME='$(REL)' _$(ROOT)/rel/kazoo/bin/kazoo escript lib/kazoo_config-*/priv/read-cookie.escript "$$@"
