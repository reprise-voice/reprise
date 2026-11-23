%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang side of `stir/inbound' and `cf_stir_shaken': the parts of
%%% the inbound call path Gleam cannot express.
%%%
%%% `call_safely/1' is the one guard between a caller on the call path and a
%%% raise: whatever `verify/1' does, the Erlang caller sees `{ok, Ccvs}' or
%%% `{error, Reason}'. The log line names the class and the reason and
%%% nothing else -- the facts hold the Identity header, which a hostile peer
%%% chose the size of.
%%%
%%% `set_caller_id_name/2' is the setter `kazoo/call' does not have. On a
%%% node with a release it is `kapps_call:set_caller_id_name/2', which
%%% changes the record and sends the `set' command to the channel; outside
%%% one, the call is the JSON map `kazoo_gleam_call_ffi' wraps, and the name
%%% is written into it so the accessor reads it back.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
-module(stir_inbound_ffi).

-export([call_safely/1
        ,set_caller_id_name/2
        ]).

%% The call outside a release, as `kazoo_gleam_call_ffi' represents it.
-define(FAKE(Map), {'kazoo_gleam_call', Map}).

-spec call_safely(fun(() -> Answer)) -> {'ok', Answer} | {'error', binary()}.
call_safely(Fun) ->
    try
        {'ok', Fun()}
    catch
        Class:Reason ->
            log_error(Class, Reason),
            {'error', <<"crash">>}
    end.

-spec set_caller_id_name(any(), binary()) -> any().
set_caller_id_name(?FAKE(Map), Name) ->
    ?FAKE(Map#{<<"Caller-ID-Name">> => Name});
set_caller_id_name(Call, Name) ->
    case code:ensure_loaded('kapps_call') of
        {'module', 'kapps_call'} -> kapps_call:set_caller_id_name(Name, Call);
        {'error', _Reason} -> Call
    end.

%% A class and a reason, with the reason cut short: an exception out of a
%% decoder carries the value it choked on, and that value is the peer's.
log_error(Class, Reason) ->
    Text = iolist_to_binary(io_lib:format("~0p", [Reason])),
    Short = case byte_size(Text) > 200 of
                'true' -> <<(binary:part(Text, 0, 200))/binary, "...">>;
                'false' -> Text
            end,
    Line = iolist_to_binary(io_lib:format("stir: inbound verification crashed: ~p: ~s", [Class, Short])),
    case code:ensure_loaded('lager') of
        {'module', 'lager'} -> lager:log('error', self(), "~s", [Line]);
        {'error', _} -> logger:error("~s", [Line])
    end.
