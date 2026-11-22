%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2016-2025, 2600Hz
%%% (C) 2026, Vonix LLC
%%% @doc Tests for the Telnyx API v2 carrier and its providers.
%%%
%%% The request shapes themselves are asserted inside the `-ifdef(TEST)'
%%% clauses of {@link knm_telnyx2_util}: reaching a fixture at all means the
%%% module sent the method, path, filters and body that Telnyx documents.
%%% What follows checks the behaviour built on top of that.
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_telnyx2_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/knm.hrl").

-export([db_dependant/0]).

-define(ORDER_ID, <<"12ade33a-21c0-473b-b055-b3c836e1c292">>).
-define(ADDRESS_ID, <<"1293384261075731501">>).

knm_number_test_() ->
    knm_test_util:start_db(fun db_dependant/0).

db_dependant() ->
    [api()
    ,acquire_number()
    ,cnam()
    ,e911()
    ].

api() ->
    Options = [{'account_id', ?RESELLER_ACCOUNT_ID}
              ,{'carriers', [<<"knm_telnyx2">>]}
              ,{'query_id', <<"QID">>}
              ],
    {'setup'
    ,fun () -> {'ok', Pid} = knm_search:start_link(), Pid end
    ,fun gen_server:stop/1
    ,fun (_ReturnOfSetup) ->
             [find_numbers(Options)
             ,find_international_numbers(Options)
             ]
     end
    }.

find_numbers(Options0) ->
    [[{"Verify found numbers"
      ,?_assertEqual(Limit, length(Results))
      }
     ,{"Verify results match queried prefix"
      ,?_assertEqual('true', lists:all(matcher(<<"+1">>, Prefix), Results))
      }
     ]
     || {Prefix, Limit} <- [{<<"301359">>, 5}
                           ,{<<"800">>, 2}
                           ],
        Options <- [[{'quantity', Limit}
                    ,{'prefix', Prefix}
                     | Options0
                    ]],
        Results <- [knm_search:find(Options)]
    ].

find_international_numbers(Options0) ->
    Country = <<"GB">>,
    [[{"Verify found numbers"
      ,?_assertEqual(Limit, length(Results))
      }
      %% unlike v1, v2 returns real E.164 numbers for an international search
      %% rather than bare prefixes needing to be padded out
     ,{"Verify results match queried prefix"
      ,?_assertEqual('true', lists:all(matcher(<<"+44">>, Prefix), Results))
      }
     ]
     || {Prefix, Limit} <- [{<<"1">>, 2}
                           ],
        Options <- [[{'country', Country}
                    ,{'quantity', Limit}
                    ,{'prefix', Prefix}
                     | Options0
                    ]],
        Results <- [knm_search:find(Options)]
    ].

matcher(Dialcode, Prefix) ->
    fun (Result) ->
            Num = <<Dialcode/binary, Prefix/binary>>,
            Size = byte_size(Num),
            case kz_json:get_value(<<"number">>, Result) of
                <<Num:Size/binary, _/binary>> -> 'true';
                _Else -> 'false'
            end
    end.

%%------------------------------------------------------------------------------
%% @doc A v2 order comes back `pending' and has to be polled until it settles.
%% @end
%%------------------------------------------------------------------------------
acquire_number() ->
    Num = ?TEST_TELNYX2_NUM,
    PN = knm_phone_number:from_number(Num),
    Result = knm_telnyx2:acquire_number(PN),
    [{"Verify number is still the one inputed"
     ,?_assertEqual(Num, knm_phone_number:number(Result))
     }
    ,{"Verify the settled order id is kept on the number"
     ,?_assertEqual(?ORDER_ID
                   ,kz_json:get_ne_binary_value(<<"order_id">>, knm_phone_number:carrier_data(Result))
                   )
     }
    ].

