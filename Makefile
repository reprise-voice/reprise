ifndef VERBOSE
MAKEFLAGS += --no-print-directory
endif

ROOT := $(shell cd "$(dirname '.')" && pwd -P)

DEPS_DIR = $(ROOT)/deps
CORE_DIR = $(ROOT)/core
APPS_DIR = $(ROOT)/applications

TAGS = $(ROOT)/TAGS
ERLANG_LS = $(ROOT)/erlang_ls.config
KZ_VSCODE = $(ROOT)/kazoo.code-workspace
KZ_VSCODE_DEBUGGER = $(ROOT)/.vscode/launch.json

ERLANG_MK = $(ROOT)/erlang.mk
DOT_ERLANG_MK = $(ROOT)/.erlang.mk

# erlang.mk
ERLANG_MK_REPO ?= https://github.com/ninenines/erlang.mk
ERLANG_MK_BUILD_CONFIG ?= build.config
ERLANG_MK_BUILD_DIR ?= .erlang.mk.build

# fixing erlang.mk to a commit, until elixir detection gets fixed
ERLANG_MK_COMMIT ?= 3f7955bad270767f87272f1066ecb0a7ae0c7914
export ERLANG_MK_COMMIT

# disabling elixir in erlang.mk
ELIXIR ?= disable
export ELIXIR

## REPRISE_GIT_BASE: where the reprise-voice forks are fetched from; set it to
## git@github.com:reprise-voice for SSH keys or to a mirror (make/repos.mk)
include $(ROOT)/make/repos.mk

BASE_BRANCH := $(shell cat $(ROOT)/.base_branch)

DEPS_HASH := $(shell cat $(ROOT)/make/repos.mk $(ROOT)/make/deps.mk | md5sum | cut -d' ' -f1)
DEPS_HASH_FILE := $(ROOT)/make/.deps.mk.$(DEPS_HASH)

