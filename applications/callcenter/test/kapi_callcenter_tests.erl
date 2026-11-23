%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `kapi_callcenter', the contract every node of the call center and every
%% consumer of its events reads: what each definition accepts and refuses,
%% where each publisher sends, what the bindings bind, and that the schemas
%% Crossbar documents say the same as the definitions.
%%
%% The validators are `kapi_definition:validate/2' over the definition's own
%% lists, and `platform_fakes' stands `kz_api''s checks in for it: default
%% headers, required headers, allowed values, types.
-module(kapi_callcenter_tests).

-include_lib("eunit/include/eunit.hrl").

-import(callcenter_messages, [message/1, full/1]).

-define(ACCOUNT, (callcenter_messages:account())).
-define(QUEUE, (callcenter_messages:queue())).
-define(AGENT, (callcenter_messages:agent())).
-define(CALL, (callcenter_messages:call())).

-define(SCHEMAS, "../crossbar/priv/couchdb/schemas").

-define(EVENTS, callcenter_messages:events()).

-define(DEFAULT_HEADERS, [<<"App-Name">>, <<"App-Version">>, <<"Event-Category">>
                         ,<<"Event-Name">>, <<"Msg-ID">>
                         ]).

with_platform(Tests) ->
    {'setup', fun platform_fakes:start/0, fun platform_fakes:stop/1, Tests}.

definition(EventName) -> kapi_callcenter:api_definition(EventName).

valid(EventName, Message) ->
    Validate = kapi_definition:validate_fun(definition(EventName)),
    Validate(Message).

%% --- The definitions --------------------------------------------------------

definitions_test_() ->
    with_platform(
      [?_assertEqual(?EVENTS
                    ,[kapi_definition:name(D) || D <- kapi_callcenter:api_definitions()]
                    )
      ,[{binary_to_list(Name), fun() -> definition_is_whole(Name) end} || Name <- ?EVENTS]
      ]).

definition_is_whole(Name) ->
    Definition = definition(Name),
    ?assertEqual(Definition, kapi_callcenter:api_definition(binary_to_atom(Name, 'utf8'))),
    ?assertEqual(<<"callcenter">>, kapi_definition:category(Definition)),
    ?assert(is_binary(kapi_definition:friendly_name(Definition))),
    ?assert(is_binary(kapi_definition:description(Definition))),
    ?assert(lists:member({<<"Event-Category">>, <<"callcenter">>}, kapi_definition:values(Definition))),
    ?assert(lists:member({<<"Event-Name">>, Name}, kapi_definition:values(Definition))),
    %% Its validator and builder are the module's own, by the event's name.
    Validator = binary_to_atom(<<Name/binary, "_v">>, 'utf8'),
    Builder = binary_to_atom(Name, 'utf8'),
    ?assertEqual({'module', 'kapi_callcenter'}, erlang:fun_info(kapi_definition:validate_fun(Definition), 'module')),
    ?assertEqual(Validator, fun_name(kapi_definition:validate_fun(Definition))),
    ?assertEqual(Builder, fun_name(kapi_definition:build_fun(Definition))),
    %% A header is required or optional, not both, and each is typed.
    Required = kapi_definition:required_headers(Definition),
    Optional = kapi_definition:optional_headers(Definition),
    ?assertEqual([], [H || H <- Required, lists:member(H, Optional)]),
    Typed = [K || {K, _} <- kapi_definition:types(Definition)],
    Enumerated = [K || {K, V} <- kapi_definition:values(Definition), is_list(V)],
    ?assertEqual([], [H || H <- Required ++ Optional,
                           not lists:member(H, Typed ++ Enumerated)
                     ]).

%% --- What each validator accepts and refuses --------------------------------

validators_test_() ->
    with_platform([{binary_to_list(Name), fun() -> validator(Name) end} || Name <- ?EVENTS]).

