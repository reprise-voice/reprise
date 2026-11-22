CWD = $(shell pwd -P)
ROOT ?= $(realpath $(CWD)/../..)
PROJECT = kazoo_stdlib

LEX_SOURCES = $(wildcard src/*.[xy]rl)
LEX_FILES := $(sort $(foreach module,$(LEX_SOURCES),src/$(shell basename $(module) | cut -d. -f1).erl))

SOURCES = $(wildcard src/*.erl) $(wildcard src/*/*.erl) $(LEX_FILES)

all: compile

clean: lex-clean

compile: $(LEX_FILES)

compile-test: $(LEX_FILES)

compile-test-direct: $(LEX_FILES)

lex-clean:
	@rm -f $(LEX_FILES)

$(LEX_FILES): $(LEX_SOURCES)
	@erlc -W0 -o src/ $?

## The .app rules in kz.mk compile $(SOURCES) and $(TEST_SOURCES) wholesale
## without naming them as prerequisites, so the generated parsers have to be
## named here or erlc reaches them before erlc has written them.
##
## Declaring it on compile/compile-test-direct above is not enough. kz.mk's
## `compile` carries no recipe, so the two rules' prerequisites merge in the
## order read and $(LEX_FILES) -- read first, here -- is built first. Its
## `compile-test-direct` DOES carry a recipe, so that rule's prerequisites are
## ordered first and these are appended after test/$(PROJECT).app. `make
## eunit` on a tree that had not already been compiled tripped over exactly
## that; it only ever worked because `make core apps` ran first and generated
## them on the way past.
ebin/$(PROJECT).app: $(LEX_FILES)
test/$(PROJECT).app: $(LEX_FILES)

include $(ROOT)/make/kz.mk
