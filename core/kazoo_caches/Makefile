CWD = $(shell pwd -P)
ROOT ?= $(realpath $(CWD)/../..)
PROJECT = kazoo_caches

all: compile

## compile-test only, deliberately not compile-test-direct. Other applications
## reach kazoo_caches through compile-test-kz-deps, which calls
## compile-test-direct -- and this target is phony, so hanging it there fired
## it once per dependent application, 65 times a run. `make eunit` here still
## goes through compile-test, and in a full run compile-test-core has built
## both of these long before any suite starts.
compile-test: compile-others

## kz_cache_amqp_tests needs these two compiled with -DTEST, and nothing more.
##
## compile-test-direct, not compile-test: this target is phony, so it re-runs
## every time kazoo_caches is touched -- once per dependent application, 65
## times in a full run -- and compile-test drags in the phony
## compile-test-kz-deps, which deletes and regenerates .test.deps through a
## fresh Erlang VM and re-enters each of their own kazoo dependencies, plus
## the phony json target over kazoo_amqp's 245 files. compile-test-direct is
## guarded by file targets, so a second call costs a Makefile parse and
## nothing else. tests.mk compile-tests all of core and all of applications
## before any suite runs, so the rest was belt-and-braces.
compile-others:
	$(MAKE) compile-test-direct -C $(ROOT)/core/kazoo_amqp
	$(MAKE) compile-test-direct -C $(ROOT)/core/kazoo_bindings

include $(ROOT)/make/kz.mk