validator(Name) ->
    Definition = definition(Name),
    Required = kapi_definition:required_headers(Definition),
    Optional = kapi_definition:optional_headers(Definition),
    Message = full(Name),

    %% The test's message is the whole of the definition, so a header added
    %% to one and not the other is a failure here.
    ?assertEqual(lists:sort(Required ++ Optional), lists:sort(proplists:get_keys(message(Name)))),

    %% Well formed, as a proplist and as the object a listener is handed.
    ?assert(valid(Name, Message)),
    ?assert(valid(Name, {Message})),
    Exported = binary_to_atom(<<Name/binary, "_v">>, 'utf8'),
    ?assert(kapi_callcenter:Exported(Message)),

    %% Every required header is required, and every optional one is not.
    [?assertNot(valid(Name, lists:keydelete(Header, 1, Message))) || Header <- Required],
    [?assert(valid(Name, lists:keydelete(Header, 1, Message))) || Header <- Optional],
    %% Nor is any of the headers every message carries optional.
    [?assertNot(valid(Name, lists:keydelete(Header, 1, Message))) || Header <- ?DEFAULT_HEADERS],

    %% An enumerated header takes each of its values and nothing else.
    [begin
         [?assert(valid(Name, lists:keystore(Key, 1, Message, {Key, Value}))) || Value <- Allowed],
         ?assertNot(valid(Name, lists:keystore(Key, 1, Message, {Key, <<"not_one_of_them">>})))
     end
     || {Key, Allowed} <- kapi_definition:values(Definition),
        is_list(Allowed)
    ],
    ?assertNot(valid(Name, lists:keystore(<<"Event-Name">>, 1, Message, {<<"Event-Name">>, <<"other">>}))),
    ?assertNot(valid(Name, lists:keystore(<<"Event-Category">>, 1, Message, {<<"Event-Category">>, <<"call_event">>}))),

    %% A typed header refuses a value of the wrong type.
    [?assertNot(valid(Name, lists:keystore(Key, 1, Message, {Key, wrong_type(Check)})))
     || {Key, Check} <- kapi_definition:types(Definition)
    ],

    %% The builder builds what the validator accepts, and nothing else.
    Build = kapi_definition:build_fun(Definition),
    ?assertMatch({'ok', _}, Build(Message)),
    [?assertMatch({'error', _}, Build(lists:keydelete(Header, 1, Message))) || Header <- Required].

wrong_type(Check) ->
    case Check(<<"text">>) of
        'true' -> 12345;
        'false' -> <<"text">>
    end.

%% A caller being offered carries the agents ringing, which may be none but
%% is always a list of ids.
agent_ids_test_() ->
    with_platform(
      fun() ->
              Message = full(<<"member_offer">>),
              ?assert(valid(<<"member_offer">>, lists:keystore(<<"Agent-IDs">>, 1, Message, {<<"Agent-IDs">>, [<<"a">>, <<"b">>]}))),
              ?assertNot(valid(<<"member_offer">>, lists:keystore(<<"Agent-IDs">>, 1, Message, {<<"Agent-IDs">>, [<<>>]}))),
              ?assertNot(valid(<<"member_offer">>, lists:keystore(<<"Agent-IDs">>, 1, Message, {<<"Agent-IDs">>, [1]})))
      end).

%% --- Where each publisher sends ---------------------------------------------

