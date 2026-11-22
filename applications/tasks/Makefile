CWD = $(shell pwd -P)
ROOT ?= $(realpath $(CWD)/../..)
PROJECT = tasks

## Generated, then included by the sources, so they have to exist before the
## .app rules compile anything. COMPILE_MOAR is where kz.mk expects an
## application to say so; `headers` below is kept as a convenience name.
COMPILE_MOAR = src/modules/kt_rates.hrl src/task_modules.hrl

all: compile

compile: headers

compile-test: headers

compile-test-direct: headers

headers: $(COMPILE_MOAR)

src/modules/kt_rates.hrl:
	./priv/schema_to_header.py $(ROOT)/applications/crossbar/priv/couchdb/schemas/rates.json src/modules/kt_rates.hrl

src/task_modules.hrl:
	./priv/list_task_modules.py

clean: clean-headers

clean-headers:
	@rm -f src/modules/kt_rates.hrl
	@rm -f src/task_modules.hrl

include $(ROOT)/make/kz.mk
