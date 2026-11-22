# Standalone build against an installed FreeSWITCH dev tree.
# Point PKG_CONFIG_PATH at <fs-prefix>/lib/pkgconfig if needed, e.g.:
#   PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig make

FS_CFLAGS := $(shell pkg-config --cflags freeswitch)
FS_LIBS := $(shell pkg-config --libs freeswitch)
MODDIR := $(shell pkg-config --variable=modulesdir freeswitch)

RABBIT_CFLAGS := $(shell pkg-config --cflags librabbitmq 2>/dev/null)
RABBIT_LIBS := $(shell pkg-config --libs librabbitmq 2>/dev/null || echo -lrabbitmq)

CC ?= gcc
# no -std: FS headers use GNU extensions; -D_GNU_SOURCE is load-bearing
# (implicit strdup declarations truncate heap pointers otherwise)
CFLAGS += -fPIC -Wall -Werror -D_GNU_SOURCE $(FS_CFLAGS) $(RABBIT_CFLAGS)
LDFLAGS += -shared $(FS_LIBS) $(RABBIT_LIBS)

SRCS := src/mod_reprise.c src/reprise_transport.c src/reprise_profiles.c src/reprise_workers.c \
        src/reprise_node.c src/reprise_commands.c src/reprise_fields.c src/reprise_publisher.c src/reprise_fetch.c \
        src/reprise_events.c src/reprise_kzutils.c src/reprise_dptools.c src/reprise_kzcommands.c src/reprise_tweaks.c src/reprise_endpoints.c src/reprise_cdr.c src/reprise_compat.c \
        src/reprise_presence.c src/reprise_originate.c src/reprise_prompts.c
OBJS := $(SRCS:.c=.o)

# unit tests: the fields/filters grammar, the ${...} expansion engine, the
# kazoo.conf parser, routing keys and the presence-dialog derivation, run
# against libfreeswitch's minimal core (no modules, no config) with the
# in-tree test framework (test/switch_test.h); `make test`
FS_LIBDIR := $(shell pkg-config --variable=libdir freeswitch)
CURL_LIBS := $(shell pkg-config --libs libcurl 2>/dev/null || echo -lcurl) # reprise_kzcommands.c calls libcurl directly
TEST_SRCS := tests/reprise_test.c tests/reprise_endpoint_test.c tests/reprise_commands_test.c tests/reprise_ring_test.c tests/reprise_cdr_test.c tests/reprise_intercept_test.c tests/reprise_loopback_event_test.c tests/reprise_transfer_event_test.c tests/reprise_hold_dtmf_test.c tests/reprise_record_append_test.c
TEST_OBJS := $(TEST_SRCS:.c=.o)

all: mod_reprise.so

mod_reprise.so: $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.c src/reprise.h src/reprise_profiles.h src/reprise_fields.h src/reprise_kz.h src/reprise_endpoint_compat.h
	$(CC) $(CFLAGS) -c -o $@ $<

$(TEST_OBJS): CFLAGS += -Isrc -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable
$(TEST_OBJS): tests/reprise_test_alloc.h tests/reprise_test_util.h

reprise_test: $(OBJS) tests/reprise_test.o
	$(CC) -o $@ $(OBJS) tests/reprise_test.o $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)

# The endpoint test compiles the implementation with two controlled edges.
tests/reprise_endpoint_test.o: src/reprise_endpoints.c
reprise_endpoint_test: $(filter-out src/reprise_endpoints.o,$(OBJS)) tests/reprise_endpoint_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)

tests/reprise_commands_test.o: src/reprise_commands.c
reprise_commands_test: $(filter-out src/reprise_commands.o,$(OBJS)) tests/reprise_commands_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)

tests/reprise_ring_test.o: src/reprise_endpoints.c
reprise_ring_test: $(filter-out src/reprise_endpoints.o,$(OBJS)) tests/reprise_ring_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)