publishers_test_() ->
    with_platform(
      [{"a caller goes to their shard's queue, persistent and mandatory"
       ,fun() ->
                sent(fun() -> kapi_callcenter:publish_member_call(7, full(<<"member_call">>)) end),
                [{'basic_publish', [<<>>, <<"callcenter.member.7">>, Payload, <<"application/json">>, Props]}] =
                    platform_fakes:calls('kz_amqp_util'),
                ?assertEqual(<<"member_call">>, kz_json:get_value(<<"Event-Name">>, Payload)),
                ?assertEqual(2, proplists:get_value('delivery_mode', Props)),
                ?assertEqual('true', proplists:get_value('mandatory', Props))
        end}
      ,{"a caller built for the confirming publisher is the message published, and nothing is sent"
       ,fun() ->
                platform_fakes:clear(),
                Req = full(<<"member_call">>),
                'ok' = kapi_callcenter:publish_member_call(<<"7">>, Req),
                [{'basic_publish', Published}] = platform_fakes:calls('kz_amqp_util'),
                platform_fakes:clear(),
                {{'prepared', <<>>, <<"callcenter.member.7">>, <<"application/json">>, Props}, Payload} =
                    kapi_callcenter:prepare_member_call(<<"7">>, Req),
                [{'prepare_basic_publish', Prepared}] = platform_fakes:calls('kz_amqp_util'),
                ?assertEqual(Published, Prepared),
                ?assertEqual(<<"member_call">>, kz_json:get_value(<<"Event-Name">>, Payload)),
                ?assertEqual(2, proplists:get_value('delivery_mode', Props)),
                ?assertEqual('true', proplists:get_value('mandatory', Props))
        end}
      ,{"a cancel follows the caller onto the same queue, persistent and not mandatory"
       ,fun() ->
                sent(fun() -> kapi_callcenter:publish_member_cancel(7, full(<<"member_cancel">>)) end),
                [{'basic_publish', [<<>>, <<"callcenter.member.7">>, _Payload, _, Props]}] =
                    platform_fakes:calls('kz_amqp_util'),
                ?assertEqual(2, proplists:get_value('delivery_mode', Props)),
                ?assertEqual('undefined', proplists:get_value('mandatory', Props))
        end}
      ,{"events go to the exchange under their family's key"
       ,fun() ->
                Expect = [{<<"member_offer">>, call}
                         ,{<<"member_connected">>, call}
                         ,{<<"member_result">>, call}
                         ,{<<"member_position">>, call}
                         ,{<<"agent_availability">>, agent}
                         ,{<<"agent_activity">>, agent}
                         ,{<<"agent_offer">>, agent}
                         ,{<<"agent_answered">>, agent}
                         ,{<<"agent_wrapup">>, agent}
                         ,{<<"queue_stats">>, queue}
                         ],
                [begin
                     Publish = binary_to_atom(<<"publish_", Name/binary>>, 'utf8'),
                     sent(fun() -> kapi_callcenter:Publish(full(Name)) end),
                     [{<<"callcenter">>, Key}] = platform_fakes:published(),
                     ?assertEqual(family_key(Family), Key)
                 end
                 || {Name, Family} <- Expect
                ]
        end}
      ,{"a status request goes to the account's status key"
       ,fun() ->
                sent(fun() -> kapi_callcenter:publish_status_req(full(<<"status_req">>)) end),
                ?assertEqual([{<<"callcenter">>, <<"callcenter.status.", ?ACCOUNT/binary>>}]
                            ,platform_fakes:published()
                            )
        end}
      ,{"a status answer goes to the requester's own queue"
       ,fun() ->
                sent(fun() -> kapi_callcenter:publish_status_resp(<<"requester-q">>, full(<<"status_resp">>)) end),
                ?assertEqual([<<"requester-q">>], platform_fakes:targeted())
        end}
      ,{"a pickup request goes to the account's pickup key, not its status key"
       ,fun() ->
                sent(fun() -> kapi_callcenter:publish_pickup_req(full(<<"pickup_req">>)) end),
                ?assertEqual([{<<"callcenter">>, <<"callcenter.pickup.", ?ACCOUNT/binary>>}]
                            ,platform_fakes:published()
                            )
        end}
      ,{"a pickup answer goes to the requester's own queue"
       ,fun() ->
                sent(fun() -> kapi_callcenter:publish_pickup_resp(<<"requester-q">>, full(<<"pickup_resp">>)) end),
                ?assertEqual([<<"requester-q">>], platform_fakes:targeted())
        end}
      ,{"the four caller events reach the callflow at its controller queue, and nothing else does"
       ,fun() ->
                [begin
                     sent(fun() -> kapi_callcenter:publish_caller_event(<<"pid://<0.1.0>/cf">>, full(Name)) end),
                     ?assertEqual([<<"pid://<0.1.0>/cf">>], platform_fakes:targeted())
                 end
                 || Name <- [<<"member_offer">>, <<"member_position">>, <<"member_connected">>, <<"member_result">>]
                ],
                platform_fakes:clear(),
                ?assertError({'not_a_caller_event', <<"agent_offer">>}
                            ,kapi_callcenter:publish_caller_event(<<"q">>, full(<<"agent_offer">>))
                            ),
                ?assertEqual([], platform_fakes:calls('kz_amqp_util'))
        end}
      ,{"a message its definition refuses is not published"
       ,fun() ->
                platform_fakes:clear(),
                Missing = lists:keydelete(<<"Position">>, 1, full(<<"member_position">>)),
                ?assertError({'badmatch', {'error', _}}, kapi_callcenter:publish_member_position(Missing)),
                ?assertEqual([], platform_fakes:calls('kz_amqp_util'))
        end}
      ,{"the exchange is a durable topic exchange"
       ,fun() ->
                platform_fakes:clear(),
                'ok' = kapi_callcenter:declare_exchanges(),
                ?assertEqual([{'new_exchange', [<<"callcenter">>, <<"topic">>, [{'durable', 'true'}]]}]
                            ,platform_fakes:calls('kz_amqp_util')
                            )
        end}
      ]).

