## 3rd party dependencies

# REPRISE_GIT_BASE: where the reprise-voice forks are fetched from
include $(ROOT)/make/repos.mk

DEPS ?=  amqp_client \
	amqp_dist \
	apns \
	couchbeam \
	cowboy \
	cowlib \
	eflame \
	eiconv \
	epgsql \
	erlazure \
	erlcloud \
	erlsom \
	erlydtl \
	ersip \
	esaml \
	fcm \
	folsom \
	gen_smtp \
	getopt \
	gproc \
	gun \
	hackney \
	hep \
	inet_cidr \
	jesse \
	jiffy \
	lager \
	lager_syslog \
	meck \
	meta \
	nklib \
	plists \
	poolboy \
	proper \
	qdate \
	qdate_localtime \
	qrcode \
	ra \
	ranch \
	recon \
	reloader \
	relx \
	soap \
	syslog \
	trie \
	yamerl \
	zucchini

ifeq ($(CIRCLECI),true)
    DEPS += coveralls
    dep_coveralls = git https://github.com/markusn/coveralls-erl 1.4.0
endif

# 3.12 doesn't compile on OTP 28 (format_rdn conditional-compilation branch);
# 4.3.x also matches the RabbitMQ 4.3.x broker
dep_amqp_client = hex 4.3.4

# vendored in this tree (vendor/amqp_dist: 2600hz erlang-amqp_dist b26715d7 +
# GEN_SERVER_CALL_TIMEOUT undef for rabbit_common 4.x); copied into deps/ by
# erlang.mk's cp fetch method so it builds like every other dep
dep_amqp_dist = cp $(ROOT)/vendor/amqp_dist

dep_esaml = git $(REPRISE_GIT_BASE)/erlang-esaml 9fe06697234113eb1a64a009a6a1167ba72c9c04
# priv app usage, branch 2600Hz-otp-26

# dep_certifi = hex 0.3.0
# Used by hackney, let it pull in certifi

# dep_chatterbox = hex 0.7.0
# used by apns4erl

# branch: 2600hz-otp26
dep_couchbeam = git $(REPRISE_GIT_BASE)/erlang-couchbeam 9191e7fd004dcc2a475afceeefcebc408c002805

# branch: fix-intermittent-chunked-response-hang (until PR merged)
dep_hackney = git $(REPRISE_GIT_BASE)/erlang-hackney afdc713d2a6517314730b4f6e3e874c06debd2e4

# Based off 2600Hz-2.12.0 branch
dep_cowboy = git $(REPRISE_GIT_BASE)/erlang-cowboy 50c21ad6b8170567b86b573b11fc95c38b58fb74

dep_eflame = git $(REPRISE_GIT_BASE)/erlang-eflame 4faa5a7064b31903f71a90d6ad79c66fa63d591d
# used by kz_tracers

# Django templates; without a dep_ line erlang.mk's package index would fetch
# the moving master branch, so it is pinned to master's tip as of 2026-11-21
dep_erlydtl = git https://github.com/erlydtl/erlydtl aae414692b6052e96d890e03bbeeeca0f4dc01c2

dep_eiconv = git https://github.com/zotonic/eiconv 1.0.0
# used by gen_smtp

dep_epgsql = git https://github.com/epgsql/epgsql 7ba52768cf0ea7d084df24d4275a88eef4db13c2
# used to store tabulator events, branch 2600Hz-otp-26

dep_erlang_localtime = git $(REPRISE_GIT_BASE)/erlang-localtime a0e19d15cd9c89c502a85b189eb8a7611bfb7548
# used by kazoo_documents, teletype, notify, crossbar, callflow
# branch 2600hz

dep_erlazure = git $(REPRISE_GIT_BASE)/erlang-erlazure 0b7b6a82c3b8b14ad8de515bf23a578029177749
# used by kazoo_attachments
# branch: 2600hz-kzoo-626

dep_erlcloud = git $(REPRISE_GIT_BASE)/erlang-erlcloud 9fd232d08063a691ed4294ce3b8e4b99bf84fdda
# 2600Hz-otp-26 branch
# used by kazoo_attachments and a crossbar test (cb_storage_tests)

