DEPS = apns fcm lager

dep_apns = git $(REPRISE_GIT_BASE)/erlang-apns4erl aba1fa96a4abbbb2c1628ad5d604f482aad4d12f
# once the tip of 2600hz's branch, now on no branch of theirs: the
# reprise-voice fork keeps it reachable as tag reprise-pin-aba1fa96

dep_fcm = git $(REPRISE_GIT_BASE)/erlang-fcm 573e437e1d1769d8f044a32c1d9cfa90dd4160b6
# Firebase cloud messaging
# used by pusher