# core/ and applications/ are part of this tree; only deps/ is fetched
APPS := $(dir $(wildcard $(APPS_DIR)/*/Makefile))
CORE := $(wildcard $(CORE_DIR))/

KAST = $(APPS_DIR)/ast

## The Gleam packages in this tree, relative to the root: every core/ or
## applications/ directory with a gleam.toml, so an application dropped into
## applications/ is picked up without editing this list. core/ comes first,
## so the shared library (core/kazoo_gleam) is checked before the
## applications that build on it. A directory named here that is not present,
## or that carries no gleam.toml, is skipped everywhere it is used below.
GLEAM_DIRS ?= $(patsubst $(ROOT)/%/gleam.toml,%,$(sort $(wildcard $(ROOT)/core/*/gleam.toml)) $(sort $(wildcard $(ROOT)/applications/*/gleam.toml)))

## The subset that is actually present, still relative to the root
GLEAM_PACKAGES = $(patsubst $(ROOT)/%/gleam.toml,%,$(wildcard $(addsuffix /gleam.toml,$(addprefix $(ROOT)/,$(GLEAM_DIRS)))))

## list files changed for more focused checks
ifeq ($(strip $(CHANGED)),)
ifeq ($(CIRCLECI),)
	CHANGED := $(strip $(shell $(ROOT)/scripts/check-changed.bash $(ROOT) $(CORE) $(APPS)))
else
    CHANGED := $(CHANGED)
endif
else
	CHANGED := $(CHANGED)
endif

CHANGED_SWAGGER ?= $(shell git -C $(ROOT) --no-pager diff --name-only HEAD $(BASE_BRANCH) -- applications/crossbar/priv/api/swagger.json 2>/dev/null)
CHANGED_ERL=$(filter %.hrl %.erl %.escript,$(CHANGED))
CHANGED_APPS=$(filter $(APPS_DIR)%,$(CHANGED_ERL))
CHANGED_JSON=$(filter %.json,$(CHANGED))
CHANGED_YML=$(filter %.yml,$(CHANGED))
CHANGED_DOCS=$(filter %.md,$(CHANGED))

## The .erl files under GLEAM_DIRS are FFI shims compiled by gleam, not by
## kz.mk, so the Erlang checks driven by CHANGED (fmt, elvis, code_checks,
## edoc, dialyze-changed) do not apply to them; `make gleam-check` is the
## equivalent.
CHANGED := $(filter-out $(addsuffix /%,$(addprefix $(ROOT)/,$(GLEAM_DIRS))),$(CHANGED))

## `gleam build` writes an ebin per package under each Gleam directory's
## build/, none of which belong to the release (an application's Makefile
## installs the ones that do, into its own ebin and into deps/). Keep those
## trees out of the sweeps that collect ebin dirs.
GLEAM_BUILD_PRUNE = $(foreach dir,$(GLEAM_DIRS),-path '$(ROOT)/$(dir)/build' -prune -o)
FIND_EBINS = find $(1) $(GLEAM_BUILD_PRUNE) -name ebin -print

PRINTABLE_CHANGED=$(subst $(ROOT),,$(CHANGED))
PRINTABLE_ERL=$(subst $(ROOT),,$(CHANGED_ERL))
PRINTABLE_APPS=$(sort $(foreach app,$(CHANGED_APPS),$(firstword $(subst /, ,$(subst $(APPS_DIR)/,,$(app))))))
PRINTABLE_JSON=$(subst $(ROOT),,$(CHANGED_JSON))
PRINTABLE_YML=$(subst $(ROOT),,$(CHANGED_YML))
PRINTABLE_DOCS=$(subst $(ROOT),,$(CHANGED_DOCS))

# exporting these so they are used in targets
export CHANGED
export CHANGED_SWAGGER
export CHANGED_ERL
export CHANGED_APPS
export CHANGED_JSON
export CHANGED_YML
export CHANGED_DOCS

# You can override this when calling make, e.g. make JOBS=1
# to prevent parallel builds, or make JOBS="8".
#
# Keep this at 1 while more than one Gleam application is in the tree: each
# one installs its whole shipment into deps/<app>, so two of them sharing a
# library (or any hex package) write the same deps/ directory, and a parallel
# build can have one removing what the other is copying.
JOBS ?= 1
CLEAN_JOBS ?=

.PHONY: all
all: prerequisites compile

.PHONY: changed
changed:
	@echo "chapps: $(CHANGED_APPS)"
	@$(ROOT)/scripts/pretty-print-files.bash "changed:" $(PRINTABLE_CHANGED)
	@$(ROOT)/scripts/pretty-print-files.bash "changed ERL:" $(PRINTABLE_ERL)
	@$(ROOT)/scripts/pretty-print-files.bash "changed APPS:" $(PRINTABLE_APPS)
	@$(ROOT)/scripts/pretty-print-files.bash "changed JSON:" $(PRINTABLE_JSON)
	@$(ROOT)/scripts/pretty-print-files.bash "changed YML:" $(PRINTABLE_YML)
	@$(ROOT)/scripts/pretty-print-files.bash "changed docs:" $(PRINTABLE_DOCS)

.PHONY: unstaged
unstaged:
	$(ROOT)/scripts/check-unstaged.bash

.PHONY: changed_swagger
changed_swagger:
	@echo "$(CHANGED_SWAGGER)"

.PHONY: prerequisites
prerequisites: make-dependency-check rebar

.PHONY: make-dependency-check
make-dependency-check:
	$(ROOT)/scripts/make-prerequisite.sh

.PHONY: compile-lean compile-lean-core compile-lean-apps
compile-lean: ACTION = compile-lean
compile-lean: deps compile-lean-core compile-lean-apps
compile-lean-core:
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C core/ compile-lean
compile-lean-apps:
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C applications/ compile-lean

.PHONY: compile
compile: ACTION = all
compile: deps kazoo

## Everything except the checked-in sources: build output, deps, release, tags
.PHONY: sparkly-clean
sparkly-clean: clean clean-release clean-deps clean-tags

.PHONY: clean-kazoo
clean-kazoo: clean

.PHONY: clean
clean: clean-core clean-apps
	$(if $(wildcard *crash.dump), rm *crash.dump)
	$(if $(wildcard scripts/log/*), rm -rf scripts/log/*)
	$(if $(wildcard rel/dev-vm.args), rm rel/dev-vm.args)

.PHONY: clean-core
clean-core:
	@$(if $(wildcard $(CORE_DIR)),ROOT=$(ROOT) $(MAKE) -j$(CLEAN_JOBS) -C $(CORE_DIR) clean)

.PHONY: clean-apps
clean-apps:
	@$(if $(wildcard $(APPS_DIR)/Makefile),ROOT=$(ROOT) $(MAKE) -j$(CLEAN_JOBS) -C $(APPS_DIR) clean)

.PHONY: clean-deps
clean-deps: clean-deps-hash
	@$(if $(wildcard $(DEPS_DIR)), rm -rf $(DEPS_DIR))
	@$(if $(wildcard $(DOT_ERLANG_MK)), rm -rf $(DOT_ERLANG_MK))
	@$(if $(wildcard $(ERLANG_MK)), rm -r $(ERLANG_MK))
	@echo "Cleaned deps-related files"

.PHONY: clean-deps-hash
clean-deps-hash:
	$(if $(wildcard $(ROOT)/make/.deps.mk.*), rm $(ROOT)/make/.deps.mk.*)

.PHONY=dot_erlang_mk
dot_erlang_mk: $(DOT_ERLANG_MK)

$(DOT_ERLANG_MK): $(ERLANG_MK)

$(ERLANG_MK):
	@# This is the exactly what https://erlang.mk/erlang.mk is doing, just adds the checkout part
ifdef ERLANG_MK_COMMIT
	git clone $(ERLANG_MK_REPO) $(ERLANG_MK_BUILD_DIR)
	cd $(ERLANG_MK_BUILD_DIR) && git checkout $(ERLANG_MK_COMMIT)
else
	git clone --depth 1 $(ERLANG_MK_REPO) $(ERLANG_MK_BUILD_DIR)
endif
	if [ -f $(ERLANG_MK_BUILD_CONFIG) ]; then cp $(ERLANG_MK_BUILD_CONFIG) $(ERLANG_MK_BUILD_DIR); fi
	cd $(ERLANG_MK_BUILD_DIR) && $(MAKE)
	cp $(ERLANG_MK_BUILD_DIR)/erlang.mk ./erlang.mk
	rm -rf $(ERLANG_MK_BUILD_DIR)

.PHONY: deps
deps: $(DEPS_HASH_FILE)

$(DEPS_HASH_FILE):
	@$(MAKE) clean-deps
	@$(MAKE) $(DEPS_DIR)/Makefile
	ROOT=$(ROOT) $(MAKE) -C $(DEPS_DIR)/ deps
	@touch $(DEPS_HASH_FILE)

$(DEPS_DIR)/Makefile: $(DOT_ERLANG_MK) $(DEPS_DIR) clean-plt
	@cp $(ROOT)/make/Makefile.deps $(DEPS_DIR)/Makefile
	@$(MAKE) -f $(ERLANG_MK) deps

$(DEPS_DIR):
	@mkdir -p $(DEPS_DIR)

# Target: core
# Compile every application under core/ (core/Makefile orders kazoo_stdlib,
# kazoo_amqp and kazoo_data first)
.PHONY: core
core: deps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(CORE_DIR) all

# Target: apps
# Compile every application under applications/ (every directory with a
# Makefile); APPS_MK can name a subset, e.g. APPS_MK=my_apps.mk with DEPS = a b
.PHONY: apps
apps: core
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(APPS_DIR) all

# The dev-tooling applications 2600hz keeps in their own repos (kazoo-ast for
# the schema generators, kazoo-properly for property tests) are not part of
# this tree; `make $(KAST)` clones kazoo-ast into applications/ast (ignored)
# (pinned: the reprise branch of the fork, upstream master as of 2026-11-21
# plus the fixes this tree needs: OTP 28, applications it does not carry,
# year-independent kzd templates, hand-written maintenance descriptions)
KAZOO_AST_REPO ?= $(REPRISE_GIT_BASE)/kazoo-ast
KAZOO_AST_REF ?= 05b9c135514baa5ed1e07797c7383cf990467cfe

.PHONY: kazoo
kazoo: deps apps $(TAGS)

.PHONY: tags
tags:
	@ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) ./scripts/tags.escript $(TAGS)

$(TAGS): tags

.PHONY: clean-tags
clean-tags:
	$(if $(wildcard $(TAGS)), rm $(TAGS))

.PHONY: fixture_shell
fixture_shell: ERL_CRASH_DUMP = "$(ROOT)/$(shell date +%s)_ecallmgr_erl_crash.dump"
fixture_shell: ERL_LIBS = "$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR):$(shell echo $(DEPS_DIR)/rabbitmq_erlang_client-*/deps)"
fixture_shell: NODE_NAME ?= fixturedb
fixture_shell:
	@ERL_CRASH_DUMP="$(ERL_CRASH_DUMP)" ERL_LIBS="$(ERL_LIBS)" KAZOO_CONFIG=$(ROOT)/rel/config-test.ini \
		erl -setcookie change_me -name '$(NODE_NAME)' -s reloader "$$@"

.PHONY: xref
xref: TO_XREF ?= $(shell $(call FIND_EBINS,$(APPS_DIR) $(CORE_DIR) $(DEPS_DIR)))
xref:
	@$(ROOT)/scripts/check-xref.escript $(TO_XREF)

.PHONY: xref_release
xref_release: TO_XREF = $(shell find $(ROOT)/_rel/kazoo/lib -name ebin)
xref_release:
	@$(ROOT)/scripts/check-xref.escript $(TO_XREF)

.PHONY: sup_completion
sup_completion: sup_completion_file = $(ROOT)/sup.bash
sup_completion:
	@$(if $(wildcard $(sup_completion_file)), rm $(sup_completion_file))
	@$(CORE_DIR)/sup/priv/build-autocomplete.escript $(sup_completion_file) $(APPS_DIR) $(CORE_DIR)
	@echo SUP Bash completion file written at $(sup_completion_file)

.PHONY: bump-copyright
bump-copyright:
	@$(ROOT)/scripts/bump-copyright-year.py $(shell find $(APPS_DIR) $(CORE_DIR) -name '*.erl')

.PHONY: bump-license
bump-license:
	@$(ROOT)/scripts/bump-license.py $(shell find $(APPS_DIR) $(CORE_DIR) -name '*.erl')

.PHONY: app_applications
app_applications:
app_applications:
	ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) $(ROOT)/scripts/apps_of_app.escript -a $(PRINTABLE_APPS)