dep_ersip = git $(REPRISE_GIT_BASE)/erlang-ersip 5125e187807eff8dd507baa7fa6113e374d08ccb
# used by properly, webhooks
# branch 2600Hz-otp-26

## Code reloaders for dev VMs, uncomment if desired
# dep_fs_event = git https://github.com/jamhed/fs_event 783400da08c2b55c295dbec81df0d926960c0346
# dep_fs_sync = git https://github.com/jamhed/fs_sync 2cf85cf5861221128f020c453604d509fd37cd53

# used by teletype, notify, and fax
# branch: 2600Hz-otp-26-fixed
dep_gen_smtp = git $(REPRISE_GIT_BASE)/erlang-gen_smtp e403e4f85783897fae3bd516c34b436cc5c08f42

dep_getopt = git $(REPRISE_GIT_BASE)/erlang-getopt v1.0.1
# used in some scripts/ and sup

dep_gproc = git $(REPRISE_GIT_BASE)/erlang-gproc 9f71a37fce4d58480a742b44458e4937c77f55c5
# used by kazoo_events, webseq, konami, acdc, ecallmgr, callflow
# based off master branch atm (no 2600Hz commits)

# dep_horse = git https://github.com/ninenines/horse 4dc81d47c3116b38af673481402f34ce03f8936b
# used by kazoo_stdlib in some test modules
# uncomment if you want to do simple perf testing of code

dep_inet_cidr = git $(REPRISE_GIT_BASE)/erlang-inet_cidr 1.0.2
# used by kz_network_utils

# used by kazoo_schemas primarily
# branch: otp-26 + external format validator
dep_jesse = git $(REPRISE_GIT_BASE)/erlang-jesse 35eabb483c3541ca0ad631b7bc5e333655303205

dep_jiffy = git $(REPRISE_GIT_BASE)/erlang-jiffy c3b68f0dba2851bc7b2c79abe802ed9bab57c887
# add an option to return error on duplicate key when decoding
# includes changes from lazedo/utf8
# used by kz_json, nklib, jesse, lager, maybe couchbeam if compiled

dep_lager = git $(REPRISE_GIT_BASE)/erlang-lager 6159a9497be54ac94fe00d9b9940b1bb7e423021
# used everywhere

dep_lager_syslog = git $(REPRISE_GIT_BASE)/erlang-lager_syslog 3.0.3

dep_meck = git $(REPRISE_GIT_BASE)/erlang-meck 0.8.13
# used in tests for kazoo_voicemail, crossbar, teletype, and other deps

dep_nklib = git $(REPRISE_GIT_BASE)/erlang-nklib ed8097b4e3bac43864cfe5d522c7907b150b7037
# used by kzsip_uri and cb_registrations
# branch 2600Hz-otp-26

# dep_parse_trans = git https://github.com/lazedo/parse_trans
# appears unused

dep_plists = git $(REPRISE_GIT_BASE)/erlang-plists 909aec1ffc2dfd651b880af8138346daff1cc407
# used by a handful of core apps
# 2600Hz-otp-26 branch

dep_poolboy = git $(REPRISE_GIT_BASE)/erlang-poolboy 9212a8770edb149ee7ca0bca353855e215f7cba5

dep_proper = git $(REPRISE_GIT_BASE)/erlang-proper a5ae5669f01143b0828fc21667d4f5e344aa760b
# used by kazoo_proper, knm, kazoo_caches, kazoo_bindings, kz_util_tests, kazoo_token_buckets, kazoo_stdlib
# used by apps hotornot and callflow
# otp 26 fixes from upstream in after this hash

dep_recon = git $(REPRISE_GIT_BASE)/erlang-recon 2.5.5

dep_ra = git https://github.com/rabbitmq/ra.git v2.17.1

dep_ranch = git $(REPRISE_GIT_BASE)/erlang-ranch 1.8.0

dep_reloader = git $(REPRISE_GIT_BASE)/erlang-reloader de1e6c74204b61ccf3b3652f05c6a7dec9e8257d
# Development-related for reloading beam files
# see rel/dev.vm.args and fixture_shell in make/kz.mk
# commit adds makefile for compile/clean

