## Where the build fetches its forked source repositories from.
##
## Every dependency repository 2600Hz or Vonix maintained (the erlang-* forks
## in make/deps.mk and the applications' deps.mk files, erlang-elvis,
## kazoo-ast) lives in the reprise-voice GitHub organisation under its
## upstream name, so each is fetched from $(REPRISE_GIT_BASE)/<name>, always
## without a .git suffix. To build from a mirror or without github.com, point
## this at a directory or server holding repositories of the same names, e.g.
##   make deps REPRISE_GIT_BASE=file:///srv/git
##   make deps REPRISE_GIT_BASE=git@github.com:reprise-voice   # SSH keys
## (run `make clean-deps` first if deps/ was fetched from elsewhere). The
## docker/*/Dockerfiles take the same value as a build argument of the same
## name; docker/build.sh passes it through from the environment.
REPRISE_GIT_BASE ?= https://github.com/reprise-voice