.PHONY: code_checks
code_checks: bump-changed-copyright bump-changed-license edoc splchk-common raw-json
	@printf "\n:: Check code\n\n"
	@$(ROOT)/scripts/code_checks.bash $(CHANGED_ERL)
	@printf "\n:: Check for Kazoo diaspora\n\n"
	@$(ROOT)/scripts/kz_diaspora.bash
	@printf "\n:: Check for Kazoo document accessors\n\n"
	@$(ROOT)/scripts/kzd_module_check.bash
	@printf "\n:: Check for proper log message usage\n\n"
	@$(ROOT)/scripts/check-loglines.bash $(CHANGED_ERL)
	@printf "\n:: Check for Erlang 21 new stacktrace syntax\n\n"
	@$(ROOT)/scripts/check-stacktrace.py $(CHANGED_ERL)

.PHONY: raw-json
raw-json:
	@printf "\n:: Check for raw JSON usage\n\n"
	@ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) $(ROOT)/scripts/no_raw_json.escript $(CHANGED_ERL)

.PHONY: edoc
edoc:
	@printf "\n:: Check for Edoc\n\n"
	@CHANGED_ERL="$(CHANGED_ERL)" $(ROOT)/scripts/edocify.escript

.PHONY: bump-changed-copyright
bump-changed-copyright:
	@printf ":: Check for copyright year\n\n"
	@$(ROOT)/scripts/bump-copyright-year.py $(CHANGED_ERL)

