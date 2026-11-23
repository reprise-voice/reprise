%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2018, Voxter Communications Inc
%%% @doc
%%% @author Ben Bradford
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cb_cdrs_test).
-include_lib("eunit/include/eunit.hrl").

%% Test handle_utc_time_offset function with different server
%% time zones and offsets
handle_utc_time_offset_test_() ->
    Timestamp = 63687252084,
    [{"Verify the Atom 'undefined' returns unaltered timestamp"
     ,?_assertEqual(Timestamp, cb_cdrs:handle_utc_time_offset(Timestamp, 'undefined'))
     }
    ,{"Verify the binary <<\"abc\">> triggers a crash as its NAN"
     ,?_assertError('badarg', cb_cdrs:handle_utc_time_offset(Timestamp, <<"bla">>))
     }
    ,{"Verify with offset binary <<\"0\">> returns UTC timestamp"
     ,?_assertEqual(Timestamp, cb_cdrs:handle_utc_time_offset(Timestamp, <<"0">>))
     }
    ].

handle_utc_time_offset_1_test_() ->
    %% {CDR Time Stamp, Resulting Timestamp, UTC offset}
    Timestamp = 63687252084,
    Tests = [{Timestamp, Timestamp - 14400, <<"-14400">>}
            ,{Timestamp, Timestamp + 14400, <<"14400">>}
            ],
    [?_assertEqual(Result, cb_cdrs:handle_utc_time_offset(UTC, Offset)) || {UTC, Result, Offset} <- Tests].

%% `?queue_id=' and `?agent_id=' are aliases for a filter on the channel
%% variable the CDR keeps them in. Without the rewrite they are not filter
%% keys at all, so the listing would ignore them and answer with every call.
expand_ccv_filters_test_() ->
    [{"a queue becomes a filter on the queue channel variable"
     ,?_assertEqual([{<<"filter_custom_channel_vars.queue_id">>, <<"q1">>}]
                   ,expanded([{<<"queue_id">>, <<"q1">>}])
                   )
     }
    ,{"an agent becomes a filter on the agent channel variable"
     ,?_assertEqual([{<<"filter_custom_channel_vars.agent_id">>, <<"a1">>}]
                   ,expanded([{<<"agent_id">>, <<"a1">>}])
                   )
     }
    ,{"both at once, and the originals are gone"
     ,?_assertEqual([{<<"filter_custom_channel_vars.agent_id">>, <<"a1">>}
                    ,{<<"filter_custom_channel_vars.queue_id">>, <<"q1">>}
                    ]
                   ,expanded([{<<"agent_id">>, <<"a1">>}
                             ,{<<"queue_id">>, <<"q1">>}
                             ])
                   )
     }
    ,{"a list of queues is carried through for the filter to decode"
     ,?_assertEqual([{<<"filter_custom_channel_vars.queue_id">>, <<"[\"q1\",\"q2\"]">>}]
                   ,expanded([{<<"queue_id">>, <<"[\"q1\",\"q2\"]">>}])
                   )
     }
    ,{"every other parameter is left alone"
     ,?_assertEqual([{<<"created_from">>, <<"63687252084">>}
                    ,{<<"filter_custom_channel_vars.queue_id">>, <<"q1">>}
                    ]
                   ,expanded([{<<"created_from">>, <<"63687252084">>}
                             ,{<<"queue_id">>, <<"q1">>}
                             ])
                   )
     }
    ,{"a listing with neither is untouched"
     ,?_assertEqual([{<<"created_to">>, <<"63687252084">>}]
                   ,expanded([{<<"created_to">>, <<"63687252084">>}])
                   )
     }
    ].

expanded(QueryString) ->
    Context = cb_context:set_query_string(cb_context:new(), kz_json:from_list(QueryString)),
    lists:sort(kz_json:to_proplist(cb_context:query_string(cb_cdrs:expand_ccv_filters(Context)))).