%%------------------------------------------------------------------------------
%% @doc Both halves of CNAM go out as one `PATCH …/voice'.
%% @end
%%------------------------------------------------------------------------------
cnam() ->
    CNAM = kz_json:from_list(
             [{?CNAM_INBOUND_LOOKUP, 'true'}
             ,{?CNAM_DISPLAY_NAME, <<"my CNAM">>}
             ]),
    PN1 = knm_telnyx2_cnam:save(in_service(kz_json:from_list([{?FEATURE_CNAM, CNAM}]))),
    PN2 = knm_telnyx2_cnam:save(reset_doc(PN1, kz_json:new())),
    PN3 = knm_telnyx2_cnam:delete(PN1),
    %% Telnyx only accepts alphanumerics and spaces, capped at 15 characters;
    %% knm_telnyx2_util asserts on what actually goes out
    Unruly = <<"Wile E. Coyote, Super-Genius">>,
    Unruly1 = knm_telnyx2_cnam:save(
                in_service(
                  kz_json:from_list(
                    [{?FEATURE_CNAM, kz_json:from_list([{?CNAM_DISPLAY_NAME, Unruly}])}]))),
    [{"Verify inbound CNAM is activated"
     ,?_assertEqual('true', is_cnam_activated(PN1))
     }
    ,{"Verify outbound CNAM is set"
     ,?_assertEqual(<<"my CNAM">>, cnam_name(PN1))
     }
    ,{"Verify inbound CNAM is deactivated once removed from the doc"
     ,?_assertEqual('false', is_cnam_activated(PN2))
     }
    ,{"Verify outbound CNAM is reset once removed from the doc"
     ,?_assertEqual('undefined', cnam_name(PN2))
     }
    ,{"Verify deleting the number clears every CNAM feature"
     ,?_assertEqual([], knm_phone_number:features_list(PN3))
     }
    ,{"Verify the display name Kazoo stores is left as the user typed it"
     ,?_assertEqual(Unruly, cnam_name(Unruly1))
     }
    ].

is_cnam_activated(PN) ->
    kz_json:is_true(?CNAM_INBOUND_LOOKUP, knm_phone_number:feature(PN, ?FEATURE_CNAM_INBOUND)).

cnam_name(PN) ->
    Outbound = knm_phone_number:feature(PN, ?FEATURE_CNAM_OUTBOUND),
    kz_json:get_ne_binary_value(?CNAM_DISPLAY_NAME, Outbound).

%%------------------------------------------------------------------------------
%% @doc E911 is a create-address then arm-the-number pair, and the address may
%% only be released after the number has been disarmed.
%% @end
%%------------------------------------------------------------------------------
e911() ->
    E911 = kz_json:from_list(
             [{?E911_STREET1, <<"301 Marina Blvd.">>}
             ,{?E911_CITY, <<"San Francisco">>}
             ,{?E911_STATE, <<"CA">>}
             ,{?E911_ZIP, <<"94123">>}
             ]),
    JObj = kz_json:from_list([{?FEATURE_E911, E911}]),
    Moved = kz_json:from_list(
              [{?FEATURE_E911
               ,kz_json:from_list([{?E911_STREET1, <<"1 Market St.">>}
                                  ,{?E911_CITY, <<"San Francisco">>}
                                  ,{?E911_STATE, <<"CA">>}
                                  ,{?E911_ZIP, <<"94105">>}
                                  ])
               }
              ]),
    PN1 = knm_telnyx2_e911:save(in_service(JObj)),
    %% saving again with the same address must not re-provision
    PN2 = knm_telnyx2_e911:save(reset_doc(PN1, JObj)),
    PN3 = knm_telnyx2_e911:delete(PN1),
    PN4 = knm_telnyx2_e911:save(reset_doc(PN1, Moved)),
    [{"Verify feature is properly set"
     ,?_assert(kz_json:are_equal(E911, knm_phone_number:feature(PN1, ?FEATURE_E911)))
     }
    ,{"Verify we are keeping track of intermediary address_id"
     ,?_assertEqual(?ADDRESS_ID, address_id(PN1))
     }
    ,{"Verify an unchanged address is left alone"
     ,?_assert(kz_json:are_equal(E911, knm_phone_number:feature(PN2, ?FEATURE_E911)))
     }
    ,{"Verify we are keeping track of the same intermediary address_id"
     ,?_assertEqual(?ADDRESS_ID, address_id(PN2))
     }
    ,{"Verify deleting the number clears the e911 feature"
     ,?_assertEqual('undefined', knm_phone_number:feature(PN3, ?FEATURE_E911))
     }
    ,{"Verify the released address is no longer referenced"
     ,?_assertEqual('undefined', address_id(PN3))
     }
    ,{"Verify moving to a new address updates the feature"
     ,?_assert(kz_json:are_equal(kz_json:get_value(?FEATURE_E911, Moved)
                                ,knm_phone_number:feature(PN4, ?FEATURE_E911)
                                ))
     }
    ,{"Verify moving to a new address repoints the number at the new one"
     ,?_assertEqual(<<"1293384261075731502">>, address_id(PN4))
     }
    ].

address_id(PN) ->
    kz_json:get_ne_binary_value(<<"address_id">>, knm_phone_number:carrier_data(PN)).

%%------------------------------------------------------------------------------
%% @doc The v2 filters are bracketed, and the query-string encoder is the thing
%% that renders the brackets. Encoding them by hand as well double-escapes the
%% `%' and Telnyx silently ignores every filter.
%% @end
%%------------------------------------------------------------------------------
query_string_test_() ->
    Query = [{<<"filter">>
             ,[{<<"limit">>, 5}
              ,{<<"best_effort">>, 'false'}
              ,{<<"national_destination_code">>, <<"301">>}
              ,{<<"phone_number">>, [{<<"starts_with">>, <<"359">>}]}
              ]
             }],
    QS = knm_telnyx2_util:query_string(Query),
    Sparse = knm_telnyx2_util:query_string(
               [{<<"filter">>, [{<<"limit">>, 5}
                               ,{<<"phone_number">>, [{<<"starts_with">>, 'undefined'}]}
                               ]}]),
    [{"Verify a scalar filter is bracketed"
     ,?_assert(contains(QS, <<"filter%5Blimit%5D=5">>))
     }
    ,{"Verify a nested filter is bracketed twice"
     ,?_assert(contains(QS, <<"filter%5Bphone_number%5D%5Bstarts_with%5D=359">>))
     }
    ,{"Verify booleans survive"
     ,?_assert(contains(QS, <<"filter%5Bbest_effort%5D=false">>))
     }
    ,{"Verify nothing is double-escaped"
     ,?_assertEqual('nomatch', binary:match(QS, <<"%25">>))
     }
    ,{"Verify undefined filters drop out entirely"
     ,?_assertEqual('nomatch', binary:match(Sparse, <<"starts_with">>))
     }
    ].

contains(Haystack, Needle) ->
    'nomatch' =/= binary:match(Haystack, Needle).

%%%=============================================================================
%%% Helpers
%%%=============================================================================

%% A number in the state the providers actually run against.
in_service(Doc) ->
    {'ok', PN} =
        knm_phone_number:setters(knm_phone_number:from_number(?TEST_TELNYX2_NUM)
                                ,[{fun knm_phone_number:set_assigned_to/2, ?RESELLER_ACCOUNT_ID}
                                 ,{fun knm_phone_number:set_module_name/2, <<"knm_telnyx2">>}
                                 ,{fun knm_phone_number:set_state/2, ?NUMBER_STATE_IN_SERVICE}
                                 ,{fun knm_phone_number:reset_doc/2, Doc}
                                 ]),
    PN.

reset_doc(PN, Doc) ->
    knm_phone_number:reset_doc(PN, Doc).