dep_syslog = git $(REPRISE_GIT_BASE)/erlang-syslog bbad537a1cb5e4f37e672d2e2665659e850662d0

# dep_wsock = git https://github.com/madtrick/wsock 1.1.7
# appears unused

dep_yamerl = git $(REPRISE_GIT_BASE)/erlang-yamerl v0.7.0
# used by kazoo_ast to create OpenAPI 3

dep_zucchini = git $(REPRISE_GIT_BASE)/erlang-zucchini 0.1.0
# INI file parser
# used by kazoo_config_init

dep_trie = git $(REPRISE_GIT_BASE)/erlang-trie v1.7.5
# used by hotornot

dep_cowlib = git $(REPRISE_GIT_BASE)/erlang-cowlib 2.13.0

dep_gun = git $(REPRISE_GIT_BASE)/erlang-gun 2600hz-2.0.0-pre.3

dep_apns = git $(REPRISE_GIT_BASE)/erlang-apns4erl 2600hz-2.4.4

dep_folsom = git $(REPRISE_GIT_BASE)/erlang-folsom 1f3f610d1498d4ae2625178daaac5fc4f5306969
# 2600Hz-otp-26 branch
# used by hangups


dep_fcm = git $(REPRISE_GIT_BASE)/erlang-fcm 573e437e1d1769d8f044a32c1d9cfa90dd4160b6
# Firebase cloud messaging
# used by pusher

dep_hep = git $(REPRISE_GIT_BASE)/hep-erlang 5f18e91e45d49d3d7013fc93897d5c12441d86d8
# Homer encapsulation protocol
# merged lazedo/hep changes
# added specs for dialyzer happiness

# runtime code generation
dep_meta = git $(REPRISE_GIT_BASE)/erlang-meta 0.1.3

# used for WSDL->record and WSDL RPC calls
dep_soap = git $(REPRISE_GIT_BASE)/erlang-soap dbdca669b4b0ef5d4ee25e60a36db9f6b2a4599e

# XML lib
# the tip of the 2600Hz branch (formerly pinned to the branch itself)
dep_erlsom = git $(REPRISE_GIT_BASE)/erlang-erlsom 18818971e0ca33a3251299d1390c4ec2bacadf56

# OTP release builder
dep_relx = git https://github.com/erlware/relx v4.9.0

# Used by kazoo_auth
# 2600Hz-otp-2 6branch
dep_qrcode = git $(REPRISE_GIT_BASE)/erlang-qrcode 7faa72913a4f8267c10d8f4a82685f73122f00d6

# the pinned 2600hz commit has an orphaned -spec, an error since OTP 27
dep_qdate = hex 0.7.4
dep_qdate_localtime = git $(REPRISE_GIT_BASE)/erlang-qdate_localtime cee705be45df8bcdcc7f77d371d4b34ef52d369b

## Dependencies of dependencies that 2600Hz forked too: erlcloud names
## 2600hz/erlang-lhttpc, folsom 2600hz/erlang-bear (by branch) and fcm
## 2600hz/erlang-google-oauth in their own rebar.config/Makefile. erlang.mk
## fetches a nested dependency only when deps/ lacks it, so listing them
## alongside their parent fetches them first, from the reprise-voice forks, at
## the commits the nested references resolve to (bear: the tip of
## 2600Hz-otp-26 as of 2026-11-21).
NESTED_FORK_DEPS := $(if $(filter erlcloud,$(DEPS)),lhttpc) \
	$(if $(filter folsom,$(DEPS)),bear) \
	$(if $(filter fcm,$(DEPS)),google_oauth)
DEPS += $(NESTED_FORK_DEPS)
dep_lhttpc = git $(REPRISE_GIT_BASE)/erlang-lhttpc 56154a701da843a8ac3e2235382e77a5459332c4
dep_bear = git $(REPRISE_GIT_BASE)/erlang-bear 30ce6689fc08623a1a2797cbd7ba072e3e511978
dep_google_oauth = git $(REPRISE_GIT_BASE)/erlang-google-oauth 80bb55a4f3f89cc9b2e7521323f3cbdfeacf5cab