.PHONY: bump-changed-license
bump-changed-license:
	@printf ":: Check for license\n\n"
	@$(ROOT)/scripts/bump-license.py $(CHANGED_ERL)

.PHONY: raw_json_check
raw_json_check:
	@ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) $(ROOT)/scripts/no_raw_json.escript

.PHONY: check_stacktrace
check_stacktrace:
	@$(ROOT)/scripts/check-stacktrace.py $(shell grep -rl "get_stacktrace" scripts $(APPS_DIR) $(CORE_DIR) --include "*.[e|h]rl" --exclude "kz_types.hrl")

## FIXME: `format-couchdb-view.py` command is a copy-paste from fmt.mk
## Adding this format couchdb view target to circleci steps for every app is painful
## also this formatting is better to be done before validate-js ci step to make sure
## the view is still in correct shape
apis: schemas api_endpoints kzd_builder
	@$(ROOT)/scripts/generate-doc-schemas.py `egrep -rl '(#+) Schema' core/ applications/ | grep -v '.[h|e]rl'`
	@$(ROOT)/scripts/format-json.py $(APPS_DIR)/crossbar/priv/api/swagger.json
	@$(ROOT)/scripts/format-json.py `find $(APPS_DIR) $(CORE_DIR) $(GLEAM_BUILD_PRUNE) -wholename '*/api/*.json' -print`
	@$(ROOT)/scripts/format-couchdb-views.py `find $(CORE_DIR)/kazoo_apps/priv/couchdb/account -name '*.json'`
	@$(ROOT)/scripts/format-couchdb-views.py `find $(APPS_DIR) $(CORE_DIR) $(GLEAM_BUILD_PRUNE) -wholename '*/couchdb/views/*.json' -print`