%% Run a publish on a clean record.
sent(Publish) ->
    platform_fakes:clear(),
    'ok' = Publish().

family_key(call) -> kapi_callcenter:call_routing_key(?ACCOUNT, ?CALL);
family_key(agent) -> kapi_callcenter:agent_routing_key(?ACCOUNT, ?AGENT);
family_key(queue) -> kapi_callcenter:queue_routing_key(?ACCOUNT, ?QUEUE).

member_queue_test_() ->
    with_platform(
      [?_assertEqual(<<"callcenter.member.0">>, kapi_callcenter:member_queue(0))
      ,?_assertEqual(<<"callcenter.member.63">>, kapi_callcenter:member_queue(63))
      ,?_assertEqual(<<"callcenter.member.63">>, kapi_callcenter:member_queue(<<"63">>))
      ]).

%% --- What the bindings bind -------------------------------------------------

bindings_test_() ->
    with_platform(
      [{"with nothing said, every family of every account"
       ,?_assertEqual([<<"callcenter.call.*.*">>, <<"callcenter.agent.*.*">>
                      ,<<"callcenter.queue.*.*">>, <<"callcenter.status.*">>
                      ]
                     ,kapi_callcenter:binding_keys([])
                     )}
      ,{"one family of one account, spelled as an atom or as Gleam hands it over"
       ,fun() ->
                Expected = [<<"callcenter.agent.", ?ACCOUNT/binary, ".*">>],
                ?assertEqual(Expected, kapi_callcenter:binding_keys([{'restrict_to', ['agent']}, {'account_id', ?ACCOUNT}])),
                ?assertEqual(Expected, kapi_callcenter:binding_keys([{'restrict_to', [<<"agent">>]}, {'account_id', ?ACCOUNT}]))
        end}
      ,{"an id narrows only its own family"
       ,?_assertEqual([<<"callcenter.queue.", ?ACCOUNT/binary, ".", ?QUEUE/binary>>
                      ,<<"callcenter.agent.", ?ACCOUNT/binary, ".*">>
                      ,<<"callcenter.status.", ?ACCOUNT/binary>>
                      ]
                     ,kapi_callcenter:binding_keys([{'restrict_to', ['queue', 'agent', 'status']}
                                                   ,{'account_id', ?ACCOUNT}
                                                   ,{'queue_id', ?QUEUE}
                                                   ])
                     )}
      ,{"the pickup family only when it is asked for, by the account"
       ,?_assertEqual([<<"callcenter.pickup.", ?ACCOUNT/binary>>]
                     ,kapi_callcenter:binding_keys([{'restrict_to', [<<"pickup">>]}
                                                   ,{'account_id', ?ACCOUNT}
                                                   ])
                     )}
      ,{"bind and unbind the same keys on the callcenter exchange"
       ,fun() ->
                platform_fakes:clear(),
                Props = [{'restrict_to', ['call', 'status']}, {'account_id', ?ACCOUNT}],
                'ok' = kapi_callcenter:bind_q(<<"q1">>, Props),
                'ok' = kapi_callcenter:unbind_q(<<"q1">>, Props),
                Keys = kapi_callcenter:binding_keys(Props),
                ?assertEqual([{'bind_q_to_exchange', [<<"q1">>, Key, <<"callcenter">>]} || Key <- Keys]
                             ++ [{'unbind_q_from_exchange', [<<"q1">>, Key, <<"callcenter">>]} || Key <- Keys]
                            ,platform_fakes:calls('kz_amqp_util')
                            )
        end}
      ]).

