.PHONY: clean-test
clean-test: clean-test-core clean-test-apps

.PHONY: clean-test-core
clean-test-core:
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(CORE_DIR) clean-test

.PHONY: clean-test-apps
clean-test-apps:
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(APPS_DIR) clean-test

.PHONY: compile-proper
compile-proper: ERLC_OPTS += -DPROPER
compile-proper: compile-test

.PHONY: compile-test
compile-test: ERLC_OPTS += +nowarn_missing_spec
compile-test: compile-test-core compile-test-apps

.PHONY: compile-test-core
compile-test-core: deps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(CORE_DIR) compile-test-direct

.PHONY: compile-test-apps
compile-test-apps: deps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(APPS_DIR) compile-test-direct

.PHONY: eunit
eunit: eunit-core eunit-apps

## Every test directory is compiled before any suite runs: test helpers are
## shared across applications (kzd_test_fixtures in kazoo_documents is set up
## by kazoo_apps, kazoo_endpoint and kazoo_convert tests), and the per-app
## dependency list cannot be trusted to name them all. The core suites need
## the applications built too, not only core: kazoo_apps reads the system
## config schemas out of crossbar's priv through code:priv_dir/1, which only
## answers once applications/crossbar/ebin exists on the code path. A warm
## CI cache carried it from the previous run and hid that; a cold tree failed
## 44 kazoo_apps tests (build 240).
.PHONY: eunit-core
eunit-core: deps compile-test-core compile-test-apps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(CORE_DIR) eunit

.PHONY: eunit-apps
eunit-apps: deps compile-test-core compile-test-apps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(APPS_DIR) eunit

.PHONY: proper
proper: ERLC_OPTS += -DPROPER
proper: proper-core proper-apps

.PHONY: proper-core
proper-core: deps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(CORE_DIR) proper

.PHONY: proper-apps
proper-apps: deps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(APPS_DIR) proper

.PHONY: test
test: ERLC_OPTS += -DPROPER
test: ERLC_OPTS += +nowarn_missing_spec
test: test-core test-apps

.PHONY: test-core
test-core: deps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(CORE_DIR) test

.PHONY: test-apps
test-apps: deps
	@ROOT=$(ROOT) $(MAKE) -j$(JOBS) -C $(APPS_DIR) test

.PHONY: coverage-report
coverage-report:
	$(ROOT)/scripts/cover.escript

.PHONY: check
check: ERLC_OPTS += -DPROPER
check: compile-test eunit clean kazoo
