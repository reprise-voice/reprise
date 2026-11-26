%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc A caller who has not been answered hears a ringback only when one is
%%% configured; a caller already answered always does.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_ringback_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/ecallmgr.hrl").

-define(TONE, <<"%(2000,4000,440,480)">>).
-define(CUSTOM, <<"%(1000,4000,425)">>).
-define(TRANSFER, <<"local_stream://hold">>).

%% Each case is the stored settings, then what each function answers.
settings_test_() ->
    {'foreach'
    ,fun() -> meck:new('kapps_config', ['passthrough', 'non_strict']) end
    ,fun(_) -> meck:unload('kapps_config') end
    ,[{Title, fun() -> check(Stored, Ringback, Transfer) end}
      || {Title, Stored, Ringback, Transfer} <-
             [{"a new cluster plays no ringback to a caller not answered, and the tone to one answered"
              ,[], 'undefined', ?TONE
              }
             ,{"a cluster that stored Kazoo's default keeps playing it to both"
              ,[{<<"default_ringback">>, ?TONE}], ?TONE, ?TONE
              }
             ,{"a stored custom default_ringback is what an answered caller hears too"
              ,[{<<"default_ringback">>, ?CUSTOM}], ?CUSTOM, ?CUSTOM
              }
             ,{"default_transfer_ringback wins for an answered caller"
              ,[{<<"default_ringback">>, ?CUSTOM}, {<<"default_transfer_ringback">>, ?TRANSFER}], ?CUSTOM, ?TRANSFER
              }
             ,{"an empty default_ringback is no ringback"
              ,[{<<"default_ringback">>, <<>>}], 'undefined', ?TONE
              }
             ]
     ]
    }.

check(Stored, Ringback, Transfer) ->
    meck:expect('kapps_config', 'get_ne_binary'
               ,fun(?APP_NAME, Key) ->
                        case props:get_value(Key, Stored) of
                            <<>> -> 'undefined';
                            Value -> Value
                        end
                end
               ),
    ?assertEqual(Ringback, ecallmgr_util:default_ringback()),
    ?assertEqual(Transfer, ecallmgr_util:default_transfer_ringback()).

bridge_exports_test_() ->
    [{"with no ringback for a caller not answered, a bridge exports only the transfer ringback"
     ,?_assertEqual([<<"transfer_ringback=", ?TONE/binary>>]
                   ,ecallmgr_fs_bridge:default_ringback_exports('undefined', ?TONE)
                   )
     }
    ,{"with one, a bridge exports both"
     ,?_assertEqual([<<"ringback=", ?CUSTOM/binary>>, <<"transfer_ringback=", ?TONE/binary>>]
                   ,ecallmgr_fs_bridge:default_ringback_exports(?CUSTOM, ?TONE)
                   )
     }
    ,{"transfer_ringback keeps its own name when exported"
     ,?_assertEqual({<<"transfer_ringback">>, ?TONE}
                   ,ecallmgr_util:get_fs_key_and_value(<<"transfer_ringback">>, ?TONE, <<"uuid">>)
                   )
     }
    ].