test-ring: reprise_ring_test
	mkdir -p tests/run && cd tests/run && ../../reprise_ring_test

tests/reprise_cdr_test.o: src/reprise_endpoints.c
reprise_cdr_test: $(filter-out src/reprise_endpoints.o,$(OBJS)) tests/reprise_cdr_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)

test-cdr: reprise_cdr_test
	mkdir -p tests/run && cd tests/run && REPRISE_TEST_MODDIR=$(MODDIR) ../../reprise_cdr_test

test: reprise_test reprise_endpoint_test reprise_commands_test
	mkdir -p tests/run && cd tests/run && REPRISE_TEST_FIXTURE=../fixtures/kazoo.conf.xml ../../reprise_test
	cd tests/run && ../../reprise_endpoint_test
	cd tests/run && ../../reprise_commands_test

install: mod_reprise.so
	install -d $(DESTDIR)$(MODDIR)
	install -m 755 mod_reprise.so $(DESTDIR)$(MODDIR)/

clean:
	rm -f $(OBJS) $(TEST_OBJS) mod_reprise.so reprise_test reprise_endpoint_test reprise_commands_test reprise_ring_test reprise_cdr_test reprise_intercept_test reprise_loopback_event_test reprise_transfer_event_test reprise_hold_dtmf_test reprise_record_append_test

.PHONY: all install clean test test-ring test-cdr test-intercept test-loopback-event test-transfer-event test-hold-dtmf test-record-append

tests/reprise_intercept_test.o: src/reprise_dptools.c
tests/reprise_intercept_test.o: CFLAGS += -Isrc -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable
reprise_intercept_test: $(filter-out src/reprise_dptools.o,$(OBJS)) tests/reprise_intercept_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)
test-intercept: reprise_intercept_test
	mkdir -p tests/run && cd tests/run && ../../reprise_intercept_test

FS_SRCDIR ?= /usr/src/freeswitch
tests/reprise_loopback_event_test.o: src/reprise_endpoints.c $(FS_SRCDIR)/src/switch_ivr_bridge.c
tests/reprise_loopback_event_test.o: CFLAGS += -I$(FS_SRCDIR)/src
reprise_loopback_event_test: $(filter-out src/reprise_endpoints.o,$(OBJS)) tests/reprise_loopback_event_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)
test-loopback-event: reprise_loopback_event_test
	mkdir -p tests/run && cd tests/run && ../../reprise_loopback_event_test

reprise_transfer_event_test: $(OBJS) tests/reprise_transfer_event_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)
test-transfer-event: reprise_transfer_event_test
	mkdir -p tests/run && cd tests/run && ../../reprise_transfer_event_test

# The hold and bridge applications compiled in: a digit pressed during
# kz_endless_playback, and during kz_bridge's ring.
tests/reprise_hold_dtmf_test.o: src/reprise_dptools.c
reprise_hold_dtmf_test: $(filter-out src/reprise_dptools.o,$(OBJS)) tests/reprise_hold_dtmf_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)
test-hold-dtmf: reprise_hold_dtmf_test
	mkdir -p tests/run && cd tests/run && ../../reprise_hold_dtmf_test

# record_session through the rewrite: a short new recording is discarded, a
# restart under the same name appends to the file still awaiting upload.
reprise_record_append_test: $(OBJS) tests/reprise_record_append_test.o
	$(CC) -o $@ $^ $(FS_LIBS) $(RABBIT_LIBS) $(CURL_LIBS) -lm -Wl,-rpath,$(FS_LIBDIR)
test-record-append: reprise_record_append_test
	mkdir -p tests/run && cd tests/run && ../../reprise_record_append_test

# These suites share the minimal-core runtime directory.
.NOTPARALLEL: test-call-paths
.PHONY: test-call-paths
test-call-paths: test test-ring test-cdr test-intercept test-loopback-event test-transfer-event test-hold-dtmf test-record-append
