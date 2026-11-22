%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(crossbar_auth_tests).

-include_lib("eunit/include/eunit.hrl").
-include("crossbar.hrl").

-define(METHOD, <<"cb_conference_auth">>).

%% system_config is absent, so the system defaults apply: an hour for a
%% method with no setting of its own, a year at most.
token_auth_expiry_test_() ->
    {'setup'
    ,fun setup/0
    ,fun cleanup/1
    ,fun(_) ->
             [{"a method configured with infinity gets the maximum lifetime"
              ,?_test(assert_lifetime(?SECONDS_IN_YEAR, expiry(<<"infinity">>)))
              }
             ,{"a positive setting is the lifetime"
              ,?_test(assert_lifetime(600, expiry(600)))
              }
             ,{"zero gets the maximum lifetime"
              ,?_test(assert_lifetime(?SECONDS_IN_YEAR, expiry(0)))
              }
             ,{"a setting above the maximum is capped"
              ,?_test(assert_lifetime(?SECONDS_IN_YEAR, expiry(2 * ?SECONDS_IN_YEAR)))
              }
             ,{"a method with no setting gets the system default"
              ,?_test(assert_lifetime(?SECONDS_IN_HOUR, crossbar_auth:token_auth_expiry(?METHOD, [], kz_json:new())))
              }
             ,{"an expiration in the token options is used as given"
              ,?_assertEqual(1234567890, crossbar_auth:token_auth_expiry(?METHOD, [{'expiration', 1234567890}], kz_json:new()))
              }
             ]
     end
    }.

%% A method minted by another application, with no crossbar module behind
%% it, is known to the default configuration only once crossbar.auth's
%% external_auth_methods lists it.
-define(EXTERNAL_METHOD, <<"cb_example_auth">>).

external_auth_method_test_() ->
    Config = crossbar_auth:default_auth_config([?EXTERNAL_METHOD]),
    Plain = crossbar_auth:default_auth_config([]),
    [{"an external method is enabled with an hour's expiry"
     ,?_assertEqual(?SECONDS_IN_HOUR
                   ,kz_json:get_integer_value([?EXTERNAL_METHOD, <<"token_auth_expiry_s">>], Config)
                   )
     }
    ,{"an external method is enabled by default"
     ,?_assert(kz_json:is_true([?EXTERNAL_METHOD, <<"enabled">>], Config))
     }
    ,{"no external method is known unless listed"
     ,?_assertEqual('undefined', kz_json:get_value(?EXTERNAL_METHOD, Plain))
     }
    ,{"listing a crossbar module does not replace its defaults"
     ,?_assertEqual(kz_json:get_value(?METHOD, Plain)
                   ,kz_json:get_value(?METHOD, crossbar_auth:default_auth_config([?METHOD]))
                   )
     }
    ,{"the external methods are read from crossbar.auth, empty by default"
     ,external_methods_setting('undefined', [])
     }
    ,{"a single external method set as a string is a list of one"
     ,external_methods_setting(?EXTERNAL_METHOD, [?EXTERNAL_METHOD])
     }
    ,{"a list of external methods is read as it is"
     ,external_methods_setting([?EXTERNAL_METHOD, ?METHOD], [?EXTERNAL_METHOD, ?METHOD])
     }
    ].

%% kapps_config:get_ne_binaries/3 answers with the default when the key is
%% unset, a binary for a string, and a list for a list.
external_methods_setting(Setting, Expected) ->
    {'setup'
    ,fun() ->
             _ = meck:new('kapps_config', []),
             meck:expect('kapps_config', 'get_ne_binaries'
                        ,fun(<<"crossbar.auth">>, <<"external_auth_methods">>, Default) ->
                                 case Setting of
                                     'undefined' -> Default;
                                     _ -> Setting
                                 end
                         end
                        )
     end
    ,fun cleanup/1
    ,?_assertEqual(Expected, crossbar_auth:external_auth_methods())
    }.

setup() ->
    _ = meck:new('kz_datamgr', []),
    meck:expect('kz_datamgr', 'open_doc', fun(_, _) -> {'error', 'not_found'} end).

cleanup(_) ->
    meck:unload().

expiry(Setting) ->
    AuthConfig = kz_json:set_value([?METHOD, <<"token_auth_expiry_s">>], Setting, kz_json:new()),
    crossbar_auth:token_auth_expiry(?METHOD, [], AuthConfig).

assert_lifetime(Expected, Expiration) ->
    Lifetime = Expiration - kz_time:current_unix_tstamp(),
    ?assert(is_integer(Expiration)),
    ?assert(Lifetime >= Expected - 5 andalso Lifetime =< Expected).
