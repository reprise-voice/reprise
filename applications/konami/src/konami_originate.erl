%%% @copyright (C) 2026, Vonix LLC
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. See https://mozilla.org/MPL/2.0/.
-module(konami_originate).

-export([control/1, event_key/1, timeout_seconds/1]).

-include("konami.hrl").

%% A successful current response owns its Call-ID and Control-Queue together.
%% An originate_uuid is only a fallback for older producers; never combine a
%% queue from one call with the identity from another response.
-spec control(kz_json:objects()) -> {'ok', binary(), binary()} | {'error', 'no_control'}.
control(Results) ->
    Responses = [J || J <- Results, kapi_resource:originate_resp_v(J)
                     ,kz_json:get_value(<<"Application-Response">>, J) =:= <<"SUCCESS">>],
    control_responses(Responses, Results).

control_responses([], _Results) -> {'error', 'no_control'};
control_responses([Resp | Rest], Results) ->
    Id = kz_json:get_ne_binary_value(<<"Call-ID">>, Resp),
    case kz_json:get_ne_binary_value(<<"Control-Queue">>, Resp) of
        Q when is_binary(Id), is_binary(Q) -> {'ok', Id, Q};
        _ ->
            Queues = [Q || J <- Results, kapi_resource:originate_uuid_v(J)
                           ,is_binary(Id)
                           ,kz_json:get_value(<<"Outbound-Call-ID">>, J) =:= Id
                           ,Q <- [kz_json:get_ne_binary_value(<<"Outbound-Call-Control-Queue">>, J)]
                           ,is_binary(Q)],
            case lists:usort(Queues) of
                [Q] -> {'ok', Id, Q};
                _ -> control_responses(Rest, Results)
            end
    end.

%% Originate replies can describe a replacement Call-ID. Route them using the
%% original request identity; ordinary call events retain their own Call-ID.
-spec event_key(kz_json:object()) -> kz_term:api_binary().
event_key(JObj) ->
    case kz_api:event_name(JObj) of
        <<"originate_", _/binary>> ->
            kz_json:get_first_defined([<<"Outbound-Call-ID">>, <<"Msg-ID">>, <<"Call-ID">>], JObj);
        _ -> kz_call_event:call_id(JObj)
    end.

-spec timeout_seconds(integer()) -> pos_integer().
timeout_seconds(Milliseconds) when is_integer(Milliseconds), Milliseconds > 0 ->
    (Milliseconds + ?MILLISECONDS_IN_SECOND - 1) div ?MILLISECONDS_IN_SECOND;
timeout_seconds(_) -> 20.
