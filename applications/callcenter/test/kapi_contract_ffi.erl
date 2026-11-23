%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% What the Gleam side of the contract tests asks of `kapi_callcenter', with
%% `platform_fakes' loaded: the values a definition allows, whether a
%% message a Gleam producer built is one its definition accepts, and what
%% went out through the fake broker.
-module(kapi_contract_ffi).

-export([allowed/2, valid/2, published_events/0, published_values/2, rejected/0]).

%% The values one header of one event may take.
-spec allowed(binary(), binary()) -> [binary()].
allowed(EventName, Header) ->
    Definition = kapi_callcenter:api_definition(EventName),
    {Header, Values} = lists:keyfind(Header, 1, kapi_definition:values(Definition)),
    Values.

%% A message as JSON, with the headers every message on the bus carries
%% added where it left them out, through the event's own validator.
-spec valid(binary(), binary()) -> boolean().
valid(EventName, Json) ->
    {Props} = kz_json:from_map(json:decode(Json)),
    Filled = lists:foldl(fun({Key, _} = Header, Acc) ->
                                 case lists:keymember(Key, 1, Acc) of
                                     'true' -> Acc;
                                     'false' -> [Header | Acc]
                                 end
                         end
                        ,Props
                        ,callcenter_messages:defaults(EventName)
                        ),
    Validate = kapi_definition:validate_fun(kapi_callcenter:api_definition(EventName)),
    Validate(Filled).

%% Every event that went out, from any process, as `#(where, name)':
%% `exchange' for the `callcenter' exchange, `caller' for a callflow's
%% controller queue.
-spec published_events() -> [{binary(), binary()}].
published_events() ->
    [{where(Function), kz_json:get_value(<<"Event-Name">>, Payload)}
     || {Function, Args} <- platform_fakes:all_calls('kz_amqp_util'),
        Payload <- payload(Function, Args)
    ].

%% One header of every event of one name that went out, as `#(where, value)'.
-spec published_values(binary(), binary()) -> [{binary(), binary()}].
published_values(EventName, Header) ->
    [{where(Function), kz_json:get_value(Header, Payload)}
     || {Function, Args} <- platform_fakes:all_calls('kz_amqp_util'),
        Payload <- payload(Function, Args),
        kz_json:get_value(<<"Event-Name">>, Payload) =:= EventName
    ].

where('basic_publish') -> <<"exchange">>;
where('targeted_publish') -> <<"caller">>.

payload('basic_publish', [<<"callcenter">>, _Key, Payload | _]) -> [Payload];
payload('targeted_publish', [_Queue, Payload | _]) -> [Payload];
payload(_Function, _Args) -> [].

%% Every publish a definition refused, as the event and why.
-spec rejected() -> [binary()].
rejected() ->
    [iolist_to_binary(io_lib:format("~s: ~p", [event_name(Req), Reason]))
     || {'rejected', [Req, Reason]} <- platform_fakes:all_calls('kz_amqp_worker')
    ].

event_name({_} = JObj) -> kz_json:get_value(<<"Event-Name">>, JObj);
event_name(Props) when is_list(Props) -> proplists:get_value(<<"Event-Name">>, Props).