%% --- The schemas Crossbar documents -----------------------------------------

schemas_test_() ->
    with_platform(
      [{"one schema per definition, and no schema for an event nobody sends"
       ,?_assertEqual(lists:sort([<<"kapi.callcenter.", Name/binary, ".json">> || Name <- ?EVENTS])
                     ,lists:sort([list_to_binary(filename:basename(F))
                                  || F <- filelib:wildcard(?SCHEMAS ++ "/kapi.callcenter.*.json")
                                 ])
                     )}
      | [{binary_to_list(Name), fun() -> schema_agrees(Name) end} || Name <- ?EVENTS]
      ]).

schema_agrees(Name) ->
    {'ok', Json} = file:read_file(?SCHEMAS ++ "/kapi.callcenter." ++ binary_to_list(Name) ++ ".json"),
    Schema = json:decode(Json),
    Definition = definition(Name),
    Required = kapi_definition:required_headers(Definition),
    Optional = kapi_definition:optional_headers(Definition),
    Properties = maps:get(<<"properties">>, Schema),
    ?assertEqual(<<"kapi.callcenter.", Name/binary>>, maps:get(<<"_id">>, Schema)),
    ?assertEqual(lists:sort(Required), lists:sort(maps:get(<<"required">>, Schema, []))),
    ?assertEqual(lists:sort([<<"Event-Category">>, <<"Event-Name">> | Required ++ Optional])
                ,lists:sort(maps:keys(Properties))
                ),
    %% The same values, in the same order.
    [?assertEqual({Key, Allowed}, {Key, maps:get(<<"enum">>, maps:get(Key, Properties))})
     || {Key, Allowed} <- kapi_definition:values(Definition),
        is_list(Allowed)
    ],
    ?assertEqual([<<"callcenter">>], enum(<<"Event-Category">>, Properties)),
    ?assertEqual([Name], enum(<<"Event-Name">>, Properties)),
    %% And the same types.
    [?assertEqual({Key, json_type(Check)}, {Key, schema_type(Check, maps:get(Key, Properties))})
     || {Key, Check} <- kapi_definition:types(Definition)
    ].

enum(Key, Properties) -> maps:get(<<"enum">>, maps:get(Key, Properties)).

json_type(Check) ->
    case fun_name(Check) of
        'is_binary' -> <<"string">>;
        'is_integer' -> <<"integer">>;
        'is_boolean' -> <<"boolean">>;
        'is_list' -> <<"array">>;
        'is_ne_binaries' -> {<<"array">>, <<"string">>};
        'is_json_object' -> <<"object">>
    end.

%% The function a fun names: `fun m:f/1' is `f', and a local `fun f/1' is
%% compiled to one named `-fun.f/1-'.
fun_name(Fun) ->
    {'name', Name} = erlang:fun_info(Fun, 'name'),
    case atom_to_list(Name) of
        "-fun." ++ Rest ->
            [Local | _] = string:split(Rest, "/"),
            list_to_atom(Local);
        _ -> Name
    end.

%% A list of ids is an array of strings; any other list only an array.
schema_type(Check, #{<<"type">> := <<"array">>} = Property) ->
    case fun_name(Check) of
        'is_ne_binaries' ->
            {<<"array">>, maps:get(<<"type">>, maps:get(<<"items">>, Property, #{}), 'undefined')};
        _ -> <<"array">>
    end;
schema_type(_Check, #{<<"type">> := Type}) -> Type.