.PHONY: kzd_builder
kzd_builder:
	@ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) $(ROOT)/scripts/generate-kzd-builders.escript

.PHONY: schemas
schemas: $(KAST)
	@ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) $(ROOT)/scripts/generate-schemas.escript $(CHANGED_ERL)
	@# the file list is read when this line runs (not when make expands the
	@# recipe), so a schema the generator has just created is formatted too;
	@# the copies under a Gleam application's build/ are not ours to format
	@$(ROOT)/scripts/format-json.py `find $(APPS_DIR) $(CORE_DIR) $(GLEAM_BUILD_PRUNE) -wholename '*/schemas/*.json' -print`

.PHONY: api_endpoints
api_endpoints:
	@ERL_LIBS=$(DEPS_DIR):$(CORE_DIR):$(APPS_DIR) $(ROOT)/scripts/generate-api-endpoints.escript

$(KAST):
	git clone -q -n $(KAZOO_AST_REPO) $(KAST)
	git -C $(KAST) checkout -q $(KAZOO_AST_REF)
	@ROOT=$(ROOT) $(MAKE) -C $(KAST) all

.PHONY: validate-swagger
validate-swagger:
	@$(ROOT)/scripts/validate-swagger.py

.PHONY: validate-js
validate-js:
	@$(ROOT)/scripts/validate-js.py $(CHANGED_JSON)

.PHONY: sdks
sdks:
	@$(ROOT)/scripts/make-swag.sh

.PHONY: validate-schemas
validate-schemas:
	@$(ROOT)/scripts/validate-schemas.py $(APPS_DIR)/crossbar/priv/couchdb/schemas

whitespace:
	@$(ROOT)/scripts/check-whitespace.sh $(CHANGED)

## The checks the Gleam packages answer to, in place of the Erlang ones the
## CHANGED filter keeps them out of. Without the gleam binary they are skipped
## with a message, the way the packages' own Makefiles skip compiling.
GLEAM ?= gleam
HAS_GLEAM := $(shell command -v $(GLEAM) 2>/dev/null)

## Runs `gleam $(1)` in every present Gleam package in turn, stopping at the
## first failure.
gleam_in_each = for dir in $(GLEAM_PACKAGES); do \
	    echo ":: gleam $(1) in $$dir"; \
	    ( cd "$(ROOT)/$$dir" && $(GLEAM) $(1) ) || exit 1; \
	 done

.PHONY: gleam-format-check gleam-test gleam-check check-gleam-manifests

ifeq ($(HAS_GLEAM),)

gleam-format-check gleam-test:
	@echo "no gleam binary, skipping $@"

else

gleam-format-check:
	@$(call gleam_in_each,format --check)

gleam-test:
	@$(call gleam_in_each,test)

endif

## Every Gleam application installs its whole shipment into deps/, so two of
## them that resolve a shared package to different versions would overwrite
## each other's copy. This needs no gleam binary: it reads the checked-in
## manifests.
check-gleam-manifests:
	@$(ROOT)/scripts/check-gleam-manifests.bash $(wildcard $(addsuffix /manifest.toml,$(addprefix $(ROOT)/,$(GLEAM_PACKAGES))))

## Serially: the manifests have to agree before the rest means anything, and
## `gleam test` writes build/ trees that share a hex cache.
gleam-check:
	@$(MAKE) check-gleam-manifests
	@$(MAKE) gleam-format-check
	@$(MAKE) gleam-test

include $(ROOT)/make/rebar.mk
include $(ROOT)/make/ci.mk
include $(ROOT)/make/dialyzer.mk
include $(ROOT)/make/docs.mk
include $(ROOT)/make/editor.mk
include $(ROOT)/make/elvis.mk
include $(ROOT)/make/fmt.mk
include $(ROOT)/make/hank.mk
include $(ROOT)/make/pest.mk
include $(ROOT)/make/releases.mk
include $(ROOT)/make/splchk.mk
include $(ROOT)/make/tests.mk
